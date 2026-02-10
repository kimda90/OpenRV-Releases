if (Test-Path "configure") {
    $configure = (Resolve-Path "configure").Path
    Write-Host "FFmpeg patch: Processing scripts in $(Split-Path $configure)"

    # Define file types to normalize: configure + .sh scripts + .mak files
    $filesToPatch = @("configure") + (Get-ChildItem -Recurse -Filter "*.sh").FullName + (Get-ChildItem -Recurse -Filter "*.mak").FullName

    # Try using dos2unix first (most reliable)
    if (Get-Command "dos2unix" -ErrorAction SilentlyContinue) {
        Write-Host "FFmpeg patch: Using system dos2unix on $($filesToPatch.Count) files..."
        foreach ($file in $filesToPatch) {
            if (Test-Path $file) { & dos2unix "$file" 2>&1 | Out-Null }
        }
    } else {
        # Fallback: Binary-safe CRLF -> LF conversion for specific target files
        Write-Host "FFmpeg patch: Using binary replacement on $($filesToPatch.Count) files..."
        foreach ($file in $filesToPatch) {
            if (-not (Test-Path $file)) { continue }

            $bytes = [System.IO.File]::ReadAllBytes($file)
            $changed = $false
            $out = New-Object System.Collections.Generic.List[byte] ($bytes.Length)
            for ($i = 0; $i -lt $bytes.Length; $i++) {
                # Replace CRLF (13,10) with LF (10) without decoding/recoding the file.
                if ($i -lt ($bytes.Length - 1) -and $bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10) {
                    $out.Add(10) | Out-Null
                    $i++
                    $changed = $true
                } else {
                    $out.Add($bytes[$i]) | Out-Null
                }
            }
            if ($changed) { [System.IO.File]::WriteAllBytes($file, $out.ToArray()) }
        }
    }

    # ----------------------------------------------------------------
    # OpenSSL import-lib compatibility for FFmpeg MSVC toolchain
    # FFmpeg maps -lssl/-lcrypto to ssl.lib/crypto.lib, but OpenSSL builds
    # produce libssl.lib/libcrypto.lib. Re-copy aliases every time.
    # ----------------------------------------------------------------
    try {
        $srcDir = Split-Path $configure -Parent
        $ffmpegRoot = Split-Path $srcDir -Parent              # ...\RV_DEPS_FFMPEG
        $buildRoot = Split-Path $ffmpegRoot -Parent           # ...\_build
        $opensslLibDir = Join-Path $buildRoot "RV_DEPS_OPENSSL\\install\\lib"
        if (-not (Test-Path $opensslLibDir)) { $opensslLibDir = Join-Path $buildRoot "RV_DEPS_OPENSSL\\install\\lib64" }

        if (Test-Path $opensslLibDir) {
            Write-Host "FFmpeg patch: OpenSSL lib dir: $opensslLibDir"
            $libFiles = Get-ChildItem -Path $opensslLibDir -Filter "*.lib" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
            if ($libFiles) {
                Write-Host "FFmpeg patch: OpenSSL .lib files: $($libFiles -join ', ')"
            } else {
                Write-Warning "FFmpeg patch: No .lib files found in $opensslLibDir"
            }
        } else {
            Write-Warning "FFmpeg patch: OpenSSL lib dir not found: $opensslLibDir"
        }

        $aliases = @(
            @{ From = "libssl.lib";    To = "ssl.lib" },
            @{ From = "libcrypto.lib"; To = "crypto.lib" },
            @{ From = "ssl.lib";       To = "libssl.lib" },
            @{ From = "crypto.lib";    To = "libcrypto.lib" }
        )

        foreach ($pair in $aliases) {
            $fromPath = Join-Path $opensslLibDir $pair.From
            $toPath = Join-Path $opensslLibDir $pair.To
            if (Test-Path $fromPath) {
                Copy-Item -Force $fromPath $toPath
                Write-Host "FFmpeg patch: OpenSSL alias ensured: $($pair.From) -> $($pair.To)" -ForegroundColor Green
            }
        }

        if (-not (Test-Path (Join-Path $opensslLibDir "ssl.lib"))) {
            Write-Warning "FFmpeg patch: ssl.lib is still missing after alias pass."
        }
        if (-not (Test-Path (Join-Path $opensslLibDir "crypto.lib"))) {
            Write-Warning "FFmpeg patch: crypto.lib is still missing after alias pass."
        }
    } catch {
        Write-Warning "FFmpeg patch: OpenSSL alias step failed: $($_.Exception.Message)"
    }

    # ----------------------------------------------------------------
    # MANDATORY FIX: Hardcode cl_major_ver in configure
    # This must run regardless of how line endings were fixed.
    # ----------------------------------------------------------------
    if (Test-Path $configure) {
        $text = [System.IO.File]::ReadAllText($configure)
        if ($text -match '(?m)^[ \t]*cl_major_ver=19[ \t]*\r?$') {
            Write-Host "FFmpeg patch: cl_major_ver already hardcoded"
        } elseif ($text -match 'cl_major_ver=') {
            # FFmpeg's cl_major_ver line contains '\)' inside the sed script, so avoid
            # a non-greedy match that stops at the first ')' and corrupts configure.
            $regex = '(?m)^([ \t]*)cl_major_ver=\$\(cl\.exe[^\n]*\)[ \t]*\r?$'
            $newText = [System.Text.RegularExpressions.Regex]::Replace($text, $regex, '$1cl_major_ver=19')

            if ($text -eq $newText) {
                # Fallback: match any command-substitution assignment to cl_major_ver
                $regex = '(?m)^([ \t]*)cl_major_ver=\$\([^\n]*\)[ \t]*\r?$'
                $newText = [System.Text.RegularExpressions.Regex]::Replace($text, $regex, '$1cl_major_ver=19')
            }

            if ($text -ne $newText) {
                $utf8NoBOM = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($configure, $newText, $utf8NoBOM)
                Write-Host "FFmpeg patch: Hardcoded cl_major_ver=19" -ForegroundColor Green
            } else {
                Write-Warning "FFmpeg patch: Could not match cl_major_ver detection line! Verify regex."
            }
        }
    }

    # Log the final cl_major_ver assignment (useful when debugging configure parse errors)
    $clLine = $null
    try {
        $m = Select-String -Path $configure -Pattern '^[ \t]*cl_major_ver=' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($m) { $clLine = $m.Line }
    } catch {}
    if ($clLine) { Write-Host "FFmpeg patch: cl_major_ver => $clLine" }

    # Sanity check: ensure configure is still syntactically valid under bash (catches accidental corruption early)
    $bashExe = $env:RV_MSYS_BASH
    if (-not $bashExe -or -not (Test-Path $bashExe)) {
        $bashExe = (Get-Command bash.exe -ErrorAction SilentlyContinue).Source
    }
    if ($bashExe -and (Test-Path $bashExe)) {
        Write-Host "FFmpeg patch: Syntax check: $bashExe -n configure"
        $syntaxOut = & $bashExe -n configure 2>&1
        $syntaxExit = $LASTEXITCODE
        if ($syntaxOut) { $syntaxOut | ForEach-Object { Write-Host $_ } }
        if ($syntaxExit -ne 0) { throw "FFmpeg patch: configure failed syntax check" }
    } else {
        Write-Warning "FFmpeg patch: bash.exe not found; skipping configure syntax check."
    }

    # Verification (check configure only)
    $checkBytes = [System.IO.File]::ReadAllBytes($configure)
    $hasCR = $false
    for ($i = 0; $i -lt [Math]::Min($checkBytes.Length, 1000); $i++) {
        if ($checkBytes[$i] -eq 13) { $hasCR = $true; break }
    }
    if ($hasCR) {
        Write-Warning "FFmpeg patch: CR bytes detected in configure script! Build may fail."
    } else {
        Write-Host "FFmpeg patch: Verified no CR bytes in header."
    }
}
