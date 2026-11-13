# godot --headless --path . --script diff_vmc.gd ++ --a=<elf> --b=<elf> [--n=3000] [--plant=1]
# Feeds the same valid, truncated and byte-flipped datagrams to two vmc ELFs and compares every output.
# Flips stay ASCII on purpose: the Lean decoder rejects non-UTF-8 strings and the C++ one in PR #1 did not.
# --plant=1 appends a byte to b's dump at the end and must give RESULT: FAIL.
extends SceneTree

func _arg(n: String, d: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.trim_prefix("--%s=" % n)
	return d

func _pstr(b: PackedByteArray, s: String) -> void:
	b.append_array(s.to_ascii_buffer())
	b.append(0)
	while b.size() % 4:
		b.append(0)

func _f(b: PackedByteArray, v: float) -> void:
	var t := PackedByteArray()
	t.resize(4)
	t.encode_float(0, v)
	t.reverse()
	b.append_array(t)

func _msg(addr: String, name: String, vals: Array) -> PackedByteArray:
	var b := PackedByteArray()
	_pstr(b, addr)
	_pstr(b, "," + ("s" if name != "" else "") + "f".repeat(vals.size()))
	if name != "":
		_pstr(b, name)
	for v in vals:
		_f(b, v)
	return b

func _bundle(els: Array) -> PackedByteArray:
	var o := PackedByteArray()
	_pstr(o, "#bundle")
	for k in 8:
		o.append(1 if k == 7 else 0)
	for e in els:
		var sz: int = e.size()
		o.append_array(PackedByteArray([(sz >> 24) & 255, (sz >> 16) & 255, (sz >> 8) & 255, sz & 255]))
		o.append_array(e)
	return o

func _load(path: String) -> Object:
	var sb = ClassDB.instantiate("Sandbox")
	sb.set("allocations_max", 1000000)
	sb.set("references_max", 4096)
	sb.set("memory_max", 64)
	sb.set("execution_timeout", 600000)
	sb.load_buffer(FileAccess.get_file_as_bytes(path))
	return sb

func _dump(sb: Object) -> String:
	var parts := PackedStringArray()
	for fn in ["vmc_stats", "vmc_bones", "vmc_roots", "vmc_trackers", "vmc_blend", "vmc_unknown", "vmc_time"]:
		parts.append("%s=%s" % [fn, str(sb.vmcall(fn))])
	for fn in ["vmc_bone_rows", "vmc_root_rows", "vmc_tracker_rows", "vmc_camera"]:
		parts.append("%s=%s" % [fn, str(sb.vmcall(fn))])
	return "\n".join(parts)

func _process(_d: float) -> bool:
	var a = _load(_arg("a", ""))
	var b = _load(_arg("b", ""))
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var n := int(_arg("n", "3000"))
	var names := ["Hips", "Spine", "Head", "LeftHand", "RightHand"]
	var diffs := 0
	var bad_agree := 0
	for i in n:
		var pk: PackedByteArray
		match i % 6:
			0: pk = _msg("/VMC/Ext/Bone/Pos", names[rng.randi() % 5], [rng.randf(), rng.randf(), rng.randf(), 0.0, 0.0, 0.0, 1.0])
			1: pk = _msg("/VMC/Ext/Root/Pos", "root", [rng.randf(), 1.0, 2.0, 0.0, 0.0, 0.0, 1.0])
			2: pk = _msg("/VMC/Ext/Tra/Pos", "T%d" % (rng.randi() % 3), [rng.randf(), 1.0, 2.0, 0.0, 0.0, 0.0, 1.0])
			3: pk = _bundle([_msg("/VMC/Ext/Blend/Val", "Joy", [rng.randf()]), _msg("/VMC/Ext/Blend/Apply", "", []), _msg("/VMC/Ext/T", "", [rng.randf() * 100.0])])
			4: pk = _msg("/VMC/Ext/Cam", "Camera", [0.0, 1.0, 2.0, 0.0, 0.0, 0.0, 1.0, 40.0])
			_: pk = _msg("/VMC/Ext/Midi/Note", "", [1.0, 2.0])
		var kind := rng.randi() % 4
		if kind == 1 and pk.size() > 1:
			pk = pk.slice(0, rng.randi_range(1, pk.size() - 1))  # truncate
		elif kind == 2 and pk.size() > 0:
			pk[rng.randi() % pk.size()] = rng.randi() % 128  # flip a byte to ASCII: UTF-8 validity is a documented difference
		var ra := int(a.vmcall("vmc_feed", pk))
		var rb := int(b.vmcall("vmc_feed", pk))
		if ra != rb:
			diffs += 1
			if diffs <= 5:
				print("DIFF feed result at ", i, " kind=", kind, " a=", ra, " b=", rb, " bytes=", pk.hex_encode())
		if ra == 0:
			bad_agree += 1
		if i % 500 == 499 or i == n - 1:
			var da := _dump(a)
			var db := _dump(b)
			if _arg("plant", "") != "" and i == n - 1:
				db += "x"
			if da != db:
				diffs += 1
				var la := da.split("\n")
				var lb := db.split("\n")
				for k in min(la.size(), lb.size()):
					if la[k] != lb[k]:
						print("DIFF state at ", i, ":\n  a ", la[k].left(300), "\n  b ", lb[k].left(300))
						break
	print("datagrams=", n, " rejected_by_both=", bad_agree, " diffs=", diffs)
	print("RESULT: ", "PASS" if diffs == 0 else "FAIL")
	quit(1 if diffs else 0)
	return true
