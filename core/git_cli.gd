@tool
extends RefCounted

## Thin wrapper around the git and git-lfs command line tools.
##
## Path conventions:
## - "repo path": relative to the repository root, forward slashes (what git prints)
## - "res path": res://..., only for files inside the Godot project
## The Godot project may live in a subfolder of the repository.
##
## Output is parsed line by line. Paths git quotes (control characters, double
## quotes, backslashes) go through unquote().

const GitTypes = preload("git_types.gd")

const BATCH_SIZE := 200

var project_dir: String = ""    ## Absolute, no trailing slash
var repo_root: String = ""      ## Absolute, no trailing slash; empty if not a repo
var project_prefix: String = "" ## Project folder relative to repo root, "" or ending with "/"

func _init(base_dir: String = ""):
	if base_dir.is_empty():
		base_dir = ProjectSettings.globalize_path("res://")
	project_dir = _normalize(base_dir)
	_detect_repo()

func _normalize(path: String) -> String:
	return path.replace("\\", "/").trim_suffix("/")

func _detect_repo() -> void:
	var res := _run(PackedStringArray(["-C", project_dir, "rev-parse", "--show-toplevel"]), false)
	if not res.success or res.output.is_empty():
		repo_root = ""
		project_prefix = ""
		return
	repo_root = _normalize(res.output)
	if project_dir.to_lower() == repo_root.to_lower():
		project_prefix = ""
	else:
		project_prefix = project_dir.substr(repo_root.length() + 1) + "/"

func is_repo() -> bool:
	return not repo_root.is_empty()

## Convert a res://, absolute, or repo-relative path to a repo path
func to_repo_path(path: String) -> String:
	var clean := path.replace("\\", "/")
	if clean.begins_with("res://"):
		return project_prefix + clean.trim_prefix("res://")
	if not repo_root.is_empty() and clean.to_lower().begins_with(repo_root.to_lower() + "/"):
		return clean.substr(repo_root.length() + 1)
	return clean

## Convert a repo path to a res:// path, or "" if it's outside the project
func to_res_path(repo_path: String) -> String:
	if not repo_path.begins_with(project_prefix):
		return ""
	return "res://" + repo_path.substr(project_prefix.length())

## Convert any supported path to an absolute path
func to_abs_path(path: String) -> String:
	var base := repo_root if not repo_root.is_empty() else project_dir
	return base + "/" + to_repo_path(path)

## Run git with the given arguments in the repository.
## merge_stderr: include stderr in the output (for user-facing messages).
## Leave it off when parsing output, so warnings don't corrupt it.
func execute_git(args: PackedStringArray, merge_stderr: bool = true) -> Dictionary:
	var full := PackedStringArray(["-C", repo_root if not repo_root.is_empty() else project_dir, "-c", "core.quotepath=false"])
	full.append_array(args)
	return _run(full, merge_stderr)

## Uses execute_with_pipe rather than OS.execute: on Windows, OS.execute decodes
## output with the system code page, which garbles git's UTF-8 (non-ASCII paths,
## author names). Reading the raw bytes lets us decode UTF-8 ourselves.
func _run(args: PackedStringArray, merge_stderr: bool) -> Dictionary:
	var proc := OS.execute_with_pipe("git", args, false)
	if proc.is_empty():
		return result_fail("Couldn't run git. Is it installed and on your PATH?")
	var stdio: FileAccess = proc.stdio
	var stderr: FileAccess = proc.stderr
	var pid: int = proc.pid
	var out_bytes := PackedByteArray()
	var err_bytes := PackedByteArray()

	# Read both pipes as we go, so a full stderr pipe can't block git.
	while true:
		var got_out := _drain(stdio, out_bytes)
		var got_err := _drain(stderr, err_bytes)
		if not got_out and not got_err:
			if not OS.is_process_running(pid):
				break
			OS.delay_msec(2)
	while _drain(stdio, out_bytes) or _drain(stderr, err_bytes):
		pass
	stdio.close()
	stderr.close()

	var exit_code := OS.get_process_exit_code(pid)
	var out_str := out_bytes.get_string_from_utf8()
	if merge_stderr and not err_bytes.is_empty():
		out_str += err_bytes.get_string_from_utf8()
	out_str = out_str.replace("\r\n", "\n")
	return {
		"exit_code": exit_code,
		"output": out_str.strip_edges(),
		"raw": out_str,
		"success": exit_code == 0
	}

## Append whatever the pipe has right now. Returns true if anything was read.
func _drain(pipe: FileAccess, into: PackedByteArray) -> bool:
	var chunk := pipe.get_buffer(65536)
	if chunk.is_empty():
		return false
	into.append_array(chunk)
	return true

func result_ok(message: String = "") -> Dictionary:
	return {"exit_code": 0, "output": message, "raw": message, "success": true}

func result_fail(message: String) -> Dictionary:
	return {"exit_code": 1, "output": message, "raw": message, "success": false}

## Git user.name and user.email
func get_user_info() -> Dictionary:
	return {
		"name": execute_git(PackedStringArray(["config", "user.name"]), false).output,
		"email": execute_git(PackedStringArray(["config", "user.email"]), false).output,
	}

## Undo git's C-style quoting of unusual paths, e.g. "a\"b" or "tab\there" or octal bytes.
## With core.quotepath=false, non-ASCII stays unquoted and only control characters,
## double quotes and backslashes cause quoting.
static func unquote(path: String) -> String:
	if path.length() < 2 or not path.begins_with("\"") or not path.ends_with("\""):
		return path
	var body := path.substr(1, path.length() - 2)
	var bytes := PackedByteArray()
	var i := 0
	while i < body.length():
		var c := body[i]
		if c != "\\" or i + 1 >= body.length():
			bytes.append_array(c.to_utf8_buffer())
			i += 1
			continue
		var n := body[i + 1]
		if n >= "0" and n <= "7" and i + 3 < body.length() + 1:
			var v := 0
			for d in body.substr(i + 1, 3):
				v = v * 8 + d.to_int()
			bytes.append(v & 0xff)
			i += 4
			continue
		match n:
			"n": bytes.append(0x0a)
			"t": bytes.append(0x09)
			"r": bytes.append(0x0d)
			"a": bytes.append(0x07)
			"b": bytes.append(0x08)
			"f": bytes.append(0x0c)
			"v": bytes.append(0x0b)
			_: bytes.append_array(n.to_utf8_buffer())
		i += 2
	return bytes.get_string_from_utf8()

# =========================================================================
# STATUS
# =========================================================================

## Parsed `git status --porcelain=v2 --branch`.
## Returns {success, branch: {head, upstream, ahead, behind}, entries: [{path, orig_path, index, work}]}
## index/work codes use v1 letters: " " unchanged, M, A, D, R, C, U, ? untracked.
func get_status() -> Dictionary:
	var result := {"success": false, "branch": {"head": "", "upstream": "", "ahead": 0, "behind": 0}, "entries": []}
	var res := execute_git(PackedStringArray(["status", "--porcelain=v2", "--branch", "--untracked-files=all"]), false)
	if not res.success:
		return result
	result.success = true

	for rec in res.raw.split("\n", false):
		if rec.begins_with("# "):
			var parts: PackedStringArray = rec.split(" ", false)
			if parts.size() < 3:
				continue
			match parts[1]:
				"branch.head":
					result.branch.head = "" if parts[2] == "(detached)" else parts[2]
				"branch.upstream":
					result.branch.upstream = parts[2]
				"branch.ab":
					result.branch.ahead = parts[2].trim_prefix("+").to_int()
					if parts.size() > 3:
						result.branch.behind = parts[3].trim_prefix("-").to_int()
			continue

		match rec.substr(0, 1):
			"1":
				# 1 XY sub mH mI mW hH hI path
				var f: PackedStringArray = rec.split(" ", true, 8)
				if f.size() == 9:
					result.entries.append(_entry(unquote(f[8]), "", f[1]))
			"2":
				# 2 XY sub mH mI mW hH hI Xscore path<TAB>origPath
				var f: PackedStringArray = rec.split(" ", true, 9)
				if f.size() == 10:
					var paths: PackedStringArray = f[9].split("\t")
					var orig := unquote(paths[1]) if paths.size() > 1 else ""
					result.entries.append(_entry(unquote(paths[0]), orig, f[1]))
			"u":
				# u XY sub m1 m2 m3 mW h1 h2 h3 path
				var f: PackedStringArray = rec.split(" ", true, 10)
				if f.size() == 11:
					result.entries.append({"path": unquote(f[10]), "orig_path": "", "index": "U", "work": "U"})
			"?":
				result.entries.append({"path": unquote(rec.substr(2)), "orig_path": "", "index": "?", "work": "?"})
	return result

func _entry(path: String, orig_path: String, xy: String) -> Dictionary:
	var x := xy.substr(0, 1)
	var y := xy.substr(1, 1)
	return {
		"path": path,
		"orig_path": orig_path,
		"index": " " if x == "." else x,
		"work": " " if y == "." else y,
	}

# =========================================================================
# LFS LOCKS
# =========================================================================

## Query LFS locks. Returns {success, error, locks: Array[LockRecord]}.
## Uses --verify so the server says which locks are ours. Falls back to comparing
## the owner with git user.name/email when the server doesn't support verify.
func get_lfs_locks(user_name: String, user_email: String) -> Dictionary:
	var locks: Array[GitTypes.LockRecord] = []
	var result := {"success": false, "error": "", "locks": locks}

	var res := execute_git(PackedStringArray(["lfs", "locks", "--verify", "--json"]), false)
	var data = JSON.parse_string(res.output) if res.success else null
	if data is Dictionary:
		for item in data.get("ours", []):
			locks.append(_lock_from_json(item, true))
		for item in data.get("theirs", []):
			locks.append(_lock_from_json(item, false))
		result.success = true
		return result

	res = execute_git(PackedStringArray(["lfs", "locks", "--json"]), false)
	data = JSON.parse_string(res.output) if res.success else null
	if data is Array:
		for item in data:
			var rec := _lock_from_json(item, false)
			rec.is_mine = not rec.owner.is_empty() and (rec.owner == user_name or rec.owner == user_email)
			locks.append(rec)
		result.success = true
		return result

	result.error = execute_git(PackedStringArray(["lfs", "locks", "--json"])).output
	return result

func _lock_from_json(item, is_mine: bool) -> GitTypes.LockRecord:
	var rec := GitTypes.LockRecord.new()
	if not item is Dictionary:
		return rec
	rec.id = str(item.get("id", ""))
	rec.path = str(item.get("path", "")).replace("\\", "/")
	var owner_data = item.get("owner", {})
	if owner_data is Dictionary:
		rec.owner = str(owner_data.get("name", ""))
	elif owner_data is String:
		rec.owner = owner_data
	rec.locked_at = str(item.get("locked_at", ""))
	rec.is_mine = is_mine
	return rec

## Which repo paths are lockable in .gitattributes. Returns repo path -> bool.
func check_lockable_attributes(repo_paths: PackedStringArray) -> Dictionary:
	var result: Dictionary = {}
	for i in range(0, repo_paths.size(), BATCH_SIZE):
		var args := PackedStringArray(["check-attr", "lockable", "--"])
		args.append_array(repo_paths.slice(i, mini(i + BATCH_SIZE, repo_paths.size())))
		var res := execute_git(args, false)
		if not res.success:
			continue
		# "<path>: lockable: <value>", path quoted if unusual
		for line in res.raw.split("\n", false):
			var parts: PackedStringArray = line.rsplit(": ", true, 2)
			if parts.size() == 3:
				var value: String = parts[2].strip_edges()
				result[unquote(parts[0]).replace("\\", "/")] = value == "set" or value == "true"
	return result

func is_path_lockable(path: String) -> bool:
	var repo_path := to_repo_path(path)
	return check_lockable_attributes(PackedStringArray([repo_path])).get(repo_path, false)

# =========================================================================
# DATA WORKFLOW
# =========================================================================
# Data files (lockable, plus their Godot .import files) are only committed on
# data branches, listed in .lfscheckout at the repo root:
#   [lfs-checkout]
#       dataBranch = main
#       dataBranch = release/*
# The pre-commit hook in hooks/pre-commit.sh enforces the same rule for every
# commit, whatever tool makes it.

const DATA_CONFIG_FILE := ".lfscheckout"
const DEFAULT_DATA_BRANCHES := ["main"]
const BYPASS_ENV := "LFS_CHECKOUT_BYPASS"
const BYPASS_CONFIG := "lfs-checkout.bypass"
const HOOK_MARKER := "# Installed by LFS Checkout"

## Branch patterns where data can be committed. Defaults to main.
func get_data_branches() -> PackedStringArray:
	var res := execute_git(PackedStringArray(["config", "-f", repo_root + "/" + DATA_CONFIG_FILE, "--get-all", "lfs-checkout.dataBranch"]), false)
	var patterns := PackedStringArray()
	if res.success:
		for line in (res.output as String).split("\n", false):
			if not line.strip_edges().is_empty():
				patterns.append(line.strip_edges())
	if patterns.is_empty():
		patterns.append_array(DEFAULT_DATA_BRANCHES)
	return patterns

static func branch_matches(branch: String, patterns: PackedStringArray) -> bool:
	if branch.is_empty():
		return false
	for p in patterns:
		if branch.match(p):
			return true
	return false

## Current branch, or "" when HEAD is detached
func get_current_branch() -> String:
	var res := execute_git(PackedStringArray(["symbolic-ref", "--short", "-q", "HEAD"]), false)
	return res.output if res.success else ""

func is_merge_in_progress() -> bool:
	return execute_git(PackedStringArray(["rev-parse", "-q", "--verify", "MERGE_HEAD"]), false).success

## Emergency bypass: the repo-local git config, or the environment variable
func is_bypass_enabled() -> bool:
	if OS.get_environment(BYPASS_ENV) == "1":
		return true
	return execute_git(PackedStringArray(["config", "--bool", BYPASS_CONFIG]), false).output == "true"

func set_bypass(enabled: bool) -> Dictionary:
	if enabled:
		return execute_git(PackedStringArray(["config", "--local", BYPASS_CONFIG, "true"]))
	var res := execute_git(PackedStringArray(["config", "--local", "--unset", BYPASS_CONFIG]))
	# Exit code 5 means it wasn't set
	return result_ok() if res.exit_code == 5 else res

## Whether a repo path counts as data: lockable, or the .import file of a lockable file
static func is_data_path(repo_path: String, lockable: Dictionary) -> bool:
	if lockable.get(repo_path, false):
		return true
	return repo_path.ends_with(".import") and lockable.get(repo_path.trim_suffix(".import"), false)

## True when the file changed on the upstream branch since this branch last synced with it.
## Fetches first. Returns false when there's no upstream to compare with.
func is_out_of_date(path: String) -> bool:
	execute_git(PackedStringArray(["fetch", "-q"]), false)
	# HEAD...upstream: only the upstream side's changes since the merge base
	var res := execute_git(PackedStringArray(["diff", "--quiet", "HEAD...@{upstream}", "--", to_repo_path(path)]), false)
	return res.exit_code == 1

## True when commits touching the file haven't been pushed to any remote
func has_unpushed_commits(path: String) -> bool:
	var res := execute_git(PackedStringArray(["log", "--format=%H", "-n", "1", "HEAD", "--not", "--remotes", "--", to_repo_path(path)]), false)
	return res.success and not res.output.is_empty()

func _hooks_dir() -> String:
	var res := execute_git(PackedStringArray(["rev-parse", "--git-path", "hooks"]), false)
	if not res.success:
		return ""
	var dir: String = res.output.replace("\\", "/")
	return dir if dir.is_absolute_path() else repo_root + "/" + dir

## The pre-commit hook the addon installs. It runs the addon's hook script,
## so updating the addon updates the check.
func _hook_stub(addon_repo_dir: String) -> String:
	return "\n".join([
		"#!/bin/sh",
		HOOK_MARKER + " (Godot addon). The addon rewrites this file; local edits are lost.",
		"hook=\"$(git rev-parse --show-toplevel)/%s/hooks/pre-commit.sh\"" % addon_repo_dir,
		"if [ -f \"$hook\" ]; then",
		"\ttr -d '\\r' < \"$hook\" | sh -s -- \"$@\"",
		"\texit $?",
		"fi",
		"echo \"LFS Checkout: $hook not found, skipping the data branch check.\" >&2",
		"exit 0",
		"",
	])

## "installed", "outdated", "missing", or "foreign" (a hook the addon didn't install)
func get_hook_state(addon_repo_dir: String) -> String:
	var dir := _hooks_dir()
	if dir.is_empty():
		return "missing"
	var path := dir + "/pre-commit"
	if not FileAccess.file_exists(path):
		return "missing"
	var content := FileAccess.get_file_as_string(path)
	if not content.contains(HOOK_MARKER):
		return "foreign"
	return "installed" if content == _hook_stub(addon_repo_dir) else "outdated"

## Install or update the pre-commit hook. Never replaces a hook the addon didn't install.
func install_hook(addon_repo_dir: String) -> Dictionary:
	var state := get_hook_state(addon_repo_dir)
	if state == "installed":
		return result_ok("Hook already installed")
	if state == "foreign":
		return result_fail("A pre-commit hook already exists in %s. Add this line to it to run the data branch check:\n  sh \"$(git rev-parse --show-toplevel)/%s/hooks/pre-commit.sh\" || exit 1" % [_hooks_dir(), addon_repo_dir])
	var dir := _hooks_dir()
	if dir.is_empty():
		return result_fail("Couldn't find the git hooks folder")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir + "/pre-commit"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return result_fail("Couldn't write %s: %s" % [path, error_string(FileAccess.get_open_error())])
	file.store_string(_hook_stub(addon_repo_dir))
	file.close()
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(path, 0x1ED)  # 0755
	return result_ok("Installed the pre-commit hook")

# =========================================================================
# ACTIONS
# =========================================================================

## Lock an LFS file (check out)
func lock_file(path: String) -> Dictionary:
	var repo_path := to_repo_path(path)
	var res := execute_git(PackedStringArray(["lfs", "lock", "--", repo_path]))
	if res.success:
		set_file_writable(repo_path, true)
	return res

## Unlock an LFS file
func unlock_file(path: String, force: bool = false) -> Dictionary:
	var repo_path := to_repo_path(path)
	var args := PackedStringArray(["lfs", "unlock"])
	if force:
		args.append("--force")
	args.append_array(["--", repo_path])
	var res := execute_git(args)
	if res.success and is_path_lockable(repo_path):
		set_file_writable(repo_path, false)
	return res

## Hijack a file: make it writable locally without taking the server lock
func hijack_file(path: String) -> Dictionary:
	var repo_path := to_repo_path(path)
	if set_file_writable(repo_path, true):
		return result_ok("File is now writable (hijacked for local edits)")
	return result_fail("Failed to make %s writable" % repo_path)

## Discard local changes to a file.
## Files that aren't in HEAD (untracked or newly added) are unstaged and moved to the trash.
## keep_writable: leave the file writable afterwards (when you hold its lock).
func revert_file(path: String, is_new: bool, keep_writable: bool) -> Dictionary:
	var repo_path := to_repo_path(path)
	if is_new:
		execute_git(PackedStringArray(["rm", "-q", "--cached", "--ignore-unmatch", "--", repo_path]))
		var abs_path := to_abs_path(repo_path)
		if FileAccess.file_exists(abs_path) and OS.move_to_trash(abs_path) != OK:
			return result_fail("Failed to move %s to the trash" % repo_path)
		return result_ok("Moved %s to the trash" % repo_path)

	var res := execute_git(PackedStringArray(["restore", "--source=HEAD", "--staged", "--worktree", "--", repo_path]))
	if not res.success:
		res = execute_git(PackedStringArray(["checkout", "HEAD", "--", repo_path]))
	if res.success and not keep_writable and is_path_lockable(repo_path):
		set_file_writable(repo_path, false)
	return res

## Stage files (git add)
func stage_files(paths: PackedStringArray) -> Dictionary:
	return _batched(PackedStringArray(["add", "--"]), paths)

## Unstage files, including in a repo with no commits yet
func unstage_files(paths: PackedStringArray) -> Dictionary:
	var res := _batched(PackedStringArray(["restore", "--staged", "--"]), paths)
	if not res.success:
		res = _batched(PackedStringArray(["rm", "-q", "--cached", "--"]), paths)
	return res

func unstage_all() -> Dictionary:
	return execute_git(PackedStringArray(["reset", "-q"]))

func _batched(base_args: PackedStringArray, paths: PackedStringArray) -> Dictionary:
	var last := result_ok()
	for i in range(0, paths.size(), BATCH_SIZE):
		var args := base_args.duplicate()
		for p in paths.slice(i, mini(i + BATCH_SIZE, paths.size())):
			args.append(to_repo_path(p))
		last = execute_git(args)
		if not last.success:
			return last
	return last

func commit(message: String) -> Dictionary:
	return execute_git(PackedStringArray(["commit", "-m", message]))

func fetch() -> Dictionary:
	return execute_git(PackedStringArray(["fetch", "--all", "--prune"]))

func pull() -> Dictionary:
	return execute_git(PackedStringArray(["pull"]))

func push() -> Dictionary:
	return execute_git(PackedStringArray(["push"]))

## Set or clear write permission on a file, without spawning a process
func set_file_writable(path: String, writable: bool) -> bool:
	var abs_path := to_abs_path(path)
	if not FileAccess.file_exists(abs_path):
		return false
	if OS.get_name() == "Windows":
		return FileAccess.set_read_only_attribute(abs_path, not writable) == OK
	var perms := FileAccess.get_unix_permissions(abs_path)
	if writable:
		perms |= FileAccess.UNIX_WRITE_OWNER
	else:
		perms &= ~(FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_WRITE_GROUP | FileAccess.UNIX_WRITE_OTHER)
	return FileAccess.set_unix_permissions(abs_path, perms) == OK

func is_file_read_only(path: String) -> bool:
	var abs_path := to_abs_path(path)
	if not FileAccess.file_exists(abs_path):
		return false
	if OS.get_name() == "Windows":
		return FileAccess.get_read_only_attribute(abs_path)
	return (FileAccess.get_unix_permissions(abs_path) & FileAccess.UNIX_WRITE_OWNER) == 0

# =========================================================================
# HISTORY
# =========================================================================

## Commit history for the Git Graph
func get_git_log(max_count: int = 100) -> Array[GitTypes.CommitItem]:
	var result: Array[GitTypes.CommitItem] = []
	# Unit separator (0x1f) between fields, record separator (0x1e) between commits,
	# so commit messages can contain anything.
	var format := "%H%x1f%h%x1f%P%x1f%an%x1f%ae%x1f%cr%x1f%ci%x1f%D%x1f%s%x1f%b%x1e"
	var res := execute_git(PackedStringArray(["log", "--all", "--date-order", "-n", str(max_count), "--format=" + format]), false)
	if not res.success:
		return result

	for raw: String in (res.raw as String).split(char(0x1e), false):
		var f: PackedStringArray = raw.trim_prefix("\n").split(char(0x1f))
		if f.size() < 10:
			continue
		var c := GitTypes.CommitItem.new()
		c.sha = f[0]
		c.short_sha = f[1]
		if not f[2].is_empty():
			c.parents.assign(f[2].split(" ", false))
		c.author_name = f[3]
		c.author_email = f[4]
		c.date_relative = f[5]
		c.date_iso = f[6]
		for r in f[7].split(",", false):
			var ref: String = r.strip_edges()
			if ref == "HEAD":
				c.is_head = true
			elif ref.begins_with("HEAD -> "):
				c.is_head = true
				c.branches.append(ref.trim_prefix("HEAD -> "))
			elif ref.begins_with("tag: "):
				c.tags.append(ref.trim_prefix("tag: "))
			else:
				c.branches.append(ref)
		c.subject = f[8]
		c.body = f[9].strip_edges()
		result.append(c)
	return result

## Files changed by a commit, as [{code, path}]
func get_commit_files(sha: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var res := execute_git(PackedStringArray(["diff-tree", "--no-commit-id", "--name-status", "-r", "--root", sha]), false)
	if not res.success:
		return result
	for line in res.raw.split("\n", false):
		# "M<TAB>path", or "R100<TAB>old<TAB>new" for renames and copies
		var parts: PackedStringArray = line.split("\t")
		if parts.size() < 2:
			continue
		result.append({"code": parts[0].substr(0, 1), "path": unquote(parts[parts.size() - 1])})
	return result
