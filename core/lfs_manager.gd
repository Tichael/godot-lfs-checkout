@tool
extends RefCounted

const GitTypes = preload("git_types.gd")
const GitCLI = preload("git_cli.gd")

signal snapshot_updated(snapshot: GitTypes.RepoSnapshot)
signal operation_started(op_name: String)
signal operation_completed(op_name: String, success: bool, message: String)
signal hijacked_staged_detected(hijacked_items: Array[GitTypes.FileStatusItem])

var cli: GitCLI
var current_snapshot: GitTypes.RepoSnapshot
var is_refreshing: bool = false
var current_user: String = ""
var current_email: String = ""

func _init(base_dir: String = ""):
	cli = GitCLI.new(base_dir)
	current_snapshot = GitTypes.RepoSnapshot.new()
	var user_info = cli.get_user_info()
	current_user = user_info.name
	current_email = user_info.email

## Asynchronously refresh all Git status, LFS locks, and Hijacked states
func refresh_async(callback: Callable = Callable()) -> void:
	if is_refreshing:
		return
	is_refreshing = true
	emit_signal("operation_started", "Refreshing Status")

	WorkerThreadPool.add_task(func():
		var snapshot = _build_snapshot_sync()
		is_refreshing = false
		_on_snapshot_ready.call_deferred(snapshot, callback)
	)

func _on_snapshot_ready(snapshot: GitTypes.RepoSnapshot, callback: Callable) -> void:
	current_snapshot = snapshot
	emit_signal("snapshot_updated", current_snapshot)
	emit_signal("operation_completed", "Refresh", true, "Status updated")

	# Check for hijacked files that are staged
	var staged_hijacked: Array[GitTypes.FileStatusItem] = []
	for f in current_snapshot.staged_files:
		if f.lock_state == GitTypes.LockState.HIJACKED:
			staged_hijacked.append(f)

	if not staged_hijacked.is_empty():
		emit_signal("hijacked_staged_detected", staged_hijacked)

	if callback.is_valid():
		callback.call(current_snapshot)

## Synchronous worker function to collect full status
func _build_snapshot_sync() -> GitTypes.RepoSnapshot:
	var snapshot = GitTypes.RepoSnapshot.new()
	snapshot.current_user_name = current_user
	snapshot.current_user_email = current_email

	# 1. Query Git LFS Locks
	var server_locks = cli.get_lfs_locks()
	for lock in server_locks:
		snapshot.active_server_locks[lock.path] = lock

	# 2. Query git status --porcelain=v1 -b -uall
	var status_res = cli.execute_git(PackedStringArray(["status", "--porcelain=v1", "-b", "-uall"]))
	var status_lines = status_res.output.split("\n", false)

	var files_to_check_lockable: PackedStringArray = []
	var raw_file_entries: Array[Dictionary] = []

	for line in status_lines:
		if line.begins_with("## "):
			# Branch header: "## main...origin/main [ahead 1, behind 2]"
			_parse_branch_header(line.trim_prefix("## "), snapshot)
			continue

		if line.length() < 3:
			continue

		var index_code = line[0]
		var work_code = line[1]
		var path_part = line.substr(3).strip_edges().replace("\\", "/")
		
		# Handle rename format "orig -> new"
		if path_part.contains(" -> "):
			path_part = path_part.split(" -> ")[1].strip_edges()

		# Remove quotes if git quoted paths with spaces
		path_part = path_part.trim_prefix("\"").trim_suffix("\"")

		raw_file_entries.append({
			"path": path_part,
			"index_code": index_code,
			"work_code": work_code
		})
		files_to_check_lockable.append(path_part)

	# Also add all server locked paths to lockable check
	for l_path in snapshot.active_server_locks.keys():
		if not files_to_check_lockable.has(l_path):
			files_to_check_lockable.append(l_path)

	# 3. Check which paths are lockable via .gitattributes
	var lockable_map = cli.check_lockable_attributes(files_to_check_lockable)

	# 4. Construct FileStatusItem instances
	for entry in raw_file_entries:
		var p = entry.path
		var item = GitTypes.FileStatusItem.new()
		item.path = p
		item.res_path = "res://" + p
		item.is_lockable = lockable_map.get(p, false)
		
		# Check server lock
		if snapshot.active_server_locks.has(p):
			var l: GitTypes.LockRecord = snapshot.active_server_locks[p]
			item.lock_owner = l.owner
			item.lock_id = l.id
			if l.owner == current_user or l.owner == current_email:
				item.lock_state = GitTypes.LockState.LOCKED_BY_ME
			else:
				item.lock_state = GitTypes.LockState.LOCKED_BY_OTHER
		else:
			# Not locked on server
			if item.is_lockable:
				# If lockable, but modified locally and NOT locked by me -> HIJACKED!
				item.lock_state = GitTypes.LockState.HIJACKED
			else:
				item.lock_state = GitTypes.LockState.NOT_LOCKABLE

		# Parse Index / Staged state
		if entry.index_code != " " and entry.index_code != "?":
			var staged_item = _duplicate_item(item)
			staged_item.staged_state = GitTypes.StagedState.STAGED
			staged_item.change_state = _code_to_change_state(entry.index_code)
			snapshot.staged_files.append(staged_item)

		# Parse Working Tree state
		if entry.work_code != " ":
			var work_item = _duplicate_item(item)
			work_item.staged_state = GitTypes.StagedState.UNSTAGED
			work_item.change_state = _code_to_change_state(entry.work_code if entry.work_code != "?" else "?")
			
			if work_item.lock_state == GitTypes.LockState.HIJACKED:
				snapshot.hijacked_files.append(work_item)
			else:
				snapshot.working_files.append(work_item)

		snapshot.all_tracked_files[p] = item

	# 5. Populate Locked by Others list (even if not modified locally)
	for l_path in snapshot.active_server_locks.keys():
		var l: GitTypes.LockRecord = snapshot.active_server_locks[l_path]
		if l.owner != current_user and l.owner != current_email:
			var other_item = GitTypes.FileStatusItem.new()
			other_item.path = l_path
			other_item.res_path = "res://" + l_path
			other_item.is_lockable = true
			other_item.lock_state = GitTypes.LockState.LOCKED_BY_OTHER
			other_item.lock_owner = l.owner
			other_item.lock_id = l.id
			snapshot.locked_by_other_files.append(other_item)

	return snapshot

func _duplicate_item(src: GitTypes.FileStatusItem) -> GitTypes.FileStatusItem:
	var dst = GitTypes.FileStatusItem.new()
	dst.path = src.path
	dst.res_path = src.res_path
	dst.is_lockable = src.is_lockable
	dst.lock_state = src.lock_state
	dst.lock_owner = src.lock_owner
	dst.lock_id = src.lock_id
	dst.change_state = src.change_state
	dst.staged_state = src.staged_state
	return dst

func _code_to_change_state(code: String) -> GitTypes.ChangeState:
	match code:
		"M": return GitTypes.ChangeState.MODIFIED
		"A": return GitTypes.ChangeState.ADDED
		"D": return GitTypes.ChangeState.DELETED
		"R": return GitTypes.ChangeState.RENAMED
		"?": return GitTypes.ChangeState.UNTRACKED
		"U": return GitTypes.ChangeState.CONFLICTED
		_: return GitTypes.ChangeState.MODIFIED

func _parse_branch_header(header: String, snapshot: GitTypes.RepoSnapshot) -> void:
	# e.g. "main...origin/main [ahead 1, behind 2]" or "main"
	var parts = header.split(" ")
	var branch_part = parts[0]
	if branch_part.contains("..."):
		var b_split = branch_part.split("...")
		snapshot.branch_name = b_split[0]
		snapshot.upstream_name = b_split[1]
	else:
		snapshot.branch_name = branch_part

	if header.contains("[ahead "):
		var a_idx = header.find("[ahead ") + 7
		var a_end = header.find(",", a_idx)
		if a_end == -1:
			a_end = header.find("]", a_idx)
		snapshot.ahead_count = header.substr(a_idx, a_end - a_idx).to_int()

	if header.contains("behind "):
		var b_idx = header.find("behind ") + 7
		var b_end = header.find("]", b_idx)
		snapshot.behind_count = header.substr(b_idx, b_end - b_idx).to_int()

# =========================================================================
# ACTIONS & WORKFLOWS
# =========================================================================

## Check out (Lock) an asset on Gitea
func checkout_file(rel_path: String, callback: Callable = Callable()) -> void:
	emit_signal("operation_started", "Locking " + rel_path)
	WorkerThreadPool.add_task(func():
		var res = cli.lock_file(rel_path)
		var success = res.success
		var msg = "Locked successfully" if success else res.output
		refresh_async(func(_s):
			emit_signal("operation_completed", "Lock File", success, msg)
			if callback.is_valid():
				callback.call(success, msg)
		)
	)

## Hijack a file (Make writable locally without server lock)
func hijack_file(rel_path: String, callback: Callable = Callable()) -> void:
	emit_signal("operation_started", "Hijacking " + rel_path)
	var ok = cli.hijack_file(rel_path)
	var msg = "File is now writable (Hijacked for local testing)" if ok else "Failed to make file writable"
	refresh_async(func(_s):
		emit_signal("operation_completed", "Hijack File", ok, msg)
		if callback.is_valid():
			callback.call(ok, msg)
	)

## Revert a file (discard working changes / revert hijack)
func revert_file(rel_path: String, callback: Callable = Callable()) -> void:
	emit_signal("operation_started", "Reverting " + rel_path)
	WorkerThreadPool.add_task(func():
		var res = cli.revert_file(rel_path)
		refresh_async(func(_s):
			emit_signal("operation_completed", "Revert", res.success, res.output if not res.success else "Reverted")
			if callback.is_valid():
				callback.call(res.success, res.output)
		)
	)

## Unlock a file on Gitea
func unlock_file(rel_path: String, force: bool = false, callback: Callable = Callable()) -> void:
	emit_signal("operation_started", "Unlocking " + rel_path)
	WorkerThreadPool.add_task(func():
		var res = cli.unlock_file(rel_path, force)
		refresh_async(func(_s):
			emit_signal("operation_completed", "Unlock File", res.success, res.output if not res.success else "Unlocked")
			if callback.is_valid():
				callback.call(res.success, res.output)
		)
	)

## Stage a file (Checks and blocks hijacked files!)
func stage_file(rel_path: String, callback: Callable = Callable()) -> void:
	var path = cli.to_repo_path(rel_path)
	# Guard: Check if file is hijacked
	if is_file_hijacked(path):
		var err_msg = "Cannot stage hijacked file '%s'. Acquire a server lock first or promote to checkout." % path
		emit_signal("operation_completed", "Stage Blocked", false, err_msg)
		if callback.is_valid():
			callback.call(false, err_msg)
		return

	emit_signal("operation_started", "Staging " + path)
	WorkerThreadPool.add_task(func():
		var res = cli.stage_file(path)
		refresh_async(func(_s):
			emit_signal("operation_completed", "Stage", res.success, res.output)
			if callback.is_valid():
				callback.call(res.success, res.output)
		)
	)

## Stage all non-hijacked files
func stage_all_valid_changes(callback: Callable = Callable()) -> void:
	emit_signal("operation_started", "Staging Changes")
	WorkerThreadPool.add_task(func():
		# Stage only items in working_files (which excludes hijacked_files)
		for item in current_snapshot.working_files:
			cli.stage_file(item.path)
		refresh_async(func(_s):
			emit_signal("operation_completed", "Stage All", true, "Staged all valid changes")
			if callback.is_valid():
				callback.call(true, "Staged")
		)
	)

## Unstage a file
func unstage_file(rel_path: String, callback: Callable = Callable()) -> void:
	emit_signal("operation_started", "Unstaging " + rel_path)
	WorkerThreadPool.add_task(func():
		var res = cli.unstage_file(rel_path)
		refresh_async(func(_s):
			emit_signal("operation_completed", "Unstage", res.success, res.output)
			if callback.is_valid():
				callback.call(res.success, res.output)
		)
	)

## Unstage all currently staged hijacked files
func unstage_all_hijacked(callback: Callable = Callable()) -> void:
	emit_signal("operation_started", "Unstaging Hijacked Files")
	WorkerThreadPool.add_task(func():
		for f in current_snapshot.staged_files:
			if f.lock_state == GitTypes.LockState.HIJACKED:
				cli.unstage_file(f.path)
		refresh_async(func(_s):
			emit_signal("operation_completed", "Unstage Hijacked", true, "Unstaged all hijacked files")
			if callback.is_valid():
				callback.call(true, "Unstaged hijacked files")
		)
	)

## Unstage all files
func unstage_all(callback: Callable = Callable()) -> void:
	emit_signal("operation_started", "Unstaging All")
	WorkerThreadPool.add_task(func():
		var res = cli.execute_git(PackedStringArray(["reset", "HEAD"]))
		refresh_async(func(_s):
			emit_signal("operation_completed", "Unstage All", res.success, res.output)
			if callback.is_valid():
				callback.call(res.success, res.output)
		)
	)

## Commit staged changes
func commit(message: String, callback: Callable = Callable()) -> void:
	if message.strip_edges().is_empty():
		emit_signal("operation_completed", "Commit", false, "Commit message cannot be empty")
		if callback.is_valid():
			callback.call(false, "Empty message")
		return

	emit_signal("operation_started", "Committing")
	WorkerThreadPool.add_task(func():
		var res = cli.commit(message)
		refresh_async(func(_s):
			emit_signal("operation_completed", "Commit", res.success, res.output if not res.success else "Committed")
			if callback.is_valid():
				callback.call(res.success, res.output)
		)
	)

## Push commits to remote
func push(callback: Callable = Callable()) -> void:
	emit_signal("operation_started", "Pushing to remote")
	WorkerThreadPool.add_task(func():
		var res = cli.push()
		refresh_async(func(_s):
			emit_signal("operation_completed", "Push", res.success, res.output if not res.success else "Pushed")
			if callback.is_valid():
				callback.call(res.success, res.output)
		)
	)

## Pull commits from remote (Sync)
func pull(callback: Callable = Callable()) -> void:
	emit_signal("operation_started", "Pulling latest changes")
	WorkerThreadPool.add_task(func():
		var res = cli.pull()
		refresh_async(func(_s):
			emit_signal("operation_completed", "Pull", res.success, res.output if not res.success else "Pulled latest")
			if callback.is_valid():
				callback.call(res.success, res.output)
		)
	)

## Fetch metadata from remote
func fetch(callback: Callable = Callable()) -> void:
	emit_signal("operation_started", "Fetching remote")
	WorkerThreadPool.add_task(func():
		var res = cli.fetch()
		refresh_async(func(_s):
			emit_signal("operation_completed", "Fetch", res.success, res.output if not res.success else "Fetched")
			if callback.is_valid():
				callback.call(res.success, res.output)
		)
	)

## Check if path is known to be hijacked
func is_file_hijacked(rel_path: String) -> bool:
	var path = cli.to_repo_path(rel_path)
	for h in current_snapshot.hijacked_files:
		if h.path == path:
			return true
	for s in current_snapshot.staged_files:
		if s.path == path and s.lock_state == GitTypes.LockState.HIJACKED:
			return true
	return false
