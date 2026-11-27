@tool
extends PanelContainer

const LFSManager = preload("../../core/lfs_manager.gd")
const GitTypes = preload("../../core/git_types.gd")

var lfs_manager: LFSManager
var label: Label
var unstage_btn: Button

func _init():
	visible = false
	custom_minimum_size = Vector2(0, 48)

func _ready():
	_setup_ui()

func setup(manager: LFSManager) -> void:
	lfs_manager = manager
	if lfs_manager != null:
		lfs_manager.hijacked_staged_detected.connect(_on_hijacked_staged)
		lfs_manager.snapshot_updated.connect(_on_snapshot_updated)

func _setup_ui() -> void:
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.8, 0.25, 0.25, 0.25)
	style.border_color = Color(1.0, 0.35, 0.35, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	add_child(vbox)

	var hbox = HBoxContainer.new()
	vbox.add_child(hbox)

	var icon_label = Label.new()
	icon_label.text = "⚠️"
	hbox.add_child(icon_label)

	label = Label.new()
	label.text = "Warning: Hijacked files are staged!"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.85))
	hbox.add_child(label)

	unstage_btn = Button.new()
	unstage_btn.text = "Unstage Hijacked Files"
	unstage_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	unstage_btn.pressed.connect(_on_unstage_pressed)
	vbox.add_child(unstage_btn)

func _on_hijacked_staged(items: Array[GitTypes.FileStatusItem]) -> void:
	if items.is_empty():
		visible = false
		return
	visible = true
	label.text = "⚠️ %d hijacked file(s) staged! Hijacked files cannot be pushed without server locks." % items.size()

func _on_snapshot_updated(snapshot: GitTypes.RepoSnapshot) -> void:
	var hijacked_count = 0
	for f in snapshot.staged_files:
		if f.lock_state == GitTypes.LockState.HIJACKED:
			hijacked_count += 1
	if hijacked_count > 0:
		visible = true
		label.text = "⚠️ %d hijacked file(s) staged! Hijacked files cannot be pushed." % hijacked_count
	else:
		visible = false

func _on_unstage_pressed() -> void:
	if lfs_manager != null:
		lfs_manager.unstage_all_hijacked()
