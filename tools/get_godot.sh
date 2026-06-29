#!/usr/bin/env bash
# get_godot.sh — download a pinned Godot 4.3 engine release (macOS/Linux).
#
# godot-minc needs the Godot editor/engine to import and run the example
# project. This script fetches the pinned upstream release for the current
# platform, verifies its SHA-256, and unpacks it into `tools/godot/`
# (gitignored). `build.sh` picks it up automatically — no PATH changes.
#
# If you already have Godot 4.3, skip this and point $GODOT at your binary.
#
# Supported platforms: macOS (universal), Linux x86_64.
#
# To rotate: bump GODOT_VERSION + each GODOT_SHA256_* below, re-run.
# A SHA-256 mismatch aborts.

set -e

GODOT_VERSION='4.3-stable'
# SHA-256 of the upstream archives. Set on first publish: run once, the
# script prints the hash, paste it here to enable verification.
GODOT_SHA256_MACOS='d17940b913b3f3bf54c941eeb09042099d93865c6e2638e09e20f7c649aa474a'
GODOT_SHA256_LINUX_X64='7de56444b130b10af84d19c7e0cf63cf9e9937ee4ba94364c3b7dd114253ca21'

here="$(cd "$(dirname "$0")" && pwd)"
dst_dir="$here/godot"

if [ -n "$GODOT" ] && [ -x "$GODOT" ]; then
    echo "\$GODOT is set ($GODOT) — skipping download."
    exit 0
fi

case "$(uname -s)/$(uname -m)" in
    Darwin/*)
        zip_name="Godot_v${GODOT_VERSION}_macos.universal.zip"
        sha="$GODOT_SHA256_MACOS"
        target="$dst_dir/Godot.app"
        ;;
    Linux/x86_64)
        zip_name="Godot_v${GODOT_VERSION}_linux.x86_64.zip"
        sha="$GODOT_SHA256_LINUX_X64"
        target="$dst_dir/Godot_v${GODOT_VERSION}_linux.x86_64"
        ;;
    *)
        echo "Unsupported platform: $(uname -s)/$(uname -m). Builds: macOS universal, Linux x86_64." >&2
        echo "On Windows, run tools/get_godot.ps1 instead." >&2
        exit 1
        ;;
esac

if [ -e "$target" ]; then
    echo "Godot already installed at $target — skipping download."
    echo "(delete tools/godot/ to force a re-fetch.)"
    exit 0
fi

zip_url="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/${zip_name}"
zip_path="$here/$zip_name"

echo "Downloading Godot $GODOT_VERSION from $zip_url"
if command -v curl >/dev/null 2>&1; then
    curl -fSL -o "$zip_path" "$zip_url"
elif command -v wget >/dev/null 2>&1; then
    wget -O "$zip_path" "$zip_url"
else
    echo "Neither curl nor wget found. Install one and re-run." >&2
    exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
    actual_sha="$(sha256sum "$zip_path" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    actual_sha="$(shasum -a 256 "$zip_path" | awk '{print $1}')"
else
    echo "Neither sha256sum nor shasum found. Cannot verify download." >&2
    rm -f "$zip_path"
    exit 1
fi

if [ "$sha" = '<set-on-first-publish>' ]; then
    echo "WARNING: SHA-256 not pinned. Got: $actual_sha" >&2
    echo "Update tools/get_godot.sh's SHA for this platform with this value." >&2
elif [ "$actual_sha" != "$sha" ]; then
    rm -f "$zip_path"
    echo "Godot download SHA-256 mismatch. Expected $sha, got $actual_sha. Refusing to proceed." >&2
    exit 1
fi

mkdir -p "$dst_dir"
if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$zip_path" -d "$dst_dir"
elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$zip_path" "$dst_dir"
else
    rm -f "$zip_path"
    echo "Neither unzip nor python3 found. Install one and re-run." >&2
    exit 1
fi
rm -f "$zip_path"

if [ ! -e "$target" ]; then
    echo "Unexpected zip layout — expected $(basename "$target") inside $zip_name." >&2
    exit 1
fi
[ -d "$target" ] || chmod +x "$target"

echo
echo "OK — Godot $GODOT_VERSION installed at $target"
echo "Try it: ./build.sh"
