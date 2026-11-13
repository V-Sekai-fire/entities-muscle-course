# godot --headless --path . --script run_vmc.gd ++ --elf=vmc.elf [--control]
# Builds real OSC datagrams, feeds them to vmc.elf, prints RESULT: PASS/FAIL.
extends SceneTree

var fails := 0

func _arg(n: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.trim_prefix("--%s=" % n)
	return ""

func _flag(n: String) -> bool:
	return OS.get_cmdline_user_args().has("--%s" % n)

func _pstr(b: PackedByteArray, s: String) -> void:
	b.append_array(s.to_ascii_buffer())
	b.append(0)
	while b.size() % 4:
		b.append(0)

func _f(b: PackedByteArray, v: float) -> void:
	var t := PackedByteArray()
	t.resize(4)
	t.encode_float(0, v)  # little endian; OSC is big endian
	t.reverse()
	b.append_array(t)

func _msg(addr: String, args: Array) -> PackedByteArray:
	var head := PackedByteArray()
	var body := PackedByteArray()
	var tags := ","
	_pstr(head, addr)
	for a in args:
		if a is String:
			tags += "s"
			_pstr(body, a)
		else:
			tags += "f"
			_f(body, a)
	_pstr(head, tags)
	head.append_array(body)
	return head

func _bundle(els: Array) -> PackedByteArray:
	var o := PackedByteArray()
	_pstr(o, "#bundle")
	for k in 8:
		o.append(1 if k == 7 else 0)
	for e in els:
		var n := PackedByteArray([0, 0, 0, 0])
		n.encode_u32(0, 0)
		var sz: int = e.size()
		o.append_array(PackedByteArray([(sz >> 24) & 255, (sz >> 16) & 255, (sz >> 8) & 255, sz & 255]))
		o.append_array(e)
	return o

func _check(ok: bool, what: String) -> void:
	if not ok:
		print("FAIL ", what)
		fails += 1

func _process(_d: float) -> bool:
	var sb = ClassDB.instantiate("Sandbox")
	sb.set("allocations_max", 1000000)
	sb.set("references_max", 4096)
	sb.set("memory_max", 256)
	sb.set("execution_timeout", 60000)
	sb.load_buffer(FileAccess.get_file_as_bytes(_arg("elf")))
	_check(sb.has_function("vmc_feed"), "has vmc_feed")
	print("clear: ", sb.vmcall("vmc_clear"))

	var pk := _bundle([
		_msg("/VMC/Ext/Root/Pos", ["root", 1.0, 2.0, 3.0, 0.0, 0.0, 0.0, 1.0]),
		_msg("/VMC/Ext/Bone/Pos", ["Hips", 0.1, 0.2, 0.3, 0.5, 0.5, 0.5, 0.5]),
		_msg("/VMC/Ext/Bone/Pos", ["Head", 0.0, 1.6, 0.0, 0.0, 0.0, 0.0, 1.0]),
		_msg("/VMC/Ext/Blend/Val", ["Joy", 0.25]),
		_msg("/VMC/Ext/Blend/Apply", []),
		_msg("/VMC/Ext/T", [12.5]),
		_msg("/VMC/Ext/Tra/Pos", ["LHAND", -0.3, 1.2, 0.1, 0.0, 0.0, 0.0, 1.0]),
	])
	_check(int(sb.vmcall("vmc_feed", pk)) == 1, "feed bundle")
	print("stats: ", sb.vmcall("vmc_stats"))
	_check(sb.vmcall("vmc_bones") == "Head\nHips\n", "bone names sorted")
	var rows: PackedFloat32Array = sb.vmcall("vmc_bone_rows")
	_check(rows.size() == 14, "bone rows size")
	_check(rows.size() == 14 and is_equal_approx(rows[7 + 1], 0.2) and is_equal_approx(rows[7 + 6], 0.5), "Hips row")
	_check(is_equal_approx(float(sb.vmcall("vmc_time")), 12.5 if not _flag("control") else 13.5), "time")
	_check(sb.vmcall("vmc_blend") == "Joy 0.25\n", "blend applied")
	_check(sb.vmcall("vmc_trackers") == "tra:LHAND\n", "tracker name")
	var rr: PackedFloat32Array = sb.vmcall("vmc_root_rows")
	_check(rr.size() == 7 and is_equal_approx(rr[2], 3.0), "root row")

	# Malformed input is rejected and counted, the guest keeps working.
	_check(int(sb.vmcall("vmc_feed", PackedByteArray([120, 121, 122]))) == 0, "junk rejected")
	var cut := pk.slice(0, pk.size() - 5)
	_check(int(sb.vmcall("vmc_feed", cut)) == 0, "truncated bundle rejected")
	_check(float(sb.vmcall("vmc_time")) > 0.0, "still alive after bad input")
	print("stats after bad: ", sb.vmcall("vmc_stats"))
	print("RESULT: ", "PASS" if fails == 0 else "FAIL (%d)" % fails)
	quit(1 if fails else 0)
	return true
