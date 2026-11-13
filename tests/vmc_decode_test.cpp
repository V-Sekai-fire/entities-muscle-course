// Native test for src/vmc_decode.hpp. Build: c++ -std=c++20 -Isrc tests/vmc_decode_test.cpp
// `--control` plants a wrong expectation and must exit non-zero.
#include "vmc_decode.hpp"
#include <cstdio>
#include <cstdlib>
#include <string>

using Bytes = std::vector<uint8_t>;
static void put32(Bytes &b, uint32_t u) { for (int s = 24; s >= 0; s -= 8) b.push_back(uint8_t(u >> s)); }
static void pstr(Bytes &b, const std::string &s) {
	for (char c : s) b.push_back(uint8_t(c));
	b.push_back(0);
	while (b.size() % 4) b.push_back(0);
}
// Message with args given as a tag string and values; 'f' takes a float, 's' a string, 'i' an int.
struct Msg {
	Bytes b;
	std::string tags = ",";
	Bytes body;
	explicit Msg(const std::string &addr) { pstr(b, addr); }
	Msg &f(float v) { tags += 'f'; uint32_t u; std::memcpy(&u, &v, 4); put32(body, u); return *this; }
	Msg &i(int32_t v) { tags += 'i'; put32(body, uint32_t(v)); return *this; }
	Msg &s(const std::string &v) { tags += 's'; pstr(body, v); return *this; }
	Bytes done() const { Bytes o = b; pstr(o, tags); o.insert(o.end(), body.begin(), body.end()); return o; }
};
static Bytes bundle(const std::vector<Bytes> &els) {
	Bytes o;
	pstr(o, "#bundle");
	for (int k = 0; k < 8; k++) o.push_back(k == 7 ? 1 : 0); // time tag: immediately
	for (auto &e : els) { put32(o, uint32_t(e.size())); o.insert(o.end(), e.begin(), e.end()); }
	return o;
}

static int fails = 0;
#define CHECK(c) do { if (!(c)) { std::printf("FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

int main(int argc, char **argv) {
	const bool control = argc > 1 && std::string(argv[1]) == "--control";
	{ // wire format: /VMC/Ext/T with 0.5 is 2f 56 4d 43 ... ,f 00 00 3f 00 00 00 (hand-computed)
		const Bytes t = Msg("/VMC/Ext/T").f(0.5f).done();
		const Bytes want = { '/','V','M','C','/','E','x','t','/','T',0,0, ',','f',0,0, 0x3f,0,0,0 };
		CHECK(t == want);
		vmc::Decoder d;
		CHECK(d.feed(t.data(), t.size()));
		CHECK(d.time == (control ? 0.75f : 0.5f));
	}
	{ // a bundle of bone, root, blend and apply
		vmc::Decoder d;
		const Bytes pk = bundle({
			Msg("/VMC/Ext/Root/Pos").s("root").f(1).f(2).f(3).f(0).f(0).f(0).f(1).done(),
			Msg("/VMC/Ext/Bone/Pos").s("Hips").f(0.1f).f(0.2f).f(0.3f).f(0.5f).f(0.5f).f(0.5f).f(0.5f).done(),
			Msg("/VMC/Ext/Bone/Pos").s("Head").f(0).f(1.6f).f(0).f(0).f(0).f(0).f(1).done(),
			Msg("/VMC/Ext/Blend/Val").s("Joy").f(0.25f).done(),
			Msg("/VMC/Ext/T").f(12.5f).done(),
		});
		CHECK(d.feed(pk.data(), pk.size()));
		CHECK(d.bones.size() == 2);
		CHECK(d.bones["Hips"].p[1] == 0.2f && d.bones["Hips"].q[3] == 0.5f);
		CHECK(d.roots["root"].p[2] == 3.0f);
		CHECK(d.blend.empty() && d.pending["Joy"] == 0.25f); // not applied yet
		const Bytes ap = Msg("/VMC/Ext/Blend/Apply").done();
		CHECK(d.feed(ap.data(), ap.size()));
		CHECK(d.blend["Joy"] == 0.25f && d.pending.empty());
		CHECK(d.time == 12.5f);
		CHECK(d.stats.bad == 0 && d.stats.messages == 6);
	}
	{ // trackers and camera with fov
		vmc::Decoder d;
		const Bytes a = Msg("/VMC/Ext/Hmd/Pos").s("HMD").f(0).f(1.7f).f(0).f(0).f(0).f(0).f(1).done();
		const Bytes b = Msg("/VMC/Ext/Tra/Pos").s("LHAND").f(-0.3f).f(1.2f).f(0.1f).f(0).f(0).f(0).f(1).done();
		const Bytes c = Msg("/VMC/Ext/Cam").s("Camera").f(0).f(1).f(2).f(0).f(0).f(0).f(1).f(40).done();
		CHECK(d.feed(a.data(), a.size()) && d.feed(b.data(), b.size()) && d.feed(c.data(), c.size()));
		CHECK(d.trackers["hmd:HMD"].p[1] == 1.7f);
		CHECK(d.trackers["tra:LHAND"].p[0] == -0.3f);
		CHECK(d.cam.p[2] == 2.0f && d.cam_fov == 40.0f);
	}
	{ // unknown address is kept by name, not an error
		vmc::Decoder d;
		const Bytes u = Msg("/VMC/Ext/Midi/Note").i(1).i(0).i(60).f(0.5f).done();
		CHECK(d.feed(u.data(), u.size()));
		CHECK(d.stats.unknown == 1 && d.unknown_addresses["/VMC/Ext/Midi/Note"] == 1);
	}
	{ // malformed input must be rejected and counted, never read past the end
		vmc::Decoder d;
		Bytes ok = Msg("/VMC/Ext/Bone/Pos").s("Hips").f(0).f(0).f(0).f(0).f(0).f(0).f(1).done();
		for (size_t cut = 1; cut < ok.size(); cut++) { // every truncation
			vmc::Decoder e;
			const bool r = e.feed(ok.data(), cut);
			CHECK(!r || e.bones.empty() || cut == ok.size());
			CHECK(e.bones.empty());
		}
		const Bytes shortArgs = Msg("/VMC/Ext/Bone/Pos").s("Hips").f(0).f(0).done();
		CHECK(d.feed(shortArgs.data(), shortArgs.size()) && d.bones.empty() && d.stats.bad == 1);
		const Bytes wrongType = Msg("/VMC/Ext/Bone/Pos").f(1).f(0).f(0).f(0).f(0).f(0).f(0).f(1).done();
		d.feed(wrongType.data(), wrongType.size());
		CHECK(d.bones.empty() && d.stats.bad == 2);
		Bytes bundleBadLen = bundle({ Msg("/VMC/Ext/T").f(1).done() });
		bundleBadLen[16 + 3] = 0xff; // element length larger than the packet
		CHECK(!d.feed(bundleBadLen.data(), bundleBadLen.size()));
		Bytes junk = { 'x', 'y', 'z' };
		CHECK(!d.feed(junk.data(), junk.size()));
		CHECK(!d.feed(junk.data(), 0));
		Bytes deep = bundle({ Msg("/VMC/Ext/T").f(1).done() });
		for (int k = 0; k < 20; k++) deep = bundle({ deep }); // deeper than the nesting cap
		CHECK(!d.feed(deep.data(), deep.size()));
	}
	std::printf(fails ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", fails);
	return fails ? 1 : 0;
}
