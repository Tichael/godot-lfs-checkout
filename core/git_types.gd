@tool
extends RefCounted

## Lock states for files
enum LockState {
	NOT_LOCKABLE,       ## Not marked lockable in .gitattributes (text/source files)
	AVAILABLE,          ## Lockable, clean, read-only on disk, ready to check out
	LOCKED_BY_ME,       ## Locked on the server by the current user (checked out)
	LOCKED_BY_OTHER,    ## Locked on the server by someone else
	HIJACKED,           ## Lockable file changed locally without holding its lock
	OUT_OF_DATE,        ## Remote has a newer version (sync before locking)
	NEW_FILE,           ## Lockable file that isn't in HEAD yet, so it needs no lock
}

## Working tree and index change states
enum ChangeState {
	UNMODIFIED,
	MODIFIED,
	ADDED,
	DELETED,
	RENAMED,
	UNTRACKED,
	CONFLICTED
}

## Staging states
enum StagedState {
	UNSTAGED,
	STAGED,
	PARTIALLY_STAGED
}

## A single LFS lock from the server
class LockRecord extends RefCounted:
	var id: String = ""
	var path: String = ""        ## Relative to the repo root
	var owner: String = ""
	var locked_at: String = ""
	var is_mine: bool = false

	func _to_string() -> String:
		return "LockRecord(%s by %s, id: %s)" % [path, owner, id]

## A changed or locked file's Git and LFS status
class FileStatusItem extends RefCounted:
	var path: String = ""                 ## Relative to the repo root (e.g. "assets/texture.png")
	var res_path: String = ""             ## Godot res:// path, empty if outside the project
	var is_lockable: bool = false         ## Marked lockable in .gitattributes
	var is_data: bool = false             ## Lockable, or the .import file of a lockable file
	var lock_state: LockState = LockState.NOT_LOCKABLE
	var lock_owner: String = ""
	var lock_id: String = ""
	var change_state: ChangeState = ChangeState.UNMODIFIED
	var staged_state: StagedState = StagedState.UNSTAGED
	var is_read_only: bool = false
	var is_out_of_date: bool = false

	## True when the file doesn't exist in HEAD (untracked or newly added)
	func is_new() -> bool:
		return change_state == ChangeState.UNTRACKED or change_state == ChangeState.ADDED

	func duplicate_item() -> FileStatusItem:
		var dst := FileStatusItem.new()
		dst.path = path
		dst.res_path = res_path
		dst.is_lockable = is_lockable
		dst.is_data = is_data
		dst.lock_state = lock_state
		dst.lock_owner = lock_owner
		dst.lock_id = lock_id
		dst.change_state = change_state
		dst.staged_state = staged_state
		dst.is_read_only = is_read_only
		dst.is_out_of_date = is_out_of_date
		return dst

	func get_status_label() -> String:
		match lock_state:
			LockState.LOCKED_BY_ME:
				return "[Checked Out]"
			LockState.LOCKED_BY_OTHER:
				return "[Locked: %s]" % lock_owner
			LockState.HIJACKED:
				return "[Hijacked]"
			LockState.OUT_OF_DATE:
				return "[Out of Date]"
			LockState.AVAILABLE:
				return "[Available]"
			_:
				match change_state:
					ChangeState.MODIFIED: return "[Modified]"
					ChangeState.ADDED: return "[Added]"
					ChangeState.DELETED: return "[Deleted]"
					ChangeState.RENAMED: return "[Renamed]"
					ChangeState.UNTRACKED: return "[Untracked]"
					ChangeState.CONFLICTED: return "[Conflicted]"
					_: return ""

	func get_status_emoji() -> String:
		match lock_state:
			LockState.LOCKED_BY_ME: return "🟢"
			LockState.LOCKED_BY_OTHER: return "🟡"
			LockState.HIJACKED: return "🟣"
			LockState.OUT_OF_DATE: return "🔴"
			LockState.AVAILABLE: return "⚪"
			_:
				match change_state:
					ChangeState.MODIFIED: return "M"
					ChangeState.ADDED: return "A"
					ChangeState.DELETED: return "D"
					ChangeState.RENAMED: return "R"
					ChangeState.UNTRACKED: return "U"
					ChangeState.CONFLICTED: return "!"
					_: return ""

	func get_status_color() -> Color:
		match lock_state:
			LockState.LOCKED_BY_ME: return Color(0.3, 0.9, 0.3)      # Green
			LockState.LOCKED_BY_OTHER: return Color(1.0, 0.75, 0.2)   # Amber
			LockState.HIJACKED: return Color(0.85, 0.45, 1.0)        # Purple
			LockState.OUT_OF_DATE: return Color(1.0, 0.35, 0.35)     # Red
			LockState.AVAILABLE: return Color(0.7, 0.7, 0.7)         # Gray
			_:
				match change_state:
					ChangeState.MODIFIED, ChangeState.RENAMED: return Color(0.35, 0.75, 1.0)
					ChangeState.ADDED, ChangeState.UNTRACKED: return Color(0.4, 0.9, 0.4)
					ChangeState.DELETED, ChangeState.CONFLICTED: return Color(0.9, 0.4, 0.4)
					_: return Color(0.8, 0.8, 0.8)

## A Git commit for the Git Graph
class CommitItem extends RefCounted:
	var sha: String = ""
	var short_sha: String = ""
	var author_name: String = ""
	var author_email: String = ""
	var date_relative: String = ""
	var date_iso: String = ""
	var subject: String = ""
	var body: String = ""
	var parents: Array[String] = []
	var branches: Array[String] = []
	var tags: Array[String] = []
	var is_head: bool = false
	var graph_lane: int = 0
	var graph_lines: Array[Dictionary] = []

## Full repository snapshot. Built on a worker thread, then read-only on the main thread.
class RepoSnapshot extends RefCounted:
	var is_repo: bool = false
	var branch_name: String = ""
	var upstream_name: String = ""
	var ahead_count: int = 0
	var behind_count: int = 0
	var current_user_name: String = ""
	var current_user_email: String = ""
	var lock_error: String = ""              ## Set when the lock query failed

	# Data workflow
	var data_branches: PackedStringArray = []
	var on_data_branch: bool = false
	var bypass_enabled: bool = false
	var merge_in_progress: bool = false
	var hook_state: String = ""              ## installed, outdated, missing or foreign
	var lfs_setup: Dictionary = {}           ## From GitCLI.get_lfs_setup()
	var allow_lock_on_code_branches: bool = false
	var primary_data_branch: String = ""     ## Where code-branch data work is submitted

	## Every data file to show in changelists: changed data files, plus files
	## you've checked out but not changed yet
	var data_files: Array[FileStatusItem] = []

	## Data files can be committed here (data branch, or bypass on)
	func can_commit_data() -> bool:
		return on_data_branch or bypass_enabled

	## Data files can be checked out here
	func can_lock_data() -> bool:
		return can_commit_data() or allow_lock_on_code_branches

	# Categorized file lists
	var staged_files: Array[FileStatusItem] = []
	var working_files: Array[FileStatusItem] = []
	var hijacked_files: Array[FileStatusItem] = []
	var locked_by_other_files: Array[FileStatusItem] = []
	var changed_files: Dictionary = {}       # repo path -> FileStatusItem
	var active_server_locks: Dictionary = {} # repo path -> LockRecord
	var lockable: Dictionary = {}            # repo path -> bool, for every path checked
