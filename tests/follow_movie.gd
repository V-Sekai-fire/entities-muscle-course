## Explained in docs/follow.md.
extends SceneTree

const Rig := preload("res://tests/follow_rig.gd")
const CLIPS := ["walk", "idle"]
const VIEWS := 8
const HOLD := 2.0
const FPS := 32
const TICK_HZ := 64
const CLIP_HZ := 100.0
const RADIUS := 3.0
const FOCUS_HEIGHT := 0.9

var rig: Rig
var clips: Array[PackedFloat64Array] = []
var frame := -1
var cam: Camera3D
var dots: Array[MeshInstance3D] = []
var dot_bodies := PackedInt32Array()
var caption: Label
var control := ""
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


func _qpos(q: PackedFloat64Array, t: float) -> PackedFloat64Array:
	var count: int = q.size() / 86
	var f: float = fmod(t * CLIP_HZ, float(count - 1))
	var i: int = mini(int(f), count - 2)
	var w: float = f - i
	var out := PackedFloat64Array()
	out.resize(86)
	for k in 86:
		out[k] = lerpf(q[i * 86 + k], q[(i + 1) * 86 + k], w)
	var len := sqrt(out[3] * out[3] + out[4] * out[4] + out[5] * out[5] + out[6] * out[6])
	for k in range(3, 7):
		out[k] /= len
	return out


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


func _light(degrees: Vector3, energy: float) -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = degrees
	light.light_energy = energy
	root.add_child(light)


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 3:
		_end("RESULT: FAIL usage: -- <mujoco.elf> <anny_base.glb> <clips dir> [--control=swap]", 1)
		return
	for x in a.slice(3):
		if x == "--control=swap":
			control = "swap"
		else:
			_end("RESULT: FAIL unknown argument %s" % x, 1)
			return
	for name in CLIPS:
		var q := FileAccess.get_file_as_bytes(a[2].path_join(name + ".f64")).to_float64_array()
		if q.size() < 172 or q.size() % 86 != 0:
			_end("RESULT: FAIL clip %s is not rows of 86 float64" % name, 1)
			return
		clips.append(q)
	rig = Rig.new()
	if not rig.build(a[0], a[1], control):
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
	_light(Vector3(-50, 35, 0), 0.7)
	_light(Vector3(55, -145, 0), 0.25)
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
	frame = 0


func _process(_delta: float) -> bool:
	if frame < 0:
		return false
	var per_view := int(HOLD * FPS)
	var per_clip := VIEWS * per_view
	if frame >= per_clip * CLIPS.size():
		print("VIDEO mapping=%s frames=%d fps=%d ticks=%d clips=%s views=%d hold=%.1f radius=%.1f worst root %s m" % [control if control != "" else "real", frame, FPS, frame * TICK_HZ / FPS, "+".join(CLIPS), VIEWS, HOLD, RADIUS, String.num_scientific(worst_root)])
		print("RESULT: PASS recorded")
		quit(0)
		return true
	var clip: int = frame / per_clip
	var local: int = frame % per_clip
	var view: int = local / per_view
	var now := PackedFloat64Array()
	var ticks: int = TICK_HZ / FPS
	for k in ticks:
		var tick: int = local * ticks + k + 1
		now = rig.bodies_at(_qpos(clips[clip], float(tick) / TICK_HZ))
	if not rig.pose(now):
		print("RESULT: FAIL the follower gave no pose at frame %d" % frame)
		quit(1)
		return true
	for i in dots.size():
		dots[i].position = Rig.origin(now, dot_bodies[i])
	var femur: Vector3 = (Rig.origin(now, rig.hips[2]) + Rig.origin(now, rig.hips[3])) * 0.5
	var hip: Vector3 = (rig.skel.get_bone_global_pose(rig.hips[0]).origin + rig.skel.get_bone_global_pose(rig.hips[1]).origin) * 0.5
	worst_root = maxf(worst_root, (hip - femur).length())
	var focus := Vector3(femur.x, FOCUS_HEIGHT, femur.z)
	var dir := _view_dir(view)
	var from := focus + dir * RADIUS
	cam.transform = Transform3D(Basis.looking_at(focus - from, Vector3.UP if absf(dir.y) < 0.9 else Vector3(0, 0, 1)), from)
	caption.text = "%s   %s   view %d of %d" % ["swap (control)" if control == "swap" else "real", CLIPS[clip], view, VIEWS]
	frame += 1
	return false
