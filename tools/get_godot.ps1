# get_godot.ps1 — download a pinned Godot 4.3 engine release (Windows).
#
# godot-minc needs the Godot editor/engine to import and run the example
# project. This script fetches the pinned upstream release, verifies its
# SHA-256, and unpacks it into `tools/godot/` (gitignored). `build.ps1`
# picks it up automatically — no PATH changes needed.
#
# If you already have Godot 4.3, skip this and point `$env:GODOT` at your binary.
#
# To rotate: bump $GodotVersion + $GodotSha256Win below, re-run.
# A SHA-256 mismatch aborts.

$ErrorActionPreference = 'Stop'

# Force TLS 1.2 — see get_minc.ps1 for why.
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Invoke-WebRequestWithRetry {
    param([string]$Uri, [string]$OutFile, [int]$Attempts = 4)
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile
            return
        } catch {
            if ($i -eq $Attempts) { throw }
            Write-Host "  download failed (attempt $i/$Attempts): $($_.Exception.Message)"
            Start-Sleep -Milliseconds (300 * $i)
        }
    }
}

$GodotVersion   = '4.3-stable'
# SHA-256 of the upstream Godot_v4.3-stable_win64.exe.zip. Set on first
# publish: run once, the script prints the hash, paste it here to enable
# verification.
$GodotSha256Win = '<set-on-first-publish>'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$dstDir = Join-Path $here 'godot'
$exe    = Join-Path $dstDir "Godot_v$GodotVersion`_win64.exe"

if ($env:GODOT -and (Test-Path $env:GODOT)) {
    Write-Host "`$env:GODOT is set ($env:GODOT) — skipping download."
    exit 0
}
if (Test-Path $exe) {
    Write-Host "Godot already installed at $exe — skipping download."
    Write-Host "(delete tools\godot\ to force a re-fetch.)"
    exit 0
}

$zipName = "Godot_v$GodotVersion`_win64.exe.zip"
$zipUrl  = "https://github.com/godotengine/godot/releases/download/$GodotVersion/$zipName"
$zipPath = Join-Path $here $zipName

Write-Host "Downloading Godot $GodotVersion from $zipUrl"
Invoke-WebRequestWithRetry -Uri $zipUrl -OutFile $zipPath

$actualSha = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
if ($GodotSha256Win -eq '<set-on-first-publish>') {
    Write-Warning "SHA-256 not pinned. Got: $actualSha"
    Write-Warning "Update tools/get_godot.ps1's `$GodotSha256Win with this value to enable verification."
} elseif ($actualSha -ne $GodotSha256Win.ToLower()) {
    Remove-Item $zipPath
    throw "Godot download SHA-256 mismatch. Expected $GodotSha256Win, got $actualSha. Refusing to proceed."
}

# The win64 zip holds Godot_v<ver>_win64.exe (and a *_console.exe variant)
# at its root. Unpack both into tools/godot/; build.ps1 prefers the GUI exe.
if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir | Out-Null }
Expand-Archive -Path $zipPath -DestinationPath $dstDir -Force
Remove-Item $zipPath -Force

if (-not (Test-Path $exe)) {
    throw "Unexpected zip layout — expected $($exe | Split-Path -Leaf) inside $zipName."
}

Write-Host ""
Write-Host "OK — Godot $GodotVersion installed at $dstDir"
Write-Host "Try it: .\build.ps1"
