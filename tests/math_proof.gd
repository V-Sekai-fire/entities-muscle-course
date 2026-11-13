## Explained in docs/follow.md.
extends SceneTree


const KINDS := ["float", "quat", "basis"]
const CHAINS := [10, 90, 104, 400, 2000]
const REPEATS := 200
const TOL := 1e-12


func _guest(kind: String) -> Object:
	var script: Object = ClassDB.instantiate("SafeGDScript")
	script.set_source_code(FileAccess.get_file_as_string("res://proof/math_%s.sgd" % kind))
	if script.get_compile_error() != "":
		print("MATH %s compile error: %s" % [kind, script.get_compile_error()])
		return null
	var sb: Object = ClassDB.instantiate("Sandbox")
	sb.load_buffer(script.get_content())
	return sb


func _diff(got, want: Quaternion) -> float:
	if not (got is PackedFloat64Array) or got.size() != 4:
		return INF
	var a: float = absf(got[0] - want.w) + absf(got[1] - want.x) + absf(got[2] - want.y) + absf(got[3] - want.z)
	var b: float = absf(got[0] + want.w) + absf(got[1] + want.x) + absf(got[2] + want.y) + absf(got[3] + want.z)
	return minf(a, b)


func _init() -> void:
	var flip: bool = OS.get_cmdline_user_args().has("--control=flip")
	var p := Quaternion(Vector3(0.3, -0.5, 0.81).normalized(), 0.7)
	var q := Quaternion(Vector3(-0.2, 0.9, 0.1).normalized(), 0.013)
	var arg := PackedFloat64Array([p.w, p.x, p.y, p.z, q.w, q.x, q.y, q.z])
	var want_mul: Quaternion = p * q
	var want_chain := {}
	for n in CHAINS:
		var c := p
		for i in n:
			c = (c * q).normalized()
		want_chain[n] = c
	if flip:
		arg[5] = -arg[5]
	var usable := {}
	for kind in KINDS:
		var sb: Object = _guest(kind)
		if sb == null:
			usable[kind] = false
			continue
		var d: float = _diff(sb.vmcallv("quat_mul", arg), want_mul)
		var ok: bool = d <= TOL
		var line := "MATH %s product diff=%s" % [kind, String.num_scientific(d)]
		var longest := 0
		for n in CHAINS:
			var got = sb.vmcallv("chain", arg, n)
			var dc: float = _diff(got, want_chain[n])
			if dc > 1e-9:
				line += "  chain %d: wrong or refused (diff=%s)" % [n, String.num_scientific(dc)]
				break
			longest = n
			var t0: int = Time.get_ticks_usec()
			for r in REPEATS:
				sb.vmcallv("chain", arg, n)
			var per_call: float = float(Time.get_ticks_usec() - t0) / REPEATS
			line += "  chain %d: diff=%s %.1f usec/call %.0f nsec/step" % [n, String.num_scientific(dc), per_call, per_call * 1000.0 / n]
		print(line)
		usable[kind] = ok and longest >= 104
		if kind == "float" and ok:
			var t0: int = Time.get_ticks_usec()
			for r in 2000:
				sb.vmcallv("nop", arg)
			var nop: float = float(Time.get_ticks_usec() - t0) / 2000.0
			t0 = Time.get_ticks_usec()
			for r in REPEATS:
				sb.vmcallv("packed_sum", arg, 4000)
			var rd: float = float(Time.get_ticks_usec() - t0) / REPEATS
			t0 = Time.get_ticks_usec()
			for r in REPEATS:
				sb.vmcallv("packed_fill", 4000)
			var wr: float = float(Time.get_ticks_usec() - t0) / REPEATS
			var filled = sb.vmcallv("packed_fill", 4000)
			var fill_ok: bool = filled is PackedFloat64Array and filled.size() == 4000 and filled[3999] == 1999.5
			print("MATH float empty call %.2f usec; packed read %.0f nsec/element; packed write %.0f nsec/element (ok=%s)" % [nop, rd * 1000.0 / 4000.0, wr * 1000.0 / 4000.0, str(fill_ok)])
	print("MATH usable for 104 bones in one call: float=%s quat=%s basis=%s" % [str(usable["float"]), str(usable["quat"]), str(usable["basis"])])
	if not usable["float"]:
		print("RESULT: FAIL the float guest does not reproduce the host's quaternion product and chains")
		quit(1)
		return
	print("RESULT: PASS")
	quit(0)
