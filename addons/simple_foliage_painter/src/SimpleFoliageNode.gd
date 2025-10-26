@tool
extends Node3D
class_name SimpleFoliageNode

# Export variables which the user can control in an inspector
@export_group("Brush Settings")
## The amount of instances to generate per brush stroke
@export_range(0, 1000, 1) var amount := 1:
	get: return amount
	set(value):
		amount = value
		_update_brush_area_size()
## The size of the draw brush
@export_range(0.01, 100, 0.1) var brush_size_base := 10.0:
	set(value):
		brush_size_base = clamp(value, 0.01, 100)
		_update_brush_area_size()
## Choose collision layer on which Simple Foliage Painter brush can paint meshes
@export_flags_3d_physics var paint_collision_layer: int = 1
## If checked, mesh will be placed perpendicularly to the terrain surface - tip: leave ON for grass, turn OFF for trees
@export var align_with_surface_normal: bool = true
## Enable uniform random scaling for placed meshes
@export_range(0.0, 0.99, 0.01) var random_scale := 0.25:
	set(value):
		random_scale = clamp(value, 0.0, 0.99)
## Toggle for random rotation around the Y-axis
@export var enable_random_rotation := true

@export_group("Mesh Settings")
## Primary Mesh (Required)
@export var mesh_lod0: Mesh: 
	set(value):
		mesh_lod0 = value
		_update_mesh_data() # Update data immediately when mesh is set
## Medium Detail Mesh (NOT Required)
@export var mesh_lod1: Mesh:
	set(value):
		mesh_lod1 = value
		_update_mesh_data()
## Low Detail Mesh (NOT Required)
@export var mesh_lod2: Mesh: # Low Detail Mesh
	set(value):
		mesh_lod2 = value
		_update_mesh_data()

@export_group("Baking Settings")
## The size of one MultiMesh tile; bigger meshes need bigger tiles
@export_range(1, 200, 1) var tile_size := 10

@export_group("Collision Settings")
## The Shape3D resource to use for the collision of each instance after baking
@export var collision_shape: Shape3D:
	set(value):
		collision_shape = value
## The collision layers for the created StaticBody3D nodes
@export_flags_3d_physics var foliage_collision_layer: int = 1

@export_group("LOD Visibility Ranges")
@export_range(0.0, 10000.0, 1.0) var lod0_max_visible_distance: float = 50.0
@export_range(0.0, 10000.0, 1.0) var lod1_max_visible_distance: float = 100.0
@export_range(0.0, 10000.0, 1.0) var lod2_max_visible_distance: float = 150.0
## Offset bigger than 0.0 means that the next level of detail will be shown before the prevoius one is culled
@export_range(0.0, 10.0, 0.1) var lod_visibility_offset: float = 0.0

@onready var _space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state

var _rng := RandomNumberGenerator.new()
var current_color : Color
var selected := false #if the node is currently selected
var _last_paint_position: Vector3 = Vector3.INF
var _min_paint_distance: float = 0.0
var show_brush_area := true
var _brush_instance : MeshInstance3D
var brush_node : Node3D
var instances_node : Node3D # Parent for MeshInstance3D nodes before baking
var is_painting := true
var brush_size : Vector3
var instant_multimesh_enabled := true
var has_painted_anything := false
var _instant_mm_instance: MultiMeshInstance3D

signal bake_state_changed
signal instances_cleared


#create nodes etc
func _ready():
	_rng.randomize()
	
	current_color = Color(0.0, 0.0, 1.0, 0.0784313725)
	
	brush_node = get_node_or_null("BrushNode")
	instances_node = get_node_or_null("InstancesNode")
	
	if not brush_node:
		brush_node = Node3D.new()
		brush_node.name = "BrushNode"
		add_child(brush_node)
		brush_node.global_transform.origin = global_transform.origin
		brush_node.set_owner(get_tree().edited_scene_root)
	
	if not instances_node:
		instances_node = Node3D.new()
		instances_node.name = "InstancesNode"
		add_child(instances_node)
		instances_node.set_owner(self)
		instances_node.global_transform.origin = global_transform.origin
		instances_node.set_owner(get_tree().edited_scene_root)
	
	_instant_mm_instance = instances_node.get_node_or_null("InstantMultiMesh")
	if _instant_mm_instance and _instant_mm_instance is MultiMeshInstance3D:
		instant_multimesh_enabled = true
	
	_update_mesh_data()


#move the brush sphere to the mouse position
func move_to_mouse(camera, mouse: Vector2):
	var start = camera.project_ray_origin(mouse)
	var end = start + camera.project_ray_normal(mouse) * 1000
	var query := PhysicsRayQueryParameters3D.create(start, end)
	query.collision_mask = paint_collision_layer
	var result = _space.intersect_ray(query)
	
	if result.is_empty():
		return false
	
	var t := Transform3D()
	t.origin = result.position
	
	#align mesh with floor nomral
	t.basis = Basis(result.normal.cross(global_transform.basis.z),
			result.normal,
			global_transform.basis.x.cross(result.normal),
		).orthonormalized()
	
	brush_node.basis = t.basis
	
	brush_node.global_transform.origin = result.position
	return true


func select():
	selected = true
	if not is_baked():
		_create_brush_area()
		_update_brush_area()
	else:
		_delete_brush_area()
	
	if instances_node.get_children():
		has_painted_anything = true
	else:
		has_painted_anything = false


func deselect():
	selected = false
	is_painting = true
	_delete_brush_area()


func draw():
	var current_pos = brush_node.global_position
	
	#only draw if the brush moved enough distance since last paint
	if _last_paint_position == Vector3.INF or current_pos.distance_to(_last_paint_position) >= _min_paint_distance:
		_last_paint_position = current_pos
		
		if is_painting:
			scatter_obj()
		else:
			erase_obj()


#toggle draw and erase mode
func toggle_painting():
	is_painting = !is_painting
	#change the colour of the draw box
	_update_brush_area()
	
	return is_painting


#creates the circular brush
func _create_brush_area() -> void:
	_delete_brush_area()
	_brush_instance = MeshInstance3D.new()
	
	var material := StandardMaterial3D.new()
	_brush_instance.material_override = material
	
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = current_color
	material.no_depth_test = true
	
	var sphere_mesh = SphereMesh.new()
	var radius = brush_size.x / 2.0
	sphere_mesh.radius = radius
	sphere_mesh.height = radius * 2.0
	
	_brush_instance.mesh = sphere_mesh
	_brush_instance.visible = show_brush_area
	
	#move the center down by half the radius so it’s half-submerged
	_brush_instance.position.y = -radius / 2.0
	
	if brush_node:
		brush_node.add_child(_brush_instance)
		_update_brush_area_size()


func _delete_brush_area() -> void:
	if _brush_instance != null && _brush_instance.is_inside_tree():
		_brush_instance.queue_free()
		_brush_instance = null


func _update_brush_area() -> void:
	if is_painting:
		current_color = Color(0.0, 0.0, 1.0, 0.0784313725)
	else:
		current_color = Color(1.0, 1.0, 1.0, 0.0784313725)
	
	if _brush_instance and _brush_instance.material_override:
		_brush_instance.material_override.albedo_color = current_color


func _update_brush_area_size() -> void:
	brush_size = Vector3(brush_size_base, brush_size_base, brush_size_base).clamp(Vector3.ONE * 0.01, Vector3.ONE * 100.0)
	
	if _brush_instance != null and _brush_instance.is_inside_tree():
		var radius = brush_size.x / 2.0
		
		if _brush_instance.mesh is SphereMesh:
			var sphere = _brush_instance.mesh as SphereMesh
			sphere.radius = radius
			sphere.height = radius * 2.0
			
			#keep half-submerged brush
			_brush_instance.position.y = -radius / 2.0
	
	#adjust minimum spacing based on brush radius
	_min_paint_distance = clamp(1.0 / (brush_size.x * 2.0), 0.02, 0.5)


func delete_all_objects():
	for child in instances_node.get_children():
		child.queue_free()
	
	var collision_parent: Node3D = get_node_or_null("BakedCollisions")
	if collision_parent:
		collision_parent.queue_free()
		
	var lod0_parent: Node3D = get_node_or_null("BakedMultiMeshesLOD0")
	if lod0_parent:
		lod0_parent.queue_free()
		
	var lod1_parent: Node3D = get_node_or_null("BakedMultiMeshesLOD1")
	if lod1_parent:
		lod1_parent.queue_free()
		
	var lod2_parent: Node3D = get_node_or_null("BakedMultiMeshesLOD2")
	if lod2_parent:
		lod2_parent.queue_free()
	
	has_painted_anything = false
	emit_signal("instances_cleared")
	_update_mesh_data()


func _update_mesh_data():
	if not instances_node:
		return
	
	if has_node("BakedMultiMeshesLOD0") or has_node("BakedMultiMeshesLOD1") or has_node("BakedMultiMeshesLOD2"):
		return
	
	if mesh_lod0 == null:
		push_warning("Simple Foliage Painter: mesh_lod0 is not chosen, cannot refresh existing instances")
		return
	
	var updated_amount := 0
	
	if instances_node:
		for child in instances_node.get_children():
			if child is MeshInstance3D:
				child.mesh = mesh_lod0
				updated_amount += 1
	
	if _instant_mm_instance and is_instance_valid(_instant_mm_instance):
		if _instant_mm_instance.multimesh:
			_instant_mm_instance.multimesh.mesh = mesh_lod0
	
	_create_brush_area()
	emit_signal("bake_state_changed")


func scatter_obj():
	if mesh_lod0 == null:
		print("Mesh LOD0 not chosen")
		return
	
	if has_painted_anything == false:
		has_painted_anything = true
		emit_signal("instances_cleared")
	
	if instant_multimesh_enabled:
		if _instant_mm_instance == null:
			_instant_mm_instance = MultiMeshInstance3D.new()
			_instant_mm_instance.name = "InstantMultiMesh"
			_instant_mm_instance.multimesh = MultiMesh.new()
			_instant_mm_instance.multimesh.mesh = mesh_lod0
			_instant_mm_instance.multimesh.transform_format = MultiMesh.TRANSFORM_3D
			instances_node.add_child(_instant_mm_instance)
			_instant_mm_instance.set_owner(get_tree().edited_scene_root)
		
		var mm := _instant_mm_instance.multimesh
		
		#store previous transforms
		var old_count := mm.instance_count
		var old_transforms: Array[Transform3D] = []
		for i in range(old_count):
			old_transforms.append(mm.get_instance_transform(i))
		
		#generate new transforms
		var new_transforms: Array[Transform3D] = []
		for i in range(amount):
			var pos := brush_node.global_position
			var R = brush_size.x / 2.0
			var radius_random = sqrt(_rng.randf_range(0.0, 1.0)) * R
			var angle_random = _rng.randf_range(0.0, 2.0 * PI)
			var x_offset = radius_random * cos(angle_random)
			var z_offset = radius_random * sin(angle_random)
			pos += Vector3(x_offset, 0, z_offset)
			
			var startPos = pos
			startPos.y += brush_size.y
			var endPos = pos
			endPos.y -= brush_size.y
			var ray := PhysicsRayQueryParameters3D.create(startPos, endPos)
			ray.collision_mask = paint_collision_layer
			var hit = _space.intersect_ray(ray)
			if hit.is_empty():
				continue
			
			var t := Transform3D()
			t.origin = hit.position
			
			if align_with_surface_normal:
				t.basis.y = hit.normal
				t.basis.x = -t.basis.z.cross(hit.normal)
				t.basis = t.basis.orthonormalized()
			else:
				t.basis = Basis()
			
			if enable_random_rotation:
				var random_yaw = deg_to_rad(_rng.randf_range(0.0, 360.0))
				var local_up = t.basis.y.normalized()
				t.basis = t.basis.rotated(local_up, random_yaw)
			
			var scale_variation = 1.0 + _rng.randf_range(-random_scale, random_scale)
			t.basis = t.basis.scaled(Vector3.ONE * scale_variation)
			
			new_transforms.append(t)
		
		#rebuild multimesh with combined transforms
		var all_transforms = old_transforms + new_transforms
		mm.instance_count = all_transforms.size()
		for i in range(all_transforms.size()):
			mm.set_instance_transform(i, all_transforms[i])
		
	else:
		#meshinstances
		for i in range(amount):
			var pos := brush_node.global_position
			var R = brush_size.x / 2.0
			var radius_random = sqrt(_rng.randf_range(0.0, 1.0)) * R
			var angle_random = _rng.randf_range(0.0, 2.0 * PI)
			var x_offset = radius_random * cos(angle_random)
			var z_offset = radius_random * sin(angle_random)
			pos += Vector3(x_offset, 0, z_offset)
			
			var startPos = pos
			startPos.y += brush_size.y
			var endPos = pos
			endPos.y -= brush_size.y
			var ray := PhysicsRayQueryParameters3D.create(startPos, endPos)
			ray.collision_mask = paint_collision_layer
			var hit = _space.intersect_ray(ray)
			if hit.is_empty():
				continue
			
			var t := Transform3D()
			t.origin = hit.position
			
			if align_with_surface_normal:
				t.basis.y = hit.normal
				t.basis.x = -t.basis.z.cross(hit.normal)
				t.basis = t.basis.orthonormalized()
			else:
				t.basis = Basis()
			
			if enable_random_rotation:
				var random_yaw = deg_to_rad(_rng.randf_range(0.0, 360.0))
				var local_up = t.basis.y.normalized()
				t.basis = t.basis.rotated(local_up, random_yaw)
			
			var scale_variation = 1.0 + _rng.randf_range(-random_scale, random_scale)
			t.basis = t.basis.scaled(Vector3.ONE * scale_variation)
			
			var mesh_inst = MeshInstance3D.new()
			mesh_inst.mesh = mesh_lod0
			mesh_inst.global_transform = t
			instances_node.add_child(mesh_inst)
			mesh_inst.set_owner(get_tree().edited_scene_root)



func erase_obj():
	if not instances_node:
		return
	
	var brush_center := brush_node.global_position
	var R := brush_size.x / 2.0
	
	if instant_multimesh_enabled and _instant_mm_instance and _instant_mm_instance.multimesh:
		var mm := _instant_mm_instance.multimesh
		var kept_transforms: Array[Transform3D] = []
		for i in range(mm.instance_count):
			var t = mm.get_instance_transform(i)
			var world_pos = _instant_mm_instance.global_transform.origin + t.origin
			if world_pos.distance_to(brush_center) > R:
				kept_transforms.append(t)
		mm.instance_count = kept_transforms.size()
		for i in range(kept_transforms.size()):
			mm.set_instance_transform(i, kept_transforms[i])
	else:
		var nodes_to_delete: Array = []
		for child in instances_node.get_children():
			if child is MeshInstance3D:
				var p = child.global_transform.origin
				if p.distance_to(brush_center) <= R:
					nodes_to_delete.append(child)
		for node in nodes_to_delete:
			node.queue_free()


func _bake_to_multimesh_grid():
	if not instances_node and _instant_mm_instance == null:
		push_warning("Simple Foliage Painter: Cannot bake - missing instances or instant multimesh")
		return
	
	var instance_transforms: Array[Transform3D] = []
	
	#if instant multimesh exists extract transforms directly from it
	if _instant_mm_instance:
		var mm = _instant_mm_instance.multimesh
		for i in range(mm.instance_count):
			instance_transforms.append(mm.get_instance_transform(i))
		_instant_mm_instance.queue_free()
		_instant_mm_instance = null
	else:
		for child in instances_node.get_children():
			if child is MeshInstance3D:
				instance_transforms.append(child.global_transform)
	
	if instance_transforms.is_empty():
		push_warning("Simple Foliage Painter: No instances found to bake.")
		return
	
	#compute center for grid alignment
	var center = Vector3.ZERO
	for t in instance_transforms:
		center += t.origin
	center /= instance_transforms.size()
	
	#remove old multimeshes if any
	for old in get_children():
		if old.name.begins_with("BakedMultiMeshesLOD") or old.name == "BakedCollisions":
			old.queue_free()
	
	var scene_root = get_tree().edited_scene_root
	
	if collision_shape:
		var collision_parent := Node3D.new()
		collision_parent.name = "BakedCollisions"
		add_child(collision_parent)
		
		collision_parent.set_owner(scene_root) 
		
		var instance_count = 0
		
		for t in instance_transforms:
			var static_body := StaticBody3D.new()
			static_body.name = "StaticBody" + str(instance_count)
			static_body.global_transform = t
			static_body.collision_layer = foliage_collision_layer
			static_body.collision_mask = foliage_collision_layer 
			
			var col_shape_inst := CollisionShape3D.new()
			col_shape_inst.name = "CollisionShape"
			col_shape_inst.shape = collision_shape
			
			static_body.add_child(col_shape_inst)
			collision_parent.add_child(static_body)
			
			static_body.set_owner(scene_root) 
			col_shape_inst.set_owner(scene_root) 
			
			instance_count += 1
	
	var lod0_parent := Node3D.new()
	lod0_parent.name = "BakedMultiMeshesLOD0"
	add_child(lod0_parent)
	lod0_parent.set_owner(scene_root)
	
	var lod1_parent := Node3D.new()
	lod1_parent.name = "BakedMultiMeshesLOD1"
	add_child(lod1_parent)
	lod1_parent.set_owner(scene_root)

	var lod2_parent := Node3D.new()
	lod2_parent.name = "BakedMultiMeshesLOD2"
	add_child(lod2_parent)
	lod2_parent.set_owner(scene_root)
	
	_create_lod_multimesh_tiles(mesh_lod0, instance_transforms, lod0_parent, "LOD0", center)
	if mesh_lod1:
		_create_lod_multimesh_tiles(mesh_lod1, instance_transforms, lod1_parent, "LOD1", center)
	if mesh_lod2:
		_create_lod_multimesh_tiles(mesh_lod2, instance_transforms, lod2_parent, "LOD2", center)
	
	for child in instances_node.get_children():
		if child is MeshInstance3D:
			child.queue_free()
	
	apply_lod_visibility_ranges()
	emit_signal("bake_state_changed")
	_delete_brush_area()
	print("Simple Foliage Painter: Baking complete")


func _create_lod_multimesh_tiles(mesh: Mesh, transforms: Array, parent: Node3D, lod_name: String, center: Vector3):
	var tile_map := {} #key: Vector2i(tile_x, tile_z), value: Array[Transform3D]
	
	var scene_root = get_tree().edited_scene_root

	#group instances into tiles
	for t in transforms:
		var local_pos = t.origin - center
		var tile_x = int(floor(local_pos.x / tile_size))
		var tile_z = int(floor(local_pos.z / tile_size))
		var key = Vector2i(tile_x, tile_z)
		
		if not tile_map.has(key):
			tile_map[key] = []
		tile_map[key].append(t)
		
	#create a multimesh per each tile
	for key in tile_map.keys():
		var instances = tile_map[key]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = instances.size()
		
		var mm_instance := MultiMeshInstance3D.new()
		mm_instance.name = "%s_Tile_%d_%d" % [lod_name, key.x, key.y]
		mm_instance.multimesh = multimesh
		parent.add_child(mm_instance)
		mm_instance.set_owner(scene_root)
		
		#compute tile origin
		var tile_origin = Vector3( (key.x * tile_size) + tile_size * 0.5, 0.0, (key.y * tile_size) + tile_size * 0.5 )
		#calculate average Y heigh for origin
		var avg_y = 0.0
		for t in instances:
			avg_y += t.origin.y
		avg_y /= instances.size()
		tile_origin.y = avg_y
		
		mm_instance.global_position = tile_origin + center
		
		#assign local transforms relative to tile
		for i in range(instances.size()):
			var t_local = instances[i]
			t_local.origin -= (mm_instance.global_position)
			multimesh.set_instance_transform(i, t_local)


func _unbake_to_meshinstances():
	var lod0_parent: Node3D = get_node_or_null("BakedMultiMeshesLOD0")
	var lod1_parent: Node3D = get_node_or_null("BakedMultiMeshesLOD1")
	var lod2_parent: Node3D = get_node_or_null("BakedMultiMeshesLOD2")

	var collision_parent: Node3D = get_node_or_null("BakedCollisions")

	if lod0_parent == null and collision_parent == null:
		push_warning("Simple Foliage Painter: No baked data found to unbake.")
		return

	var all_transforms: Array[Transform3D] = []
	for mm_instance in lod0_parent.get_children():
		if mm_instance is MultiMeshInstance3D and mm_instance.multimesh:
			var mm: MultiMesh = mm_instance.multimesh
			for i in range(mm.instance_count):
				var local_t: Transform3D = mm.get_instance_transform(i)
				var world_t: Transform3D = mm_instance.global_transform * local_t
				all_transforms.append(world_t)
	
	for t in all_transforms:
		var mesh_inst = MeshInstance3D.new()
		mesh_inst.mesh = mesh_lod0
		mesh_inst.global_transform = t
		instances_node.add_child(mesh_inst)
		mesh_inst.set_owner(get_tree().edited_scene_root)
	
	if lod0_parent:
		lod0_parent.queue_free()
	if lod1_parent:
		lod1_parent.queue_free()
	if lod2_parent:
		lod2_parent.queue_free()
	if collision_parent:
		collision_parent.queue_free()
	
	instant_multimesh_enabled = false
	
	emit_signal("bake_state_changed")
	_create_brush_area()
	print("Simple Foliage Painter: Unbaked successfully, you can now adjust instances again")


func _unbake_to_multimesh():
	var lod0_parent: Node3D = get_node_or_null("BakedMultiMeshesLOD0")
	var lod1_parent: Node3D = get_node_or_null("BakedMultiMeshesLOD1")
	var lod2_parent: Node3D = get_node_or_null("BakedMultiMeshesLOD2")

	var collision_parent: Node3D = get_node_or_null("BakedCollisions")

	if lod0_parent == null and collision_parent == null:
		push_warning("Simple Foliage Painter: No baked data found to unbake.")
		return

	var all_transforms: Array[Transform3D] = []
	for mm_instance in lod0_parent.get_children():
		if mm_instance is MultiMeshInstance3D and mm_instance.multimesh:
			var mm: MultiMesh = mm_instance.multimesh
			for i in range(mm.instance_count):
				var local_t: Transform3D = mm.get_instance_transform(i)
				var world_t: Transform3D = mm_instance.global_transform * local_t
				all_transforms.append(world_t)
	
	_instant_mm_instance = MultiMeshInstance3D.new()
	_instant_mm_instance.name = "InstantMultiMesh"
	
	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh_lod0
	mm.instance_count = all_transforms.size()
	for i in range(all_transforms.size()):
		mm.set_instance_transform(i, all_transforms[i])
	_instant_mm_instance.multimesh = mm
	instances_node.add_child(_instant_mm_instance)
	_instant_mm_instance.set_owner(get_tree().edited_scene_root)
	
	if lod0_parent:
		lod0_parent.queue_free()
	if lod1_parent:
		lod1_parent.queue_free()
	if lod2_parent:
		lod2_parent.queue_free()
	if collision_parent:
		collision_parent.queue_free()
		
	instant_multimesh_enabled = true
	emit_signal("bake_state_changed")
	_create_brush_area()
	print("Simple Foliage Painter: Unbaked successfully, you can now adjust MultiMesh again")


func apply_lod_visibility_ranges(lod0_set_distance := 0.0, lod1_set_distance := 0.0, lod2_set_distance := 0.0):
	if lod0_set_distance == 0.0:
		lod0_set_distance = lod0_max_visible_distance
	if lod1_set_distance == 0.0:
		lod1_set_distance = lod1_max_visible_distance
	if lod2_set_distance == 0.0:
		lod2_set_distance = lod2_max_visible_distance
	
	var lod0_parent: Node3D = get_node_or_null("BakedMultiMeshesLOD0")
	var lod1_parent: Node3D = get_node_or_null("BakedMultiMeshesLOD1")
	var lod2_parent: Node3D = get_node_or_null("BakedMultiMeshesLOD2")
	
	if lod0_parent:
		for mm_instance in lod0_parent.get_children():
			if mm_instance is MultiMeshInstance3D:
				mm_instance.visibility_range_begin = 0.0
				mm_instance.visibility_range_end = lod0_set_distance
	
	if lod1_parent:
		for mm_instance in lod1_parent.get_children():
			if mm_instance is MultiMeshInstance3D:
				mm_instance.visibility_range_begin = max(0.0, lod0_set_distance - lod_visibility_offset)
				mm_instance.visibility_range_end = lod1_set_distance
	
	if lod2_parent:
		for mm_instance in lod2_parent.get_children():
			if mm_instance is MultiMeshInstance3D:
				mm_instance.visibility_range_begin = max(0.0, lod1_set_distance - lod_visibility_offset)
				mm_instance.visibility_range_end = lod2_set_distance


func is_baked() -> bool:
	return has_node("BakedMultiMeshesLOD0") or has_node("BakedMultiMeshesLOD1") or has_node("BakedMultiMeshesLOD2")
