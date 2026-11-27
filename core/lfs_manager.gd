@tool
extends RefCounted

## Owns the repository snapshot and runs every git operation off the main thread.
## All public methods must be called from the main thread; callbacks and signals
## are always delivered on the main thread.

const GitTypes = preload("git_types.gd")
const GitCLI = preload("git_cli.gd")

signal snapshot_updated(snapshot: GitTypes.RepoSnapshot)
signal operation_started(op_name: String)
signal operation_completed(op_name: String, success: bool, message: String)
signal hijacked_staged_detected(hijacked_items: Array[GitTypes.FileStatusItem])

var cli: GitCLI
var current_snapshot: GitTypes.RepoSnapshot
var is_refreshing: bool = false

var _refresh_queued: bool = false
var _pending_callbacks: Array[Callable] = []
var _lockable_cache: Dictionary = {}  # repo path -> bool, main thread only

func _init(base_dir: String = ""):
	cli = GitCLI.new(base_dir)
	current_snapshot = GitTypes.RepoSnapshot.new()

# =========================================================================
# REFRESH
# =========================================================================

## Refresh status, locks and lock states in the background.
## If a refresh is already running, another one runs after it, and callback(snapshot)
## is called once the up-to-date snapshot is ready.
func refresh_async(callback: Callable = Callable()) -> void:
	if callback.is_valid():
		_pending_callbacks.append(callback)
	if is_refreshing:
		_refresh_queued = true
		return
	_start_refresh()

func _start_refresh() -> void:
	is_refreshing = true
	_refresh_queued = false
	operation_started.emit("Refreshing Status")
	WorkerThreadPool.add_task(func():
		var snapshot := _build_snapshot_sync()
		_on_snapshot_ready.call_deferred(snapshot)
	)

func _on_snapshot_ready(snapshot: GitTypes.RepoSnapshot) -> void:
	is_refreshing = false
	if _refresh_queued:
		# Something changed while this snapshot was being built; it may be stale.
		_start_refresh()
		return

	current_snapshot = snapshot
	_lockable_cache.clear()
	snapshot_updated.emit(current_snapshot)
	operation_completed.emit("Refresh", true, "Status updated")

	var staged_hijacked: Array[GitTypes.FileStatusItem] = []
	for f in current_snapshot.staged_files:
		if f.lock_state == GitTypes.LockState.HIJACKED:
			staged_hijacked.append(f)
	if not staged_hijacked.is_empty():
		hijacked_staged_detected.emit(staged_hijacked)

	var callbacks := _pending_callbacks.duplicate()
	_pending_callbacks.clear()
	for cb in callbacks:
		if cb.is_valid():
			cb.call(current_snapshot)

## Runs on a worker thread. Only touches `cli` and the new snapshot.
func _build_snapshot_sync() -> GitTypes.RepoSnapshot:
	var snapshot := GitTypes.RepoSnapshot.new()
	snapshot.is_repo = cli.is_repo()
	if not snapshot.is_repo:
		return snapshot

	var user := cli.get_user_info()
	snapshot.current_user_name = user.name
	snapshot.current_user_email = user.email

	# 1. Server locks
	var lock_res := cli.get_lfs_locks(user.name, user.email)
	snapshot.lock_error = lock_res.error
	for lock in lock_res.locks:
		snapshot.active_server_locks[lock.path] = lock

	# 2. Working tree and index status
	var status := cli.get_status()
	snapshot.branch_name = status.branch.head
	snapshot.upstream_name = status.branch.upstream
	snapshot.ahead_count = status.branch.ahead
	snapshot.behind_count = status.branch.behind

	# 3. Lockable attribute for every changed or locked path
	var to_check := PackedStringArray()
	for entry in status.entries:
		to_check.append(entry.path)
	for l_path in snapshot.active_server_locks:
		if not to_check.has(l_path):
			to_check.append(l_path)
	snapshot.lockable = cli.check_lockable_attributes(to_check)

	# 4. File items
	for entry in status.entries:
		var p: String = entry.path
		var is_new: bool = entry.index == "?" or entry.index == "A"

		var item := GitTypes.FileStatusItem.new()
		item.path = p
		item.res_path = cli.to_res_path(p)
		item.is_lockable = snapshot.lockable.get(p, false)
		item.change_state = _code_to_change_state(entry.work if entry.work != " " else entry.index)
		if is_new:
			item.change_state = GitTypes.ChangeState.UNTRACKED if entry.index == "?" else GitTypes.ChangeState.ADDED

		var lock: GitTypes.LockRecord = snapshot.active_server_locks.get(p, null)
		if lock != null:
			item.lock_owner = lock.owner
			item.lock_id = lock.id

		if lock != null and lock.is_mine:
			item.lock_state = GitTypes.LockState.LOCKED_BY_ME
		elif item.is_lockable and is_new:
			# Not in HEAD yet: nobody can hold its lock, so committing it is fine.
			item.lock_state = GitTypes.LockState.NEW_FILE
		elif item.is_lockable:
			# Changed without holding the lock (unlocked, or locked by someone else).
			item.lock_state = GitTypes.LockState.HIJACKED
		elif lock != null:
			item.lock_state = GitTypes.LockState.LOCKED_BY_OTHER
		else:
			item.lock_state = GitTypes.LockState.NOT_LOCKABLE

		if entry.index != " " and entry.index != "?":
			var staged_item := item.duplicate_item()
			staged_item.staged_state = GitTypes.StagedState.STAGED
			staged_item.change_state = _code_to_change_state(entry.index)
			snapshot.staged_files.append(staged_item)

		if entry.work != " ":
			var work_item := item.duplicate_item()
			work_item.staged_state = GitTypes.StagedState.UNSTAGED
			if work_item.lock_state == GitTypes.LockState.HIJACKED:
				snapshot.hijacked_files.append(work_item)
			else:
				snapshot.working_files.append(work_item)

		snapshot.changed_files[p] = item

	# 5. Files locked by others, whether or not they're changed locally
	for l_path in snapshot.active_server_locks:
		var l: GitTypes.LockRecord = snapshot.active_server_locks[l_path]
		if l.is_mine:
			continue
		var other_item := GitTypes.FileStatusItem.new()
		other_item.path = l_path
		other_item.res_path = cli.to_res_path(l_path)
		other_item.is_lockable = true
		other_item.lock_state = GitTypes.LockState.LOCKED_BY_OTHER
		other_item.lock_owner = l.owner
		other_item.lock_id = l.id
		snapshot.locked_by_other_files.append(other_item)

	return snapshot

func _code_to_change_state(code: String) -> GitTypes.ChangeState:
	match code:
		"M": return GitTypes.ChangeState.MODIFIED
		"A": return GitTypes.ChangeState.ADDED
		"D": return GitTypes.ChangeState.DELETED
		"R", "C": return GitTypes.ChangeState.RENAMED
		"?": return GitTypes.ChangeState.UNTRACKED
		"U": return GitTypes.ChangeState.CONFLICTED
		_: return GitTypes.ChangeState.MODIFIED

# =========================================================================
# QUERIES (main thread)
# =========================================================================

## Whether a path is lockable. Uses the snapshot when it can; otherwise asks git once
## and caches the answer until the next refresh.
func is_path_lockable(path: String) -> bool:
	var repo_path := cli.to_repo_path(path)
	if current_snapshot.lockable.has(repo_path):
		return current_snapshot.lockable[repo_path]
	if not _lockable_cache.has(repo_path):
		_lockable_cache[repo_path] = cli.is_path_lockable(repo_path)
	return _lockable_cache[repo_path]

func get_lock(path: String) -> GitTypes.LockRecord:
	return current_snapshot.active_server_locks.get(cli.to_repo_path(path), null)

func get_changed_item(path: String) -> GitTypes.FileStatusItem:
	return current_snapshot.changed_files.get(cli.to_repo_path(path), null)

func is_file_hijacked(path: String) -> bool:
	var item := get_changed_item(path)
	return item != null and item.lock_state == GitTypes.LockState.HIJACKED

# =========================================================================
# ACTIONS
# =========================================================================

## Run work() on a worker thread, refresh, then report on the main thread.
## work() must return a result Dictionary from GitCLI.
## callback(success: bool, message: String)
func _run_op(started_label: String, op_name: String, work: Callable, callback: Callable, ok_message: String = "") -> void:
	operation_started.emit(started_label)
	WorkerThreadPool.add_task(func():
		var res: Dictionary = work.call()
		_finish_op.call_deferred(op_name, res, ok_message, callback)
	)

func _finish_op(op_name: String, res: Dictionary, ok_message: String, callback: Callable) -> void:
	var success: bool = res.success
	var message: String = ok_message if success and not ok_message.is_empty() else res.output
	refresh_async(func(_s):
		operation_completed.emit(op_name, success, message)
		if callback.is_valid():
			callback.call(success, message)
	)

func _fail_now(op_name: String, message: String, callback: Callable) -> void:
	operation_completed.emit(op_name, false, message)
	if callback.is_valid():
		callback.call(false, message)

## Check out (lock) a file on the LFS server
func checkout_file(path: String, callback: Callable = Callable()) -> void:
	_run_op("Locking " + path, "Lock File", func(): return cli.lock_file(path), callback, "Locked")

## Release a lock on the LFS server
func unlock_file(path: String, force: bool = false, callback: Callable = Callable()) -> void:
	_run_op("Unlocking " + path, "Unlock File", func(): return cli.unlock_file(path, force), callback, "Unlocked")

## Make a file writable locally without taking its lock
func hijack_file(path: String, callback: Callable = Callable()) -> void:
	_run_op("Hijacking " + path, "Hijack File", func(): return cli.hijack_file(path), callback)

## Discard local changes. New files are moved to the trash.
func revert_file(path: String, callback: Callable = Callable()) -> void:
	revert_files(PackedStringArray([path]), callback)

func revert_files(paths: PackedStringArray, callback: Callable = Callable()) -> void:
	# Gather what each file needs on the main thread, where the snapshot lives.
	var jobs: Array[Dictionary] = []
	for p in paths:
		var item := get_changed_item(p)
		var lock := get_lock(p)
		jobs.append({
			"path": cli.to_repo_path(p),
			"is_new": item != null and item.is_new(),
			"keep_writable": lock != null and lock.is_mine,
		})
	var label: String = "Reverting " + (jobs[0].path if jobs.size() == 1 else "%d files" % jobs.size())
	_run_op(label, "Revert", func():
		for job in jobs:
			var res: Dictionary = cli.revert_file(job.path, job.is_new, job.keep_writable)
			if not res.success:
				return res
		return cli._ok("Reverted")
	, callback)

## Stage a file. Hijacked files are refused: take the lock first.
func stage_file(path: String, callback: Callable = Callable()) -> void:
	var repo_path := cli.to_repo_path(path)
	if is_file_hijacked(repo_path):
		_fail_now("Stage Blocked", "Cannot stage hijacked file '%s'. Check it out (take the lock) first." % repo_path, callback)
		return
	_run_op("Staging " + repo_path, "Stage", func(): return cli.stage_files(PackedStringArray([repo_path])), callback, "Staged")

## Stage every change except hijacked files
func stage_all_valid_changes(callback: Callable = Callable()) -> void:
	var paths := PackedStringArray()
	for item in current_snapshot.working_files:
		paths.append(item.path)
	_run_op("Staging Changes", "Stage All", func(): return cli.stage_files(paths), callback, "Staged all valid changes")

func unstage_file(path: String, callback: Callable = Callable()) -> void:
	_run_op("Unstaging " + path, "Unstage", func(): return cli.unstage_files(PackedStringArray([path])), callback, "Unstaged")

## Unstage every staged hijacked file
func unstage_all_hijacked(callback: Callable = Callable()) -> void:
	var paths := PackedStringArray()
	for f in current_snapshot.staged_files:
		if f.lock_state == GitTypes.LockState.HIJACKED:
			paths.append(f.path)
	_run_op("Unstaging Hijacked Files", "Unstage Hijacked", func(): return cli.unstage_files(paths), callback, "Unstaged hijacked files")

func unstage_all(callback: Callable = Callable()) -> void:
	_run_op("Unstaging All", "Unstage All", func(): return cli.unstage_all(), callback, "Unstaged all")

func commit(message: String, callback: Callable = Callable()) -> void:
	if message.strip_edges().is_empty():
		_fail_now("Commit", "Commit message cannot be empty", callback)
		return
	_run_op("Committing", "Commit", func(): return cli.commit(message), callback, "Committed")

func push(callback: Callable = Callable()) -> void:
	_run_op("Pushing to remote", "Push", func(): return cli.push(), callback, "Pushed")

func pull(callback: Callable = Callable()) -> void:
	_run_op("Pulling latest changes", "Pull", func(): return cli.pull(), callback, "Pulled latest")

func fetch(callback: Callable = Callable()) -> void:
	_run_op("Fetching remote", "Fetch", func(): return cli.fetch(), callback, "Fetched")
