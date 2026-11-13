extends RefCounted

## Apparatus shared by the follow gate and the follow recording; it does not ship. It builds the
## muscle skeleton in the physics guest, loads the avatar, reads data/drive.tsv, resolves its names
## to indices and hands the tables to follow.sgd. `pose` then moves the engine's skeleton.

const HIP_BONES := ["upperleg01.L", "upperleg01.R"]
const HIP_BODIES := ["femur_l", "femur_r"]

var error := ""
var physics: Object
var follower: Object
var scene: Node
var skel: Skeleton3D
var bones := PackedStringArray()
var bodies := PackedStringArray()
var parts := PackedStringArray()
var rows := 0
var zero_qpos := PackedFloat64Array()
var zero := PackedFloat64Array()
var hips := PackedInt32Array()
var usec := 0


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _swap_side(body: String) -> String:
	if body.ends_with("_l"):
		return body.trim_suffix("_l") + "_r"
	if body.ends_with("_r"):
		return body.trim_suffix("_r") + "_l"
	return body


## control "swap" hands the follower the table with left and right driving bodies exchanged.
func build(elf: String, glb: String, control: String) -> bool:
	physics = ClassDB.instantiate("Sandbox")
	physics.set_memory_max(1024)
	physics.set_allocations_max(1 << 22)
	physics.set_unboxed_arguments(true)
	physics.set("execution_timeout", 4000000)
	physics.load_buffer(FileAccess.get_file_as_bytes(elf))
	if physics.vmcall("mjc_load_human", -1) != true:
		error = "the model did not build"
		return false
	bodies = physics.vmcall("mjc_names", 1)
	zero_qpos = physics.vmcall("mjc_qpos")
	if zero_qpos.size() != 86:
		error = "qpos is %d numbers, not 86" % zero_qpos.size()
		return false
	zero = bodies_at(zero_qpos)
	if zero.size() != bodies.size() * 7:
		error = "mjc_bodies gave %d numbers for %d bodies" % [zero.size(), bodies.size()]
		return false

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(glb, state) != OK:
		error = "cannot read %s" % glb
		return false
	scene = doc.generate_scene(state)
	skel = _find(scene, "Skeleton3D") as Skeleton3D
	if skel == null:
		error = "no skeleton in %s" % glb
		return false
	var parents := PackedInt32Array()
	var rest := PackedFloat64Array()
	for c in skel.get_bone_count():
		bones.append(skel.get_bone_name(c))
		parents.append(skel.get_bone_parent(c))
		var g := skel.get_bone_global_rest(c)
		var q := g.basis.get_rotation_quaternion()
		rest.append_array([g.origin.x, g.origin.y, g.origin.z, q.x, q.y, q.z, q.w])

	var drive := PackedInt32Array()
	var table := FileAccess.get_file_as_string("res://data/drive.tsv").split("\n", false)
	for r in range(1, table.size()):
		var f := table[r].split("\t", true)
		if f.size() != 6:
			error = "drive.tsv row %d has %d fields" % [r, f.size()]
			return false
		if not parts.has(f[1]):
			parts.append(f[1])
		var body: String = _swap_side(f[1]) if control == "swap" else f[1]
		var row := [bones.find(f[0]), bodies.find(body), -1, -1, -1, -1]
		if f[2] != "":
			row = [row[0], row[1], bones.find(f[2]), bones.find(f[3]), bodies.find(f[4]), bodies.find(f[5])]
		if row[0] < 0 or row[1] < 0 or (f[2] != "" and row.has(-1)):
			error = "drive.tsv row %d names something unknown" % r
			return false
		drive.append_array(row)
	rows = drive.size() / 6
	hips = PackedInt32Array([bones.find(HIP_BONES[0]), bones.find(HIP_BONES[1]), bodies.find(HIP_BODIES[0]), bodies.find(HIP_BODIES[1])])
	if hips.has(-1):
		error = "the hip bones or the femur bodies are missing"
		return false

	var script: Object = ClassDB.instantiate("SafeGDScript")
	script.set_source_code(FileAccess.get_file_as_string("res://follow.sgd"))
	if script.get_compile_error() != "":
		error = "follow.sgd does not compile: %s" % script.get_compile_error()
		return false
	follower = ClassDB.instantiate("Sandbox")
	follower.load_buffer(script.get_content())
	var before = follower.vmcallv("pose", zero)
	if not (before is PackedFloat64Array) or before.size() != 0:
		error = "the follower answers a pose before it has its tables"
		return false
	var set_up = follower.vmcallv("setup", parents, rest, drive, zero, hips)
	if typeof(set_up) != TYPE_INT or set_up != 0:
		error = "the follower refused its tables: %s" % str(set_up)
		return false
	return true


## The 7 numbers of every body at this qpos, in MuJoCo's axes.
func bodies_at(qpos: PackedFloat64Array) -> PackedFloat64Array:
	physics.vmcall("mjc_set_qpos", qpos)
	physics.vmcall("mjc_forward")
	return physics.vmcall("mjc_bodies")


## Poses the skeleton from the bodies. The skeleton must be inside the tree, or the engine does not
## recompute its global poses. False when the follower gave no pose.
func pose(now: PackedFloat64Array) -> bool:
	var n := bones.size()
	var t0 := Time.get_ticks_usec()
	var out = follower.vmcallv("pose", now)
	usec += Time.get_ticks_usec() - t0
	if not (out is PackedFloat64Array) or out.size() != n * 4 + 3:
		return false
	for c in n:
		skel.set_bone_pose_rotation(c, Quaternion(out[c * 4], out[c * 4 + 1], out[c * 4 + 2], out[c * 4 + 3]))
	skel.set_bone_pose_position(0, Vector3(out[n * 4], out[n * 4 + 1], out[n * 4 + 2]))
	return true


## A body's origin here: MuJoCo's (x, y, z) is (y, z, x) in the engine's axes.
static func origin(now: PackedFloat64Array, body: int) -> Vector3:
	return Vector3(now[body * 7 + 1], now[body * 7 + 2], now[body * 7])
