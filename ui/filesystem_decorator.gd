@tool
extends RefCounted

## Shows lock and change status in the FileSystem dock.
##
## The dock owns its items, so this only adds what it can take back: a text color
## and, in the tree, a suffix like "[Checked Out]". It never changes item text,
## metadata or tooltips, which the dock uses for paths, renaming, search and
## resource tooltips.
##
## The dock rebuilds its items whenever it likes (navigation, search, rescans).
## Each control's `draw` signal is watched, and items are decorated again when the
## control's contents change.

const GitTypes = preload("../core/git_types.gd")
const LFSManager = preload("../core/lfs_manager.gd")

const DECORATED_META := &"_lfs_checkout_decorated"

var lfs_manager: LFSManager
var fs_dock: FileSystemDock
var efs: EditorFileSystem

var _trees: Array[Tree] = []
var _item_lists: Array[ItemList] = []
var _signatures: Dictionary = {}       # control instance id -> contents signature
var _decorated_paths: Dictionary = {}  # ItemList instance id -> {path: true}
var _queued: bool = false

func setup(manager: LFSManager) -> void:
	lfs_manager = manager
	fs_dock = EditorInterface.get_file_system_dock()
	efs = EditorInterface.get_resource_filesystem()

	lfs_manager.snapshot_updated.connect(_on_snapshot_updated)
	if efs != null:
		efs.filesystem_changed.connect(_queue_decorate.bind(true))
	_find_controls()

func cleanup() -> void:
	if lfs_manager != null and lfs_manager.snapshot_updated.is_connected(_on_snapshot_updated):
		lfs_manager.snapshot_updated.disconnect(_on_snapshot_updated)
	if efs != null:
		for c in efs.filesystem_changed.get_connections():
			if c.callable.get_object() == self:
				efs.filesystem_changed.disconnect(c.callable)
	for tree in _trees:
		if is_instance_valid(tree):
			tree.draw.disconnect(_on_control_draw)
			var root := tree.get_root()
			if root != null:
				_clear_tree_item(root)
	for list in _item_lists:
		if is_instance_valid(list):
			list.draw.disconnect(_on_control_draw)
			_clear_item_list(list)
	_trees.clear()
	_item_lists.clear()

func _find_controls() -> void:
	if fs_dock == null:
		return
	_collect(fs_dock)
	for tree in _trees:
		tree.draw.connect(_on_control_draw.bind(tree))
	for list in _item_lists:
		list.draw.connect(_on_control_draw.bind(list))

func _collect(node: Node) -> void:
	if node is Tree:
		_trees.append(node)
	elif node is ItemList:
		_item_lists.append(node)
	for child in node.get_children():
		_collect(child)

func _on_snapshot_updated(_snapshot: GitTypes.RepoSnapshot) -> void:
	_queue_decorate(true)

## Called on every redraw, so it only compares a cheap signature.
func _on_control_draw(control: Control) -> void:
	if _signature(control) != _signatures.get(control.get_instance_id(), ""):
		_queue_decorate(false)

func _signature(control: Control) -> String:
	if control is Tree:
		var root: TreeItem = control.get_root()
		return str(root.get_instance_id()) if root != null else ""
	var list := control as ItemList
	if list.item_count == 0:
		return "0"
	return "%d|%s|%s" % [list.item_count, list.get_item_metadata(0), list.get_item_metadata(list.item_count - 1)]

func _queue_decorate(force: bool) -> void:
	if force:
		_signatures.clear()
	if _queued:
		return
	_queued = true
	_decorate.call_deferred()

func _decorate() -> void:
	_queued = false
	if lfs_manager == null or lfs_manager.current_snapshot == null:
		return
	for tree in _trees:
		if is_instance_valid(tree):
			var root := tree.get_root()
			if root != null:
				_decorate_tree_item(root)
			_signatures[tree.get_instance_id()] = _signature(tree)
	for list in _item_lists:
		if is_instance_valid(list):
			_decorate_item_list(list)
			_signatures[list.get_instance_id()] = _signature(list)

## Status shown for a path: [color, label], or [] when there's nothing to show
func _status_for(res_path: String) -> Array:
	var item := lfs_manager.get_changed_item(res_path)
	if item != null and not item.get_status_emoji().is_empty():
		return [item.get_status_color(), item.get_status_label()]
	var lock := lfs_manager.get_lock(res_path)
	if lock != null:
		if lock.is_mine:
			return [Color(0.3, 0.9, 0.3), "[Checked Out]"]
		return [Color(1.0, 0.75, 0.2), "[Locked: %s]" % lock.owner]
	return []

func _decorate_tree_item(item: TreeItem) -> void:
	var meta = item.get_metadata(0)
	if meta is String and meta.begins_with("res://") and not meta.ends_with("/"):
		var status := _status_for(meta)
		if not status.is_empty():
			item.set_custom_color(0, status[0])
			item.set_suffix(0, status[1])
			item.set_meta(DECORATED_META, true)
		elif item.has_meta(DECORATED_META):
			_clear_single_tree_item(item)
	var child := item.get_first_child()
	while child != null:
		_decorate_tree_item(child)
		child = child.get_next()

func _decorate_item_list(list: ItemList) -> void:
	var id := list.get_instance_id()
	var decorated: Dictionary = _decorated_paths.get(id, {})
	var still_decorated := {}
	for i in list.item_count:
		var meta = list.get_item_metadata(i)
		if not (meta is String and meta.begins_with("res://")):
			continue
		var status := _status_for(meta)
		if not status.is_empty():
			list.set_item_custom_fg_color(i, status[0])
			still_decorated[meta] = true
		elif decorated.has(meta):
			list.set_item_custom_fg_color(i, Color())
	_decorated_paths[id] = still_decorated

func _clear_single_tree_item(item: TreeItem) -> void:
	item.clear_custom_color(0)
	item.set_suffix(0, "")
	item.remove_meta(DECORATED_META)

func _clear_tree_item(item: TreeItem) -> void:
	if item.has_meta(DECORATED_META):
		_clear_single_tree_item(item)
	var child := item.get_first_child()
	while child != null:
		_clear_tree_item(child)
		child = child.get_next()

func _clear_item_list(list: ItemList) -> void:
	var decorated: Dictionary = _decorated_paths.get(list.get_instance_id(), {})
	for i in list.item_count:
		if decorated.has(list.get_item_metadata(i)):
			list.set_item_custom_fg_color(i, Color())
	_decorated_paths.erase(list.get_instance_id())
