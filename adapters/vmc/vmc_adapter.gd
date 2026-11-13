class_name VmcAdapter
extends Node
## VMC capture adapter. Named by wire format. Writes Godot trackers.
##
## The host owns the UDP socket: a guest cannot bind one. Each datagram goes to vmc.elf
## (guest/vmc, a port of DigitOtter/godot-vmc-lib, MIT), which decodes the OSC/VMC bytes and
## holds the poses. This node reads them back once per tick and writes the trackers.

const DEFAULT_PORT := 39539  # VMC convention
const FORBIDDEN_PORT := 9000  # VRChat holds this on the Steam Frame

@export var port: int = DEFAULT_PORT
@export var elf_path := "res://vmc.elf"

var body_tracker := XRBodyTracker.new()

var _udp := PacketPeerUDP.new()
var _sb: Object
var _listening := false


func start() -> Error:
	if port == FORBIDDEN_PORT:
		push_error("VmcAdapter: refusing UDP %d (held by VRChat on the Steam Frame)" % port)
		return ERR_INVALID_PARAMETER
	if not ClassDB.class_exists("Sandbox"):
		push_error("VmcAdapter: the Sandbox class is not registered (godot-sandbox add-on missing)")
		return ERR_UNCONFIGURED
	_sb = ClassDB.instantiate("Sandbox")
	_sb.set("allocations_max", 1000000)
	_sb.set("references_max", 4096)
	_sb.set("memory_max", 64)
	_sb.load_buffer(FileAccess.get_file_as_bytes(elf_path))
	if not _sb.has_function("vmc_feed"):
		push_error("VmcAdapter: %s has no vmc_feed (wrong ELF, or a Variant-size mismatch)" % elf_path)
		return ERR_FILE_CORRUPT
	var err := _udp.bind(port)
	if err != OK:
		push_error("VmcAdapter: cannot bind UDP %d: %s" % [port, error_string(err)])
		return err
	_listening = true
	return OK


func _process(_delta: float) -> void:
	if not _listening:
		return
	while _udp.get_available_packet_count() > 0:
		_sb.vmcall("vmc_feed", _udp.get_packet())
	# TODO: map vmc_bone_rows / vmc_tracker_rows onto body_tracker and register it with
	#       XRServer.add_body_tracker(). Names come from vmc_bones / vmc_trackers, same order.
	# TODO: mm.elf query - tracker poses are the matching features.
	# TODO: mjc_inverse call on the mujoco.elf guest at the 64 Hz (15.625 ms) tick.


func stop() -> void:
	_udp.close()
	_listening = false
