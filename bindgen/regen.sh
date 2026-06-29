#!/usr/bin/env bash
# regen.sh — validate bindings.json and regenerate the lib/ binding modules.
#
# Edit bindgen/bindings.json (add a class/method/enum), then run this. It
# rewrites lib/godot_{enums,classes,utility}.mc. Set $PYTHON to override the
# interpreter (defaults to python3).
set -e

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
py="${PYTHON:-python3}"

cd "$root"
echo ":: validating bindgen/bindings.json"
"$py" bindgen/godot_to_minc.py bindgen/extension_api.json --spec bindgen/bindings.json --check
echo ":: regenerating lib/godot_{enums,classes,utility}.mc"
"$py" bindgen/godot_to_minc.py bindgen/extension_api.json --spec bindgen/bindings.json --outdir lib
echo "OK — regenerated. Rebuild an example to pick up the change."
