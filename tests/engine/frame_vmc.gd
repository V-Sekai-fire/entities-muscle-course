# godot --headless --path . --script frame_vmc.gd ++ --elf=vmc.elf [--n=2000]
# One VMC frame as a sender emits it: a bundle of 55 bone poses, a root, 5 trackers and /T. Times feed
# plus reading bone_rows and tracker_rows back, which is what the adapter does each tick.
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

func _process(_d: float) -> bool:
	var sb = ClassDB.instantiate("Sandbox")
	sb.set("allocations_max", 1000000)
	sb.set("references_max", 4096)
	sb.set("memory_max", 64)
	sb.set("execution_timeout", 600000)
	sb.load_buffer(FileAccess.get_file_as_bytes(_arg("elf", "")))
	var els: Array = []
	for i in 55:
		els.append(_msg("/VMC/Ext/Bone/Pos", "Bone%02d" % i, [0.1 * i, 0.2, 0.3, 0.0, 0.0, 0.0, 1.0]))
	els.append(_msg("/VMC/Ext/Root/Pos", "root", [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0]))
	for i in 5:
		els.append(_msg("/VMC/Ext/Tra/Pos", "T%d" % i, [0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]))
	els.append(_msg("/VMC/Ext/T", "", [1.0]))
	var o := PackedByteArray()
	_pstr(o, "#bundle")
	for k in 8:
		o.append(1 if k == 7 else 0)
	for e in els:
		var sz: int = e.size()
		o.append_array(PackedByteArray([(sz >> 24) & 255, (sz >> 16) & 255, (sz >> 8) & 255, sz & 255]))
		o.append_array(e)
	print("datagram bytes=", o.size(), " messages=", els.size())
	var n := int(_arg("n", "2000"))
	var feed_us := 0
	var read_us := 0
	var worst := 0
	for i in n:
		var t0 := Time.get_ticks_usec()
		sb.vmcall("vmc_feed", o)
		var t1 := Time.get_ticks_usec()
		sb.vmcall("vmc_bone_rows")
		sb.vmcall("vmc_tracker_rows")
		var t2 := Time.get_ticks_usec()
		feed_us += t1 - t0
		read_us += t2 - t1
		worst = max(worst, t2 - t0)
	print("frames=", n, " feed_us=", feed_us / n, " readback_us=", read_us / n, " worst_total_us=", worst, " ", sb.vmcall("vmc_stats"))
	quit(0)
	return true
