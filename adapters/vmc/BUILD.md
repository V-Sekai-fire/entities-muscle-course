# VMC adapter

`vmc.elf` is a godot-sandbox guest built from `guest/vmc/main.cpp`. Its decoder is
`src/vmc_decode.hpp`, a port of DigitOtter/godot-vmc-lib (MIT, upstream master 0c1adf8, kept
under `godot-vmc-lib/` for reference).

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
- A bundle is applied element by element. A truncated bundle keeps the elements that came
  before the bad one and is reported as malformed.
- Not ported: oscpack, `other_data` argument values (only the address and a count are kept),
  and the `/VMC/Ext/OK`, `Con`, `Key`, `Midi`, `Light`, `Remote` messages.

## Build and check

    PATH=<sysroot>/.pixi/envs/default/bin:$PATH elixir tools/build.exs   # vmc.elf
    c++ -std=c++20 -Isrc tests/vmc_decode_test.cpp && ./a.out            # decoder, native
    ./a.out --control                                                    # must exit 1

The engine run (`tests/engine/run_vmc.gd`, `RESULT: PASS`, and `--control` must give
`RESULT: FAIL`) needs the double editor and the godot-sandbox add-on library from
service-godot-build, in a scratch project.

## Open

- The tracker mapping onto `XRBodyTracker` and the `mm.elf` query are TODOs.
- New guest code is meant to be Lean 4. This one is C++ because it ports C++.
