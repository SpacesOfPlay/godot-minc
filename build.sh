#!/bin/sh
# build.sh — build a minc GDExtension example and run its scene (macOS/Linux).
#
# Usage:
#   ./build.sh                 # list the available examples
#   ./build.sh cube            # build all examples + run cube.tscn
#   ./build.sh cube --no-run   # just compile, don't launch Godot
#
# Your example is examples/<name>.mc; it writes `import godot;` and defines
# gd_register(). It builds to examples/bin/lib<name>.{dylib,so} (matching
# examples/<name>.gdextension) and runs examples/<name>.tscn.
#
# Compiler: $MINC or PATH (install from minc.dev — see install_minc.md).
# Engine:   godot/ (run ./get_godot.sh) or $GODOT or PATH.
set -e

EXAMPLE=""
NORUN=0
for a in "$@"; do
    case "$a" in
        --no-run) NORUN=1 ;;
        -*) echo "unknown option: $a" >&2; exit 1 ;;
        *) EXAMPLE="$a" ;;
    esac
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJ="$ROOT/examples"

# No example given → list the available ones and exit (don't build/run).
if [ -z "$EXAMPLE" ]; then
    echo "Usage: ./build.sh <example> [--no-run]"
    echo
    echo "Available examples:"
    for mc in "$PROJ"/*.mc; do
        echo "  $(basename "$mc" .mc)"
    done
    echo
    echo "e.g. ./build.sh cube"
    exit 0
fi

case "$(uname -s)" in
    Darwin) TARGET="macos"; EXT="dylib"; PREFIX="lib" ;;
    Linux)  TARGET="linux"; EXT="so";    PREFIX="lib" ;;
    *)      echo "unsupported OS for build.sh (use build.ps1 on Windows)" >&2; exit 1 ;;
esac

# Locate the minc compiler: $MINC env (install dir, or a direct binary
# path), then a sibling build (../build/minc), then PATH.
if [ -n "$MINC" ] && [ -d "$MINC" ] && [ -x "$MINC/minc" ]; then MINC="$MINC/minc";
elif [ -n "$MINC" ] && [ -x "$MINC" ]; then :;   # honour the caller's $MINC
elif [ -x "$ROOT/../build/minc" ]; then MINC="$ROOT/../build/minc";
elif command -v minc >/dev/null 2>&1; then MINC="$(command -v minc)";
else MINC="";
fi
if [ -z "$MINC" ]; then
    echo "" >&2
    echo "minc compiler not found." >&2
    echo "  Install it:  curl -fsSL https://minc.dev/install | bash" >&2
    echo "  Or set \$MINC to a minc install dir, or put minc on PATH." >&2
    exit 1
fi

[ -f "$PROJ/$EXAMPLE.mc" ]          || { echo "no examples/$EXAMPLE.mc" >&2; exit 1; }
[ -f "$PROJ/$EXAMPLE.gdextension" ] || { echo "no examples/$EXAMPLE.gdextension" >&2; exit 1; }

# Build every example so all of the project's .gdextensions load cleanly. minc
# runs with the repo root as cwd so `import godot;` resolves to lib/godot.mc.
mkdir -p "$PROJ/bin"
( cd "$ROOT"
  for mc in examples/*.mc; do
      n="$(basename "$mc" .mc)"
      echo ":: building examples/$n.mc -> examples/bin/${PREFIX}${n}.${EXT}"
      "$MINC" "$mc" --shared --target "$TARGET" -o "examples/bin/${PREFIX}${n}.${EXT}"
  done )

# The asteroids example embeds the minc compiler: stage libminc next to the
# extension libraries (searched next to the compiler, then ../build/), plus
# the minc stdlib as bin/lib/ so runtime-compiled scripts can `import math;`
# (libminc anchors imports on its own directory).
case "$TARGET" in
    macos) LM="libminc.dylib" ;;
    *)     LM="libminc.so" ;;
esac
for lm in "$(dirname "$MINC")/$LM" "$ROOT/../build/$LM"; do
    if [ -f "$lm" ]; then cp -f "$lm" "$PROJ/bin/"; break; fi
done
MINC_LIB="$(dirname "$MINC")/lib"
[ -d "$MINC_LIB" ] || MINC_LIB="$ROOT/../lib"
if [ -d "$MINC_LIB" ]; then
    mkdir -p "$PROJ/bin/lib"
    cp -f "$MINC_LIB"/*.mc "$PROJ/bin/lib/"
fi

if [ "$NORUN" = 1 ]; then echo ":: built (skipping run)"; exit 0; fi

# Locate Godot only when we're actually going to launch: $GODOT env, then the
# downloaded godot/, then PATH.
if [ -n "$GODOT" ] && [ -x "$GODOT" ]; then :;   # honour the caller's $GODOT
elif [ "$TARGET" = "macos" ] && [ -x "$ROOT/godot/Godot.app/Contents/MacOS/Godot" ]; then
    GODOT="$ROOT/godot/Godot.app/Contents/MacOS/Godot";
elif [ "$TARGET" = "linux" ] && [ -x "$ROOT/godot/Godot_v4.3-stable_linux.x86_64" ]; then
    GODOT="$ROOT/godot/Godot_v4.3-stable_linux.x86_64";
elif command -v godot >/dev/null 2>&1; then GODOT="$(command -v godot)";
else GODOT="";
fi
if [ -z "$GODOT" ]; then
    echo "" >&2
    echo "Godot engine not found." >&2
    echo "  Fetch it:  ./get_godot.sh   (drops godot/)" >&2
    echo "  Or set \$GODOT to an existing Godot 4.3 binary, or put it on PATH." >&2
    echo "  (Compilation succeeded; re-run without --no-run once Godot is available.)" >&2
    exit 1
fi

# One-time editor import so Godot writes .godot/extension_list.cfg
# makes the extensions load on run
if [ ! -f "$PROJ/.godot/extension_list.cfg" ]; then
    echo ":: importing project (first run)"
    "$GODOT" --headless --editor --path "$PROJ" --quit-after 300 >/dev/null 2>&1 || true
fi

echo ":: running res://$EXAMPLE.tscn (close the window to quit)"
exec "$GODOT" --path "$PROJ" "res://$EXAMPLE.tscn"
