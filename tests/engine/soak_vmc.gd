# godot --headless --path . --script soak_vmc.gd ++ --elf=vmc.elf [--n=20000]
# Feeds many datagrams to one Sandbox and prints the guest's counters, to see state stay flat.
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

func _pose(name: String, x: float) -> PackedByteArray:
	var b := PackedByteArray()
	_pstr(b, "/VMC/Ext/Bone/Pos")
	_pstr(b, ",sfffffff")
	_pstr(b, name)
	for v in [x, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0]:
		_f(b, v)
	return b

func _process(_d: float) -> bool:
	var sb = ClassDB.instantiate("Sandbox")
	sb.set("allocations_max", 1000000)
	sb.set("references_max", 4096)
	sb.set("memory_max", 64)
	sb.set("execution_timeout", 600000)
	sb.load_buffer(FileAccess.get_file_as_bytes(_arg("elf", "")))
	var n := int(_arg("n", "20000"))
	var names := ["Hips", "Spine", "Chest", "Head", "LeftUpperArm", "RightUpperArm"]
	var t0 := Time.get_ticks_usec()
	for i in n:
		sb.vmcall("vmc_feed", _pose(names[i % names.size()], float(i)))
		if i % (n / 4) == 0:
			print("i=", i, " ", sb.vmcall("vmc_stats"), " bones=", String(sb.vmcall("vmc_bones")).count("\n"))
	var us := Time.get_ticks_usec() - t0
	print("feeds=", n, " us_per_feed=", us / n, " ", sb.vmcall("vmc_stats"))
	var rows: PackedFloat32Array = sb.vmcall("vmc_bone_rows")
	print("rows=", rows.size(), " last x of Hips=", rows[0], " expect=", float(n - 6 + 0 if (n - 1) % 6 != 0 else n - 1))
	quit(0)
	return true
