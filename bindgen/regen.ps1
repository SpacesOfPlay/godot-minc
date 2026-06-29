# regen.ps1 — validate bindings.json and regenerate the lib/ binding modules.
#
# Edit bindgen\bindings.json (add a class/method/enum), then run this. It
# rewrites lib\godot_{enums,classes,utility}.mc. Set $env:PYTHON to override the
# interpreter (defaults to python).
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = (Resolve-Path (Join-Path $here "..")).Path
$py   = if ($env:PYTHON) { $env:PYTHON } else { "python" }

Push-Location $root
try {
    Write-Host ":: validating bindgen\bindings.json"
    & $py bindgen/godot_to_minc.py bindgen/extension_api.json --spec bindgen/bindings.json --check
    Write-Host ":: regenerating lib\godot_{enums,classes,utility}.mc"
    & $py bindgen/godot_to_minc.py bindgen/extension_api.json --spec bindgen/bindings.json --outdir lib
    Write-Host "OK — regenerated. Rebuild an example to pick up the change."
} finally { Pop-Location }
