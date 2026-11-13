class_name VmcAdapter
extends Node
## VMC capture adapter. Named by wire format. Writes Godot trackers.
## The receiver is DigitOtter/godot-vmc-lib (MIT), vendored by subtree under
## adapters/vmc/godot-vmc-lib. It is a C++ GDExtension and needs a native
## build per platform (Mac, linux-arm64) before this node can listen.

const DEFAULT_PORT := 39539 # VMC convention
const FORBIDDEN_PORT := 9000 # VRChat holds this on the Steam Frame

@export var port: int = DEFAULT_PORT

var body_tracker := XRBodyTracker.new()


func start() -> Error:
	if port == FORBIDDEN_PORT:
		push_error("VmcAdapter: refusing UDP %d (held by VRChat on the Steam Frame)" % port)
		return ERR_INVALID_PARAMETER
	# TODO: build godot-vmc-lib and bind its receiver to `port`.
	# TODO: map received bone transforms onto body_tracker and register it
	#       with XRServer.add_body_tracker().
	return ERR_UNCONFIGURED


# TODO: mm.elf query - tracker poses are the matching features.
# TODO: mjc_inverse call on the mujoco.elf guest at the 64 Hz (15.625 ms) tick.
