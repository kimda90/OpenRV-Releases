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

$opensslCmake = Join-Path $WorkDir 'cmake\dependencies\openssl.cmake'
if (Test-Path $opensslCmake) {
    $opensslRenameScript = Join-Path $WorkDir 'cmake\dependencies\openssl_rename_importlibs.cmake'
    @'
if(NOT DEFINED OPENSSL_INSTALL_DIR OR NOT DEFINED OPENSSL_LIB_DIR)
  message(FATAL_ERROR "OPENSSL_INSTALL_DIR and OPENSSL_LIB_DIR are required")
endif()

function(copy_import_lib canonical_name prefixed_name)
  set(src "")
  file(MAKE_DIRECTORY "${OPENSSL_LIB_DIR}")
  if(EXISTS "${OPENSSL_INSTALL_DIR}/lib/${prefixed_name}")
    set(src "${OPENSSL_INSTALL_DIR}/lib/${prefixed_name}")
  elseif(EXISTS "${OPENSSL_INSTALL_DIR}/lib/${canonical_name}")
    set(src "${OPENSSL_INSTALL_DIR}/lib/${canonical_name}")
  elseif(EXISTS "${OPENSSL_INSTALL_DIR}/lib64/${prefixed_name}")
    set(src "${OPENSSL_INSTALL_DIR}/lib64/${prefixed_name}")
  elseif(EXISTS "${OPENSSL_INSTALL_DIR}/lib64/${canonical_name}")
    set(src "${OPENSSL_INSTALL_DIR}/lib64/${canonical_name}")
  endif()

  if(src STREQUAL "")
    file(GLOB_RECURSE found_prefixed
      "${OPENSSL_INSTALL_DIR}/*/${prefixed_name}"
      "${OPENSSL_INSTALL_DIR}/${prefixed_name}"
    )
    file(GLOB_RECURSE found_canonical
      "${OPENSSL_INSTALL_DIR}/*/${canonical_name}"
      "${OPENSSL_INSTALL_DIR}/${canonical_name}"
    )
    if(found_prefixed)
      list(GET found_prefixed 0 src)
    elseif(found_canonical)
      list(GET found_canonical 0 src)
    endif()
  endif()

  if(src STREQUAL "")
    if(prefixed_name MATCHES "ssl")
      set(_keyword "ssl")
    else()
      set(_keyword "crypto")
    endif()
    file(GLOB_RECURSE found_keyword
      "${OPENSSL_INSTALL_DIR}/*${_keyword}*.lib"
    )
    list(FILTER found_keyword EXCLUDE REGEX "static")
    if(found_keyword)
      list(GET found_keyword 0 src)
    endif()
  endif()

  if(src STREQUAL "" AND DEFINED OPENSSL_SOURCE_DIR AND NOT OPENSSL_SOURCE_DIR STREQUAL "")
    file(GLOB_RECURSE found_src_prefixed
      "${OPENSSL_SOURCE_DIR}/*/${prefixed_name}"
      "${OPENSSL_SOURCE_DIR}/${prefixed_name}"
    )
    file(GLOB_RECURSE found_src_canonical
      "${OPENSSL_SOURCE_DIR}/*/${canonical_name}"
      "${OPENSSL_SOURCE_DIR}/${canonical_name}"
    )
    if(found_src_prefixed)
      list(GET found_src_prefixed 0 src)
    elseif(found_src_canonical)
      list(GET found_src_canonical 0 src)
    endif()
  endif()

  if(src STREQUAL "" AND DEFINED OPENSSL_SOURCE_DIR AND NOT OPENSSL_SOURCE_DIR STREQUAL "")
    if(prefixed_name MATCHES "ssl")
      set(_keyword "ssl")
    else()
      set(_keyword "crypto")
    endif()
    file(GLOB_RECURSE found_src_keyword
      "${OPENSSL_SOURCE_DIR}/*${_keyword}*.lib"
    )
    list(FILTER found_src_keyword EXCLUDE REGEX "static")
    if(found_src_keyword)
      list(GET found_src_keyword 0 src)
    endif()
  endif()

  if(src STREQUAL "")
    message(WARNING "OpenSSL import library not found for ${canonical_name}. Tried direct and recursive search for ${prefixed_name} and ${canonical_name} under ${OPENSSL_INSTALL_DIR} and OPENSSL_SOURCE_DIR=${OPENSSL_SOURCE_DIR}. Continuing without rename.")
    return()
  endif()

  file(COPY_FILE "${src}" "${OPENSSL_LIB_DIR}/${canonical_name}" ONLY_IF_DIFFERENT)
endfunction()

copy_import_lib("ssl.lib" "libssl.lib")
copy_import_lib("crypto.lib" "libcrypto.lib")
'@ | Set-Content -Path $opensslRenameScript -Encoding ASCII -NoNewline

    $content = Get-Content $opensslCmake -Raw
    if ($content -notmatch 'openssl_rename_importlibs\.cmake') {
        $pattern = 'COMMAND \$\{CMAKE_COMMAND\} -E copy \$\{RV_DEPS_OPENSSL_INSTALL_DIR\}/lib/libssl\.lib \$\{_lib_dir\}/ssl\.lib\s*[\r\n]+\s*COMMAND \$\{CMAKE_COMMAND\} -E copy \$\{RV_DEPS_OPENSSL_INSTALL_DIR\}/lib/libcrypto\.lib \$\{_lib_dir\}/crypto\.lib'
        $replacement = 'COMMAND ${CMAKE_COMMAND} -DOPENSSL_INSTALL_DIR=${RV_DEPS_OPENSSL_INSTALL_DIR} -DOPENSSL_SOURCE_DIR=${_source_dir} -DOPENSSL_LIB_DIR=${_lib_dir} -P ${PROJECT_SOURCE_DIR}/cmake/dependencies/openssl_rename_importlibs.cmake'
        $updated = [regex]::Replace($content, $pattern, $replacement)
        if ($updated -eq $content) {
            throw "openssl patch failed: expected import-lib rename commands not found in $opensslCmake"
        }
        Set-Content $opensslCmake -Value $updated -NoNewline
        Write-Host 'OpenSSL: import-lib rename now handles ssl/libssl + crypto/libcrypto (lib/lib64).' -ForegroundColor Green
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
