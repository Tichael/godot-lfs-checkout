@tool
extends RefCounted

const GitTypes = preload("../core/git_types.gd")
const LFSManager = preload("../core/lfs_manager.gd")

var lfs_manager: LFSManager
var fs_dock: FileSystemDock
var efs: EditorFileSystem

func setup(manager: LFSManager) -> void:
	lfs_manager = manager
	fs_dock = EditorInterface.get_file_system_dock()
	efs = EditorInterface.get_resource_filesystem()

	if lfs_manager != null:
		lfs_manager.snapshot_updated.connect(_on_snapshot_updated)

	if efs != null:
		efs.filesystem_changed.connect(_on_filesystem_changed)

func cleanup() -> void:
	if lfs_manager != null and lfs_manager.snapshot_updated.is_connected(_on_snapshot_updated):
		lfs_manager.snapshot_updated.disconnect(_on_snapshot_updated)
	if efs != null and efs.filesystem_changed.is_connected(_on_filesystem_changed):
		efs.filesystem_changed.disconnect(_on_filesystem_changed)
	_clear_decorations()

func _on_snapshot_updated(_snapshot: GitTypes.RepoSnapshot) -> void:
	decorate()

func _on_filesystem_changed() -> void:
	decorate()

## Traverse and decorate FileSystem trees and item lists
func decorate() -> void:
	if fs_dock == null or lfs_manager == null or lfs_manager.current_snapshot == null:
		return

	var trees: Array[Tree] = []
	var item_lists: Array[ItemList] = []
	_find_fs_controls(fs_dock, trees, item_lists)

	for tree in trees:
		_decorate_tree(tree)

	for item_list in item_lists:
		_decorate_item_list(item_list)

func _find_fs_controls(node: Node, trees: Array[Tree], item_lists: Array[ItemList]) -> void:
	if node is Tree:
		trees.append(node)
	elif node is ItemList:
		item_lists.append(node)

	for child in node.get_children():
		_find_fs_controls(child, trees, item_lists)

func _decorate_tree(tree: Tree) -> void:
	var root = tree.get_root()
	if root == null:
		return
	_decorate_tree_item_recursive(root)

func _decorate_tree_item_recursive(item: TreeItem) -> void:
	_decorate_single_tree_item(item)
	var child = item.get_first_child()
	while child != null:
		_decorate_tree_item_recursive(child)
		child = child.get_next()

func _decorate_single_tree_item(item: TreeItem) -> void:
	var meta_path = item.get_metadata(0)
	var path_str = ""
	if meta_path is String:
		path_str = meta_path
	
	if path_str.is_empty():
		# Try to reconstruct from item text
		var raw_text = item.get_text(0)
		# Strip old status tag if already decorated
		var clean_text = _strip_decorations(raw_text)
		path_str = clean_text

	if path_str.is_empty():
		return

	var rel_path = lfs_manager.cli.to_repo_path(path_str)
	var snapshot = lfs_manager.current_snapshot

	# Check status
	var status_item: GitTypes.FileStatusItem = snapshot.all_tracked_files.get(rel_path, null)
	var lock_record: GitTypes.LockRecord = snapshot.active_server_locks.get(rel_path, null)

	var orig_name = item.get_meta("orig_name", "")
	if orig_name.is_empty():
		orig_name = _strip_decorations(item.get_text(0))
		item.set_meta("orig_name", orig_name)

	if status_item != null:
		var emoji = status_item.get_status_emoji()
		var label = status_item.get_status_label()
		var color = status_item.get_status_color()

		if not emoji.is_empty():
			item.set_text(0, "%s %s %s" % [emoji, orig_name, label])
			item.set_custom_color(0, color)
			var tooltip = "File: %s\nStatus: %s\nOwner: %s" % [
				rel_path,
				label,
				status_item.lock_owner if not status_item.lock_owner.is_empty() else "N/A"
			]
			item.set_tooltip_text(0, tooltip)
			return

	if lock_record != null:
		var is_mine = (lock_record.owner == snapshot.current_user_name or lock_record.owner == snapshot.current_user_email)
		var emoji = "🟢" if is_mine else "🟡"
		var label = "[Checked Out]" if is_mine else "[Locked: %s]" % lock_record.owner
		var color = Color(0.3, 0.9, 0.3) if is_mine else Color(1.0, 0.75, 0.2)
		item.set_text(0, "%s %s %s" % [emoji, orig_name, label])
		item.set_custom_color(0, color)
		item.set_tooltip_text(0, "LFS Lock\nOwner: %s\nID: %s" % [lock_record.owner, lock_record.id])
		return

	# Reset if clean
	if not orig_name.is_empty():
		item.set_text(0, orig_name)
		item.clear_custom_color(0)

func _decorate_item_list(item_list: ItemList) -> void:
	for i in range(item_list.item_count):
		var raw_text = item_list.get_item_text(i)
		var orig_name = item_list.get_item_metadata(i)
		if orig_name == null or str(orig_name).is_empty():
			orig_name = _strip_decorations(raw_text)
			item_list.set_item_metadata(i, orig_name)
		else:
			orig_name = str(orig_name)

		var rel_path = lfs_manager.cli.to_repo_path(orig_name)
		var snapshot = lfs_manager.current_snapshot
		var status_item: GitTypes.FileStatusItem = snapshot.all_tracked_files.get(rel_path, null)
		var lock_record: GitTypes.LockRecord = snapshot.active_server_locks.get(rel_path, null)

		if status_item != null:
			var emoji = status_item.get_status_emoji()
			var label = status_item.get_status_label()
			item_list.set_item_text(i, "%s %s %s" % [emoji, orig_name, label])
			item_list.set_item_custom_fg_color(i, status_item.get_status_color())
		elif lock_record != null:
			var is_mine = (lock_record.owner == snapshot.current_user_name or lock_record.owner == snapshot.current_user_email)
			var emoji = "🟢" if is_mine else "🟡"
			var label = "[Checked Out]" if is_mine else "[Locked: %s]" % lock_record.owner
			item_list.set_item_text(i, "%s %s %s" % [emoji, orig_name, label])
			item_list.set_item_custom_fg_color(i, Color(0.3, 0.9, 0.3) if is_mine else Color(1.0, 0.75, 0.2))
		else:
			item_list.set_item_text(i, orig_name)

func _strip_decorations(text: String) -> String:
	var clean = text
	# Strip leading emojis
	for em in ["🟢 ", "🟡 ", "🟣 ", "🔴 ", "⚪ ", "M ", "A ", "D ", "U "]:
		if clean.begins_with(em):
			clean = clean.trim_prefix(em)
	# Strip trailing bracket labels
	var b_idx = clean.find(" [")
	if b_idx != -1:
		clean = clean.substr(0, b_idx)
	return clean.strip_edges()

func _clear_decorations() -> void:
	if fs_dock == null:
		return
	var trees: Array[Tree] = []
	var item_lists: Array[ItemList] = []
	_find_fs_controls(fs_dock, trees, item_lists)
	for tree in trees:
		var root = tree.get_root()
		if root != null:
			_clear_tree_item_recursive(root)

func _clear_tree_item_recursive(item: TreeItem) -> void:
	var orig = item.get_meta("orig_name", "")
	if not str(orig).is_empty():
		item.set_text(0, str(orig))
		item.clear_custom_color(0)
	var child = item.get_first_child()
	while child != null:
		_clear_tree_item_recursive(child)
		child = child.get_next()
