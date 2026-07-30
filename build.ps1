# build.ps1 — build a minc GDExtension example and run its scene (Windows).
#
# Usage:
#   ./build.ps1                 # list the available examples
#   ./build.ps1 cube            # build all examples + run cube.tscn
#   ./build.ps1 cube -NoRun     # just compile, don't launch Godot
#
# Your example is examples/<name>.mc; it writes `import godot;` and defines
# gd_register(). It builds to examples/bin/<name>.dll (matching
# examples/<name>.gdextension) and runs examples/<name>.tscn.
#
# Compiler: $env:MINC or PATH (install from minc.dev — see install_minc.md).
# Engine:   godot/ (run ./get_godot.ps1) or $env:GODOT or PATH.
param(
    [Parameter(Position=0)]
    [string]$Example,
    [switch]$NoRun
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$proj = Join-Path $root "examples"

# No example given → list the available ones and exit (don't build/run).
if (-not $Example) {
    Write-Host "Usage: .\build.ps1 <example> [-NoRun]"
    Write-Host ""
    Write-Host "Available examples:"
    Get-ChildItem (Join-Path $proj "*.mc") | ForEach-Object {
        Write-Host "  $($_.BaseName)"
    }
    Write-Host ""
    Write-Host "e.g. .\build.ps1 cube"
    exit 0
}

# Locate the minc compiler: $env:MINC (install dir, or a direct binary
# path), then a sibling build (../build/minc.exe), then PATH.
$minc = $null
if ($env:MINC -and (Test-Path $env:MINC)) {
    $minc = $env:MINC
    if (Test-Path $minc -PathType Container) { $minc = Join-Path $minc "minc.exe" }
} else {
    $cand = Join-Path $root "..\build\minc.exe"
    if (Test-Path $cand) { $minc = (Resolve-Path $cand).Path }
    if (-not $minc) { $minc = (Get-Command minc.exe -ErrorAction SilentlyContinue).Source }
}
if (-not $minc) {
    Write-Host ""
    Write-Host "minc compiler not found." -ForegroundColor Red
    Write-Host '  Install it:  powershell -c "irm minc.dev/install.ps1 | iex"'
    Write-Host "  Or set `$env:MINC to a minc install dir, or put minc on PATH."
    exit 1
}

if (-not (Test-Path (Join-Path $proj "$Example.mc")))          { Write-Error "no examples\$Example.mc"; exit 1 }
if (-not (Test-Path (Join-Path $proj "$Example.gdextension"))) { Write-Error "no examples\$Example.gdextension"; exit 1 }

# Build every example so all of the project's .gdextensions load cleanly. minc
# runs with the repo root as cwd so `import godot;` resolves to lib/godot.mc.
New-Item -ItemType Directory -Force (Join-Path $proj "bin") | Out-Null
Push-Location $root
try {
    Get-ChildItem (Join-Path $proj "*.mc") | ForEach-Object {
        $n = $_.BaseName
        Write-Host ":: building examples\$n.mc -> examples\bin\$n.dll"
        & $minc "examples\$n.mc" --shared --target windows -o "examples\bin\$n.dll"
        if ($LASTEXITCODE -ne 0) { Write-Error "compile failed: $n.mc"; exit 1 }
    }
} finally { Pop-Location }

# The asteroids example embeds the minc compiler: stage libminc.dll next to
# the extension libraries (searched next to the compiler, then ../build/),
# plus the minc stdlib as bin/lib/ so runtime-compiled scripts can
# `import math;` (libminc anchors imports on its own directory).
foreach ($lm in @((Join-Path (Split-Path $minc) "libminc.dll"),
                  (Join-Path $root "..\build\libminc.dll"))) {
    if (Test-Path $lm) { Copy-Item $lm (Join-Path $proj "bin") -Force; break }
}
$mincLib = Join-Path (Split-Path $minc) "lib"
if (-not (Test-Path $mincLib)) { $mincLib = Join-Path $root "..\lib" }
if (Test-Path $mincLib) {
    New-Item -ItemType Directory -Force (Join-Path $proj "bin\lib") | Out-Null
    Copy-Item (Join-Path $mincLib "*.mc") (Join-Path $proj "bin\lib") -Force
}

if ($NoRun) { Write-Host ":: built (skipping run)"; exit 0 }

# Locate Godot only when we're actually going to launch: $env:GODOT, then the
# downloaded godot/, then PATH. Prefer the GUI exe over *_console.
$godot = $null
if ($env:GODOT -and (Test-Path $env:GODOT)) {
    $godot = $env:GODOT
} else {
    $godot = Get-ChildItem (Join-Path $root "godot") -Filter "Godot_*.exe" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "_console" } | Select-Object -First 1 -ExpandProperty FullName
    if (-not $godot) { $godot = (Get-Command godot.exe -ErrorAction SilentlyContinue).Source }
}
if (-not $godot) {
    Write-Host ""
    Write-Host "Godot engine not found." -ForegroundColor Red
    Write-Host "  Fetch it:  .\get_godot.ps1   (drops godot\Godot_*.exe)"
    Write-Host "  Or set `$env:GODOT to an existing Godot 4.3 binary, or put it on PATH."
    Write-Host "  (Compilation succeeded; re-run without -NoRun once Godot is available.)"
    exit 1
}

# One-time editor import so Godot writes .godot/extension_list.cfg
# makes the extensions load on run
if (-not (Test-Path (Join-Path $proj ".godot\extension_list.cfg"))) {
    Write-Host ":: importing project (first run)"
    & $godot --headless --editor --path $proj --quit-after 300 2>&1 | Out-Null
}

Write-Host ":: running res://$Example.tscn (close the window to quit)"
& $godot --path $proj "res://$Example.tscn"
