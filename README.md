# godot-minc

Write [Godot](https://godotengine.org) game logic in
[minc](https://minc.dev), a small, fast, compiled
language, and load it as a native GDExtension.

minc emits the platform shared library (`.dll` / `.so` / `.dylib`) 
directly, and Godot loads it.

```mc
import godot;

void hello_ready(void* instance, void* args, void* ret) {
    gd_print("Hello from minc! (HelloMinc._ready)");
    return;
}

void gd_register() {
    i32 cls = gd_class("HelloMinc", "Node", hello_create, hello_free);
    gd_bind_virtual(cls, "_ready", hello_ready);
    return;
}
```

## Quickstart

You need two things: the minc compiler and the Godot 4.3 engine.
The one-liner in [install_minc.md](install_minc.md) installs the
compiler from [minc.dev](https://minc.dev); `get_godot.*` fetches a
pinned, SHA-verified Godot into `godot/` (gitignored). The build script
picks both up automatically.

See [Using an existing install](#using-an-existing-install).

### Windows

```powershell
git clone <this-repo> godot-minc
cd godot-minc
powershell -c "irm minc.dev/install.ps1 | iex"   # install minc
./get_godot.ps1           # downloads Godot 4.3 -> godot/
./build.ps1               # lists the available examples
./build.ps1 cube          # builds the examples + runs cube.tscn
```

### macOS / Linux

```sh
git clone <this-repo> godot-minc
cd godot-minc
curl -fsSL https://minc.dev/install | bash       # install minc
./get_godot.sh            # downloads Godot 4.3 -> godot/
./build.sh                # lists the available examples
./build.sh cube           # builds the examples + runs cube.tscn
```

Run with no argument to list the examples.


## Using an existing install

- minc: set `MINC` (`$env:MINC` on Windows) to your `minc` binary, or put it
  on `PATH` (the minc.dev installer does). The build script checks `MINC`,
  then `PATH`.

- Godot: set `GODOT` to your Godot 4.3 binary, or put `godot` on `PATH`. The
  build script checks `GODOT`, then `godot/`, then `PATH`. The `get_godot`
  scripts no-op when `GODOT` is already set.

```sh
MINC=/path/to/minc GODOT=/path/to/Godot ./build.sh cube
```


## How it works

A GDExtension is a C-ABI shared library Godot loads at startup. minc compiles
your `.mc` to that library with `--shared`, exporting one entry symbol,
`minc_gdextension_init`. The `.gdextension` manifest points Godot at the library
per platform; on load Godot calls the entry point, minc fetches the engine's
interface function pointers, registers your classes, and from then on Godot
drives your `_ready` / `_process` virtuals while your code calls back into the
engine through typed `ptrcall` wrappers.

```
examples/cube.mc  --(import godot;)-->  lib/godot.mc + lib/godot_*.mc
       |
       |  minc cube.mc --shared --target <os>
       v
examples/bin/cube.dll        cube.gdextension  ->  Godot loads it
```

## Layout

```
lib/        the binding modules (import godot; resolves to lib/godot.mc)
examples/   the Godot project (one project, several example extensions)
bindgen/    the binding generator + Godot API spec (extend the bound surface)
install_minc.md          how to install the minc compiler
get_godot.ps1 / .sh      download the Godot editor -> godot/
build.ps1 / build.sh     build an example + run its scene
```

- Examples: [`examples/README.md`](examples/README.md).
- Extending the API surface: [`bindgen/README.md`](bindgen/README.md).


## Licensing

The bindings and examples in this repo are under [`LICENSE.md`](LICENSE.md).

The minc compiler is closed-source, separately licensed software. It is not
covered by this repo's license; see the license shipped with the minc
install (in `~/.minc`).

Godot is MIT-licensed (godotengine.org).
