@tool
class_name RepoWatcher
extends Node

const LFSManager = preload("res://addons/godot_git_lfs_p4/core/lfs_manager.gd")

var lfs_manager: LFSManager
var auto_refresh_timer: Timer
var auto_refresh_interval: float = 60.0 # seconds
var is_active: bool = false

func setup(manager: LFSManager) -> void:
	lfs_manager = manager
	
	auto_refresh_timer = Timer.new()
	auto_refresh_timer.wait_time = auto_refresh_interval
	auto_refresh_timer.autostart = true
	auto_refresh_timer.one_shot = false
	auto_refresh_timer.timeout.connect(_on_timer_timeout)
	add_child(auto_refresh_timer)
	is_active = true

func _notification(what: int) -> void:
	if not is_active or lfs_manager == null:
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		# Auto-refresh when user alt-tabs or focuses Godot editor
		lfs_manager.refresh_async()

func _on_timer_timeout() -> void:
	if is_active and lfs_manager != null:
		lfs_manager.refresh_async()

func cleanup() -> void:
	is_active = false
	if auto_refresh_timer != null and is_instance_valid(auto_refresh_timer):
		auto_refresh_timer.stop()
		auto_refresh_timer.queue_free()
