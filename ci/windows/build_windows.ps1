# Build OpenRV on Windows - Pure PowerShell approach (no nested interpreters)
# Requires: VS 2022 (MSVC v143), Python 3.11, CMake 3.27+, Qt 6.5.3 (msvc2019_64),
#   Strawberry Perl, Rust, MSYS2 with MinGW64 packages.
# Usage: .\build_windows.ps1 -Tag 'v3.2.1' [-RepoUrl '...'] [-WorkDir 'C:\OpenRV']
#        [-BMDDeckLinkSdkZipPath 'C:\path\to\zip'] [-NDISdkRoot 'C:\path\to\NDI SDK']
param(
    [Parameter(Mandatory = $true)]
    [string]$Tag,
    [string]$RepoUrl = 'https://github.com/AcademySoftwareFoundation/OpenRV.git',
    [string]$WorkDir = 'C:\OpenRV',
    [string]$BMDDeckLinkSdkZipPath = '',
    [string]$NDISdkRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "OpenRV Windows Build Script" -ForegroundColor Cyan
Write-Host "Tag: $Tag" -ForegroundColor Cyan
Write-Host "WorkDir: $WorkDir" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ============================================================================
# Step 1: Setup Visual Studio environment
# ============================================================================
Write-Host "`n[1/8] Setting up Visual Studio environment..." -ForegroundColor Yellow

# Find vcvarsall.bat
$vcvarsall = $null
$vsSearchPaths = @(
    "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvarsall.bat",
    "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat",
    "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat",
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvarsall.bat",
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat",
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat",
    "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
)
foreach ($path in $vsSearchPaths) {
    if (Test-Path $path) { $vcvarsall = $path; break }
}
if (-not $vcvarsall) {
    throw "vcvarsall.bat not found. Please install Visual Studio 2022 with C++ workload."
}
Write-Host "Found: $vcvarsall"

# Import VS environment into PowerShell
$envBefore = @{}
Get-ChildItem Env: | ForEach-Object { $envBefore[$_.Name] = $_.Value }

$tempBat = [System.IO.Path]::GetTempFileName() + ".bat"
$tempEnv = [System.IO.Path]::GetTempFileName()
@"
@echo off
call "$vcvarsall" x64
set > "$tempEnv"
"@ | Set-Content $tempBat -Encoding ASCII

cmd /c $tempBat 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to initialize VS environment" }

Get-Content $tempEnv | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') {
        $name = $matches[1]
        $value = $matches[2]
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}
Remove-Item $tempBat, $tempEnv -ErrorAction SilentlyContinue
Write-Host "VS 2022 x64 environment loaded."

# ============================================================================
# Step 2: Setup PATH with all required tools
# ============================================================================
Write-Host "`n[2/8] Configuring PATH..." -ForegroundColor Yellow

# Detect Qt
$qtHome = $env:QT_HOME
if (-not $qtHome -or -not (Test-Path $qtHome)) {
    $qtHome = "C:\Qt\6.5.3\msvc2019_64"
}
if (-not (Test-Path $qtHome)) {
    throw "Qt not found at $qtHome. Set QT_HOME or install Qt 6.5.3."
}
$env:QT_HOME = $qtHome
$env:CMAKE_PREFIX_PATH = $qtHome
Write-Host "QT_HOME: $qtHome"

# Detect Python
$pythonExe = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $pythonExe) { throw "Python not found in PATH" }
$pythonDir = Split-Path $pythonExe
Write-Host "Python: $pythonExe"

# Ensure python3.exe exists
$python3Exe = Join-Path $pythonDir 'python3.exe'
if (-not (Test-Path $python3Exe)) {
    Copy-Item $pythonExe $python3Exe
    Write-Host "Created python3.exe symlink"
}

# Build PATH: CMake, Python, Rust, MSYS2 MinGW64, then VS tools, then Perl at end
$pathComponents = @(
    "C:\Program Files\CMake\bin",
    $pythonDir,
    "$env:USERPROFILE\.cargo\bin",
    "C:\msys64\mingw64\bin",
    "C:\msys64\usr\bin",
    $env:PATH,
    "C:\Strawberry\perl\bin"
)
$env:PATH = ($pathComponents | Where-Object { $_ }) -join ';'

# Set additional environment variables
$env:WIN_PERL = "C:/Strawberry/perl/bin"
$env:RV_DEPS_WIN_PERL_ROOT = "C:/Strawberry/perl/bin"
$env:MSYSTEM = "MINGW64"
$env:CL = "/FS"
$env:DISTUTILS_USE_SDK = "1"
$env:SETUPTOOLS_USE_DISTUTILS = "stdlib"
$env:RV_VFX_PLATFORM = "CY2024"

Write-Host "PATH configured with CMake, Python, Rust, MSYS2, VS tools, Perl"

# ============================================================================
# Step 3: Clone OpenRV
# ============================================================================
Write-Host "`n[3/8] Cloning OpenRV $Tag..." -ForegroundColor Yellow

if (Test-Path $WorkDir) {
    Write-Host "Removing existing $WorkDir..."
    Remove-Item -Recurse -Force $WorkDir
}
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null

& git clone --recursive $RepoUrl $WorkDir
if ($LASTEXITCODE -ne 0) { throw "git clone failed" }

Push-Location $WorkDir
try {
    & git fetch --tags
    & git checkout "refs/tags/$Tag"
    if ($LASTEXITCODE -ne 0) { throw "git checkout failed" }
    & git submodule update --init --recursive
    if ($LASTEXITCODE -ne 0) { throw "git submodule update failed" }
} finally {
    Pop-Location
}
Write-Host "OpenRV cloned and checked out at $Tag"

# ============================================================================
# Step 4: Setup Python virtual environment
# ============================================================================
Write-Host "`n[4/8] Setting up Python virtual environment..." -ForegroundColor Yellow

Push-Location $WorkDir
try {
    & python -m venv .venv
    if ($LASTEXITCODE -ne 0) { throw "Failed to create venv" }
    
    # Activate venv
    $venvActivate = Join-Path $WorkDir '.venv\Scripts\Activate.ps1'
    . $venvActivate
    
    # Install requirements
    Write-Host "Installing Python requirements..."
    & python -m pip install --upgrade pip
    & python -m pip install --upgrade -r requirements.txt
    if ($LASTEXITCODE -ne 0) { throw "pip install requirements failed" }
    
    Write-Host "Python venv ready"
} finally {
    Pop-Location
}

# ============================================================================
# Step 5: Prepare CMake extra arguments for optional SDKs
# ============================================================================
Write-Host "`n[5/8] Preparing CMake configuration..." -ForegroundColor Yellow

$cmakeExtraArgs = @()

if ($BMDDeckLinkSdkZipPath -and (Test-Path $BMDDeckLinkSdkZipPath)) {
    $bmdPathCmake = $BMDDeckLinkSdkZipPath -replace '\\', '/'
    $cmakeExtraArgs += "-DRV_DEPS_BMD_DECKLINK_SDK_ZIP_PATH=$bmdPathCmake"
    Write-Host "BMD DeckLink SDK: $bmdPathCmake"
}

if ($NDISdkRoot -and (Test-Path $NDISdkRoot)) {
    $ndiRootCmake = $NDISdkRoot -replace '\\', '/'
    $cmakeExtraArgs += "-DNDI_SDK_ROOT=$ndiRootCmake"
    $env:NDI_SDK_ROOT = $NDISdkRoot
    Write-Host "NDI SDK: $ndiRootCmake"
}

# ============================================================================
# Step 6: Run CMake configure
# ============================================================================
Write-Host "`n[6/8] Running CMake configure..." -ForegroundColor Yellow

$buildDir = Join-Path $WorkDir '_build'
$qtHomeCmake = $qtHome -replace '\\', '/'
$winPerlCmake = "C:/Strawberry/perl/bin"

$cmakeArgs = @(
    "-B", $buildDir,
    "-G", "Visual Studio 17 2022",
    "-T", "v143",
    "-A", "x64",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DRV_DEPS_QT6_LOCATION=$qtHomeCmake",
    "-DRV_VFX_PLATFORM=CY2024",
    "-DRV_DEPS_WIN_PERL_ROOT=$winPerlCmake"
) + $cmakeExtraArgs

Push-Location $WorkDir
try {
    Write-Host "cmake $($cmakeArgs -join ' ')"
    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { throw "CMake configure failed with exit code $LASTEXITCODE" }
    Write-Host "CMake configure completed"
} finally {
    Pop-Location
}

# ============================================================================
# Step 7: Run CMake build
# ============================================================================
Write-Host "`n[7/8] Running CMake build..." -ForegroundColor Yellow

$cpuCount = [Environment]::ProcessorCount
Write-Host "Building with $cpuCount parallel jobs..."

Push-Location $WorkDir
try {
    & cmake --build $buildDir --config Release --parallel $cpuCount --target main_executable
    if ($LASTEXITCODE -ne 0) { throw "CMake build failed with exit code $LASTEXITCODE" }
    Write-Host "CMake build completed"
} finally {
    Pop-Location
}

# ============================================================================
# Step 8: Verify build output
# ============================================================================
Write-Host "`n[8/8] Verifying build output..." -ForegroundColor Yellow

$rvExe = Join-Path $WorkDir '_build\stage\app\bin\rv.exe'
if (-not (Test-Path $rvExe)) {
    # Try to find build logs for debugging
    Write-Host "ERROR: rv.exe not found at $rvExe" -ForegroundColor Red
    Write-Host "Searching for error logs..." -ForegroundColor Yellow
    
    $logFiles = Get-ChildItem -Path $buildDir -Recurse -Filter "*.log" -ErrorAction SilentlyContinue
    foreach ($log in $logFiles) {
        $content = Get-Content $log.FullName -Raw -ErrorAction SilentlyContinue
        if ($content -match 'error|fatal|failed') {
            Write-Host "`n=== Errors in $($log.FullName) ===" -ForegroundColor Red
            $content | Select-String -Pattern 'error|fatal|failed' -Context 2,2 | Select-Object -First 20
        }
    }
    
    throw "Build verification failed: rv.exe not found"
}

Write-Host "========================================" -ForegroundColor Green
Write-Host "BUILD SUCCESSFUL" -ForegroundColor Green
Write-Host "rv.exe: $rvExe" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
