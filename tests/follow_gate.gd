extends SceneTree

## Gate: the avatar's bones, posed through follow.sgd from the muscle skeleton in the physics guest,
## against a reference made outside the engine (the reference script's own mapping, run through the
## avatar model's own forward pass).
##   godot --headless --path . -s tests/follow_gate.gd -- <mujoco.elf> <anny_base.glb> <reference dir> [--control=swap]
## The verdict is the RESULT: line.
## The reference directory holds bones.txt, parents.txt, bodies.txt, qpos0.f64, rest.f64 (per bone 9
## rotation numbers by rows and 3 for the head), clips.tsv (name, frames) and per clip <name>.qpos.f64
## (86 per frame) and <name>.poses.f64 (per frame and bone, 9 and 3 as in rest.f64). The reference is
## Z up; (x, y, z) there is (x, z, -y) here.
## For every frame of every clip, read from the engine's own Skeleton3D after the pose is set:
##   turn   the angle between each bone's turn from rest here and in the reference
##   head   the distance between each bone's head here and in the reference, both from the hip midpoint
##   root   the distance of the hip midpoint from the midpoint of the two femur bodies' origins
## Both sides are double precision, so the limits are far below anything a wrong mapping gives.
## --control=swap hands the follower the table with left and right driving bodies exchanged: must FAIL.

const Rig := preload("res://tests/follow_rig.gd")
const TOL_TURN := 1e-9
const TOL_HEAD := 1e-9
const TOL_ROOT := 1e-9
const MIN_MOTION := 0.1


func _end(line: String, code: int) -> void:
	print(line)
	quit(code)


func _lines(path: String) -> PackedStringArray:
	return FileAccess.get_file_as_string(path).split("\n", false)


## Reference (Z up) to here (Y up).
func _vec(t: PackedFloat64Array, o: int) -> Vector3:
	return Vector3(t[o], t[o + 2], -t[o + 1])


## A reference rotation matrix M, 9 numbers by rows, as B M B^T with B the map of _vec.
func _mat(t: PackedFloat64Array, o: int) -> Basis:
	return Basis(
		Vector3(t[o], t[o + 6], -t[o + 3]),
		Vector3(t[o + 2], t[o + 8], -t[o + 5]),
		Vector3(-t[o + 1], -t[o + 7], t[o + 4]))


## The angle of a rotation, exact for small angles too (acos of the w part is blind below 1e-8).
func _angle(b: Basis) -> float:
	var q := b.get_rotation_quaternion()
	return 2.0 * atan2(Vector3(q.x, q.y, q.z).length(), absf(q.w))


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 3:
		_end("RESULT: FAIL usage: -- <mujoco.elf> <anny_base.glb> <reference dir> [--control=swap]", 1)
		return
	var control := ""
	for x in a.slice(3):
		if x == "--control=swap":
			control = "swap"
		else:
			_end("RESULT: FAIL unknown argument %s" % x, 1)
			return
	var ref: String = a[2]
	var rig := Rig.new()
	if not rig.build(a[0], a[1], control):
		_end("RESULT: FAIL " + rig.error, 1)
		return
	var skel: Skeleton3D = rig.skel
	var n := rig.bones.size()
	root.add_child(rig.scene)
	await process_frame
	if not skel.is_inside_tree():
		_end("RESULT: FAIL the skeleton is not in the tree, so the engine would not pose it", 1)
		return

	# The two sides must be the same skeletons before any pose is compared.
	if rig.bodies != _lines(ref.path_join("bodies.txt")):
		_end("RESULT: FAIL the guest's bodies are not the reference's", 1)
		return
	if rig.bones != _lines(ref.path_join("bones.txt")):
		_end("RESULT: FAIL the avatar's bones are not the reference's", 1)
		return
	var ref_parents := _lines(ref.path_join("parents.txt"))
	for c in n:
		if skel.get_bone_parent(c) != int(ref_parents[c]):
			_end("RESULT: FAIL bone %s has another parent in the reference" % rig.bones[c], 1)
			return
	var ref_q0 := FileAccess.get_file_as_bytes(ref.path_join("qpos0.f64")).to_float64_array()
	var ref_rest := FileAccess.get_file_as_bytes(ref.path_join("rest.f64")).to_float64_array()
	if ref_q0.size() != 86 or ref_rest.size() != n * 12:
		_end("RESULT: FAIL the reference's qpos0.f64 or rest.f64 has the wrong size", 1)
		return
	var q0_diff := 0.0
	for i in 86:
		q0_diff = maxf(q0_diff, absf(rig.zero_qpos[i] - ref_q0[i]))
	var rest_turn := 0.0
	var rest_head := 0.0
	var rest_inv: Array[Basis] = []
	var ref_rest_inv: Array[Basis] = []
	for c in n:
		var g := skel.get_bone_global_rest(c)
		var here := Basis(g.basis.get_rotation_quaternion())
		var want := _mat(ref_rest, c * 12)
		rest_inv.append(here.inverse())
		ref_rest_inv.append(want.inverse())
		rest_turn = maxf(rest_turn, _angle(here * want.inverse()))
		rest_head = maxf(rest_head, (g.origin - _vec(ref_rest, c * 12 + 9)).length())
	print("FOLLOW rest: %d bones, %d bodies; default pose differs from the reference's by %s; rest turn by %s rad, rest head by %s m" % [n, rig.bodies.size(), String.num_scientific(q0_diff), String.num_scientific(rest_turn), String.num_scientific(rest_head)])
	print("FOLLOW table: %d rows, %d driving bodies in order: %s" % [rig.rows, rig.parts.size(), " ".join(rig.parts)])

	var hips := rig.hips
	var worst_turn := 0.0
	var worst_turn_at := ""
	var worst_head := 0.0
	var worst_head_at := ""
	var worst_root := 0.0
	var frames_done := 0
	var compared := 0
	var failed := ""
	for line in _lines(ref.path_join("clips.tsv")):
		var clip: String = line.split("\t")[0]
		var frames: int = int(line.split("\t")[1])
		var qpos := FileAccess.get_file_as_bytes(ref.path_join(clip + ".qpos.f64")).to_float64_array()
		var want := FileAccess.get_file_as_bytes(ref.path_join(clip + ".poses.f64")).to_float64_array()
		if frames == 0 or qpos.size() != frames * 86 or want.size() != frames * n * 12:
			_end("RESULT: FAIL clip %s: qpos %d, poses %d numbers for %d frames" % [clip, qpos.size(), want.size(), frames], 1)
			return
		var motion := 0.0
		var clip_turn := 0.0
		var clip_head := 0.0
		for f in frames:
			var now: PackedFloat64Array = rig.bodies_at(qpos.slice(f * 86, f * 86 + 86))
			if not rig.pose(now):
				_end("RESULT: FAIL clip %s frame %d: the follower gave no pose" % [clip, f], 1)
				return
			var base := f * n * 12
			var hip: Vector3 = (skel.get_bone_global_pose(hips[0]).origin + skel.get_bone_global_pose(hips[1]).origin) * 0.5
			var ref_hip: Vector3 = (_vec(want, base + hips[0] * 12 + 9) + _vec(want, base + hips[1] * 12 + 9)) * 0.5
			var femur: Vector3 = (Rig.origin(now, hips[2]) + Rig.origin(now, hips[3])) * 0.5
			worst_root = maxf(worst_root, (hip - femur).length())
			for c in n:
				var g := skel.get_bone_global_pose(c)
				var turned: Basis = g.basis.orthonormalized() * rest_inv[c]
				var ref_turned: Basis = _mat(want, base + c * 12) * ref_rest_inv[c]
				var turn: float = _angle(turned * ref_turned.inverse())
				var head: float = ((g.origin - hip) - (_vec(want, base + c * 12 + 9) - ref_hip)).length()
				motion = maxf(motion, _angle(ref_turned))
				clip_turn = maxf(clip_turn, turn)
				clip_head = maxf(clip_head, head)
				if turn > worst_turn:
					worst_turn = turn
					worst_turn_at = "%s frame %d %s" % [clip, f, rig.bones[c]]
				if head > worst_head:
					worst_head = head
					worst_head_at = "%s frame %d %s" % [clip, f, rig.bones[c]]
				compared += 1
			frames_done += 1
		print("FOLLOW clip %s: %d frames, largest turn from rest in the reference %.3f rad; worst turn %s rad, worst head %s m" % [clip, frames, motion, String.num_scientific(clip_turn), String.num_scientific(clip_head)])
		if motion < MIN_MOTION and failed == "":
			failed = "clip %s does not move in the reference (%.4f rad)" % [clip, motion]
	print("FOLLOW control=%s frames=%d comparisons=%d follower %.1f usec a pose" % [control if control != "" else "none", frames_done, compared, float(rig.usec) / maxi(frames_done, 1)])
	print("FOLLOW worst turn %s rad at %s (limit %s)" % [String.num_scientific(worst_turn), worst_turn_at, String.num_scientific(TOL_TURN)])
	print("FOLLOW worst head %s m at %s (limit %s)" % [String.num_scientific(worst_head), worst_head_at, String.num_scientific(TOL_HEAD)])
	print("FOLLOW worst root %s m (limit %s)" % [String.num_scientific(worst_root), String.num_scientific(TOL_ROOT)])
	if failed == "" and (frames_done == 0 or compared != frames_done * n):
		failed = "nothing was compared"
	if failed == "" and q0_diff > 1e-12:
		failed = "the guest's default pose is not the reference's"
	if failed == "" and worst_turn > TOL_TURN:
		failed = "a bone's turn differs from the reference by %s rad at %s" % [String.num_scientific(worst_turn), worst_turn_at]
	if failed == "" and worst_head > TOL_HEAD:
		failed = "a bone's head differs from the reference by %s m at %s" % [String.num_scientific(worst_head), worst_head_at]
	if failed == "" and worst_root > TOL_ROOT:
		failed = "the hip midpoint is %s m off the muscle skeleton's" % String.num_scientific(worst_root)
	if failed != "":
		_end("RESULT: FAIL " + failed, 1)
		return
	_end("RESULT: PASS %d frames, %d bones each" % [frames_done, n], 0)
