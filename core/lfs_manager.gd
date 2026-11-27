@tool
extends RefCounted

## Owns the repository snapshot and runs every git operation off the main thread.
## All public methods must be called from the main thread; callbacks and signals
## are always delivered on the main thread.

const GitTypes = preload("git_types.gd")
const GitCLI = preload("git_cli.gd")
const Changelists = preload("changelists.gd")

signal snapshot_updated(snapshot: GitTypes.RepoSnapshot)
signal operation_started(op_name: String)
signal operation_completed(op_name: String, success: bool, message: String)
signal hijacked_staged_detected(hijacked_items: Array[GitTypes.FileStatusItem])
## Git LFS isn't fully set up in this clone. fixable: install_lfs() can fix part of it.
signal lfs_setup_problem(problems: PackedStringArray, fixable: bool)

var cli: GitCLI
var changelists: Changelists
var current_snapshot: GitTypes.RepoSnapshot
var is_refreshing: bool = false

var _refresh_queued: bool = false
var _pending_callbacks: Array[Callable] = []
var _lockable_cache: Dictionary = {}  # repo path -> bool, main thread only

## The addon folder as a repo path (e.g. "game/addons/lfs_checkout"), for the hook
var addon_repo_dir: String = ""

func _init(base_dir: String = ""):
	cli = GitCLI.new(base_dir)
	current_snapshot = GitTypes.RepoSnapshot.new()
	# This script is in <addon>/core/
	var addon_res_dir: String = (get_script() as Script).resource_path.get_base_dir().get_base_dir()
	addon_repo_dir = cli.to_repo_path(addon_res_dir)
	changelists = Changelists.new()
	if cli.is_repo():
		changelists.load_from(cli.get_state_dir())
	else:
		changelists.load_from("")

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
	# Forget changelist assignments for files that are no longer changed or checked out
	var live := {}
	for f in snapshot.data_files:
		live[f.path] = true
	for p in changelists.shelved_paths():
		live[p] = true
	changelists.prune(live)
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

	# 0. Data workflow state
	snapshot.data_branches = cli.get_data_branches()
	snapshot.bypass_enabled = cli.is_bypass_enabled()
	snapshot.merge_in_progress = cli.is_merge_in_progress()
	snapshot.hook_state = cli.get_hook_state(addon_repo_dir)
	snapshot.lfs_setup = cli.get_lfs_setup()
	snapshot.allow_lock_on_code_branches = cli.get_allow_lock_on_code_branches()
	snapshot.primary_data_branch = cli.get_primary_data_branch(snapshot.data_branches)

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
	snapshot.on_data_branch = GitCLI.branch_matches(snapshot.branch_name, snapshot.data_branches)

	# 3. Lockable attribute for every changed or locked path, and for the asset
	#    each changed .import file belongs to
	var to_check := PackedStringArray()
	for entry in status.entries:
		to_check.append(entry.path)
		if (entry.path as String).ends_with(".import"):
			to_check.append((entry.path as String).trim_suffix(".import"))
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
		item.is_data = GitCLI.is_data_path(p, snapshot.lockable)
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
		if item.is_data:
			snapshot.data_files.append(item)

	# 5. Files locked by others, whether or not they're changed locally.
	#    Files you've checked out but not changed yet go in the changelists.
	for l_path in snapshot.active_server_locks:
		var l: GitTypes.LockRecord = snapshot.active_server_locks[l_path]
		if l.is_mine:
			if not snapshot.changed_files.has(l_path):
				var mine := GitTypes.FileStatusItem.new()
				mine.path = l_path
				mine.res_path = cli.to_res_path(l_path)
				mine.is_lockable = true
				mine.is_data = true
				mine.lock_state = GitTypes.LockState.LOCKED_BY_ME
				mine.lock_owner = l.owner
				mine.lock_id = l.id
				snapshot.data_files.append(mine)
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

## Check out (lock) a file on the LFS server, optionally into a changelist.
##
## On a data branch: only when you have the latest version of the file.
## On a code branch: only when .lfscheckout allows it. The data will be submitted
## to the primary data branch, so the file must match that branch on the server.
## If your copy is unchanged and older, it's replaced with the latest version first.
func checkout_file(path: String, callback: Callable = Callable(), changelist_id: String = "") -> void:
	var repo_path := cli.to_repo_path(path)
	_run_op("Locking " + repo_path, "Lock File", func():
		var branch := cli.get_current_branch()
		var patterns := cli.get_data_branches()
		var on_data := GitCLI.branch_matches(branch, patterns)
		var bypass := cli.is_bypass_enabled()
		if not on_data and not bypass and not cli.get_allow_lock_on_code_branches():
			return cli.result_fail("Can't check out %s on %s. Data changes go on a data branch (%s). Hijack the file instead to try a change locally." % [
				repo_path, branch if not branch.is_empty() else "a detached HEAD", ", ".join(patterns)])

		var primary := cli.get_primary_data_branch(patterns)
		var base := cli.get_data_base_ref(on_data or bypass, primary)
		var note := ""
		match cli.check_freshness(repo_path, base):
			"stale_clean":
				if on_data or bypass:
					return cli.result_fail("A newer version of %s is on the server. Pull before checking it out." % repo_path)
				var restored := cli.restore_from(base, repo_path)
				if not restored.success:
					return restored
				note = " (loaded the latest version from %s)" % base
			"stale_modified":
				return cli.result_fail("A newer version of %s is on %s, and your local edits are based on an older one. Revert them, or save a copy and reapply them after checking out." % [repo_path, base])

		var res := cli.lock_file(repo_path)
		if res.success:
			return cli.result_ok("Locked " + repo_path + note)
		return res
	, func(ok, msg):
		if ok and not changelist_id.is_empty():
			changelists.assign(PackedStringArray([repo_path]), changelist_id)
			_changelists_changed()
		if callback.is_valid():
			callback.call(ok, msg)
	)

## Release a lock on the LFS server.
## Refused while commits touching the file haven't been pushed: releasing the lock
## then would let someone else edit an older version. force skips that check.
func unlock_file(path: String, force: bool = false, callback: Callable = Callable()) -> void:
	_run_op("Unlocking " + path, "Unlock File", func():
		if not force and cli.has_unpushed_commits(path):
			return cli.result_fail("%s has commits that aren't pushed yet. Push them before releasing the lock." % cli.to_repo_path(path))
		return cli.unlock_file(path, force)
	, callback, "Unlocked")

## Turn the emergency bypass for the data branch rules on or off (this clone only)
func set_bypass(enabled: bool, callback: Callable = Callable()) -> void:
	_run_op("Changing bypass", "Bypass", func(): return cli.set_bypass(enabled), callback,
		"Data branch rules bypassed" if enabled else "Data branch rules enforced")

## Install or update the pre-commit hook
func install_hook(callback: Callable = Callable()) -> void:
	_run_op("Installing hook", "Install Hook", func(): return cli.install_hook(addon_repo_dir), callback)

## Install the hook if it's missing or outdated. Leaves a hook the addon didn't install alone.
func ensure_hook() -> void:
	WorkerThreadPool.add_task(func():
		if not cli.is_repo():
			return
		if cli.get_hook_state(addon_repo_dir) != "installed":
			# For a foreign hook this returns the instructions to add the check by hand
			_report_hook.call_deferred(cli.install_hook(addon_repo_dir))
	)

func _report_hook(res: Dictionary) -> void:
	if res.success:
		print("LFS Checkout: ", res.output)
	else:
		push_warning("LFS Checkout: " + res.output)
	refresh_async()

## Configure the LFS filter and add missing LFS hooks. Never replaces existing hooks.
func install_lfs(callback: Callable = Callable()) -> void:
	_run_op("Setting up Git LFS", "Set Up Git LFS", func(): return cli.install_lfs(), func(ok, msg):
		if ok:
			print("LFS Checkout: ", msg)
		if callback.is_valid():
			callback.call(ok, msg)
	)

## Check the Git LFS setup of this clone. If something is missing, warn in the
## Output panel and emit lfs_setup_problem so the user can be offered a fix.
func check_lfs_setup() -> void:
	WorkerThreadPool.add_task(func():
		if not cli.is_repo():
			return
		var setup := cli.get_lfs_setup()
		if not GitCLI.lfs_setup_ok(setup):
			_report_lfs_setup.call_deferred(setup)
	)

func _report_lfs_setup(setup: Dictionary) -> void:
	var problems := describe_lfs_problems(setup)
	push_warning("LFS Checkout: Git LFS isn't fully set up in this clone.\n  " + "\n  ".join(problems))
	lfs_setup_problem.emit(problems, GitCLI.lfs_setup_fixable(setup))

## One line per problem, for the Output panel and dialogs
func describe_lfs_problems(setup: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	if setup.is_empty():
		return lines
	if not setup.lfs_found:
		lines.append("Git LFS isn't installed (git lfs version failed). Install it from https://git-lfs.com.")
		return lines
	if not setup.filter_ok:
		lines.append("The Git LFS filter isn't configured, so LFS files are committed as normal git files.")
	if not setup.missing_hooks.is_empty():
		var missing: PackedStringArray = setup.missing_hooks
		var effects := PackedStringArray()
		var push_missing := "pre-push" in missing
		if push_missing:
			effects.append("pushes don't upload LFS files")
		if missing.size() > (1 if push_missing else 0):
			effects.append("lockable files aren't always made read-only")
		lines.append("Missing Git LFS hooks: %s, so %s." % [", ".join(missing), " and ".join(effects)])
	if not setup.foreign_hooks.is_empty():
		lines.append(cli.foreign_lfs_hooks_message(setup.foreign_hooks))
	return lines

## Staged data files that the data branch rules don't allow committing here
func get_blocked_staged_data() -> PackedStringArray:
	var blocked := PackedStringArray()
	var s := current_snapshot
	if s.can_commit_data() or s.merge_in_progress:
		# During a merge, the hook tells merged data from new edits.
		return blocked
	for f in s.staged_files:
		if f.is_data:
			blocked.append(f.path)
	return blocked

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
		return cli.result_ok("Reverted")
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
	var blocked := get_blocked_staged_data()
	if not blocked.is_empty():
		_fail_now("Commit", "Data files can only be committed on a data branch (%s). Unstage these or switch branches:\n  %s" % [
			", ".join(current_snapshot.data_branches), "\n  ".join(blocked)], callback)
		return
	_run_op("Committing", "Commit", func(): return cli.commit(message), callback, "Committed")

func push(callback: Callable = Callable()) -> void:
	_run_op("Pushing to remote", "Push", func(): return cli.push(), callback, "Pushed")

func pull(callback: Callable = Callable()) -> void:
	_run_op("Pulling latest changes", "Pull", func(): return cli.pull(), callback, "Pulled latest")

func fetch(callback: Callable = Callable()) -> void:
	_run_op("Fetching remote", "Fetch", func(): return cli.fetch(), callback, "Fetched")

# =========================================================================
# CHANGELISTS
# =========================================================================

const PENDING_PREFIX := "Committed, but "

## Redraw anything showing changelists, without waiting for a refresh
func _changelists_changed() -> void:
	snapshot_updated.emit(current_snapshot)

## Data files grouped by changelist id
func get_changelist_files() -> Dictionary:
	return changelists.group(current_snapshot.data_files)

func create_changelist(cl_name: String) -> String:
	var cl := changelists.create(cl_name)
	_changelists_changed()
	return cl.id

func rename_changelist(id: String, new_name: String) -> void:
	changelists.rename(id, new_name)
	_changelists_changed()

func delete_changelist(id: String) -> bool:
	var ok := changelists.remove(id)
	_changelists_changed()
	return ok

func move_to_changelist(paths: PackedStringArray, id: String) -> void:
	var repo_paths := PackedStringArray()
	for p in paths:
		repo_paths.append(cli.to_repo_path(p))
	changelists.assign(repo_paths, id)
	_changelists_changed()

## Submit a changelist: commit its files, push, then release its locks.
##
## On a data branch (or with the bypass on), this happens on the current branch.
## On a code branch, the addon switches to the primary data branch for it:
##   1. stash every other local change, so it can't block the switch
##   2. switch to the data branch and fast-forward it
##   3. commit, push, unlock
##   4. switch back and restore the stashed changes
## If a step fails, it stops and puts things back as far as it safely can.
## callback(success: bool, message: String)
func submit_changelist(id: String, message: String, callback: Callable = Callable()) -> void:
	var cl := changelists.get_changelist(id)
	var s := current_snapshot
	if cl == null:
		_fail_now("Submit", "That changelist no longer exists", callback)
		return
	if cl.is_shelved():
		_fail_now("Submit", "Unshelve '%s' before submitting it" % cl.name, callback)
		return
	message = message.strip_edges()
	if message.is_empty() and not cl.pending_push:
		_fail_now("Submit", "Describe the change first: the description is the commit message", callback)
		return

	var items: Array = get_changelist_files().get(id, [])
	var to_commit := PackedStringArray()
	var to_unlock := PackedStringArray()
	var hijacked := PackedStringArray()
	for item: GitTypes.FileStatusItem in items:
		if item.lock_state == GitTypes.LockState.HIJACKED:
			hijacked.append(item.path)
		if item.change_state != GitTypes.ChangeState.UNMODIFIED:
			to_commit.append(item.path)
		if item.lock_state == GitTypes.LockState.LOCKED_BY_ME:
			to_unlock.append(item.path)
	if not hijacked.is_empty():
		_fail_now("Submit", "Check out these files before submitting (they're changed without their lock):\n  " + "\n  ".join(hijacked), callback)
		return
	if to_commit.is_empty() and not cl.pending_push:
		_fail_now("Submit", "'%s' has no changes to submit" % cl.name, callback)
		return

	# Everything else that's changed locally, to stash on a branch switch
	var others := PackedStringArray()
	for p in s.changed_files:
		if not to_commit.has(p):
			others.append(p)

	var direct := s.can_commit_data()
	if not direct and s.primary_data_branch.is_empty():
		_fail_now("Submit", "No data branch to submit to. Create %s, or list your data branches in .lfscheckout." % " or ".join(s.data_branches), callback)
		return

	var plan := {
		"direct": direct,
		"pending": cl.pending_push,
		"pending_branch": cl.pending_branch,
		"message": message,
		"to_commit": to_commit,
		"to_unlock": to_unlock,
		"others": others,
		"original": s.branch_name,
		"target": s.branch_name if direct else s.primary_data_branch,
		"name": cl.name,
	}
	if Engine.is_editor_hint():
		EditorInterface.save_all_scenes()
	_run_op("Submitting " + cl.name, "Submit", func(): return _submit_work(plan), func(ok, msg):
		if ok:
			changelists.finish_submit(id, to_commit + to_unlock)
		elif (msg as String).begins_with(PENDING_PREFIX):
			changelists.set_pending_push(id, true, plan.target)
		_rescan_filesystem()
		_changelists_changed()
		if callback.is_valid():
			callback.call(ok, msg)
	)

## Runs on a worker thread
func _submit_work(plan: Dictionary) -> Dictionary:
	if plan.pending:
		# A previous submit committed but didn't finish pushing or unlocking
		var retry := cli.push_branch(plan.pending_branch)
		if not retry.success:
			return cli.result_fail(PENDING_PREFIX + "the push failed again:\n" + retry.output)
		return _unlock_all(plan.to_unlock, "Pushed and released the locks")

	if plan.direct:
		var commit_res := cli.commit_paths(plan.message, plan.to_commit)
		if not commit_res.success:
			return commit_res
		var push_res := cli.push_branch(plan.target)
		if not push_res.success:
			return cli.result_fail(PENDING_PREFIX + "the push failed. Submit again to retry:\n" + push_res.output)
		return _unlock_all(plan.to_unlock, "Submitted '%s' to %s" % [plan.name, plan.target])

	# Code branch: submit from the data branch, then come back
	var stash_sha := ""
	if not plan.others.is_empty():
		var stash := cli.stash_paths("lfs-checkout: other changes while submitting " + plan.name, plan.others)
		if not stash.success:
			return cli.result_fail("Couldn't set your other changes aside:\n" + stash.output)
		stash_sha = stash.output

	var switched := cli.switch_branch(plan.target)
	if not switched.success:
		return cli.result_fail(_return_from_submit(plan.original, stash_sha, "Couldn't switch to %s:\n%s" % [plan.target, switched.output]))

	if not cli.get_data_base_ref(true, plan.target).is_empty():
		var pulled := cli.pull_fast_forward()
		if not pulled.success:
			return cli.result_fail(_return_from_submit(plan.original, stash_sha, "Couldn't update %s from the server:\n%s" % [plan.target, pulled.output]))

	var committed := cli.commit_paths(plan.message, plan.to_commit)
	if not committed.success:
		return cli.result_fail(_return_from_submit(plan.original, stash_sha, "Couldn't commit on %s:\n%s" % [plan.target, committed.output]))

	var pushed := cli.push_branch(plan.target)
	if not pushed.success:
		return cli.result_fail(_return_from_submit(plan.original, stash_sha, PENDING_PREFIX + "the push failed. Submit again to retry:\n" + pushed.output))

	var unlocked := _unlock_all(plan.to_unlock, "Submitted '%s' to %s" % [plan.name, plan.target])
	var msg := _return_from_submit(plan.original, stash_sha, unlocked.output)
	var back_ok: bool = cli.get_current_branch() == plan.original and (stash_sha.is_empty() or cli.find_stash(stash_sha).is_empty())
	return cli.result_ok(msg) if unlocked.success and back_ok else cli.result_fail(msg)

## Switch back to the original branch and restore the stashed changes.
## Returns message, plus what to do if either step failed.
func _return_from_submit(original: String, stash_sha: String, message: String) -> String:
	if cli.get_current_branch() != original:
		var back := cli.switch_branch(original)
		if not back.success:
			message += "\n\nYou're still on %s: switching back to %s failed:\n%s" % [cli.get_current_branch(), original, back.output]
			if not stash_sha.is_empty():
				message += "\nYour other changes are in the stash (%s). Run `git stash pop` once you're back on %s." % [stash_sha.left(8), original]
			return message
	if not stash_sha.is_empty():
		var popped := cli.pop_stash(stash_sha)
		if not popped.success:
			message += "\n\nYour other changes couldn't be restored and are still in the stash (%s):\n%s" % [stash_sha.left(8), popped.output]
	return message

func _unlock_all(paths: PackedStringArray, ok_message: String) -> Dictionary:
	var failed := PackedStringArray()
	for p in paths:
		var res := cli.unlock_file(p)
		if not res.success:
			failed.append("%s: %s" % [p, res.output])
	if failed.is_empty():
		return cli.result_ok(ok_message)
	return cli.result_fail(ok_message + ", but some locks weren't released:\n  " + "\n  ".join(failed))

## Shelve a changelist: stash its changed files. Locks are kept.
func shelve_changelist(id: String, callback: Callable = Callable()) -> void:
	var cl := changelists.get_changelist(id)
	if cl == null or cl.is_shelved():
		_fail_now("Shelve", "Nothing to shelve", callback)
		return
	var paths := PackedStringArray()
	var mine := {}
	for item: GitTypes.FileStatusItem in get_changelist_files().get(id, []):
		if item.change_state != GitTypes.ChangeState.UNMODIFIED:
			paths.append(item.path)
		var lock := get_lock(item.path)
		if lock != null and lock.is_mine:
			mine[item.path] = true
	if paths.is_empty():
		_fail_now("Shelve", "'%s' has no changes to shelve" % cl.name, callback)
		return
	if Engine.is_editor_hint():
		EditorInterface.save_all_scenes()
	var cl_name := cl.name
	var sha := [""]
	_run_op("Shelving " + cl_name, "Shelve", func():
		var res := cli.stash_paths("lfs-checkout: shelved " + cl_name, paths)
		if not res.success:
			return res
		sha[0] = res.output
		# The restored files: writable if you hold the lock, read-only otherwise
		for p in paths:
			if cli.is_path_lockable(p):
				cli.set_file_writable(p, mine.has(p))
		return cli.result_ok("Shelved '%s'" % cl_name)
	, func(ok, msg):
		if ok:
			changelists.set_shelved(id, sha[0], paths)
		_rescan_filesystem()
		_changelists_changed()
		if callback.is_valid():
			callback.call(ok, msg)
	)

## Bring a shelved changelist's files back
func unshelve_changelist(id: String, callback: Callable = Callable()) -> void:
	var cl := changelists.get_changelist(id)
	if cl == null or not cl.is_shelved():
		_fail_now("Unshelve", "Nothing to unshelve", callback)
		return
	var cl_name := cl.name
	var sha := cl.shelved_sha
	_run_op("Unshelving " + cl_name, "Unshelve", func():
		var res := cli.pop_stash(sha)
		if res.success:
			return cli.result_ok("Unshelved '%s'" % cl_name)
		if cli.find_stash(sha).is_empty():
			# git drops the stash only once it's applied, so this applied with conflicts
			return cli.result_fail("Unshelved '%s' with conflicts. Resolve them, then check the files.\n%s" % [cl_name, res.output])
		return cli.result_fail("Couldn't unshelve '%s'. The shelved changes are kept.\n%s" % [cl_name, res.output])
	, func(ok, msg):
		if ok or cli.find_stash(sha).is_empty():
			changelists.set_shelved(id, "", PackedStringArray())
		_rescan_filesystem()
		_changelists_changed()
		if callback.is_valid():
			callback.call(ok, msg)
	)

func _rescan_filesystem() -> void:
	if Engine.is_editor_hint() and EditorInterface.get_resource_filesystem() != null:
		EditorInterface.get_resource_filesystem().scan()
