@tool
extends EditorPlugin

var selection = get_editor_interface().get_selection()
var selected_node

var mouse_down = false
var can_move_selection = true
var erase_button : CheckBox
var instant_multimesh_button : CheckBox
var delete_button : Button
var refresh_button : Button
var bake_button : Button
var unbake_to_meshinstances_button : Button
var unbake_to_multimesh_button : Button


func _enter_tree():
	add_custom_type("SimpleFoliageNode", "Node3D",
		preload("res://addons/simple_foliage_painter/src/SimpleFoliageNode.gd"),
		preload("res://addons/simple_foliage_painter/SimpleFoliagePainter.png"))
	
	selection.selection_changed.connect(_on_selection_changed)
	InputMap.add_action("PlaceTerrain")
	var ev = InputEventKey.new()
	ev.keycode = KEY_C
	InputMap.action_add_event("PlaceTerrain", ev)
	add_toolbar_buttons()


func _exit_tree():
	remove_custom_type("SimpleFoliageNode")
	InputMap.action_erase_events("PlaceTerrain")
	if selected_node and selected_node.bake_state_changed.is_connected(_on_bake_state_changed):
		selected_node.bake_state_changed.disconnect(_on_bake_state_changed)
	remove_toolbar_buttons()


func _make_visible(visible):
	if visible:
		selected_node.selected = true
		add_toolbar_buttons()
	else:
		remove_toolbar_buttons()


func add_toolbar_buttons():
	remove_toolbar_buttons()
	if selected_node == null:
		return
	
	if selected_node.is_baked():
		unbake_to_meshinstances_button = Button.new()
		unbake_to_meshinstances_button.text = "Unbake to MeshInstances (WARNING)"
		unbake_to_meshinstances_button.pressed.connect(_on_unbake_to_meshinstances_pressed)
		add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, unbake_to_meshinstances_button)
		
		unbake_to_multimesh_button = Button.new()
		unbake_to_multimesh_button.text = "Unbake to MultiMesh"
		unbake_to_multimesh_button.pressed.connect(_on_unbake_to_multimesh_pressed)
		add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, unbake_to_multimesh_button)
		
	else:
		erase_button = CheckBox.new()
		erase_button.text = "Erase"
		erase_button.toggled.connect(_on_toggle_painting)
		add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, erase_button)
	
		if not selected_node.has_painted_anything:
			instant_multimesh_button = CheckBox.new()
			instant_multimesh_button.text = "Instant Multimesh"
			instant_multimesh_button.button_pressed = selected_node.instant_multimesh_enabled
			instant_multimesh_button.toggled.connect(_on_toggle_instant_multimesh)
			add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, instant_multimesh_button)
		
		delete_button = Button.new()
		delete_button.text = "Delete All"
		delete_button.pressed.connect(_on_delete_pressed)
		add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, delete_button)
		
		refresh_button = Button.new()
		refresh_button.text = "Refresh"
		refresh_button.pressed.connect(_on_refresh_pressed)
		add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, refresh_button)
		
		bake_button = Button.new()
		bake_button.text = "Bake"
		bake_button.pressed.connect(_on_bake_pressed)
		add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, bake_button)


func remove_toolbar_buttons():
	for btn in [erase_button, instant_multimesh_button, delete_button, refresh_button, bake_button, unbake_to_meshinstances_button, unbake_to_multimesh_button]:
		if btn and is_instance_valid(btn):
			remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, btn)
			btn.queue_free()
	erase_button = null
	instant_multimesh_button = null
	delete_button = null
	refresh_button = null
	bake_button = null
	unbake_to_meshinstances_button = null
	unbake_to_multimesh_button = null


#if the current node is a simplefoliage get the custom keybinds/actions
func _handles(object):
	if object is SimpleFoliageNode:
		selected_node = object
		selected_node.select()
		if not selected_node.bake_state_changed.is_connected(_on_bake_state_changed):
			selected_node.bake_state_changed.connect(_on_bake_state_changed)
		if not selected_node.instances_cleared.is_connected(_on_instances_cleared):
			selected_node.instances_cleared.connect(_on_instances_cleared)
		add_toolbar_buttons()
		return true
	return false


func _on_selection_changed():
	if selected_node:
		if selected_node.bake_state_changed.is_connected(_on_bake_state_changed):
			selected_node.bake_state_changed.disconnect(_on_bake_state_changed)
		if selected_node.instances_cleared.is_connected(_on_instances_cleared):
			selected_node.instances_cleared.disconnect(_on_instances_cleared)
		selected_node.deselect()
		selected_node = null
	remove_toolbar_buttons()

func _forward_3d_gui_input(viewport_camera, event):
	var captured_event = false
	if selected_node == null or selected_node.is_baked():
		return false
	
	#if alt held/pressed dont do anything
	if event is InputEventKey:
		if event.keycode == KEY_ALT:
			can_move_selection = not event.pressed
			return false
		
		#E switches between erase and draw mode
		if event.keycode == KEY_E and event.pressed:
			if erase_button:
				erase_button.button_pressed = !erase_button.button_pressed
	
	#mouse inputs
	if can_move_selection and selected_node != null:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if not event.pressed:
					mouse_down = false
					captured_event = true
					selected_node._last_paint_position = Vector3.INF
				else:
					mouse_down = true
		if event is InputEventMouseMotion:
			if mouse_down:
				move_object_to_mouse(viewport_camera, selected_node, event.position)
				selected_node.draw()
				captured_event = true
			else:
				captured_event = move_object_to_mouse(viewport_camera, selected_node, event.position)
	return captured_event


func _on_toggle_painting(_toggle = false):
	if selected_node:
		selected_node.toggle_painting()


func _on_toggle_instant_multimesh(toggle_value: bool):
	if selected_node:
		selected_node.instant_multimesh_enabled = toggle_value


func _on_delete_pressed():
	if selected_node:
		selected_node.delete_all_objects()


func _on_refresh_pressed():
	if selected_node:
		selected_node._update_mesh_data()


func _on_bake_pressed():
	if selected_node:
		selected_node._bake_to_multimesh_grid()
		add_toolbar_buttons()


func _on_unbake_to_meshinstances_pressed():
	if selected_node:
		selected_node._unbake_to_meshinstances()
		add_toolbar_buttons()


func _on_unbake_to_multimesh_pressed():
	if selected_node:
		selected_node._unbake_to_multimesh()
		add_toolbar_buttons()


func _on_instances_cleared():
	await get_tree().process_frame
	add_toolbar_buttons() #restore instant multimesh checkbox


func move_object_to_mouse(camera, object, mouse_pos):
	object.move_to_mouse(camera, mouse_pos)


func _on_bake_state_changed():
	await get_tree().process_frame
	add_toolbar_buttons()
