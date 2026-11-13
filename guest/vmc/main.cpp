// vmc.elf: VMC/OSC decoding in a godot-sandbox guest. The decoder is src/vmc_decode.hpp, a port of
// DigitOtter/godot-vmc-lib (MIT). A guest cannot bind a socket or start a thread, so the host owns
// the UDP socket (PacketPeerUDP on the VMC port, never 9000) and calls vmc_feed with each datagram.
//
//   vmc_clear()                 -> "CLEARED"
//   vmc_feed(bytes)             -> 1 if the datagram was well formed, else 0 (it is counted in vmc_stats)
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
#include <api.hpp>
#include "vmc_decode.hpp"
#include <cstdio>
#include <string>
#include <vector>

static vmc::Decoder g_dec;

static Variant text(const std::string &s) {
	return Variant(String(s));
}

static Variant vmc_clear() {
	g_dec.clear();
	return text("CLEARED");
}

static Variant vmc_feed(PackedArray<uint8_t> bytes) {
	const std::vector<uint8_t> b = bytes.fetch();
	return Variant(int64_t(g_dec.feed(b.data(), b.size()) ? 1 : 0));
}

static Variant vmc_stats() {
	char line[96];
	std::snprintf(line, sizeof(line), "messages %u vmc %u unknown %u bad %u", g_dec.stats.messages, g_dec.stats.vmc,
			g_dec.stats.unknown, g_dec.stats.bad);
	return text(line);
}

static Variant vmc_time() {
	return Variant(double(g_dec.time));
}

static std::string names_of(const std::map<std::string, vmc::Pose> &m) {
	std::string out;
	for (const auto &kv : m) out += kv.first + "\n";
	return out;
}

static PackedArray<float> rows_of(const std::map<std::string, vmc::Pose> &m) {
	std::vector<float> out;
	out.reserve(m.size() * 7);
	for (const auto &kv : m) {
		out.insert(out.end(), kv.second.p, kv.second.p + 3);
		out.insert(out.end(), kv.second.q, kv.second.q + 4);
	}
	return PackedArray<float>(out);
}

static Variant vmc_bones() { return text(names_of(g_dec.bones)); }
static Variant vmc_roots() { return text(names_of(g_dec.roots)); }
static Variant vmc_trackers() { return text(names_of(g_dec.trackers)); }
static Variant vmc_bone_rows() { return Variant(rows_of(g_dec.bones)); }
static Variant vmc_root_rows() { return Variant(rows_of(g_dec.roots)); }
static Variant vmc_tracker_rows() { return Variant(rows_of(g_dec.trackers)); }

static Variant vmc_blend() {
	std::string out;
	char num[48];
	for (const auto &kv : g_dec.blend) {
		std::snprintf(num, sizeof(num), " %.9g\n", double(kv.second));
		out += kv.first + num;
	}
	return text(out);
}

static Variant vmc_camera() {
	const std::vector<float> v = { g_dec.cam.p[0], g_dec.cam.p[1], g_dec.cam.p[2], g_dec.cam.q[0], g_dec.cam.q[1],
		g_dec.cam.q[2], g_dec.cam.q[3], g_dec.cam_fov };
	return Variant(PackedArray<float>(v));
}

static Variant vmc_unknown() {
	std::string out;
	for (const auto &kv : g_dec.unknown_addresses) out += kv.first + " " + std::to_string(kv.second) + "\n";
	return text(out);
}

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
