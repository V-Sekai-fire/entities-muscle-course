// vmc.elf: VMC/OSC decoding in a godot-sandbox guest. The decoder is Vmc/Decode.lean, a port of
// DigitOtter/godot-vmc-lib (MIT) written in Lean; this file is only the sandbox surface. A guest
// cannot bind a socket or start a thread, so the host owns the UDP socket (PacketPeerUDP on the VMC
// port, never 9000) and calls vmc_feed with each datagram.
//
//   vmc_clear()                 -> "CLEARED"
//   vmc_feed(bytes)             -> 1 if the datagram was well formed, else 0 (counted in vmc_stats)
//   vmc_stats()                 -> "messages M vmc V unknown U bad B"
//   vmc_time()                  -> last /VMC/Ext/T
//   vmc_bones() / vmc_roots() / vmc_trackers()
//                               -> names, one per line, in sorted order
//   vmc_bone_rows() / vmc_root_rows() / vmc_tracker_rows()
//                               -> 7 floats per name, same order: px py pz qx qy qz qw
//   vmc_blend()                 -> "name value" per line (applied shapes only)
//   vmc_camera()                -> px py pz qx qy qz qw fov
//   vmc_unknown()               -> "address count" per line
// Tracker names are "hmd:<serial>", "con:<serial>", "tra:<serial>".
//
// Ownership: every Lean export takes its arguments owned. g_state is the one live reference, so
// feed hands it over and stores the result; every query takes a lean_inc first.
#include <api.hpp>
#include <lean/lean.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

extern "C" {
lean_object *initialize_vmc_Vmc_Decode(uint8_t builtin);
lean_object *vmc_new(lean_object *unit);
lean_object *vmc_feed_bytes(lean_object *state, lean_object *bytes);
uint8_t vmc_last_ok(lean_object *state);
lean_object *vmc_stats_text(lean_object *state);
double vmc_time_value(lean_object *state);
lean_object *vmc_bones_text(lean_object *state);
lean_object *vmc_roots_text(lean_object *state);
lean_object *vmc_trackers_text(lean_object *state);
lean_object *vmc_bone_floats(lean_object *state);
lean_object *vmc_root_floats(lean_object *state);
lean_object *vmc_tracker_floats(lean_object *state);
lean_object *vmc_blend_names(lean_object *state);
lean_object *vmc_blend_floats(lean_object *state);
lean_object *vmc_camera_floats(lean_object *state);
lean_object *vmc_unknown_text(lean_object *state);
}

static lean_object *g_state = nullptr;
static bool g_ready = false;

// Lean's runtime and Init are initialised once, on first use. `main` only registers the surface.
static bool ready() {
	if (g_ready) return true;
	lean_object *res = initialize_vmc_Vmc_Decode(1);
	if (!lean_io_result_is_ok(res)) return false;
	lean_dec_ref(res);
	lean_io_mark_end_initialization();
	g_state = vmc_new(lean_box(0));
	g_ready = true;
	return true;
}

static Variant text(const std::string &s) {
	return Variant(String(s));
}

static std::string take_string(lean_object *o) {
	std::string s(lean_string_cstr(o), lean_string_size(o) - 1);
	lean_dec(o);
	return s;
}

static std::vector<float> take_floats(lean_object *o) {
	const size_t n = lean_sarray_size(o);
	const double *d = lean_float_array_cptr(o);
	std::vector<float> out(n);
	for (size_t i = 0; i < n; i++) out[i] = float(d[i]);
	lean_dec(o);
	return out;
}

#define STATE (lean_inc(g_state), g_state)

static Variant vmc_clear() {
	if (!ready()) return text("LEAN INIT FAILED");
	lean_dec(g_state);
	g_state = vmc_new(lean_box(0));
	return text("CLEARED");
}

static Variant vmc_feed(PackedArray<uint8_t> bytes) {
	if (!ready()) return Variant(int64_t(0));
	const std::vector<uint8_t> b = bytes.fetch();
	lean_object *arr = lean_alloc_sarray(1, b.size(), b.size());
	if (!b.empty()) std::memcpy(lean_sarray_cptr(arr), b.data(), b.size());
	g_state = vmc_feed_bytes(g_state, arr);
	return Variant(int64_t(vmc_last_ok(STATE) ? 1 : 0));
}

static Variant vmc_stats() {
	if (!ready()) return text("LEAN INIT FAILED");
	return text(take_string(vmc_stats_text(STATE)));
}

static Variant vmc_time() {
	if (!ready()) return Variant(0.0);
	return Variant(vmc_time_value(STATE));
}

static Variant vmc_bones() { return ready() ? text(take_string(vmc_bones_text(STATE))) : text(""); }
static Variant vmc_roots() { return ready() ? text(take_string(vmc_roots_text(STATE))) : text(""); }
static Variant vmc_trackers() { return ready() ? text(take_string(vmc_trackers_text(STATE))) : text(""); }
static Variant vmc_bone_rows() { return Variant(PackedArray<float>(ready() ? take_floats(vmc_bone_floats(STATE)) : std::vector<float>())); }
static Variant vmc_root_rows() { return Variant(PackedArray<float>(ready() ? take_floats(vmc_root_floats(STATE)) : std::vector<float>())); }
static Variant vmc_tracker_rows() { return Variant(PackedArray<float>(ready() ? take_floats(vmc_tracker_floats(STATE)) : std::vector<float>())); }

static Variant vmc_blend() {
	if (!ready()) return text("");
	const std::string names = take_string(vmc_blend_names(STATE));
	const std::vector<float> vals = take_floats(vmc_blend_floats(STATE));
	std::string out;
	char num[48];
	size_t at = 0, k = 0;
	while (at < names.size() && k < vals.size()) {
		const size_t e = names.find('\n', at);
		if (e == std::string::npos) break;
		std::snprintf(num, sizeof(num), " %.9g\n", double(vals[k++]));
		out += names.substr(at, e - at) + num;
		at = e + 1;
	}
	return text(out);
}

static Variant vmc_camera() {
	return Variant(PackedArray<float>(ready() ? take_floats(vmc_camera_floats(STATE)) : std::vector<float>()));
}

static Variant vmc_unknown() { return ready() ? text(take_string(vmc_unknown_text(STATE))) : text(""); }

int main() {
	ADD_API_FUNCTION(vmc_clear, "String", "", "Forget all decoded state");
	ADD_API_FUNCTION(vmc_feed, "int", "PackedByteArray bytes", "Decode one UDP datagram; 1 if well formed");
	ADD_API_FUNCTION(vmc_stats, "String", "", "messages vmc unknown bad");
	ADD_API_FUNCTION(vmc_time, "float", "", "Last /VMC/Ext/T");
	ADD_API_FUNCTION(vmc_bones, "String", "", "Bone names, one per line");
	ADD_API_FUNCTION(vmc_bone_rows, "PackedFloat32Array", "", "px py pz qx qy qz qw per bone");
	ADD_API_FUNCTION(vmc_roots, "String", "", "Root names, one per line");
	ADD_API_FUNCTION(vmc_root_rows, "PackedFloat32Array", "", "px py pz qx qy qz qw per root");
	ADD_API_FUNCTION(vmc_trackers, "String", "", "hmd:/con:/tra: names, one per line");
	ADD_API_FUNCTION(vmc_tracker_rows, "PackedFloat32Array", "", "px py pz qx qy qz qw per tracker");
	ADD_API_FUNCTION(vmc_blend, "String", "", "Applied blend shapes: name value");
	ADD_API_FUNCTION(vmc_camera, "PackedFloat32Array", "", "px py pz qx qy qz qw fov");
	ADD_API_FUNCTION(vmc_unknown, "String", "", "Unrecognised OSC addresses: address count");
	halt();
}
