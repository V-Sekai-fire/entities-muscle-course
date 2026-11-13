# VMC adapter

`vmc.elf` is a godot-sandbox guest. The decoder is `Vmc/Decode.lean`, a port of
DigitOtter/godot-vmc-lib (MIT, upstream master 0c1adf8, kept under `godot-vmc-lib/` for
reference). `guest/vmc/main.cpp` is only the sandbox surface: it holds one Lean state object and
calls the decoder's `@[export]` functions.

## Why the port is split

A guest cannot bind a socket or start a thread. Upstream's `VmcReceiver` is a Godot Node that
runs oscpack's `UdpSocket` on a worker thread. So:

- The host owns the UDP socket (`vmc_adapter.gd`, `PacketPeerUDP`) and passes each datagram to
  `vmc_feed`.
- The guest decodes OSC messages and bundles, and holds the bone, root, tracker, blend-shape and
  camera state. The host reads it back with `vmc_*_rows` once per tick.

Upstream's C++ GDExtension is not built or used, so its `godot-cpp` 4.1 pin and the dropped
submodule links (`godot-cpp`, `oscpack`) no longer matter.

## What differs from upstream

- Every read is bounds-checked and a bad packet is counted in `vmc_stats`. Upstream uses
  `assert` on argument counts, which is compiled out in release builds.
- `/VMC/Ext/{Hmd,Con,Tra}/Pos` are decoded into trackers (`hmd:`, `con:`, `tra:` plus the
  serial). Upstream leaves them in `other_data`. They are the tracker poses the `mm.elf`
  query takes as features.
- A string that is not UTF-8 makes its message bad. Upstream passes the bytes through. The
  witness pins this.
- A bundle is applied element by element. A truncated bundle keeps the elements that came
  before the bad one and is reported as malformed.
- Not ported: oscpack, `other_data` argument values (only the address and a count are kept),
  and the `/VMC/Ext/OK`, `Con`, `Key`, `Midi`, `Light`, `Remote` messages.

## Build and check

Decoder, native, on any machine with the pinned Lean (`lean-toolchain`, v4.34.1):

    lake build vmc_witness && .lake/build/bin/vmc_witness   # RESULT: PASS
    .lake/build/bin/vmc_witness --control                   # must exit 1

Guest ELF:

    PATH=<sysroot>/.pixi/envs/default/bin:$PATH ELAN_TOOLCHAIN=leanprover/lean4:v4.34.1 \
      elixir tools/build.exs

It links a riscv64 Lean core (`LEAN_CORE`, default `~/.cache/lean-guest/v4.34.1`). That cached
core was built before `interactor-lean-guest`'s `runtime-guest.patch` and opens `/dev/urandom`,
which a sandbox does not have, so Lean's init fails. Until the core is rebuilt from
`interactor-lean-guest`, apply the patch's `io.cpp` hunk to the runtime's `io.cpp` and pass it:

    VMC_CMAKE_ARGS="-DLEAN_IO_PATCHED=/path/to/patched/io.cpp" elixir tools/build.exs

That is a desk build. It is not the shippable artifact (see Open).

Engine runs (`tests/engine/`) need the double editor and the godot-sandbox add-on library from
service-godot-build, in a scratch project:

- `run_vmc.gd`: `RESULT: PASS`; with `--control` it must give `RESULT: FAIL`.
- `soak_vmc.gd`: many feeds on one Sandbox; counters and bone count stay flat.
- `diff_vmc.gd`: the same valid, truncated and byte-flipped datagrams into two ELFs, comparing
  every output. It was run against the C++ decoder from PR #1 (commit dd6c907): 0 diffs in
  6,000 datagrams when byte flips stay ASCII. Non-UTF-8 flips differ on purpose.

## Open

- No CI workflow and no translated-vs-interpreted check yet, so no shippable ELF.
- The tracker mapping onto `XRBodyTracker` and the `mm.elf` query are TODOs.
- Speed: about 29 us per one-message datagram in the engine, against 6 us for the C++ decoder.
  That is the interpreter, not binary translation, and it is one message, not a full frame.
