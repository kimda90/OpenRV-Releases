# Build OpenRV on Windows: clone to short path, then build via bash (rvcmds.sh + rvbootstrap).
# Requires: VS 2022, Python 3.11, CMake, Qt 6.5.3 (msvc2019_64), Strawberry Perl, Rust, MSYS2 MinGW64 + pacman deps.
# Usage: .\build_windows.ps1 -Tag 'v3.2.1' [-RepoUrl '...'] [-WorkDir 'C:\OpenRV']
param(
    [Parameter(Mandatory = $true)]
    [string]$Tag,
    [string]$RepoUrl = 'https://github.com/AcademySoftwareFoundation/OpenRV.git',
    [string]$WorkDir = 'C:\OpenRV'
)

$ErrorActionPreference = 'Stop'

# Find bash (MSYS2 or Git for Windows)
$bashExe = $env:BASH_EXE
if (-not $bashExe) {
    foreach ($p in @('C:\msys64\usr\bin\bash.exe', 'C:\Program Files\Git\bin\bash.exe')) {
        if (Test-Path $p) { $bashExe = $p; break }
    }
}
if (-not $bashExe) {
    throw 'Bash not found. Set BASH_EXE or install MSYS2 or Git for Windows.'
}

# Clone to short path to avoid MAX_PATH issues
if (Test-Path $WorkDir) {
    Remove-Item -Recurse -Force $WorkDir
}
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

Write-Host "Cloning OpenRV $Tag into $WorkDir"
& git clone --recursive $RepoUrl $WorkDir
Push-Location $WorkDir
try {
    & git fetch --tags
    & git checkout "refs/tags/$Tag"
    & git submodule update --init --recursive
} finally {
    Pop-Location
}

# Convert Windows path to MSYS2 path (C:\OpenRV -> /c/OpenRV)
$workDirBash = '/' + $WorkDir.Substring(0, 1).ToLower() + $WorkDir.Substring(2).Replace('\', '/')

# QT_HOME should be set by caller (e.g. C:\Qt\6.5.3\msvc2019_64)
if (-not $env:QT_HOME) {
    $qtCandidate = 'C:\Qt\6.5.3\msvc2019_64'
    if (Test-Path $qtCandidate) { $env:QT_HOME = $qtCandidate }
}
if (-not $env:QT_HOME) { throw 'QT_HOME not set and C:\Qt\6.5.3\msvc2019_64 not found. Install Qt 6.5.3 (e.g. aqt install-qt).' }
$qtHomeBash = '/' + $env:QT_HOME.Substring(0, 1).ToLower() + $env:QT_HOME.Substring(2).Replace('\', '/')

# Build in bash: set env and run rvbootstrap
$env:RV_VFX_PLATFORM = 'CY2024'
$env:RV_BUILD_TYPE = 'Release'

$buildScript = @"
set -e
cd '$workDirBash'
export RV_VFX_PLATFORM=CY2024
export RV_BUILD_TYPE=Release
export QT_HOME='$qtHomeBash'
source rvcmds.sh
rvbootstrap
"@

Write-Host "Running rvbootstrap in bash..."
& $bashExe -c $buildScript

$rvExe = Join-Path $WorkDir '_build\stage\app\bin\rv.exe'
if (-not (Test-Path $rvExe)) {
    throw "Post-build check failed: $rvExe not found"
}
Write-Host "Post-build check OK: $rvExe exists"
