# The avatar follows the muscle skeleton

`follow.sgd` is a SafeGDScript guest. It turns the body placements of the muscle skeleton
(MS-Human-700 in the MuJoCo sandbox guest) into bone poses for the skinned avatar (ANNY, 104 bones).
The mapping is data plus arithmetic: the host hands over the tables once, and then one array of
body placements per pose.

## Frames

The muscle skeleton is in MuJoCo's axes: Z up, the body faces +X, its left is +Y. The avatar is in
the engine's axes: Y up, faces +Z, left is +X. A MuJoCo vector (x, y, z) is the engine's (y, z, x).
A MuJoCo quaternion (w; x, y, z) is the engine's (w; y, z, x). In `follow.sgd` only `_at` and
`_turn` know this. In the test apparatus only `Rig.origin` does.

The reference is in ANNY's own frame, Z up. A reference vector (x, y, z) is (x, z, -y) in the
engine. The gate's `_vec` and `_mat` do this change.

## The mapping

For an avatar bone c that body b drives, the orientation of the bone in the skeleton's space is

    W_c = D_b * A_c * R_c

- `R_c` is the rest orientation of the bone.
- `D_b = turn_b(pose) * turn_b(default pose)^-1` is how far the body has turned from the default
  pose of the muscle skeleton.
- `A_c` is the smallest rotation that takes the avatar's rest direction (head of bone `from` to
  head of bone `to`) onto the default direction of the muscle skeleton (origin of body `from` to
  origin of body `to`). A row without a pair has no such rotation.

A bone that no row drives keeps its rest orientation against its parent. Only orientations are
set. Each bone keeps its rest offset from its parent, so the avatar keeps its own bone lengths.
Last, the root bone is moved so that the midpoint of the avatar's two hip joints (the heads of
`upperleg01.L` and `upperleg01.R`) is at the midpoint of the origins of `femur_l` and `femur_r`.

## Calls

`setup(parents, rest, drive, zero, hips) -> int` takes the tables once. It returns 0, or a
negative number for the table it refused.

| Argument | Contents |
| --- | --- |
| `parents` | One per bone. Bone 0 is the only root (-1). A parent comes before its children. |
| `rest` | 7 per bone, in the skeleton's space at rest: head x, y, z and orientation x, y, z, w. |
| `drive` | 6 per row: bone, body, bone from, bone to, body from, body to. The pair is -1 when absent. |
| `zero` | 7 per body at the default pose, as the physics guest gives them: x, y, z, w, x, y, z. |
| `hips` | The two hip bones, then the two femur bodies. |

Refusals: -1 `rest` size, -2 `zero` size, -3 `drive` or `hips` size, -4 a hip index, -5 bone
order, -6 a row's bone or body (or a bone driven twice), -7 a pair index, -8 a pair of zero
length, -9 a pair that points the opposite way.

`pose(bodies) -> PackedFloat64Array` takes 7 numbers per body from `mjc_bodies()`. It returns 4
per bone (the pose rotation of the bone against its parent, x, y, z, w) and then 3 (the pose
position of the root bone). It returns an empty array before `setup`, or for a wrong body count.

## The drive table

`data/drive.tsv` has one row per driven bone: the bone, the body that drives it, and the four
names of the alignment pair (empty for the three pelvis rows). `tools/drive_table.exs` writes it
from the expanded table of the reference script:

    elixir tools/drive_table.exs <drive_table.txt> data/drive.tsv

The rows are grouped by driving body in the part order of the wire, so the order in which the
body column first shows each name is that order (21 bodies, 64 rows). The apparatus reads the
file, finds the indices and hands them to the guest. The table is in no other file.

## Which math the guest uses

`tests/math_proof.gd` runs three small guests in `proof/`. Each computes one quaternion product,
and chains of 10 to 2000 products with a normalisation after each product. One guest uses only
floats and a packed array, one uses `Quaternion` values, one uses `Basis` values. Each result is
compared with the host's.

    godot --headless --path . -s tests/math_proof.gd [-- --control=flip]

Measured on the double-precision editor on an Apple silicon Mac: all three agree with the host
(the `Quaternion` guest bit for bit, the other two to about 1e-15). A chain step costs about 300
nanoseconds with floats or `Quaternion` and about 390 with `Basis`. Chains of 2000 steps run, so
the limit of about 100 scoped values in one call does not stop a loop. `follow.sgd` therefore
keeps its tables as Arrays of `Quaternion` and `Vector3`. `--control=flip` changes one input
after the host has computed its answer, and must fail.

## The gate

    godot --headless --path . -s tests/follow_gate.gd -- <mujoco.elf> <anny_base.glb> <reference dir> [--control=swap]

The verdict is the `RESULT:` line, not the exit code alone.

The reference is made outside the engine: the reference script's own mapping, run through the
forward pass of the avatar model in double precision. The reference directory holds `bones.txt`,
`parents.txt`, `bodies.txt`, `qpos0.f64`, `rest.f64` (per bone, 9 rotation numbers by rows and 3
for the head), `clips.tsv` (name, frames), and per clip `<name>.qpos.f64` (86 per frame) and
`<name>.poses.f64` (per frame and bone, 9 and 3 as in `rest.f64`). The reference and the clips
are scratch data and are not in this repository.

For every frame of every clip the gate sets the pose on the engine's own `Skeleton3D` and reads
back the global poses:

- turn: the angle between the turn of each bone from rest here and in the reference;
- head: the distance between the head of each bone here and in the reference, both measured
  from the hip midpoint;
- root: the distance of the hip midpoint from the midpoint of the two femur origins.

Each limit is 1e-9 (radians or metres). Both sides are double precision. Measured on `walk` (401
frames) and `idle` (997 frames): turn 5.8e-15 rad, head 2.3e-14 m, root 9.0e-16 m. The follower
takes about 250 microseconds for one pose. The angle is computed with `atan2`, because `acos` of
the w part cannot see angles below 1e-8.

`--control=swap` gives the follower the table with the left and right driving bodies exchanged.
It must fail, and it does (2.57 rad on `walk`).

The gate compares bones, not skin. The baked base mesh in `anny_base.glb` is not the rest mesh of
the model's default phenotype (the vertices differ by 3.8 cm on average), although the bone heads
are equal. A comparison of vertices with the reference would therefore not compare like with like.

The skeleton must be inside the scene tree. Outside the tree the engine does not recompute the
global poses, and `get_bone_global_pose` returns the rest pose. The gate waits one frame and
fails if the skeleton is not in the tree.

`tests/follow_rig.gd` is apparatus that the gate and the recorder share. It builds the muscle
skeleton, loads the avatar, reads `data/drive.tsv` and sets up the follower.

## The recording

`tests/follow_movie.gd` is not a gate. It needs a window and the movie writer:

    godot --path . --write-movie <out.mkv> --fixed-fps 32 -s tests/follow_movie.gd -- <mujoco.elf> <anny_base.glb> <clips dir> [--control=swap]

It shows `walk` and then `idle`. A clip is raw float64, 86 per frame, 100 frames a second, and
loops. The physics runs at 64 ticks a second, two ticks for each movie frame; the pose at a tick
is interpolated between the two nearest clip frames. Each clip is shown from 8 views, each held
for 2 seconds, from 3 m. The movie is therefore 32 seconds, 1024 frames.

The views are the Hammersley sphere sequence, offset 0, no remap. For view i of N:
pitch = acos(1 - 2 i / N) - pi / 2, yaw = 2 pi times the base-2 radical inverse of i, and the
direction from the focus to the camera is (sin(yaw) cos(pitch), sin(pitch), -cos(yaw) cos(pitch)).
View 0 is straight below. The focus is above the femur midpoint at a height of 0.9 m.

The output is CineForm in Matroska, which is the movie writer's default for `.mkv`. The width
must divide by 16 and the height by 8. The size comes from the project's viewport settings; a
temporary `override.cfg` beside `project.godot` sets 1280 by 720 for a run and is then removed.

## What the picture shows and does not

- The orange dots are the origins of the 21 driving bodies of the muscle skeleton, drawn through
  the skin. They do not sit on the avatar's joints. The avatar keeps ANNY's bone lengths and the
  muscle skeleton has its own proportions. Only the hip midpoint is made to coincide. The dots
  and the mesh will not coincide until the later prosthetics step.
- The mapping reproduces the scratch reference to 1e-14. It is as right or as wrong as that
  reference. The reference itself bows the head forward, puts the arms behind the torso in
  `walk` and holds them away from the body in `idle`. The follower repeats this exactly.
- Bone roll is not constrained. The alignment rotation fixes the direction of a bone at the
  default pose and nothing more, so the twist of a limb about its own axis is whatever the rest
  poses of the two skeletons give.
- The skin is the baked base mesh, not the default phenotype, and no body shape is fitted to
  the muscle skeleton.
- The gate does not measure the skin. The picture is the only check that the mesh deforms.
- In the control recording the left and right driving bodies are exchanged. Each side of the
  avatar then does what the other side of the muscle skeleton does.
