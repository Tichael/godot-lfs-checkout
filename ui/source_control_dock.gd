@tool
extends VBoxContainer

## Source Control dock.
##
## Data files (lockable files and their .import files) are organized in
## changelists, which are checked out, shelved and submitted together.
## Code files keep the usual staged/unstaged flow and the commit box.

const GitTypes = preload("../core/git_types.gd")
const LFSManager = preload("../core/lfs_manager.gd")
const Changelists = preload("../core/changelists.gd")
const HijackWarningBanner = preload("components/hijack_warning_banner.gd")
const CommitBox = preload("components/commit_box.gd")

const COLOR_WARN := Color(1.0, 0.75, 0.2)
const COLOR_BAD := Color(1.0, 0.35, 0.35)
const COLOR_MUTED := Color(0.6, 0.6, 0.6)

var lfs_manager: LFSManager

# UI Elements
var branch_label: Label
var refresh_btn: Button
var fetch_btn: Button
var pull_btn: Button
var push_btn: Button
var new_changelist_btn: Button

var workflow_label: Label
var hijack_banner: HijackWarningBanner
var commit_box: CommitBox
var file_tree: Tree
var move_menu: PopupMenu

var root_item: TreeItem
var _move_paths := PackedStringArray()

# Tree button IDs
enum TreeBtnId {
	STAGE = 10,
	UNSTAGE = 11,
	DISCARD = 12,
	LOCK = 13,
	UNLOCK = 14,
	HIJACK = 15,
	MOVE = 16,
	STAGE_ALL = 20,
	UNSTAGE_ALL = 21,
	DISCARD_ALL = 22,
	CL_SUBMIT = 30,
	CL_SHELVE = 31,
	CL_UNSHELVE = 32,
	CL_RENAME = 33,
	CL_DELETE = 34,
}

func _init():
	name = "Source Control"

func _ready():
	name = "Source Control"
	_build_ui()

func setup(manager: LFSManager) -> void:
	lfs_manager = manager
	if hijack_banner != null:
		hijack_banner.setup(lfs_manager)
	if commit_box != null:
		commit_box.setup(lfs_manager)

	if lfs_manager != null:
		lfs_manager.snapshot_updated.connect(_on_snapshot_updated)
		lfs_manager.operation_started.connect(_on_op_started)
		lfs_manager.operation_completed.connect(_on_op_completed)

func _build_ui() -> void:
	add_theme_constant_override("separation", 6)

	# 1. Header toolbar
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	add_child(header)

	branch_label = Label.new()
	branch_label.text = "🌿 main"
	branch_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	branch_label.clip_text = true
	header.add_child(branch_label)

	new_changelist_btn = _header_button(header, "Add", "New changelist")
	new_changelist_btn.pressed.connect(func(): _prompt_name("New Changelist", "", func(n): lfs_manager.create_changelist(n)))
	refresh_btn = _header_button(header, "Reload", "Refresh status and locks")
	refresh_btn.pressed.connect(_on_refresh_pressed)
	fetch_btn = _header_button(header, "Search", "Fetch from remote")
	fetch_btn.pressed.connect(func(): lfs_manager.fetch())
	pull_btn = _header_button(header, "MoveDown", "Pull latest changes")
	pull_btn.pressed.connect(func(): lfs_manager.pull())
	push_btn = _header_button(header, "MoveUp", "Push commits")
	push_btn.pressed.connect(func(): lfs_manager.push())

	# 2. Data workflow status (branch rules, bypass, hook)
	workflow_label = Label.new()
	workflow_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	workflow_label.visible = false
	add_child(workflow_label)

	# 3. Hijack warning banner
	hijack_banner = HijackWarningBanner.new()
	add_child(hijack_banner)

	# 4. File tree: changelists, then code changes, then others' locks
	file_tree = Tree.new()
	file_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	file_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	file_tree.hide_root = true
	file_tree.columns = 1
	file_tree.select_mode = Tree.SELECT_MULTI
	file_tree.button_clicked.connect(_on_tree_button_clicked)
	file_tree.item_activated.connect(_on_item_double_clicked)
	add_child(file_tree)
	root_item = file_tree.create_item()

	# 5. Commit box, for code changes
	commit_box = CommitBox.new()
	add_child(commit_box)

	move_menu = PopupMenu.new()
	move_menu.id_pressed.connect(_on_move_menu_id)
	add_child(move_menu)

func _header_button(parent: Control, icon_name: String, tooltip: String) -> Button:
	var btn := Button.new()
	btn.icon = _get_icon(icon_name)
	btn.tooltip_text = tooltip
	btn.flat = true
	parent.add_child(btn)
	return btn

func _on_refresh_pressed() -> void:
	if lfs_manager != null:
		lfs_manager.refresh_async()

func _on_op_started(_op_name: String) -> void:
	refresh_btn.disabled = true

func _on_op_completed(op_name: String, success: bool, msg: String) -> void:
	refresh_btn.disabled = false
	if success:
		if op_name in ["Submit", "Shelve", "Unshelve", "Lock File"]:
			print("LFS Checkout: ", msg)
		return
	push_warning("LFS Checkout: %s failed: %s" % [op_name, msg])
	# Changelist operations can leave things to sort out by hand; say so in a dialog
	if op_name in ["Submit", "Shelve", "Unshelve"]:
		var dialog := AcceptDialog.new()
		dialog.title = op_name + " Failed"
		dialog.dialog_text = msg
		dialog.visibility_changed.connect(func():
			if not dialog.visible:
				dialog.queue_free()
		)
		add_child(dialog)
		dialog.popup_centered()

func _on_snapshot_updated(snapshot: GitTypes.RepoSnapshot) -> void:
	_update_branch_header(snapshot)
	_update_workflow_label(snapshot)
	_rebuild_tree(snapshot)

func _update_workflow_label(snapshot: GitTypes.RepoSnapshot) -> void:
	var lines := PackedStringArray()
	var color := COLOR_WARN
	if not snapshot.is_repo:
		workflow_label.visible = false
		return
	if snapshot.bypass_enabled:
		lines.append("⚠ Data branch rules are bypassed in this clone. Turn this off in Project > Tools > Source Control when the emergency is over.")
		color = Color(1.0, 0.45, 0.45)
	elif not snapshot.on_data_branch:
		var target := snapshot.primary_data_branch if not snapshot.primary_data_branch.is_empty() else ", ".join(snapshot.data_branches)
		if snapshot.allow_lock_on_code_branches:
			lines.append("Code branch: you can check out data here. Submitting a changelist commits it to %s." % target)
		else:
			lines.append("Code branch: data can't be checked out here (data branches: %s). Hijack files to try changes locally." % ", ".join(snapshot.data_branches))
	match snapshot.hook_state:
		"foreign":
			lines.append("⚠ Another pre-commit hook is installed, so commits made outside the editor aren't checked. See the Output panel to add the check to it.")
		"missing", "outdated":
			lines.append("⚠ The pre-commit hook isn't installed. Use Project > Tools > Source Control: Reinstall Pre-Commit Hook.")
	var lfs: Dictionary = snapshot.lfs_setup
	if not lfs.is_empty():
		if not lfs.lfs_found:
			lines.append("⚠ Git LFS isn't installed. Install it from https://git-lfs.com, then restart the editor.")
			color = COLOR_BAD
		elif not lfs.filter_ok or not lfs.missing_hooks.is_empty():
			lines.append("⚠ Git LFS isn't fully set up in this clone, so pushes may not upload LFS files. Use Project > Tools > Source Control: Set Up Git LFS in This Clone.")
			color = COLOR_BAD
		elif not lfs.foreign_hooks.is_empty():
			lines.append("⚠ Some git hooks don't run Git LFS (%s). See the Output panel." % ", ".join(lfs.foreign_hooks))
	workflow_label.text = "\n".join(lines)
	workflow_label.add_theme_color_override("font_color", color)
	workflow_label.visible = not lines.is_empty()

func _update_branch_header(snapshot: GitTypes.RepoSnapshot) -> void:
	if not snapshot.is_repo:
		branch_label.text = "Not a git repository"
		branch_label.tooltip_text = ""
		pull_btn.text = ""
		push_btn.text = ""
		return
	branch_label.tooltip_text = "Couldn't read LFS locks:\n" + snapshot.lock_error if not snapshot.lock_error.is_empty() else ""
	var b_str = "🌿 %s" % (snapshot.branch_name if not snapshot.branch_name.is_empty() else "detached")
	if not snapshot.lock_error.is_empty():
		b_str += " ⚠"
	if snapshot.ahead_count > 0 or snapshot.behind_count > 0:
		b_str += " [↑%d ↓%d]" % [snapshot.ahead_count, snapshot.behind_count]
	branch_label.text = b_str
	pull_btn.text = str(snapshot.behind_count) if snapshot.behind_count > 0 else ""
	push_btn.text = str(snapshot.ahead_count) if snapshot.ahead_count > 0 else ""

func _section(text: String, color: Color = Color(0.85, 0.85, 0.85)) -> TreeItem:
	var section := file_tree.create_item(root_item)
	section.set_text(0, text)
	section.set_custom_color(0, color)
	section.set_selectable(0, false)
	return section

func _rebuild_tree(snapshot: GitTypes.RepoSnapshot) -> void:
	file_tree.clear()
	root_item = file_tree.create_item()
	if not snapshot.is_repo:
		return

	# 1. Changelists (data files)
	var groups := lfs_manager.get_changelist_files()
	for cl: Changelists.Changelist in lfs_manager.changelists.get_all():
		var files: Array = groups.get(cl.id, [])
		_add_changelist(cl, files, snapshot)

	# 2. Code changes (everything that isn't data)
	var staged := snapshot.staged_files.filter(func(f): return not f.is_data)
	var working := snapshot.working_files.filter(func(f): return not f.is_data)

	var staged_section := _section("CODE: STAGED (%d)" % staged.size())
	if not staged.is_empty():
		staged_section.add_button(0, _get_icon("Remove"), TreeBtnId.UNSTAGE_ALL, false, "Unstage all")
	for item: GitTypes.FileStatusItem in staged:
		var row := _file_row(staged_section, item)
		row.add_button(0, _get_icon("Remove"), TreeBtnId.UNSTAGE, false, "Unstage")

	var changes_section := _section("CODE: CHANGES (%d)" % working.size())
	if not working.is_empty():
		changes_section.add_button(0, _get_icon("Add"), TreeBtnId.STAGE_ALL, false, "Stage all")
		changes_section.add_button(0, _get_icon("Reload"), TreeBtnId.DISCARD_ALL, false, "Discard all")
	for item: GitTypes.FileStatusItem in working:
		var row := _file_row(changes_section, item)
		row.add_button(0, _get_icon("Add"), TreeBtnId.STAGE, false, "Stage")
		row.add_button(0, _get_icon("Reload"), TreeBtnId.DISCARD, false, "Discard changes")

	# 3. Locked by others
	if not snapshot.locked_by_other_files.is_empty():
		var locks_section := _section("🟡 LOCKED BY OTHERS (%d)" % snapshot.locked_by_other_files.size(), COLOR_WARN)
		for item in snapshot.locked_by_other_files:
			var row = file_tree.create_item(locks_section)
			row.set_text(0, "🟡 %s (%s)" % [item.path, item.lock_owner])
			row.set_custom_color(0, COLOR_WARN)
			row.set_metadata(0, item)
			row.set_tooltip_text(0, "Locked by: %s\nLock ID: %s" % [item.lock_owner, item.lock_id])
			row.add_button(0, _get_icon("Edit"), TreeBtnId.HIJACK, false, "Hijack (make writable to try changes locally)")

func _add_changelist(cl: Changelists.Changelist, files: Array, snapshot: GitTypes.RepoSnapshot) -> void:
	# Default is hidden while it's empty; named changelists always show
	if cl.is_default() and files.is_empty() and not cl.is_shelved() and not cl.pending_push:
		return
	var count := cl.shelved_files.size() if cl.is_shelved() else files.size()
	var title := "📦 %s (%d)" % [cl.name, count]
	var color := Color(0.85, 0.85, 0.85)
	var tip := "Changelist"
	if cl.is_shelved():
		title += "  [shelved]"
		color = COLOR_MUTED
		tip = "Shelved: the changes are stashed. Unshelve to bring them back."
	elif cl.pending_push:
		title += "  [push pending]"
		color = COLOR_WARN
		tip = "Committed to %s, but not pushed yet. Submit again to push and release the locks." % cl.pending_branch
	var section := _section(title, color)
	section.set_metadata(0, {"changelist": cl.id})
	section.set_tooltip_text(0, tip)

	if cl.is_shelved():
		section.add_button(0, _get_icon("Load"), TreeBtnId.CL_UNSHELVE, false, "Unshelve")
	else:
		var can_submit := not files.is_empty() or cl.pending_push
		var submit_tip := "Submit: commit, push and release the locks"
		if not snapshot.can_commit_data() and not snapshot.primary_data_branch.is_empty():
			submit_tip += " (switches to %s and back)" % snapshot.primary_data_branch
		section.add_button(0, _get_icon("MoveUp"), TreeBtnId.CL_SUBMIT, not can_submit, submit_tip)
		section.add_button(0, _get_icon("Save"), TreeBtnId.CL_SHELVE, files.is_empty(), "Shelve (stash the changes, keep the locks)")
	if not cl.is_default():
		section.add_button(0, _get_icon("Rename"), TreeBtnId.CL_RENAME, false, "Rename")
		section.add_button(0, _get_icon("Remove"), TreeBtnId.CL_DELETE, cl.is_shelved(), "Delete (files go back to Default)")

	if cl.is_shelved():
		for p in cl.shelved_files:
			var row := file_tree.create_item(section)
			row.set_text(0, "  " + p)
			row.set_custom_color(0, COLOR_MUTED)
			row.set_selectable(0, false)
		return

	for item: GitTypes.FileStatusItem in files:
		var row := _file_row(section, item)
		if item.lock_state == GitTypes.LockState.HIJACKED and snapshot.can_lock_data() and item.lock_owner.is_empty():
			row.add_button(0, _get_icon("Lock"), TreeBtnId.LOCK, false, "Check out (take the lock)")
		if item.lock_state == GitTypes.LockState.LOCKED_BY_ME and item.change_state == GitTypes.ChangeState.UNMODIFIED:
			row.add_button(0, _get_icon("Unlock"), TreeBtnId.UNLOCK, false, "Release the lock")
		row.add_button(0, _get_icon("ArrowRight"), TreeBtnId.MOVE, false, "Move to another changelist")
		if item.change_state != GitTypes.ChangeState.UNMODIFIED:
			row.add_button(0, _get_icon("Reload"), TreeBtnId.DISCARD, false, "Discard changes")

func _file_row(parent: TreeItem, item: GitTypes.FileStatusItem) -> TreeItem:
	var row := file_tree.create_item(parent)
	var label := item.get_status_label()
	if item.change_state == GitTypes.ChangeState.UNMODIFIED and item.lock_state == GitTypes.LockState.LOCKED_BY_ME:
		label = "[Checked Out, unchanged]"
	row.set_text(0, "%s %s %s" % [item.get_status_emoji(), item.path, label])
	row.set_custom_color(0, item.get_status_color())
	row.set_metadata(0, item)
	var tip := item.path
	if item.lock_state == GitTypes.LockState.HIJACKED:
		tip += "\nChanged without holding the lock. Check it out before submitting."
		if not item.lock_owner.is_empty():
			tip += "\nCurrently locked by: %s" % item.lock_owner
	row.set_tooltip_text(0, tip)
	return row

func _on_tree_button_clicked(item: TreeItem, column: int, id: int, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	var meta = item.get_metadata(column)
	var file_meta: GitTypes.FileStatusItem = meta if meta is GitTypes.FileStatusItem else null
	var cl_id: String = meta.get("changelist", "") if meta is Dictionary else ""

	match id:
		TreeBtnId.STAGE_ALL:
			lfs_manager.stage_all_valid_changes()
		TreeBtnId.UNSTAGE_ALL:
			lfs_manager.unstage_all()
		TreeBtnId.DISCARD_ALL:
			_confirm_discard_all()
		TreeBtnId.STAGE:
			if file_meta != null:
				lfs_manager.stage_file(file_meta.path)
		TreeBtnId.UNSTAGE:
			if file_meta != null:
				lfs_manager.unstage_file(file_meta.path)
		TreeBtnId.DISCARD:
			if file_meta != null:
				_confirm_discard_file(file_meta.path)
		TreeBtnId.LOCK:
			if file_meta != null:
				lfs_manager.checkout_file(file_meta.path)
		TreeBtnId.UNLOCK:
			if file_meta != null:
				lfs_manager.unlock_file(file_meta.path)
		TreeBtnId.HIJACK:
			if file_meta != null:
				lfs_manager.hijack_file(file_meta.path)
		TreeBtnId.MOVE:
			if file_meta != null:
				_show_move_menu(_selected_or(file_meta.path))
		TreeBtnId.CL_SUBMIT:
			_prompt_submit(cl_id)
		TreeBtnId.CL_SHELVE:
			lfs_manager.shelve_changelist(cl_id)
		TreeBtnId.CL_UNSHELVE:
			lfs_manager.unshelve_changelist(cl_id)
		TreeBtnId.CL_RENAME:
			var cl := lfs_manager.changelists.get_changelist(cl_id)
			if cl != null:
				_prompt_name("Rename Changelist", cl.name, func(n): lfs_manager.rename_changelist(cl_id, n))
		TreeBtnId.CL_DELETE:
			lfs_manager.delete_changelist(cl_id)

## The selected file rows' paths, or just `path` if it isn't among them
func _selected_or(path: String) -> PackedStringArray:
	var paths := PackedStringArray()
	var sel := file_tree.get_next_selected(null)
	while sel != null:
		var m = sel.get_metadata(0)
		if m is GitTypes.FileStatusItem and m.is_data:
			paths.append(m.path)
		sel = file_tree.get_next_selected(sel)
	return paths if paths.has(path) else PackedStringArray([path])

# =========================================================================
# DIALOGS
# =========================================================================

func _show_move_menu(paths: PackedStringArray) -> void:
	_move_paths = paths
	move_menu.clear()
	var all := lfs_manager.changelists.get_all()
	for i in all.size():
		if not all[i].is_shelved():
			move_menu.add_item(all[i].name, i)
	move_menu.add_separator()
	move_menu.add_item("New Changelist...", 10000)
	move_menu.position = Vector2i(get_screen_position() + get_local_mouse_position())
	move_menu.popup()

func _on_move_menu_id(id: int) -> void:
	var paths := _move_paths
	if id == 10000:
		_prompt_name("New Changelist", "", func(n):
			lfs_manager.move_to_changelist(paths, lfs_manager.create_changelist(n)))
		return
	var all := lfs_manager.changelists.get_all()
	if id >= 0 and id < all.size():
		lfs_manager.move_to_changelist(paths, all[id].id)

func _prompt_name(title: String, initial: String, on_ok: Callable) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = title
	var edit := LineEdit.new()
	edit.text = initial
	edit.placeholder_text = "Changelist name"
	edit.custom_minimum_size = Vector2(320, 0)
	dialog.add_child(edit)
	dialog.register_text_enter(edit)
	dialog.confirmed.connect(func():
		var n := edit.text.strip_edges()
		if not n.is_empty():
			on_ok.call(n)
	)
	_popup(dialog)
	edit.grab_focus()

func _prompt_submit(cl_id: String) -> void:
	var cl := lfs_manager.changelists.get_changelist(cl_id)
	if cl == null:
		return
	if cl.pending_push:
		lfs_manager.submit_changelist(cl_id, "")
		return
	var s := lfs_manager.current_snapshot
	var dialog := ConfirmationDialog.new()
	dialog.title = "Submit '%s'" % cl.name
	dialog.ok_button_text = "Submit"
	var box := VBoxContainer.new()
	dialog.add_child(box)
	var info := Label.new()
	if s.can_commit_data():
		info.text = "Commits the changelist to %s, pushes it, and releases its locks." % s.branch_name
	else:
		info.text = "Switches to %s, commits the changelist, pushes it, releases its locks, then switches back to %s.\nYour other changes are stashed during the switch and restored afterwards." % [s.primary_data_branch, s.branch_name]
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.custom_minimum_size = Vector2(420, 0)
	box.add_child(info)
	var edit := TextEdit.new()
	edit.placeholder_text = "Describe the change (commit message)"
	edit.text = cl.description if not cl.description.is_empty() else ("" if cl.is_default() else cl.name)
	edit.custom_minimum_size = Vector2(420, 90)
	box.add_child(edit)
	dialog.confirmed.connect(func():
		lfs_manager.changelists.set_description(cl_id, edit.text)
		lfs_manager.submit_changelist(cl_id, edit.text)
	)
	_popup(dialog)
	edit.grab_focus()

func _popup(dialog: Window) -> void:
	dialog.visibility_changed.connect(func():
		if not dialog.visible:
			dialog.queue_free()
	)
	add_child(dialog)
	dialog.popup_centered()

func _confirm_discard_file(path: String) -> void:
	_confirm("Discard local changes to %s? This can't be undone." % path.get_file(), func():
		lfs_manager.revert_file(path))

func _confirm_discard_all() -> void:
	var paths := PackedStringArray()
	for f in lfs_manager.current_snapshot.working_files:
		if not f.is_data:
			paths.append(f.path)
	if paths.is_empty():
		return
	_confirm("Discard all %d unstaged code changes? New files are moved to the trash. This can't be undone." % paths.size(), func():
		lfs_manager.revert_files(paths))

func _confirm(text: String, on_ok: Callable) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Discard Changes"
	dialog.dialog_text = text
	dialog.ok_button_text = "Discard"
	dialog.confirmed.connect(on_ok)
	_popup(dialog)

func _on_item_double_clicked() -> void:
	var selected = file_tree.get_selected()
	if selected == null:
		return
	var meta = selected.get_metadata(0)
	if meta is GitTypes.FileStatusItem and not meta.res_path.is_empty():
		var res_p: String = meta.res_path
		if ResourceLoader.exists(res_p):
			var res = ResourceLoader.load(res_p)
			if res != null:
				EditorInterface.edit_resource(res)
		elif FileAccess.file_exists(lfs_manager.cli.to_abs_path(meta.path)):
			EditorInterface.select_file(res_p)

func _get_icon(icon_name: String) -> Texture2D:
	if EditorInterface.get_editor_theme().has_icon(icon_name, "EditorIcons"):
		return EditorInterface.get_editor_theme().get_icon(icon_name, "EditorIcons")
	return null
