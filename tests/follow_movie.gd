extends SceneTree

## Recording, not a gate: the avatar following the muscle skeleton through a clip, seen from the
## Hammersley orbit views one after another. It needs a window and the movie writer:
##   godot --path . --resolution 1280x720 --write-movie <out.mov> --fixed-fps 30 -s tests/follow_movie.gd -- <mujoco.elf> <anny_base.glb> <clip.f64> [label] [--shots=<dir>]
## The clip is raw float64, 86 per frame, 100 frames a second, and loops. Each view is held for
## HOLD seconds, so the recording is VIEWS * HOLD seconds long. The dots are the origins of the 21
## driving bodies of the muscle skeleton, drawn through the skin. --shots saves one still per view.
## Views: sphere_hammersley_sequence(i, N), offset 0, no remap: pitch = acos(1 - 2 i / N) - pi / 2,
## yaw = 2 pi * the base-2 radical inverse of i; view 0 is straight below. Z up there is Y up here.

const Rig := preload("res://tests/follow_rig.gd")
const VIEWS := 8
const HOLD := 2.0
const FPS := 30
const CLIP_HZ := 100.0
const DISTANCE := 3.0
const FOCUS_HEIGHT := 0.9

var rig: Rig
var qpos := PackedFloat64Array()
var frames := 0
var tick := -1
var cam: Camera3D
var dots: Array[MeshInstance3D] = []
var dot_bodies := PackedInt32Array()
var caption: Label
var label := ""
var shots := ""
var worst_root := 0.0


func _rad2(i: int) -> float:
	var r := 0.0
	var f := 0.5
	var n := i
	while n > 0:
		r += f * float(n & 1)
		n >>= 1
		f *= 0.5
	return r


func _view_dir(view: int) -> Vector3:
	var pitch := acos(1.0 - 2.0 * float(view) / float(VIEWS)) - PI / 2.0
	var phi := TAU * _rad2(view)
	return Vector3(sin(phi) * cos(pitch), sin(pitch), -cos(phi) * cos(pitch))


func _end(line: String, code: int) -> void:
	print(line)
	quit(code)


func _grid() -> MeshInstance3D:
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.45, 0.47, 0.5)
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for i in range(-10, 11):
		im.surface_add_vertex(Vector3(i, 0, -10))
		im.surface_add_vertex(Vector3(i, 0, 10))
		im.surface_add_vertex(Vector3(-10, 0, i))
		im.surface_add_vertex(Vector3(10, 0, i))
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	return mi


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 3:
		_end("RESULT: FAIL usage: -- <mujoco.elf> <anny_base.glb> <clip.f64> [label] [--shots=<dir>]", 1)
		return
	for x in a.slice(3):
		if x.begins_with("--shots="):
			shots = x.trim_prefix("--shots=")
		else:
			label = x
	qpos = FileAccess.get_file_as_bytes(a[2]).to_float64_array()
	frames = qpos.size() / 86
	if frames == 0 or qpos.size() != frames * 86:
		_end("RESULT: FAIL %s is not rows of 86 float64" % a[2], 1)
		return
	rig = Rig.new()
	if not rig.build(a[0], a[1], ""):
		_end("RESULT: FAIL " + rig.error, 1)
		return
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.13, 0.14, 0.16)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.3
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 0.7
	root.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(55, -145, 0)
	fill.light_energy = 0.25
	root.add_child(fill)
	root.add_child(_grid())
	root.add_child(rig.scene)
	cam = Camera3D.new()
	cam.fov = 40.0
	cam.near = 0.05
	cam.far = 50.0
	root.add_child(cam)
	cam.make_current()
	var ball := SphereMesh.new()
	ball.radius = 0.018
	ball.height = 0.036
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.35, 0.1)
	mat.no_depth_test = true
	mat.render_priority = 10
	ball.material = mat
	for p in rig.parts:
		var d := MeshInstance3D.new()
		d.mesh = ball
		root.add_child(d)
		dots.append(d)
		dot_bodies.append(rig.bodies.find(p))
	var layer := CanvasLayer.new()
	caption = Label.new()
	caption.position = Vector2(24, 18)
	caption.add_theme_font_size_override("font_size", 22)
	layer.add_child(caption)
	root.add_child(layer)
	await process_frame
	if not rig.skel.is_inside_tree():
		_end("RESULT: FAIL the skeleton is not in the tree", 1)
		return
	tick = 0


func _process(_delta: float) -> bool:
	if tick < 0:
		return false
	var total := int(VIEWS * HOLD * FPS)
	if tick >= total:
		print("VIDEO %s: %d frames written, %d views; hip midpoint off the femur midpoint by at most %s m" % [label, tick, VIEWS, String.num_scientific(worst_root)])
		print("RESULT: PASS recorded")
		quit(0)
		return true
	var t := float(tick) / FPS
	var f := int(round(t * CLIP_HZ)) % frames
	var view := mini(int(t / HOLD), VIEWS - 1)
	var now: PackedFloat64Array = rig.bodies_at(qpos.slice(f * 86, f * 86 + 86))
	if not rig.pose(now):
		print("RESULT: FAIL the follower gave no pose at clip frame %d" % f)
		quit(1)
		return true
	for i in dots.size():
		dots[i].position = Rig.origin(now, dot_bodies[i])
	var femur: Vector3 = (Rig.origin(now, rig.hips[2]) + Rig.origin(now, rig.hips[3])) * 0.5
	var hip: Vector3 = (rig.skel.get_bone_global_pose(rig.hips[0]).origin + rig.skel.get_bone_global_pose(rig.hips[1]).origin) * 0.5
	worst_root = maxf(worst_root, (hip - femur).length())
	var focus := Vector3(femur.x, FOCUS_HEIGHT, femur.z)
	var dir := _view_dir(view)
	var from := focus + dir * DISTANCE
	cam.transform = Transform3D(Basis.looking_at(focus - from, Vector3.UP if absf(dir.y) < 0.9 else Vector3(0, 0, 1)), from)
	caption.text = "%s   view %d of %d   clip frame %d" % [label, view, VIEWS, f]
	if shots != "" and tick % int(HOLD * FPS) == int(HOLD * FPS) / 2:
		_shot(view)
	tick += 1
	return false


func _shot(view: int) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(shots.path_join("%s_view%d.png" % [label, view]))
