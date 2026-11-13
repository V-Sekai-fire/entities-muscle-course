# entities-obstacle-course

Twin of the model explorer. It keeps the skinned-avatar walk and gives it the
MS-Human-700 muscle skeleton too.

## Design (from the operator's decisions, 2026-11-12)

- The motion-matching picker (`mm.elf`) picks a clip each frame from the
  player's input. MS-Human-700 runs inverse dynamics underneath on that motion,
  and the skinned avatar's bones follow its pose each tick.
- MS-Human-700 runs inside the `mujoco.elf` godot-sandbox guest through a new
  `mjc_inverse` call, timed against the 15.625 ms (64 Hz) tick.
- Live capture drives the `mm.elf` query: tracker poses are the matching
  features. Adapters are named by wire format and write Godot
  `XRBodyTracker` / `XRPositionalTracker`. The first adapter speaks VMC
  (`adapters/vmc/`). Adapters must not bind UDP 9000, which VRChat holds on the
  Steam Frame.
- Platforms: Mac desktop first, then a Steam Frame linux-arm64 export.
- `Motion.gd`, `Bintr.gd` and `CardStyle.gd` stay in model-explorer until the
  shared repo exists. Do not copy them here.

## Status

Scaffold only. Nothing here runs the course yet.

## Licence

MIT or Apache-2.0, at your option.
