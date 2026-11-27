@tool
extends RefCounted

const GitTypes = preload("git_types.gd")

var project_dir: String = ""

func _init(base_dir: String = ""):
	if base_dir.is_empty():
		project_dir = ProjectSettings.globalize_path("res://").trim_suffix("/")
	else:
		project_dir = base_dir.trim_suffix("/")

## Helper to convert a res:// path or absolute path to a repo-relative path
func to_repo_path(path: String) -> String:
	var clean = path.replace("\\", "/")
	if clean.begins_with("res://"):
		clean = clean.trim_prefix("res://")
	var glob_proj = project_dir.replace("\\", "/")
	if clean.begins_with(glob_proj):
		clean = clean.trim_prefix(glob_proj).trim_prefix("/")
	return clean

## Helper to convert a repo-relative path to an absolute path
func to_abs_path(rel_path: String) -> String:
	var clean = to_repo_path(rel_path)
	return project_dir + "/" + clean

## Execute a Git command synchronously
func execute_git(args: PackedStringArray) -> Dictionary:
	var output: Array = []
	var exit_code = OS.execute("git", args, output, true)
	var out_str = ""
	if output.size() > 0:
		out_str = str(output[0])
	return {
		"exit_code": exit_code,
		"output": out_str.strip_edges(),
		"success": (exit_code == 0)
	}

## Execute a Git command in a background thread and call callback(result) on completion
func execute_git_async(args: PackedStringArray, callback: Callable) -> void:
	WorkerThreadPool.add_task(func():
		var res = execute_git(args)
		if callback.is_valid():
			callback.call_deferred(res)
	)

## Get Git user.name and user.email
func get_user_info() -> Dictionary:
	var name_res = execute_git(PackedStringArray(["config", "user.name"]))
	var email_res = execute_git(PackedStringArray(["config", "user.email"]))
	return {
		"name": name_res.output,
		"email": email_res.output
	}

## Query all Git LFS locks from server (via JSON output)
func get_lfs_locks() -> Array[GitTypes.LockRecord]:
	var result: Array[GitTypes.LockRecord] = []
	var res = execute_git(PackedStringArray(["lfs", "locks", "--json"]))
	if not res.success or res.output.is_empty():
		# Fallback to plain text if json failed
		var plain_res = execute_git(PackedStringArray(["lfs", "locks"]))
		if plain_res.success and not plain_res.output.is_empty():
			return parse_plain_lfs_locks(plain_res.output)
		return result

	var json = JSON.new()
	var parse_err = json.parse(res.output)
	if parse_err != OK:
		return parse_plain_lfs_locks(res.output)

	var data = json.get_data()
	if data is Array:
		for item in data:
			if item is Dictionary:
				var rec = GitTypes.LockRecord.new()
				rec.id = str(item.get("id", ""))
				rec.path = str(item.get("path", "")).replace("\\", "/")
				var owner_data = item.get("owner", {})
				if owner_data is Dictionary:
					rec.owner = str(owner_data.get("name", ""))
				elif owner_data is String:
					rec.owner = owner_data
				rec.locked_at = str(item.get("locked_at", ""))
				result.append(rec)
	return result

func parse_plain_lfs_locks(text: String) -> Array[GitTypes.LockRecord]:
	var result: Array[GitTypes.LockRecord] = []
	var lines = text.split("\n", false)
	for line in lines:
		# Format: "path/to/file.png\tAuthor Name\tID:123"
		var parts = line.split("\t")
		if parts.size() >= 3:
			var rec = GitTypes.LockRecord.new()
			rec.path = parts[0].strip_edges().replace("\\", "/")
			rec.owner = parts[1].strip_edges()
			rec.id = parts[2].strip_edges().replace("ID:", "").strip_edges()
			result.append(rec)
		else:
			# Space separated fallback
			var s_parts = line.strip_edges().split(" ")
			if s_parts.size() >= 2:
				var rec = GitTypes.LockRecord.new()
				rec.path = s_parts[0].replace("\\", "/")
				rec.owner = s_parts[1]
				if s_parts.size() >= 3:
					rec.id = s_parts[2].replace("ID:", "")
				result.append(rec)
	return result

## Check which files are lockable via .gitattributes
func check_lockable_attributes(file_paths: PackedStringArray) -> Dictionary:
	var result: Dictionary = {} # rel_path -> bool
	if file_paths.is_empty():
		return result

	# Check in batches of 50 files
	var batch_size = 50
	var total = file_paths.size()
	for i in range(0, total, batch_size):
		var batch = file_paths.slice(i, mini(i + batch_size, total))
		var args = PackedStringArray(["check-attr", "lockable", "--"])
		for p in batch:
			args.append(to_repo_path(p))
		var res = execute_git(args)
		if res.success:
			var lines = res.output.split("\n", false)
			for line in lines:
				# Format: "path: lockable: set" or "path: lockable: unspecified"
				var parts = line.split(":")
				if parts.size() >= 3:
					var p = parts[0].strip_edges().replace("\\", "/")
					var val = parts[2].strip_edges()
					result[p] = (val == "set" or val == "true")
	return result

## Check lockable status for a single file
func is_path_lockable(rel_path: String) -> bool:
	var path = to_repo_path(rel_path)
	var res = execute_git(PackedStringArray(["check-attr", "lockable", "--", path]))
	if res.success:
		return res.output.ends_with("set") or res.output.ends_with("true")
	return false

## Lock an LFS file (Check out)
func lock_file(rel_path: String) -> Dictionary:
	var path = to_repo_path(rel_path)
	var res = execute_git(PackedStringArray(["lfs", "lock", path]))
	if res.success:
		set_file_writable(path, true)
	return res

## Unlock an LFS file
func unlock_file(rel_path: String, force: bool = false) -> Dictionary:
	var path = to_repo_path(rel_path)
	var args = PackedStringArray(["lfs", "unlock"])
	if force:
		args.append("--force")
	args.append(path)
	var res = execute_git(args)
	if res.success:
		# If lockable, restore read-only
		if is_path_lockable(path):
			set_file_writable(path, false)
	return res

## Hijack a file: strip read-only attribute locally without server lock
func hijack_file(rel_path: String) -> bool:
	var path = to_repo_path(rel_path)
	return set_file_writable(path, true)

## Revert a hijacked file: restore clean git copy and set read-only
func revert_file(rel_path: String) -> Dictionary:
	var path = to_repo_path(rel_path)
	var res = execute_git(PackedStringArray(["restore", "--staged", "--worktree", "--", path]))
	if not res.success:
		res = execute_git(PackedStringArray(["checkout", "HEAD", "--", path]))
	if is_path_lockable(path):
		set_file_writable(path, false)
	return res

## Stage a file (git add)
func stage_file(rel_path: String) -> Dictionary:
	var path = to_repo_path(rel_path)
	return execute_git(PackedStringArray(["add", "--", path]))

## Unstage a file (git reset/restore --staged)
func unstage_file(rel_path: String) -> Dictionary:
	var path = to_repo_path(rel_path)
	var res = execute_git(PackedStringArray(["restore", "--staged", "--", path]))
	if not res.success:
		res = execute_git(PackedStringArray(["reset", "HEAD", "--", path]))
	return res

## Commit staged changes
func commit(message: String) -> Dictionary:
	return execute_git(PackedStringArray(["commit", "-m", message]))

## Fetch from remote
func fetch() -> Dictionary:
	return execute_git(PackedStringArray(["fetch", "--all", "--prune"]))

## Pull from remote
func pull() -> Dictionary:
	return execute_git(PackedStringArray(["pull"]))

## Push to remote
func push() -> Dictionary:
	return execute_git(PackedStringArray(["push"]))

## Helper to set Windows / OS file read-only state
func set_file_writable(rel_path: String, writable: bool) -> bool:
	var abs_p = to_abs_path(rel_path).replace("/", "\\")
	if not FileAccess.file_exists(to_abs_path(rel_path)):
		return false

	if OS.get_name() == "Windows":
		var flag = "-r" if writable else "+r"
		var out: Array = []
		var code = OS.execute("attrib", [flag, abs_p], out, true)
		return (code == 0)
	else:
		var mode = "644" if writable else "444"
		var out: Array = []
		var code = OS.execute("chmod", [mode, abs_p], out, true)
		return (code == 0)

## Check if file is currently read-only on disk
func is_file_read_only(rel_path: String) -> bool:
	var abs_p = to_abs_path(rel_path)
	if not FileAccess.file_exists(abs_p):
		return false
	if OS.get_name() == "Windows":
		var out: Array = []
		var code = OS.execute("attrib", [abs_p.replace("/", "\\")], out, true)
		if code == 0 and out.size() > 0:
			var s = str(out[0]).strip_edges()
			# If contains "R", it's read only
			return s.contains(" R ") or s.begins_with("R ") or s.contains("R  ")
	var fa = FileAccess.open(abs_p, FileAccess.READ_WRITE)
	if fa == null:
		return true
	fa.close()
	return false

## Get log history for Git Graph
func get_git_log(max_count: int = 100) -> Array[GitTypes.CommitItem]:
	var result: Array[GitTypes.CommitItem] = []
	# Use standard delimiter for reliable parsing
	var delim = "---COMMIT_DELIM---"
	var format = "%H%n%h%n%P%n%an%n%ae%n%cr%n%ci%n%d%n%s%n%b" + delim
	var args = PackedStringArray([
		"log",
		"--all",
		"--date-order",
		"-n", str(max_count),
		"--pretty=format:" + format
	])
	var res = execute_git(args)
	if not res.success or res.output.is_empty():
		return result

	var raw_commits = res.output.split(delim, false)
	for raw in raw_commits:
		var lines = raw.strip_edges().split("\n")
		if lines.size() >= 9:
			var commit = GitTypes.CommitItem.new()
			commit.sha = lines[0].strip_edges()
			commit.short_sha = lines[1].strip_edges()
			var p_str = lines[2].strip_edges()
			if not p_str.is_empty():
				commit.parents.assign(p_str.split(" "))
			commit.author_name = lines[3].strip_edges()
			commit.author_email = lines[4].strip_edges()
			commit.date_relative = lines[5].strip_edges()
			commit.date_iso = lines[6].strip_edges()
			
			var ref_decorations = lines[7].strip_edges().trim_prefix("(").trim_suffix(")")
			if not ref_decorations.is_empty():
				var refs = ref_decorations.split(",")
				for r in refs:
					var clean_ref = r.strip_edges()
					if clean_ref.begins_with("HEAD ->"):
						commit.is_head = true
						commit.branches.append(clean_ref.replace("HEAD ->", "").strip_edges())
					elif clean_ref.begins_with("tag:"):
						commit.tags.append(clean_ref.replace("tag:", "").strip_edges())
					else:
						commit.branches.append(clean_ref)

			commit.subject = lines[8].strip_edges()
			if lines.size() > 9:
				commit.body = "\n".join(lines.slice(9)).strip_edges()
			result.append(commit)
	return result
