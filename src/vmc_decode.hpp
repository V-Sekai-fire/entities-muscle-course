// VMC / OSC decoder. A port of DigitOtter/godot-vmc-lib (MIT) vmc_receiver.cpp's message handling,
// with the oscpack and UDP-thread parts replaced: a guest cannot bind a socket, so the host reads
// UDP and hands each datagram to feed(). No Godot, no sandbox, no I/O: native tests include it.
//
// Differences from upstream, on purpose:
//  - every read is bounds-checked and a bad packet is counted, never asserted (upstream asserts
//    argument counts, which are compiled out in release and then read past the end);
//  - /VMC/Ext/{Hmd,Con,Tra}/Pos are decoded into trackers (upstream leaves them in other_data);
//    they are the tracker poses the mm.elf query takes as features.
#pragma once
#include <cmath>
#include <cstdint>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace vmc {

struct Pose {
	float p[3] = { 0, 0, 0 };
	float q[4] = { 0, 0, 0, 1 }; // x y z w
};

struct Arg {
	char tag = 0;
	int64_t i = 0;
	double f = 0;
	std::string s;
};

struct Stats {
	uint32_t messages = 0, vmc = 0, unknown = 0, bad = 0;
};

class Decoder {
public:
	float time = 0;
	std::map<std::string, Pose> bones, roots, trackers; // trackers keyed "hmd:<serial>", "con:..", "tra:.."
	std::map<std::string, float> blend, pending;
	Pose cam;
	float cam_fov = 0;
	std::map<std::string, uint32_t> unknown_addresses;
	Stats stats;

	void clear() { *this = Decoder(); }

	// One UDP datagram: a message or a (nested) bundle. Returns false if it was malformed.
	bool feed(const uint8_t *d, size_t n) { return packet(d, n, 0); }

private:
	static uint32_t be32(const uint8_t *p) {
		return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | uint32_t(p[3]);
	}
	static uint64_t be64(const uint8_t *p) { return (uint64_t(be32(p)) << 32) | be32(p + 4); }
	static size_t pad4(size_t n) { return (n + 4) & ~size_t(3); } // string incl. NUL, rounded up

	// A NUL-terminated string padded to 4 bytes. Advances `at`.
	static bool str(const uint8_t *d, size_t n, size_t &at, std::string &out) {
		size_t e = at;
		while (e < n && d[e] != 0) e++;
		if (e >= n) return false;
		const size_t next = at + pad4(e - at);
		if (next > n) return false;
		out.assign(reinterpret_cast<const char *>(d + at), e - at);
		at = next;
		return true;
	}

	bool packet(const uint8_t *d, size_t n, int depth) {
		if (n == 0 || depth > 8) { stats.bad++; return false; }
		if (n >= 8 && std::memcmp(d, "#bundle\0", 8) == 0) {
			if (n < 16) { stats.bad++; return false; }
			size_t at = 16; // skip the 8-byte time tag
			bool ok = true;
			while (at < n) {
				if (at + 4 > n) { stats.bad++; return false; }
				const size_t len = be32(d + at);
				at += 4;
				if (len > n - at) { stats.bad++; return false; }
				ok = packet(d + at, len, depth + 1) && ok;
				at += len;
			}
			return ok;
		}
		return message(d, n);
	}

	bool message(const uint8_t *d, size_t n) {
		size_t at = 0;
		std::string addr, tags;
		if (!str(d, n, at, addr) || addr.empty() || addr[0] != '/') { stats.bad++; return false; }
		if (at >= n) { tags = ","; } else if (!str(d, n, at, tags) || tags.empty() || tags[0] != ',') { stats.bad++; return false; }
		std::vector<Arg> args;
		for (size_t k = 1; k < tags.size(); k++) {
			Arg a;
			a.tag = tags[k];
			switch (a.tag) {
				case 'i': case 'c':
					if (at + 4 > n) { stats.bad++; return false; }
					a.i = int32_t(be32(d + at));
					a.f = double(a.i);
					at += 4;
					break;
				case 'f': {
					if (at + 4 > n) { stats.bad++; return false; }
					const uint32_t u = be32(d + at);
					float f;
					std::memcpy(&f, &u, 4);
					a.f = f;
					at += 4;
				} break;
				case 'h':
					if (at + 8 > n) { stats.bad++; return false; }
					a.i = int64_t(be64(d + at));
					a.f = double(a.i);
					at += 8;
					break;
				case 'd': {
					if (at + 8 > n) { stats.bad++; return false; }
					const uint64_t u = be64(d + at);
					std::memcpy(&a.f, &u, 8);
					at += 8;
				} break;
				case 's': case 'S':
					if (!str(d, n, at, a.s)) { stats.bad++; return false; }
					break;
				case 'T': a.i = 1; break;
				case 'F': case 'N': case 'I': break;
				case 'b': { // blob: int32 size, bytes, padded to 4
					if (at + 4 > n) { stats.bad++; return false; }
					const size_t len = be32(d + at);
					at += 4;
					const size_t padded = (len + 3) & ~size_t(3);
					if (len > n - at || padded > n - at) { stats.bad++; return false; }
					at += padded;
				} break;
				default: stats.bad++; return false; // unknown type tag: the rest cannot be framed
			}
			args.push_back(std::move(a));
		}
		stats.messages++;
		dispatch(addr, args);
		return true;
	}

	static bool nums(const std::vector<Arg> &a, size_t from, size_t count) {
		if (a.size() < from + count) return false;
		for (size_t i = from; i < from + count; i++)
			if (a[i].tag != 'f' && a[i].tag != 'i' && a[i].tag != 'd') return false;
		return true;
	}
	static bool is_str(const Arg &a) { return a.tag == 's' || a.tag == 'S'; }
	static Pose pose(const std::vector<Arg> &a, size_t from) {
		Pose r;
		for (int i = 0; i < 3; i++) r.p[i] = float(a[from + i].f);
		for (int i = 0; i < 4; i++) r.q[i] = float(a[from + 3 + i].f);
		return r;
	}

	void dispatch(const std::string &addr, const std::vector<Arg> &a) {
		auto bad = [&] { stats.bad++; };
		stats.vmc++;
		if (addr == "/VMC/Ext/T") {
			if (!nums(a, 0, 1)) return bad();
			time = float(a[0].f);
		} else if (addr == "/VMC/Ext/Blend/Val") {
			if (a.size() < 2 || !is_str(a[0]) || !nums(a, 1, 1)) return bad();
			pending[a[0].s] = float(a[1].f);
		} else if (addr == "/VMC/Ext/Blend/Apply") {
			blend = pending; // upstream copies key by key; same result
			pending.clear();
		} else if (addr == "/VMC/Ext/Bone/Pos") {
			if (a.empty() || !is_str(a[0]) || !nums(a, 1, 7)) return bad();
			bones[a[0].s] = pose(a, 1);
		} else if (addr == "/VMC/Ext/Root/Pos") {
			if (a.empty() || !is_str(a[0]) || !nums(a, 1, 7)) return bad();
			roots[a[0].s] = pose(a, 1);
		} else if (addr == "/VMC/Ext/Cam") {
			if (!nums(a, 1, 7)) return bad(); // arg 0 is the camera name; upstream skips it too
			cam = pose(a, 1);
			cam_fov = nums(a, 8, 1) ? float(a[8].f) : 0;
		} else if (addr == "/VMC/Ext/Hmd/Pos" || addr == "/VMC/Ext/Con/Pos" || addr == "/VMC/Ext/Tra/Pos") {
			if (a.empty() || !is_str(a[0]) || !nums(a, 1, 7)) return bad();
			const char *kind = addr[9] == 'H' ? "hmd:" : addr[9] == 'C' ? "con:" : "tra:";
			trackers[kind + a[0].s] = pose(a, 1);
		} else {
			stats.vmc--;
			stats.unknown++;
			unknown_addresses[addr]++;
		}
	}
};

} // namespace vmc
