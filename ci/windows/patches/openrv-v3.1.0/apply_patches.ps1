param(
    [Parameter(Mandatory = $true)]
    [string]$WorkDir,
    [Parameter(Mandatory = $true)]
    [hashtable]$EnvInfo,
    [Parameter(Mandatory = $true)]
    [string]$PatchShimPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$dav1dCmake = Join-Path $WorkDir 'cmake\dependencies\dav1d.cmake'
if (Test-Path $dav1dCmake) {
    $content = Get-Content $dav1dCmake -Raw
    if ($content -notmatch '-Denable_asm=false') {
        $updated = $content -replace '-Denable_tools=false', '-Denable_tools=false -Denable_asm=false'
        if ($updated -eq $content) {
            throw "DAV1D patch failed: expected '-Denable_tools=false' token not found in $dav1dCmake"
        }
        Set-Content $dav1dCmake -Value $updated -NoNewline
        Write-Host 'DAV1D: added -Denable_asm=false to CONFIGURE_COMMAND.' -ForegroundColor Green
    }
}

$atomicOpsCmake = Join-Path $WorkDir 'cmake\dependencies\atomic_ops.cmake'
if (Test-Path $atomicOpsCmake) {
    $content = Get-Content $atomicOpsCmake -Raw
    if ($content -notmatch 'CC=gcc CXX=g\+\+') {
        $updated = $content -replace 'CONFIGURE_COMMAND \$\{_autogen_command\} && \$\{_configure_command\} \$\{_configure_args\}', 'CONFIGURE_COMMAND "$${CMAKE_COMMAND}" -E env CC=gcc CXX=g++ $${_autogen_command} && "$${CMAKE_COMMAND}" -E env CC=gcc CXX=g++ $${_configure_command} $${_configure_args}'
        if ($updated -eq $content) {
            throw "atomic_ops patch failed: expected configure command pattern not found in $atomicOpsCmake"
        }
        Set-Content $atomicOpsCmake -Value $updated -NoNewline
        Write-Host 'atomic_ops: CONFIGURE_COMMAND now uses gcc for both autogen and configure.' -ForegroundColor Green
    }
}

$pcre2Cmake = Join-Path $WorkDir 'cmake\dependencies\pcre2.cmake'
if (Test-Path $pcre2Cmake) {
    $content = Get-Content $pcre2Cmake -Raw
    if ($content -notmatch 'CC=gcc CXX=g\+\+') {
        $updated = $content -replace 'CONFIGURE_COMMAND \$\{_pcre2_autogen_command\} && \$\{_pcre2_configure_command\} \$\{_pcre2_configure_args\}', 'CONFIGURE_COMMAND "$${CMAKE_COMMAND}" -E env CC=gcc CXX=g++ $${_pcre2_autogen_command} && "$${CMAKE_COMMAND}" -E env CC=gcc CXX=g++ $${_pcre2_configure_command} $${_pcre2_configure_args}'
        $updated = $updated -replace 'BUILD_COMMAND make -j\$\{_cpu_count\}', 'BUILD_COMMAND "$${CMAKE_COMMAND}" -E env CC=gcc CXX=g++ make -j$${_cpu_count}'
        if ($updated -eq $content) {
            throw "pcre2 patch failed: expected patterns not found in $pcre2Cmake"
        }
        Set-Content $pcre2Cmake -Value $updated -NoNewline
        Write-Host 'pcre2: CONFIGURE_COMMAND/BUILD_COMMAND now use gcc.' -ForegroundColor Green
    }
}

$ffmpegTarget = Join-Path $WorkDir 'cmake\dependencies\ffmpeg.cmake'
$ffmpegTemplate = Join-Path $PSScriptRoot 'ffmpeg_windows_patched.cmake'
if (-not (Test-Path $ffmpegTemplate)) {
    throw "FFmpeg patched template not found: $ffmpegTemplate"
}

$content = Get-Content $ffmpegTemplate -Raw
$shimPath = ($PatchShimPath -replace '\\', '/')
$content = $content -replace '@FFMPEG_PATCH_SHIM@', $shimPath

$msysBinDir = $EnvInfo.MsysBinPaths[0] -replace '\\', '/'
$msysBash = "$msysBinDir/bash.exe"
if (-not (Test-Path $msysBash)) { $msysBash = "$msysBinDir/sh.exe" }
if ($msysBash -notmatch 'C:/msys64') {
    $content = $content.Replace('"C:/msys64/usr/bin/bash.exe"', '"' + $msysBash + '"')
}

Set-Content $ffmpegTarget -Value $content -NoNewline
Write-Host 'FFmpeg: replaced ffmpeg.cmake with v3.1.0 patched template.' -ForegroundColor Green
