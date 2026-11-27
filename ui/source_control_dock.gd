@tool
extends VBoxContainer

const GitTypes = preload("../core/git_types.gd")
const LFSManager = preload("../core/lfs_manager.gd")
const HijackWarningBanner = preload("components/hijack_warning_banner.gd")
const CommitBox = preload("components/commit_box.gd")

var lfs_manager: LFSManager

# UI Elements
var branch_label: Label
var refresh_btn: Button
var fetch_btn: Button
var pull_btn: Button
var push_btn: Button

var workflow_label: Label
var hijack_banner: HijackWarningBanner
var commit_box: CommitBox
var file_tree: Tree

# Tree Roots
var root_item: TreeItem
var hijacked_section: TreeItem
var staged_section: TreeItem
var changes_section: TreeItem
var team_locks_section: TreeItem

# Item action button IDs
enum TreeBtnId {
	STAGE = 10,
	UNSTAGE = 11,
	DISCARD = 12,
	LOCK = 13,
	UNLOCK = 14,
	HIJACK = 15,
	STAGE_ALL = 20,
	UNSTAGE_ALL = 21,
	DISCARD_ALL = 22,
	UNSTAGE_ALL_HIJACKED = 23
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

	# 1. Header Toolbar
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	add_child(header)

	branch_label = Label.new()
	branch_label.text = "🌿 main"
	branch_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(branch_label)

	refresh_btn = Button.new()
	refresh_btn.tooltip_text = "Refresh Status & Locks"
	refresh_btn.icon = _get_icon("Reload")
	refresh_btn.pressed.connect(_on_refresh_pressed)
	header.add_child(refresh_btn)

	fetch_btn = Button.new()
	fetch_btn.tooltip_text = "Fetch from remote"
	fetch_btn.icon = _get_icon("Search")
	fetch_btn.pressed.connect(func(): lfs_manager.fetch())
	header.add_child(fetch_btn)

	pull_btn = Button.new()
	pull_btn.tooltip_text = "Pull (Sync) latest changes"
	pull_btn.icon = _get_icon("MoveDown")
	pull_btn.pressed.connect(func(): lfs_manager.pull())
	header.add_child(pull_btn)

	push_btn = Button.new()
	push_btn.tooltip_text = "Push commits to remote"
	push_btn.icon = _get_icon("MoveUp")
	push_btn.pressed.connect(func(): lfs_manager.push())
	header.add_child(push_btn)

	# 2. Data workflow status (branch rules, bypass, hook)
	workflow_label = Label.new()
	workflow_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	workflow_label.visible = false
	add_child(workflow_label)

	# 3. Hijack Warning Banner
	hijack_banner = HijackWarningBanner.new()
	add_child(hijack_banner)

	# 3. Commit Box
	commit_box = CommitBox.new()
	add_child(commit_box)

	# 4. File Tree
	file_tree = Tree.new()
	file_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	file_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	file_tree.hide_root = true
	file_tree.columns = 1
	file_tree.button_clicked.connect(_on_tree_button_clicked)
	file_tree.item_activated.connect(_on_item_double_clicked)
	add_child(file_tree)

	root_item = file_tree.create_item()

func _on_refresh_pressed() -> void:
	if lfs_manager != null:
		lfs_manager.refresh_async()

func _on_op_started(op_name: String) -> void:
	refresh_btn.disabled = true

func _on_op_completed(op_name: String, success: bool, msg: String) -> void:
	refresh_btn.disabled = false
	if not success:
		push_warning("LFS Checkout: %s failed: %s" % [op_name, msg])

func _on_snapshot_updated(snapshot: GitTypes.RepoSnapshot) -> void:
	_update_branch_header(snapshot)
	_update_workflow_label(snapshot)
	_rebuild_tree(snapshot)

func _update_workflow_label(snapshot: GitTypes.RepoSnapshot) -> void:
	var lines := PackedStringArray()
	var color := Color(1.0, 0.75, 0.2)
	if not snapshot.is_repo:
		workflow_label.visible = false
		return
	if snapshot.bypass_enabled:
		lines.append("⚠ Data branch rules are bypassed in this clone. Turn this off in Project > Tools > Source Control when the emergency is over.")
		color = Color(1.0, 0.45, 0.45)
	elif not snapshot.on_data_branch:
		lines.append("Code branch: data files can't be checked out or committed here. Data branches: %s. Hijack files to try changes locally." % ", ".join(snapshot.data_branches))
	match snapshot.hook_state:
		"foreign":
			lines.append("⚠ Another pre-commit hook is installed, so commits made outside the editor aren't checked. See the Output panel to add the check to it.")
		"missing", "outdated":
			lines.append("⚠ The pre-commit hook isn't installed. Use Project > Tools > Source Control: Reinstall Pre-Commit Hook.")
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

func _rebuild_tree(snapshot: GitTypes.RepoSnapshot) -> void:
	file_tree.clear()
	root_item = file_tree.create_item()

	# -------------------------------------------------------------
	# 1. HIJACKED FILES (Purple Highlight)
	# -------------------------------------------------------------
	if not snapshot.hijacked_files.is_empty():
		hijacked_section = file_tree.create_item(root_item)
		hijacked_section.set_text(0, "🟣 HIJACKED (Local Edits - No Server Lock) (%d)" % snapshot.hijacked_files.size())
		hijacked_section.set_custom_color(0, Color(0.85, 0.45, 1.0))
		hijacked_section.set_selectable(0, false)

		for item in snapshot.hijacked_files:
			var row = file_tree.create_item(hijacked_section)
			row.set_text(0, "🟣 %s [Hijacked]" % item.path)
			row.set_custom_color(0, Color(0.85, 0.45, 1.0))
			row.set_metadata(0, item)
			var hijack_tip := "Changed locally without holding the lock.\nCheck it out (take the lock) before committing."
			if not item.lock_owner.is_empty():
				hijack_tip += "\nCurrently locked by: %s" % item.lock_owner
			row.set_tooltip_text(0, hijack_tip)
			# Action Buttons: Promote Lock, Revert
			row.add_button(0, _get_icon("Lock"), TreeBtnId.LOCK, false, "Promote to Check Out (Acquire LFS Lock)")
			row.add_button(0, _get_icon("Reload"), TreeBtnId.DISCARD, false, "Revert Hijack (Discard Changes)")

	# -------------------------------------------------------------
	# 2. STAGED CHANGES
	# -------------------------------------------------------------
	staged_section = file_tree.create_item(root_item)
	staged_section.set_text(0, "STAGED CHANGES (%d)" % snapshot.staged_files.size())
	staged_section.set_selectable(0, false)
	if not snapshot.staged_files.is_empty():
		staged_section.add_button(0, _get_icon("Remove"), TreeBtnId.UNSTAGE_ALL, false, "Unstage All Changes")

	var blocked := lfs_manager.get_blocked_staged_data()
	for item in snapshot.staged_files:
		var row = file_tree.create_item(staged_section)
		var is_blocked := blocked.has(item.path)
		var prefix = ""
		if item.lock_state == GitTypes.LockState.HIJACKED:
			prefix = "⚠️ [HIJACKED] "
		elif is_blocked:
			prefix = "⛔ [DATA] "
		row.set_text(0, "%s%s %s" % [prefix, item.get_status_emoji(), item.path])
		var bad := is_blocked or item.lock_state == GitTypes.LockState.HIJACKED
		row.set_custom_color(0, Color(1.0, 0.35, 0.35) if bad else item.get_status_color())
		row.set_metadata(0, item)
		row.set_tooltip_text(0, "Data file: can't be committed on this branch. Unstage it, or commit it from a data branch." if is_blocked else "Staged file: " + item.path)
		row.add_button(0, _get_icon("Remove"), TreeBtnId.UNSTAGE, false, "Unstage File")

	# -------------------------------------------------------------
	# 3. WORKING TREE CHANGES
	# -------------------------------------------------------------
	changes_section = file_tree.create_item(root_item)
	changes_section.set_text(0, "CHANGES (%d)" % snapshot.working_files.size())
	changes_section.set_selectable(0, false)
	if not snapshot.working_files.is_empty():
		changes_section.add_button(0, _get_icon("Add"), TreeBtnId.STAGE_ALL, false, "Stage All Valid Changes")
		changes_section.add_button(0, _get_icon("Reload"), TreeBtnId.DISCARD_ALL, false, "Discard All Changes")

	for item in snapshot.working_files:
		var row = file_tree.create_item(changes_section)
		row.set_text(0, "%s %s" % [item.get_status_emoji(), item.path])
		row.set_custom_color(0, item.get_status_color())
		row.set_metadata(0, item)
		row.set_tooltip_text(0, "Modified file: " + item.path)
		# Action Buttons: Stage (+), Discard (↩️)
		row.add_button(0, _get_icon("Add"), TreeBtnId.STAGE, false, "Stage File")
		row.add_button(0, _get_icon("Reload"), TreeBtnId.DISCARD, false, "Discard Changes")

	# -------------------------------------------------------------
	# 4. LOCKED BY TEAM
	# -------------------------------------------------------------
	if not snapshot.locked_by_other_files.is_empty():
		team_locks_section = file_tree.create_item(root_item)
		team_locks_section.set_text(0, "🟡 LOCKED BY OTHERS (%d)" % snapshot.locked_by_other_files.size())
		team_locks_section.set_custom_color(0, Color(1.0, 0.75, 0.2))
		team_locks_section.set_selectable(0, false)

		for item in snapshot.locked_by_other_files:
			var row = file_tree.create_item(team_locks_section)
			row.set_text(0, "🟡 %s (%s)" % [item.path, item.lock_owner])
			row.set_custom_color(0, Color(1.0, 0.75, 0.2))
			row.set_metadata(0, item)
			row.set_tooltip_text(0, "Locked by: %s\nLock ID: %s" % [item.lock_owner, item.lock_id])
			# Hijack button
			row.add_button(0, _get_icon("Edit"), TreeBtnId.HIJACK, false, "Hijack (Make Writable for Local Testing)")

func _on_tree_button_clicked(item: TreeItem, column: int, id: int, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return

	var file_meta: GitTypes.FileStatusItem = item.get_metadata(column)

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
		TreeBtnId.HIJACK:
			if file_meta != null:
				lfs_manager.hijack_file(file_meta.path)

func _confirm_discard_file(path: String) -> void:
	_confirm("Discard local changes to %s? This can't be undone." % path.get_file(), func():
		lfs_manager.revert_file(path))

func _confirm_discard_all() -> void:
	var paths := PackedStringArray()
	for f in lfs_manager.current_snapshot.working_files:
		paths.append(f.path)
	if paths.is_empty():
		return
	_confirm("Discard all %d unstaged changes? New files are moved to the trash. This can't be undone." % paths.size(), func():
		lfs_manager.revert_files(paths))

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
	add_child(dialog)
	dialog.popup_centered()

func _on_item_double_clicked() -> void:
	var selected = file_tree.get_selected()
	if selected == null:
		return
	var meta: GitTypes.FileStatusItem = selected.get_metadata(0)
	if meta != null and not meta.res_path.is_empty():
		var res_p = meta.res_path
		if ResourceLoader.exists(res_p):
			var res = ResourceLoader.load(res_p)
			if res != null:
				EditorInterface.edit_resource(res)
		elif FileAccess.file_exists(lfs_manager.cli.to_abs_path(meta.path)):
			EditorInterface.select_file(res_p)

func _get_icon(name: String) -> Texture2D:
	if EditorInterface.get_editor_theme().has_icon(name, "EditorIcons"):
		return EditorInterface.get_editor_theme().get_icon(name, "EditorIcons")
	return null
