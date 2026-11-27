@tool
extends EditorPlugin

const LFSManager = preload("core/lfs_manager.gd")
const RepoWatcher = preload("core/repo_watcher.gd")
const FileSystemDecorator = preload("ui/filesystem_decorator.gd")
const ContextMenuHandler = preload("ui/context_menu_handler.gd")
const SourceControlDock = preload("ui/source_control_dock.gd")
const GitGraphPanel = preload("ui/git_graph_panel.gd")

var lfs_manager: LFSManager
var repo_watcher: RepoWatcher
var fs_decorator: FileSystemDecorator
var context_menu_handler: ContextMenuHandler
var sc_dock: SourceControlDock
var graph_panel: GitGraphPanel
var graph_bottom_btn: Button

func _enter_tree() -> void:
	# 1. Initialize Core Manager
	lfs_manager = LFSManager.new()

	# 2. Setup Focus & Auto-Refresh Watcher
	repo_watcher = RepoWatcher.new()
	add_child(repo_watcher)
	repo_watcher.setup(lfs_manager)

	# 3. Setup FileSystem Decorator
	fs_decorator = FileSystemDecorator.new()
	fs_decorator.setup(lfs_manager)

	# 4. Setup Context Menu Handler
	context_menu_handler = ContextMenuHandler.new()
	context_menu_handler.setup(lfs_manager)
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, context_menu_handler)

	# 5. Setup Source Control Side Dock
	sc_dock = SourceControlDock.new()
	sc_dock.name = "Source Control"
	add_control_to_dock(DOCK_SLOT_LEFT_UR, sc_dock)
	sc_dock.setup(lfs_manager)

	# 6. Setup Git Graph Bottom Panel
	graph_panel = GitGraphPanel.new()
	graph_panel.name = "Git Graph"
	graph_bottom_btn = add_control_to_bottom_panel(graph_panel, "Git Graph")
	graph_panel.setup(lfs_manager)

	# 7. Add Tools Menu Actions
	add_tool_menu_item("Source Control: Open Git Graph", Callable(self, "_on_menu_open_graph"))
	add_tool_menu_item("Source Control: Refresh Status & Locks", Callable(self, "_on_menu_refresh_locks"))
	add_tool_menu_item("Source Control: Sync (Pull)", Callable(self, "_on_menu_sync"))
	add_tool_menu_item("Source Control: Push", Callable(self, "_on_menu_push"))
	add_tool_menu_item(MENU_BYPASS, _on_menu_toggle_bypass)
	add_tool_menu_item(MENU_HOOK, func(): lfs_manager.install_hook())

	# Install the pre-commit hook for this clone, then show the initial status
	lfs_manager.ensure_hook()
	lfs_manager.refresh_async()

const MENU_BYPASS := "Source Control: Toggle Data Branch Bypass..."
const MENU_HOOK := "Source Control: Reinstall Pre-Commit Hook"

func _on_menu_toggle_bypass() -> void:
	if lfs_manager == null:
		return
	if lfs_manager.current_snapshot.bypass_enabled:
		lfs_manager.set_bypass(false)
		return
	var dialog := ConfirmationDialog.new()
	dialog.title = "Bypass Data Branch Rules"
	dialog.dialog_text = "Allow checking out and committing data files on any branch, in this clone only?\n\nUse this for emergencies, and turn it off afterwards. Data committed outside a data branch can still cause merge conflicts in binary files."
	dialog.ok_button_text = "Bypass"
	dialog.confirmed.connect(func(): lfs_manager.set_bypass(true))
	dialog.visibility_changed.connect(func():
		if not dialog.visible:
			dialog.queue_free()
	)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered()

func _exit_tree() -> void:
	# Remove Menu Items
	remove_tool_menu_item("Source Control: Open Git Graph")
	remove_tool_menu_item("Source Control: Refresh Status & Locks")
	remove_tool_menu_item("Source Control: Sync (Pull)")
	remove_tool_menu_item("Source Control: Push")
	remove_tool_menu_item(MENU_BYPASS)
	remove_tool_menu_item(MENU_HOOK)

	# Remove Context Menu
	if context_menu_handler != null:
		remove_context_menu_plugin(context_menu_handler)
		context_menu_handler = null

	# Remove Bottom Panel
	if graph_panel != null:
		remove_control_from_bottom_panel(graph_panel)
		graph_panel.queue_free()
		graph_panel = null

	# Remove Dock
	if sc_dock != null:
		remove_control_from_docks(sc_dock)
		sc_dock.queue_free()
		sc_dock = null

	# Cleanup Decorator
	if fs_decorator != null:
		fs_decorator.cleanup()
		fs_decorator = null

	# Cleanup Watcher
	if repo_watcher != null:
		repo_watcher.cleanup()
		repo_watcher.queue_free()
		repo_watcher = null

	lfs_manager = null

func _on_menu_open_graph() -> void:
	if graph_bottom_btn != null:
		make_bottom_panel_item_visible(graph_panel)
	if graph_panel != null:
		graph_panel.refresh_graph()

func _on_menu_refresh_locks() -> void:
	if lfs_manager != null:
		lfs_manager.refresh_async()

func _on_menu_sync() -> void:
	if lfs_manager != null:
		lfs_manager.pull()

func _on_menu_push() -> void:
	if lfs_manager != null:
		lfs_manager.push()
