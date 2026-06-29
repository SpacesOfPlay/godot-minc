# minc → Godot examples

GDExtensions written in minc. One Godot project, several examples.

| Example | Class | What it shows |
|---|---|---|
| `cube.mc` | `MincNode` | A custom-shaded cube spun each frame in `_process`. The minimal 3D extension. |
| `features.mc` | `MincFeatures` | A tour of the binding surface: a `value` property, 1- and 2-arg signals, Variant round-trip, singleton / static / utility calls. Prints a line per step. |
| `hello.mc` | `HelloMinc` | The minimal starter: a `Node` whose `_ready` prints. Copy it to begin a new extension. |
| `game.mc` | `SokoGame` | A playable 3D Sokoban. |

## Build + run

From the repo root, one command builds every example and opens the chosen one in
a window (runs until you close it):

```sh
./build.sh cube       # macOS / Linux
./build.sh hello
```
```powershell
.\build.ps1 cube      # Windows
```

It compiles each example to the native library named in its `.gdextension`
(`.dll` / `.so` / `.dylib`, no external linker), does a one-time editor import
(writes `.godot/extension_list.cfg`, which is what makes Godot load the
extension), and runs that example's scene. Add `-NoRun` (`--no-run`) to compile
without launching.

## Start your own

Copy `hello.mc` to `mygame.mc`, rename the class in `gd_register()`, add a
`mygame.gdextension` (point `macos`/`windows`/`linux.x86_64` at the matching
`bin/...` library) and a `mygame.tscn` whose root is your class, then
`./build.sh mygame`. The build scripts pick up any `*.mc` in this folder
automatically.
