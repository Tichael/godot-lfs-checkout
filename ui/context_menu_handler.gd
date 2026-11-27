@tool
extends EditorContextMenuPlugin

## FileSystem dock right-click actions. The menu is built from the first selected
## file's status; actions apply to every selected file.

const GitTypes = preload("../core/git_types.gd")
const LFSManager = preload("../core/lfs_manager.gd")

var lfs_manager: LFSManager

func setup(manager: LFSManager) -> void:
	lfs_manager = manager

func _popup_menu(paths: PackedStringArray) -> void:
	if lfs_manager == null or paths.is_empty() or not lfs_manager.current_snapshot.is_repo:
		return

	var first_path := paths[0]
	var item := lfs_manager.get_changed_item(first_path)
	var lock := lfs_manager.get_lock(first_path)
	var is_lockable := lfs_manager.is_path_lockable(first_path)
	var is_hijacked := item != null and item.lock_state == GitTypes.LockState.HIJACKED
	var is_locked_by_me := lock != null and lock.is_mine
	var is_locked_by_other := lock != null and not lock.is_mine
	var is_new := item != null and item.is_new()

	# 1. Lock actions (new files aren't on the server yet, so they can't be locked)
	if is_lockable and not is_new:
		if lock == null and not is_hijacked:
			add_context_menu_item("Check Out (Git LFS Lock)", func(_p):
				for p in paths:
					lfs_manager.checkout_file(p)
			, _get_theme_icon("Lock"))

		if is_locked_by_me:
			add_context_menu_item("Unlock (Release Server Lock)", func(_p):
				for p in paths:
					lfs_manager.unlock_file(p)
			, _get_theme_icon("Unlock"))

		if is_locked_by_other:
			add_context_menu_item("Locked by %s (View Info)" % lock.owner, func(_p):
				OS.alert("File: %s\nLocked by: %s\nLock ID: %s" % [lock.path, lock.owner, lock.id], "Git LFS Lock Info")
			, _get_theme_icon("StatusWarning"))

		# 2. Hijack: make writable locally without the lock
		if not is_locked_by_me and not is_hijacked:
			add_context_menu_item("Hijack File (Make Writable Locally)", func(_p):
				for p in paths:
					lfs_manager.hijack_file(p)
			, _get_theme_icon("Edit"))

		# 3. Promote a hijack to a real checkout
		if is_hijacked and not is_locked_by_other:
			add_context_menu_item("Promote Hijack to Check Out", func(_p):
				for p in paths:
					lfs_manager.checkout_file(p)
			, _get_theme_icon("Lock"))

	# 4. Revert / discard
	if item != null:
		var rev_label := "Revert Hijack (Discard Changes)" if is_hijacked else "Revert / Discard Changes"
		if is_new:
			rev_label = "Discard New File (Move to Trash)"
		add_context_menu_item(rev_label, func(_p):
			_confirm("Discard local changes to %s? This can't be undone." % _describe(paths), func():
				lfs_manager.revert_files(paths))
		, _get_theme_icon("Reload"))

	# 5. Stage
	if item != null and not is_hijacked:
		add_context_menu_item("Stage File", func(_p):
			for p in paths:
				lfs_manager.stage_file(p)
		, _get_theme_icon("Add"))

	# 6. Sync
	add_context_menu_item("Get Latest Revision (Pull)", func(_p):
		lfs_manager.pull()
	, _get_theme_icon("MoveDown"))

func _describe(paths: PackedStringArray) -> String:
	return paths[0].get_file() if paths.size() == 1 else "%d files" % paths.size()

func _confirm(text: String, on_ok: Callable) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Discard Changes"
	dialog.dialog_text = text
	dialog.ok_button_text = "Discard"
	dialog.confirmed.connect(on_ok)
	dialog.visibility_changed.connect(func():
		if not dialog.visible:
			dialog.queue_free()
	)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()

func _get_theme_icon(icon_name: String) -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme.has_icon(icon_name, "EditorIcons"):
		return theme.get_icon(icon_name, "EditorIcons")
	return null
