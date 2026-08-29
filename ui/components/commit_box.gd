@tool
class_name CommitBox
extends VBoxContainer

const LFSManager = preload("res://addons/godot_git_lfs_p4/core/lfs_manager.gd")

var lfs_manager: LFSManager
var prefix_selector: OptionButton
var message_edit: TextEdit
var commit_button: Button
var commit_push_button: Button

func _ready():
	_setup_ui()

func setup(manager: LFSManager) -> void:
	lfs_manager = manager

func _setup_ui() -> void:
	add_theme_constant_override("separation", 4)

	# 1. Conventional Commits prefix selector
	var header_hbox = HBoxContainer.new()
	add_child(header_hbox)

	var lbl = Label.new()
	lbl.text = "Type:"
	header_hbox.add_child(lbl)

	prefix_selector = OptionButton.new()
	prefix_selector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prefix_selector.add_item("None (Custom)", 0)
	prefix_selector.add_item("feat: (New feature)", 1)
	prefix_selector.add_item("fix: (Bug fix)", 2)
	prefix_selector.add_item("chore: (Build / Maintenance)", 3)
	prefix_selector.add_item("refactor: (Code refactoring)", 4)
	prefix_selector.add_item("docs: (Documentation)", 5)
	prefix_selector.add_item("style: (Formatting / Assets)", 6)
	prefix_selector.add_item("perf: (Performance)", 7)
	prefix_selector.add_item("test: (Testing)", 8)
	prefix_selector.item_selected.connect(_on_prefix_selected)
	header_hbox.add_child(prefix_selector)

	# 2. Commit Message Input
	message_edit = TextEdit.new()
	message_edit.placeholder_text = "Message (Ctrl+Enter to commit)"
	message_edit.custom_minimum_size = Vector2(0, 64)
	message_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	message_edit.gui_input.connect(_on_message_gui_input)
	add_child(message_edit)

	# 3. Action Buttons
	var btn_hbox = HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 4)
	add_child(btn_hbox)

	commit_button = Button.new()
	commit_button.text = "Commit"
	commit_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	commit_button.pressed.connect(_on_commit_pressed)
	btn_hbox.add_child(commit_button)

	commit_push_button = Button.new()
	commit_push_button.text = "Commit & Push"
	commit_push_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	commit_push_button.pressed.connect(_on_commit_push_pressed)
	btn_hbox.add_child(commit_push_button)

func _on_prefix_selected(idx: int) -> void:
	if idx == 0:
		return
	var prefixes = ["", "feat: ", "fix: ", "chore: ", "refactor: ", "docs: ", "style: ", "perf: ", "test: "]
	var prefix = prefixes[idx]
	var cur_text = message_edit.text
	# If text doesn't already start with prefix, prepend it
	for p in prefixes:
		if not p.is_empty() and cur_text.begins_with(p):
			cur_text = cur_text.trim_prefix(p)
	message_edit.text = prefix + cur_text
	message_edit.set_caret_column(message_edit.text.length())

func _on_message_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event.ctrl_pressed or event.command_or_control_autoremap) and event.keycode == KEY_ENTER:
			_on_commit_pressed()
			accept_event()

func _get_full_commit_message() -> String:
	return message_edit.text.strip_edges()

func _on_commit_pressed() -> void:
	var msg = _get_full_commit_message()
	if msg.is_empty():
		return
	if lfs_manager != null:
		commit_button.disabled = true
		lfs_manager.commit(msg, func(success, _m):
			commit_button.disabled = false
			if success:
				message_edit.text = ""
				prefix_selector.selected = 0
		)

func _on_commit_push_pressed() -> void:
	var msg = _get_full_commit_message()
	if msg.is_empty():
		return
	if lfs_manager != null:
		commit_push_button.disabled = true
		lfs_manager.commit(msg, func(success, _m):
			if success:
				lfs_manager.push(func(_s2, _m2):
					commit_push_button.disabled = false
					message_edit.text = ""
					prefix_selector.selected = 0
				)
			else:
				commit_push_button.disabled = false
		)
