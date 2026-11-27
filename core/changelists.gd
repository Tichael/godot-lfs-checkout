@tool
extends RefCounted

## Changelists: named groups of data files that are submitted or shelved together.
##
## Saved in .git/lfs-checkout/changelists.json, so they're local to the clone and
## never committed. Only explicit assignments are stored: a data file that isn't
## assigned is in the Default changelist. A file's Godot .import file always goes
## with the file.
##
## Main thread only.

const GitTypes = preload("git_types.gd")

const DEFAULT_ID := "default"
const FILE_NAME := "changelists.json"

class Changelist extends RefCounted:
	var id: String = ""
	var name: String = ""
	var description: String = ""        ## Default commit message
	var shelved_sha: String = ""        ## Stash commit while shelved, else ""
	var shelved_files: PackedStringArray = []
	var pending_push: bool = false      ## Committed, but the push or unlock didn't finish
	var pending_branch: String = ""     ## Branch the pending commit is on

	func is_default() -> bool:
		return id == DEFAULT_ID

	func is_shelved() -> bool:
		return not shelved_sha.is_empty()

	func to_dict() -> Dictionary:
		return {
			"id": id, "name": name, "description": description,
			"shelved_sha": shelved_sha, "shelved_files": Array(shelved_files),
			"pending_push": pending_push, "pending_branch": pending_branch,
		}

	static func from_dict(d: Dictionary) -> Changelist:
		var cl := Changelist.new()
		cl.id = str(d.get("id", ""))
		cl.name = str(d.get("name", ""))
		cl.description = str(d.get("description", ""))
		cl.shelved_sha = str(d.get("shelved_sha", ""))
		cl.shelved_files = PackedStringArray(d.get("shelved_files", []))
		cl.pending_push = bool(d.get("pending_push", false))
		cl.pending_branch = str(d.get("pending_branch", ""))
		return cl

var _dir: String = ""
var _changelists: Array[Changelist] = []
var _assignments: Dictionary = {}  # repo path -> changelist id

func load_from(state_dir: String) -> void:
	_dir = state_dir
	_changelists.clear()
	_assignments.clear()
	var path := _dir + "/" + FILE_NAME
	if not _dir.is_empty() and FileAccess.file_exists(path):
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary:
			for d in data.get("changelists", []):
				if d is Dictionary:
					var cl := Changelist.from_dict(d)
					if not cl.id.is_empty():
						_changelists.append(cl)
			var assignments = data.get("assignments", {})
			if assignments is Dictionary:
				_assignments = assignments
	if get_changelist(DEFAULT_ID) == null:
		var default_cl := Changelist.new()
		default_cl.id = DEFAULT_ID
		default_cl.name = "Default"
		_changelists.push_front(default_cl)
	# Drop assignments to changelists that no longer exist
	for p in _assignments.keys():
		if get_changelist(_assignments[p]) == null:
			_assignments.erase(p)

func save() -> void:
	if _dir.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(_dir)
	var data := {"changelists": _changelists.map(func(cl): return cl.to_dict()), "assignments": _assignments}
	var f := FileAccess.open(_dir + "/" + FILE_NAME, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()

func get_all() -> Array[Changelist]:
	return _changelists

func get_changelist(id: String) -> Changelist:
	for cl in _changelists:
		if cl.id == id:
			return cl
	return null

func create(cl_name: String) -> Changelist:
	var cl := Changelist.new()
	cl.id = "cl_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]
	cl.name = cl_name
	_changelists.append(cl)
	save()
	return cl

func rename(id: String, new_name: String) -> void:
	var cl := get_changelist(id)
	if cl != null and not cl.is_default():
		cl.name = new_name
		save()

func set_description(id: String, description: String) -> void:
	var cl := get_changelist(id)
	if cl != null:
		cl.description = description
		save()

## Delete a changelist; its files go back to Default. Shelved changelists can't be deleted.
func remove(id: String) -> bool:
	var cl := get_changelist(id)
	if cl == null or cl.is_default() or cl.is_shelved():
		return false
	for p in _assignments.keys():
		if _assignments[p] == id:
			_assignments.erase(p)
	_changelists.erase(cl)
	save()
	return true

## Move files to a changelist. Each file's .import file follows it.
func assign(paths: PackedStringArray, id: String) -> void:
	if get_changelist(id) == null:
		return
	for p in paths:
		var owner := owner_path(p)
		if id == DEFAULT_ID:
			_assignments.erase(owner)
		else:
			_assignments[owner] = id
	save()

## The path that decides a file's changelist: the asset for an .import file
static func owner_path(path: String) -> String:
	return path.trim_suffix(".import") if path.ends_with(".import") else path

func changelist_id_of(path: String) -> String:
	return _assignments.get(owner_path(path), DEFAULT_ID)

## Forget assignments for files that are no longer changed, checked out or shelved
func prune(live_paths: Dictionary) -> void:
	var changed := false
	for p in _assignments.keys():
		if not live_paths.has(p) and not live_paths.has(p + ".import"):
			_assignments.erase(p)
			changed = true
	if changed:
		save()

## Group data items by changelist id
func group(items: Array[GitTypes.FileStatusItem]) -> Dictionary:
	var groups := {}
	for cl in _changelists:
		var list: Array[GitTypes.FileStatusItem] = []
		groups[cl.id] = list
	for item in items:
		var id := changelist_id_of(item.path)
		if not groups.has(id):
			id = DEFAULT_ID
		groups[id].append(item)
	return groups

## Mark a changelist as shelved (or not), remembering the stash and its files
func set_shelved(id: String, sha: String, files: PackedStringArray) -> void:
	var cl := get_changelist(id)
	if cl == null:
		return
	cl.shelved_sha = sha
	cl.shelved_files = files
	# Keep the assignments of shelved files, so they come back to this changelist
	for p in files:
		if id != DEFAULT_ID:
			_assignments[owner_path(p)] = id
	save()

func set_pending_push(id: String, pending: bool, branch: String = "") -> void:
	var cl := get_changelist(id)
	if cl != null:
		cl.pending_push = pending
		cl.pending_branch = branch if pending else ""
		save()

## After a successful submit: forget the files, and delete the changelist unless it's Default
func finish_submit(id: String, paths: PackedStringArray) -> void:
	for p in paths:
		if _assignments.get(owner_path(p), "") == id:
			_assignments.erase(owner_path(p))
	var cl := get_changelist(id)
	if cl == null:
		return
	cl.pending_push = false
	cl.pending_branch = ""
	cl.description = ""
	if not cl.is_default():
		_changelists.erase(cl)
	save()

## Paths kept alive by shelved changelists (so prune doesn't drop them)
func shelved_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	for cl in _changelists:
		paths.append_array(cl.shelved_files)
	return paths
