@tool
class_name GitTypes
extends RefCounted

## Lock States for Assets
enum LockState {
	NOT_LOCKABLE,       ## Standard text/source file (not tracked by Git LFS lockable)
	AVAILABLE,          ## Lockable binary asset, clean, read-only on disk, ready to check out
	LOCKED_BY_ME,       ## Locked on server by current user, writable (Checked out)
	LOCKED_BY_OTHER,    ## Locked on server by another team member, read-only on disk
	HIJACKED,           ## Lockable binary asset modified locally WITHOUT server lock (Local test)
	OUT_OF_DATE         ## Remote has newer version on Gitea (needs sync before lock)
}

## File Working Tree & Index Change States
enum ChangeState {
	UNMODIFIED,
	MODIFIED,
	ADDED,
	DELETED,
	RENAMED,
	UNTRACKED,
	CONFLICTED
}

## Staging States
enum StagedState {
	UNSTAGED,
	STAGED,
	PARTIALLY_STAGED
}

## Represents a single LFS lock from server
class LockRecord extends RefCounted:
	var id: String = ""
	var path: String = ""
	var owner: String = ""
	var locked_at: String = ""

	func _to_string() -> String:
		return "LockRecord(%s by %s, id: %s)" % [path, owner, id]

## Represents a tracked project file's Git & LFS status
class FileStatusItem extends RefCounted:
	var path: String = ""                 ## Relative to repo root (e.g. "assets/texture.png")
	var res_path: String = ""             ## Godot res:// path (e.g. "res://assets/texture.png")
	var is_lockable: bool = false         ## Is tracked as lockable in .gitattributes
	var lock_state: LockState = LockState.NOT_LOCKABLE
	var lock_owner: String = ""
	var lock_id: String = ""
	var change_state: ChangeState = ChangeState.UNMODIFIED
	var staged_state: StagedState = StagedState.UNSTAGED
	var is_read_only: bool = false
	var is_out_of_date: bool = false

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
					ChangeState.UNTRACKED: return "[Untracked]"
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
					ChangeState.UNTRACKED: return "U"
					_: return ""

	func get_status_color() -> Color:
		match lock_state:
			LockState.LOCKED_BY_ME: return Color(0.3, 0.9, 0.3)      # Bright Green
			LockState.LOCKED_BY_OTHER: return Color(1.0, 0.75, 0.2)   # Amber / Orange
			LockState.HIJACKED: return Color(0.85, 0.45, 1.0)        # Purple
			LockState.OUT_OF_DATE: return Color(1.0, 0.35, 0.35)     # Red
			LockState.AVAILABLE: return Color(0.7, 0.7, 0.7)         # Subdued Gray
			_:
				match change_state:
					ChangeState.MODIFIED: return Color(0.35, 0.75, 1.0)
					ChangeState.ADDED: return Color(0.4, 0.9, 0.4)
					ChangeState.DELETED: return Color(0.9, 0.4, 0.4)
					_: return Color(0.8, 0.8, 0.8)

## Represents a Git commit for the Git Graph
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

## Full Repository Snapshot
class RepoSnapshot extends RefCounted:
	var branch_name: String = ""
	var upstream_name: String = ""
	var ahead_count: int = 0
	var behind_count: int = 0
	var current_user_name: String = ""
	var current_user_email: String = ""
	
	# File categorized lists
	var staged_files: Array[FileStatusItem] = []
	var working_files: Array[FileStatusItem] = []
	var hijacked_files: Array[FileStatusItem] = []
	var locked_by_other_files: Array[FileStatusItem] = []
	var all_tracked_files: Dictionary = {}  # relative_path -> FileStatusItem
	var active_server_locks: Dictionary = {} # relative_path -> LockRecord
