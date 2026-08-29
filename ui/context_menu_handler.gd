@tool
class_name ContextMenuHandler
extends EditorContextMenuPlugin

const GitTypes = preload("res://addons/godot_git_lfs_p4/core/git_types.gd")
const LFSManager = preload("res://addons/godot_git_lfs_p4/core/lfs_manager.gd")

var lfs_manager: LFSManager

func setup(manager: LFSManager) -> void:
	lfs_manager = manager

func _popup_menu(paths: PackedStringArray) -> void:
	if lfs_manager == null or paths.is_empty():
		return

	var first_path = lfs_manager.cli.to_repo_path(paths[0])
	var is_lockable = lfs_manager.cli.is_path_lockable(first_path)
	var is_hijacked = lfs_manager.is_file_hijacked(first_path)

	var snapshot = lfs_manager.current_snapshot
	var lock_rec: GitTypes.LockRecord = snapshot.active_server_locks.get(first_path, null)
	var is_locked_by_me = (lock_rec != null and (lock_rec.owner == snapshot.current_user_name or lock_rec.owner == snapshot.current_user_email))
	var is_locked_by_other = (lock_rec != null and not is_locked_by_me)

	# 1. Check Out / Lock Action
	if is_lockable or is_hijacked or is_locked_by_other:
		if not is_locked_by_me and not is_locked_by_other:
			add_context_menu_item("🟢 Check Out (Git LFS Lock)", func(_p):
				for p in paths:
					lfs_manager.checkout_file(p)
			, _get_theme_icon("Lock"))

		if is_locked_by_me:
			add_context_menu_item("🔓 Unlock (Release Server Lock)", func(_p):
				for p in paths:
					lfs_manager.unlock_file(p)
			, _get_theme_icon("Unlock"))

		if is_locked_by_other:
			add_context_menu_item("⚠️ Locked by %s (View Info)" % lock_rec.owner, func(_p):
				OS.alert("File: %s\nLocked by: %s\nLock ID: %s" % [first_path, lock_rec.owner, lock_rec.id], "Git LFS Lock Info")
			, _get_theme_icon("StatusWarning"))

	# 2. Hijack / Local Prototype Action
	if (is_lockable or is_locked_by_other) and not is_locked_by_me and not is_hijacked:
		add_context_menu_item("🟣 Hijack File (Make Writable Locally)", func(_p):
			for p in paths:
				lfs_manager.hijack_file(p)
		, _get_theme_icon("Edit"))

	# 3. Promote Hijack to Checkout
	if is_hijacked and not is_locked_by_other:
		add_context_menu_item("🟢 Promote Hijack to Check Out", func(_p):
			for p in paths:
				lfs_manager.checkout_file(p)
		, _get_theme_icon("Lock"))

	# 4. Revert / Discard Action
	var is_modified = snapshot.all_tracked_files.has(first_path) or is_hijacked
	if is_modified:
		var rev_label = "Revert Hijack (Discard Changes)" if is_hijacked else "Revert / Discard Changes"
		add_context_menu_item("↩️ " + rev_label, func(_p):
			for p in paths:
				lfs_manager.revert_file(p)
		, _get_theme_icon("Reload"))

	# 5. Staging Actions
	if is_modified and not is_hijacked:
		add_context_menu_item("➕ Stage File", func(_p):
			for p in paths:
				lfs_manager.stage_file(p)
		, _get_theme_icon("Add"))

	# 6. Sync / Get Latest
	add_context_menu_item("⬇️ Get Latest Revision (Sync)", func(_p):
		lfs_manager.pull()
	, _get_theme_icon("MoveDown"))

func _get_theme_icon(icon_name: String) -> Texture2D:
	if EditorInterface.get_editor_theme().has_icon(icon_name, "EditorIcons"):
		return EditorInterface.get_editor_theme().get_icon(icon_name, "EditorIcons")
	return null
