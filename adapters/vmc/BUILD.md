# Building godot-vmc-lib

`godot-vmc-lib` (DigitOtter, MIT, upstream master 0c1adf8) is a C++ GDExtension,
not GDScript. It needs a native build per platform (Mac, linux-arm64).

The subtree import dropped its two submodule gitlinks, because the upstream
`.gitmodules` sits below the repo root and does nothing here. Restore them
before building, outside git:

- `third_party/godot-cpp`: upstream pins the godot-cpp 4.1 branch. This project
  targets Godot 4.6 with double precision, so expect a godot-cpp bump and a
  `precision=double` build.
- `third_party/oscpack`: upstream pin is in its `.gitmodules`.

Upstream last pushed 2024-06-17. Treat the Godot 4.6 port as open work.
