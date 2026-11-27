@tool
extends VBoxContainer

const GitTypes = preload("../core/git_types.gd")
const LFSManager = preload("../core/lfs_manager.gd")

var lfs_manager: LFSManager
var commits: Array[GitTypes.CommitItem] = []

# UI Nodes
var search_edit: LineEdit
var refresh_btn: Button
var graph_tree: Tree
var commit_details_box: VBoxContainer
var commit_title_lbl: Label
var commit_info_lbl: Label
var commit_files_tree: Tree

func _ready():
	_build_ui()

func setup(manager: LFSManager) -> void:
	lfs_manager = manager
	if lfs_manager != null:
		lfs_manager.snapshot_updated.connect(func(_s): refresh_graph())

func _build_ui() -> void:
	add_theme_constant_override("separation", 4)

	# 1. Toolbar
	var toolbar = HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 6)
	add_child(toolbar)

	var title_lbl = Label.new()
	title_lbl.text = "Git Graph History"
	toolbar.add_child(title_lbl)

	search_edit = LineEdit.new()
	search_edit.placeholder_text = "Filter commits by message, author, or SHA..."
	search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search_edit.text_changed.connect(_on_filter_changed)
	toolbar.add_child(search_edit)

	refresh_btn = Button.new()
	refresh_btn.text = "Refresh"
	refresh_btn.icon = _get_icon("Reload")
	refresh_btn.pressed.connect(refresh_graph)
	toolbar.add_child(refresh_btn)

	# 2. Main Split: Graph Table + Commit Details
	var hsplit = HSplitContainer.new()
	hsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hsplit.split_offset = 500
	add_child(hsplit)

	# Left: Graph Tree
	graph_tree = Tree.new()
	graph_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph_tree.columns = 5
	graph_tree.column_titles_visible = true
	graph_tree.set_column_title(0, "Graph / SHA")
	graph_tree.set_column_title(1, "Message")
	graph_tree.set_column_title(2, "Ref / Branch")
	graph_tree.set_column_title(3, "Author")
	graph_tree.set_column_title(4, "Date")
	graph_tree.set_column_expand(0, false)
	graph_tree.set_column_custom_minimum_width(0, 100)
	graph_tree.set_column_expand(1, true)
	graph_tree.set_column_expand(2, false)
	graph_tree.set_column_custom_minimum_width(2, 120)
	graph_tree.set_column_expand(3, false)
	graph_tree.set_column_custom_minimum_width(3, 110)
	graph_tree.set_column_expand(4, false)
	graph_tree.set_column_custom_minimum_width(4, 110)
	graph_tree.item_selected.connect(_on_commit_selected)
	hsplit.add_child(graph_tree)

	# Right: Commit Details
	commit_details_box = VBoxContainer.new()
	commit_details_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	commit_details_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	commit_details_box.add_theme_constant_override("separation", 4)
	hsplit.add_child(commit_details_box)

	var details_header = Label.new()
	details_header.text = "Commit Details"
	details_header.add_theme_font_size_override("font_size", 14)
	commit_details_box.add_child(details_header)

	commit_title_lbl = Label.new()
	commit_title_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	commit_details_box.add_child(commit_title_lbl)

	commit_info_lbl = Label.new()
	commit_info_lbl.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	commit_details_box.add_child(commit_info_lbl)

	var files_header = Label.new()
	files_header.text = "Changed Files:"
	commit_details_box.add_child(files_header)

	commit_files_tree = Tree.new()
	commit_files_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	commit_files_tree.hide_root = true
	commit_details_box.add_child(commit_files_tree)

func refresh_graph() -> void:
	if lfs_manager == null:
		return
	refresh_btn.disabled = true
	WorkerThreadPool.add_task(func():
		var log_commits = lfs_manager.cli.get_git_log(100)
		_on_log_ready.call_deferred(log_commits)
	)

func _on_log_ready(log_commits: Array[GitTypes.CommitItem]) -> void:
	commits = log_commits
	refresh_btn.disabled = false
	_render_commits(search_edit.text.strip_edges().to_lower())

func _on_filter_changed(filter_text: String) -> void:
	_render_commits(filter_text.strip_edges().to_lower())

func _render_commits(filter: String) -> void:
	graph_tree.clear()
	var root = graph_tree.create_item()

	for commit in commits:
		if not filter.is_empty():
			var match_msg = commit.subject.to_lower().contains(filter)
			var match_author = commit.author_name.to_lower().contains(filter)
			var match_sha = commit.short_sha.to_lower().contains(filter)
			if not match_msg and not match_author and not match_sha:
				continue

		var item = graph_tree.create_item(root)
		# Col 0: Dot + SHA
		var marker = "● " if commit.is_head else "○ "
		item.set_text(0, marker + commit.short_sha)
		item.set_custom_color(0, Color(0.4, 0.8, 1.0) if commit.is_head else Color(0.75, 0.75, 0.75))

		# Col 1: Subject
		item.set_text(1, commit.subject)
		if commit.is_head:
			item.set_custom_color(1, Color(1.0, 1.0, 1.0))

		# Col 2: Refs / Branches / Tags
		var refs_str = ""
		if not commit.branches.is_empty():
			refs_str += "🌿 " + ", ".join(commit.branches)
		if not commit.tags.is_empty():
			if not refs_str.is_empty(): refs_str += " "
			refs_str += "🏷️ " + ", ".join(commit.tags)
		item.set_text(2, refs_str)
		item.set_custom_color(2, Color(0.4, 0.9, 0.6))

		# Col 3: Author
		item.set_text(3, commit.author_name)
		item.set_custom_color(3, Color(0.7, 0.7, 0.7))

		# Col 4: Date
		item.set_text(4, commit.date_relative)
		item.set_custom_color(4, Color(0.6, 0.6, 0.6))

		item.set_metadata(0, commit)

func _on_commit_selected() -> void:
	var selected = graph_tree.get_selected()
	if selected == null:
		return
	var commit: GitTypes.CommitItem = selected.get_metadata(0)
	if commit == null:
		return

	commit_title_lbl.text = "%s (%s)" % [commit.subject, commit.short_sha]
	commit_info_lbl.text = "Author: %s <%s>\nDate: %s (%s)" % [
		commit.author_name,
		commit.author_email,
		commit.date_iso,
		commit.date_relative
	]

	# Load changed files for commit
	_load_commit_files(commit.sha)

func _load_commit_files(sha: String) -> void:
	commit_files_tree.clear()
	var root = commit_files_tree.create_item()

	WorkerThreadPool.add_task(func():
		var res = lfs_manager.cli.execute_git(PackedStringArray([
			"diff-tree",
			"--no-commit-id",
			"--name-status",
			"-r",
			sha
		]))
		_on_commit_files_ready.call_deferred(res.output)
	)

func _on_commit_files_ready(output: String) -> void:
	commit_files_tree.clear()
	var root = commit_files_tree.create_item()
	var lines = output.split("\n", false)

	for line in lines:
		var parts = line.split("\t")
		if parts.size() >= 2:
			var code = parts[0].strip_edges()
			var path = parts[1].strip_edges()
			var item = commit_files_tree.create_item(root)
			item.set_text(0, "%s %s" % [code, path])
			match code:
				"M": item.set_custom_color(0, Color(0.35, 0.75, 1.0))
				"A": item.set_custom_color(0, Color(0.4, 0.9, 0.4))
				"D": item.set_custom_color(0, Color(0.9, 0.4, 0.4))
				_: item.set_custom_color(0, Color(0.8, 0.8, 0.8))

func _get_icon(name: String) -> Texture2D:
	if EditorInterface.get_editor_theme().has_icon(name, "EditorIcons"):
		return EditorInterface.get_editor_theme().get_icon(name, "EditorIcons")
	return null
