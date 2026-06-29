# get_minc.ps1 — download a pinned minc compiler release.
#
# minc is the language the godot-minc bindings are written in. It's a
# separate **closed-source** binary distributed from
# https://github.com/SpacesOfPlay/minc-dev/releases — see LICENSE.md
# at the top of this repo for the disclosure.
#
# This script fetches the pinned version, verifies its SHA-256, and
# extracts to `tools/minc/` (gitignored). `build.ps1` picks it up
# automatically — no PATH changes needed.
#
# To rotate: bump $MincVersion and $MincSha256Win below, re-run.
# A SHA-256 mismatch aborts the script.

$ErrorActionPreference = 'Stop'

# Force TLS 1.2 — Windows PowerShell defaults to SSL3/TLS 1.0
# which GitHub's CDN rejects, causing "An existing connection
# was forcibly closed by the remote host" on the first call.
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Retry transient connection failures. GitHub's CDN occasionally
# resets the first TLS handshake; a single retry almost always
# succeeds because .NET caches the session state.
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

$MincVersion   = '0.9.8'
$MincSha256Win = '4e2e0f47f719c4adeea37464eb5ae121803fe82eef894c9e99ee96019af48615'

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$zipName = "minc-$MincVersion-win-x64.zip"
$zipUrl  = "https://github.com/SpacesOfPlay/minc-dev/releases/download/v$MincVersion/$zipName"
$zipPath = Join-Path $here $zipName
$dstDir  = Join-Path $here 'minc'
$mincExe = Join-Path $dstDir 'minc.exe'

if (Test-Path $mincExe) {
    Write-Host "minc already installed at $mincExe — skipping download."
    Write-Host "(delete tools\minc\ to force a re-fetch.)"
    exit 0
}

Write-Host "minc compiler is closed-source proprietary software from"
Write-Host "  https://github.com/SpacesOfPlay/minc-dev/"
Write-Host "It is NOT covered by this repo's license. See LICENSE.md."
Write-Host ""
Write-Host "Downloading minc v$MincVersion from $zipUrl"
Invoke-WebRequestWithRetry -Uri $zipUrl -OutFile $zipPath

$actualSha = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
if ($MincSha256Win -eq '<unverified-set-on-first-publish>') {
    Write-Warning "SHA-256 not pinned. Got: $actualSha"
    Write-Warning "Update tools/get_minc.ps1's `$MincSha256Win with this value."
} elseif ($actualSha -ne $MincSha256Win.ToLower()) {
    Remove-Item $zipPath
    throw "minc download SHA-256 mismatch. Expected $MincSha256Win, got $actualSha. Refusing to proceed."
}

# The zip extracts a `minc-win-x64/` directory at the root. We
# rename that to `tools/minc/` so the lookup path is stable across
# versions.
$tmpExtract = Join-Path $here "__minc_extract"
if (Test-Path $tmpExtract) { Remove-Item -Recurse -Force $tmpExtract }
Expand-Archive -Path $zipPath -DestinationPath $tmpExtract -Force
$inner = Join-Path $tmpExtract 'minc-win-x64'
if (-not (Test-Path $inner)) {
    Remove-Item -Recurse -Force $tmpExtract
    Remove-Item $zipPath
    throw "Unexpected zip layout — expected minc-win-x64/ at root."
}
if (Test-Path $dstDir) { Remove-Item -Recurse -Force $dstDir }
Move-Item -Path $inner -Destination $dstDir
Remove-Item -Recurse -Force $tmpExtract
Remove-Item $zipPath -Force

Write-Host ""
Write-Host "OK — minc v$MincVersion installed at $dstDir"
Write-Host "     license: $dstDir\LICENSE.md"
Write-Host ""
Write-Host "Try it: .\build.ps1"
