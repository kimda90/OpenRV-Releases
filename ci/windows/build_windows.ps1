# Build OpenRV on Windows - Supports phased runs for CI (smaller logs per step).
# Requires: VS 2022 (MSVC v143), Python 3.11, CMake 3.27+, Qt 6.5.3 (msvc2019_64),
#   Strawberry Perl, Rust, MSYS2 with MinGW64 packages.
#
# Usage (all-in-one, local):
#   .\build_windows.ps1 -Tag 'v3.2.1' [-WorkDir 'C:\OpenRV'] [-BMDDeckLinkSdkZipPath '...'] [-NDISdkRoot '...']
#
# Usage (phased, CI - run each phase as a separate workflow step):
#   .\build_windows.ps1 -Tag 'v3.2.1' -Phase Clone ...
#   .\build_windows.ps1 -Tag 'v3.2.1' -Phase Venv ...
#   .\build_windows.ps1 -Tag 'v3.2.1' -Phase Configure ...
#   .\build_windows.ps1 -Tag 'v3.2.1' -Phase BuildDependencies ...
#   .\build_windows.ps1 -Tag 'v3.2.1' -Phase BuildMain ...
#   .\build_windows.ps1 -Tag 'v3.2.1' -Phase Verify ...
#
# Phases: Clone, Venv, Configure, BuildDependencies, BuildMain, Verify. Default: All
param(
    [Parameter(Mandatory = $true)]
    [string]$Tag,
    [ValidateSet('All', 'Clone', 'Venv', 'Configure', 'BuildDependencies', 'BuildMain', 'Verify')]
    [string]$Phase = 'All',
    [string]$RepoUrl = 'https://github.com/AcademySoftwareFoundation/OpenRV.git',
    [string]$WorkDir = 'C:\OpenRV',
    [string]$BMDDeckLinkSdkZipPath = '',
    [string]$NDISdkRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$buildDir = Join-Path $WorkDir '_build'
$BuildLogDir = Join-Path $WorkDir '_build_logs'

# When running a build phase, write CMake output to a log and only show tail in console (keeps job log small).
# On failure, show last $TailLinesOnFailure lines + any line containing error/fatal.
$TailLinesNormal = 80
$TailLinesOnFailure = 500

function Write-BuildTail {
    param([string]$LogPath, [int]$TailLines, [switch]$IncludeErrors)
    if (-not (Test-Path $LogPath)) { return }
    $lines = Get-Content $LogPath -ErrorAction SilentlyContinue
    if ($lines) {
        if ($IncludeErrors) {
            $errLines = $lines | Select-String -Pattern 'error|fatal|failed' -CaseSensitive:$false
            if ($errLines) {
                Write-Host "`n--- Lines containing error/fatal/failed ---" -ForegroundColor Red
                $errLines | ForEach-Object { $_.Line } | Select-Object -First 100
            }
        }
        Write-Host "`n--- Last $TailLines lines of build log ---" -ForegroundColor Yellow
        $lines | Select-Object -Last $TailLines
    }
}

# ============================================================================
# Setup: VS environment + PATH (run at start of script or of each phase when Phase != All)
# ============================================================================
function Initialize-BuildEnv {
    # Check if VS environment is already initialized (cl.exe in PATH)
    $clExeCheck = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($clExeCheck) {
        Write-Host "VS environment already initialized (cl.exe found in PATH). Skipping vcvarsall.bat." -ForegroundColor Green
        $vsEnvAlreadySet = $true
    } else {
        Write-Host "Initializing VS environment via vcvarsall.bat..." -ForegroundColor Yellow
        $vsEnvAlreadySet = $false
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
    }

    # Derive VC x64 tools dir (cl, link, ml64) from vcvarsall path so MSBuild/FFmpeg subprocesses see them even if PATH parsing failed
    # When VS env is already set, find vcvarsall for the derivation
    if ($vsEnvAlreadySet) {
        $clExePath = (Get-Command cl.exe -ErrorAction SilentlyContinue).Source
        if ($clExePath) {
            # Derive vcvarsall from cl.exe path: e.g. ...\VC\Tools\MSVC\14.x.y\bin\Hostx64\x64\cl.exe -> ...\VC\Auxiliary\Build\vcvarsall.bat
            $vcBin = Split-Path $clExePath -Parent
            $hostDir = Split-Path $vcBin -Parent
            $binDir = Split-Path $hostDir -Parent
            $msvcVerDir = Split-Path $binDir -Parent
            $msvcDir = Split-Path $msvcVerDir -Parent
            $vcDir = Split-Path $msvcDir -Parent
            $vcvarsall = Join-Path (Join-Path $vcDir "Auxiliary\Build") "vcvarsall.bat"
            if (-not (Test-Path $vcvarsall)) { $vcvarsall = $null }
        }
    }
    $vcBinDerived = $null
    if ($vcvarsall) {
        $vcDir = Split-Path (Split-Path (Split-Path $vcvarsall -Parent) -Parent) -Parent  # VC folder
        $msvcDir = Join-Path $vcDir "Tools\MSVC"
        if (Test-Path $msvcDir) {
            $verDir = Get-ChildItem -Path $msvcDir -Directory | Sort-Object Name -Descending | Select-Object -First 1
            if ($verDir) {
                $vcBin = Join-Path $verDir.FullName "bin\Hostx64\x64"
                if (Test-Path (Join-Path $vcBin "ml64.exe")) { $vcBinDerived = $vcBin }
            }
        }
    }

    # PATH and env
    $qtHome = $env:QT_HOME
    if (-not $qtHome -or -not (Test-Path $qtHome)) { $qtHome = "C:\Qt\6.5.3\msvc2019_64" }
    if (-not (Test-Path $qtHome)) { throw "Qt not found at $qtHome. Set QT_HOME or install Qt 6.5.3." }
    $env:QT_HOME = $qtHome
    $env:CMAKE_PREFIX_PATH = $qtHome

    $pythonExe = (Get-Command python -ErrorAction SilentlyContinue).Source
    if (-not $pythonExe) { throw "Python not found in PATH" }
    $pythonDir = Split-Path $pythonExe
    $python3Exe = Join-Path $pythonDir 'python3.exe'
    if (-not (Test-Path $python3Exe)) { Copy-Item $pythonExe $python3Exe }

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

    # Prepend VC tools dir (cl, link, ml64) so MSBuild custom builds (e.g. Python _decimal vcdiv64.asm) and FFmpeg configure find them
    if ($vcBinDerived) {
        $env:PATH = "$vcBinDerived;$env:PATH"
    }
    $clExe = (Get-Command cl -ErrorAction SilentlyContinue).Source
    if ($clExe) {
        $vcBin = Split-Path $clExe -Parent
        if ($vcBin -ne $vcBinDerived) { $env:PATH = "$vcBin;$env:PATH" }
    }

    $env:WIN_PERL = "C:/Strawberry/perl/bin"
    $env:RV_DEPS_WIN_PERL_ROOT = "C:/Strawberry/perl/bin"
    $env:MSYSTEM = "MINGW64"
    $env:CL = "/FS"
    $env:DISTUTILS_USE_SDK = "1"
    $env:SETUPTOOLS_USE_DISTUTILS = "stdlib"
    $env:RV_VFX_PLATFORM = "CY2024"

    # Force Meson and other subprocesses to use MSVC (avoid "icl" / Intel compiler detection)
    $env:CC = "cl"
    $env:CXX = "cl"

    return @{ QtHome = $qtHome; PythonDir = $pythonDir }
}

# ============================================================================
# Phase: Clone
# ============================================================================
function Invoke-PhaseClone {
    Write-Host "[Phase: Clone] OpenRV $Tag -> $WorkDir" -ForegroundColor Cyan
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
    Write-Host "Clone completed." -ForegroundColor Green
}

# ============================================================================
# Phase: Venv
# ============================================================================
function Invoke-PhaseVenv {
    Write-Host "[Phase: Venv] Creating venv and installing requirements" -ForegroundColor Cyan
    if (-not (Test-Path $WorkDir)) { throw "WorkDir $WorkDir not found. Run Clone phase first." }

    Push-Location $WorkDir
    try {
        & python -m venv .venv
        if ($LASTEXITCODE -ne 0) { throw "Failed to create venv" }
        $venvActivate = Join-Path $WorkDir '.venv\Scripts\Activate.ps1'
        . $venvActivate
        & python -m pip install --upgrade pip
        & python -m pip install --upgrade -r requirements.txt
        if ($LASTEXITCODE -ne 0) { throw "pip install requirements failed" }
    } finally {
        Pop-Location
    }
    Write-Host "Venv phase completed." -ForegroundColor Green
}

# ============================================================================
# Phase: Configure
# ============================================================================
function Invoke-PhaseConfigure {
    Write-Host "[Phase: Configure] CMake configure" -ForegroundColor Cyan
    if (-not (Test-Path $WorkDir)) { throw "WorkDir $WorkDir not found. Run Clone and Venv first." }

    # Apply Windows build patches to cloned OpenRV (we do not modify upstream; patch only the clone at build time)
    $patchDir = Join-Path $PSScriptRoot "patches"
    $dav1dPatch = Join-Path $patchDir "dav1d_windows_meson.patch"
    if (Test-Path $dav1dPatch) {
        Write-Host "Applying DAV1D Windows Meson patch..." -ForegroundColor Yellow
        Push-Location $WorkDir
        try {
            & git apply --ignore-whitespace $dav1dPatch 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Warning: DAV1D patch could not be applied (maybe already applied or OpenRV version changed). Continuing." -ForegroundColor Yellow
            }
        } finally {
            Pop-Location
        }
    }

    $cmakeExtraArgs = @()
    if ($BMDDeckLinkSdkZipPath -and (Test-Path $BMDDeckLinkSdkZipPath)) {
        $cmakeExtraArgs += "-DRV_DEPS_BMD_DECKLINK_SDK_ZIP_PATH=$($BMDDeckLinkSdkZipPath -replace '\\', '/')"
    }
    if ($NDISdkRoot -and (Test-Path $NDISdkRoot)) {
        $cmakeExtraArgs += "-DNDI_SDK_ROOT=$($NDISdkRoot -replace '\\', '/')"
        $env:NDI_SDK_ROOT = $NDISdkRoot
    }

    $qtHome = $env:QT_HOME
    if (-not $qtHome) { $qtHome = "C:\Qt\6.5.3\msvc2019_64" }
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
        & cmake @cmakeArgs
        if ($LASTEXITCODE -ne 0) { throw "CMake configure failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
    Write-Host "Configure phase completed." -ForegroundColor Green
}

# ============================================================================
# Phase: BuildDependencies
# ============================================================================
function Invoke-PhaseBuildDependencies {
    Write-Host "[Phase: BuildDependencies] Building dependencies target" -ForegroundColor Cyan
    if (-not (Test-Path $buildDir)) { throw "Build dir not found. Run Configure first." }

    New-Item -ItemType Directory -Path $BuildLogDir -Force | Out-Null
    $logFile = Join-Path $BuildLogDir "build_dependencies.log"

    $cpuCount = [Environment]::ProcessorCount
    Push-Location $WorkDir
    try {
        & cmake --build $buildDir --config Release --parallel $cpuCount --target dependencies 2>&1 | Tee-Object -FilePath $logFile
        if ($LASTEXITCODE -ne 0) {
            Write-BuildTail -LogPath $logFile -TailLines $TailLinesOnFailure -IncludeErrors
            throw "CMake build dependencies failed with exit code $LASTEXITCODE"
        }
        Write-Host "`n--- Last $TailLinesNormal lines ---" -ForegroundColor Gray
        Get-Content $logFile -Tail $TailLinesNormal
    } finally {
        Pop-Location
    }
    Write-Host "BuildDependencies phase completed." -ForegroundColor Green
}

# ============================================================================
# Phase: BuildMain
# ============================================================================
function Invoke-PhaseBuildMain {
    Write-Host "[Phase: BuildMain] Building main_executable target" -ForegroundColor Cyan
    if (-not (Test-Path $buildDir)) { throw "Build dir not found. Run Configure and BuildDependencies first." }

    New-Item -ItemType Directory -Path $BuildLogDir -Force | Out-Null
    $logFile = Join-Path $BuildLogDir "build_main.log"

    $cpuCount = [Environment]::ProcessorCount
    Push-Location $WorkDir
    try {
        & cmake --build $buildDir --config Release --parallel $cpuCount --target main_executable 2>&1 | Tee-Object -FilePath $logFile
        if ($LASTEXITCODE -ne 0) {
            Write-BuildTail -LogPath $logFile -TailLines $TailLinesOnFailure -IncludeErrors
            throw "CMake build main_executable failed with exit code $LASTEXITCODE"
        }
        Write-Host "`n--- Last $TailLinesNormal lines ---" -ForegroundColor Gray
        Get-Content $logFile -Tail $TailLinesNormal
    } finally {
        Pop-Location
    }
    Write-Host "BuildMain phase completed." -ForegroundColor Green
}

# ============================================================================
# Phase: Verify
# ============================================================================
function Invoke-PhaseVerify {
    Write-Host "[Phase: Verify] Checking rv.exe" -ForegroundColor Cyan
    $rvExe = Join-Path $WorkDir '_build\stage\app\bin\rv.exe'
    if (-not (Test-Path $rvExe)) {
        Write-Host "ERROR: rv.exe not found at $rvExe" -ForegroundColor Red
        $logFiles = Get-ChildItem -Path $BuildLogDir -Filter "*.log" -ErrorAction SilentlyContinue
        foreach ($log in $logFiles) {
            Write-BuildTail -LogPath $log.FullName -TailLines 100 -IncludeErrors
        }
        throw "Build verification failed: rv.exe not found"
    }
    Write-Host "Verify OK: $rvExe" -ForegroundColor Green
}

# ============================================================================
# Main
# ============================================================================
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "OpenRV Windows Build" -ForegroundColor Cyan
Write-Host "Tag: $Tag | Phase: $Phase | WorkDir: $WorkDir" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($Phase -notin @('Clone', 'Venv')) {
    Initialize-BuildEnv | Out-Null
} else {
    Write-Host "Skipping VS environment init for $Phase phase." -ForegroundColor Yellow
}

if ($Phase -eq 'All') {
    Invoke-PhaseClone
    Invoke-PhaseVenv
    Invoke-PhaseConfigure
    # Single build step for "All" - build main_executable (pulls in deps); log to file and tail on failure
    New-Item -ItemType Directory -Path $BuildLogDir -Force | Out-Null
    $logFile = Join-Path $BuildLogDir "build_all.log"
    $cpuCount = [Environment]::ProcessorCount
    Push-Location $WorkDir
    try {
        & cmake --build $buildDir --config Release --parallel $cpuCount --target main_executable 2>&1 | Tee-Object -FilePath $logFile
        if ($LASTEXITCODE -ne 0) {
            Write-BuildTail -LogPath $logFile -TailLines $TailLinesOnFailure -IncludeErrors
            throw "CMake build failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
    Invoke-PhaseVerify
} else {
    switch ($Phase) {
        'Clone'               { Invoke-PhaseClone }
        'Venv'                { Invoke-PhaseVenv }
        'Configure'           { Invoke-PhaseConfigure }
        'BuildDependencies'   { Invoke-PhaseBuildDependencies }
        'BuildMain'           { Invoke-PhaseBuildMain }
        'Verify'              { Invoke-PhaseVerify }
    }
}

Write-Host "========================================" -ForegroundColor Green
Write-Host "SUCCESS: Phase '$Phase' completed" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
