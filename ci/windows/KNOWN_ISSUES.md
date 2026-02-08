# Known issues (Windows CI)

## DAV1D and POSIX/compiler detection

- **DAV1D** (AV1 decoder) is built via Meson. On Windows, Meson can incorrectly detect the Intel C++ compiler ("icl") or try to use POSIX headers (e.g. `pthread.h`, `unistd.h`), leading to "The system cannot find the file specified" for `icl` or missing-header errors.
- **Fixes applied in this repo**:
  - **MSVC environment**: The workflow uses `ilammy/msvc-dev-cmd@v1` so the runner has `cl`, `link`, `INCLUDE`, and `LIB` set. `build_windows.ps1` also sets `CC=cl` and `CXX=cl` after configuring the VS environment so Meson and other subprocesses use MSVC.
  - **DAV1D Meson options**: We apply a build-time patch to the cloned OpenRV's `cmake/dependencies/dav1d.cmake` (see `ci/windows/patches/dav1d_windows_meson.patch`) to add `-Denable_asm=false` for the Meson configure command. This avoids asm/POSIX detection issues on Windows. The patch is applied in the Configure phase; if it fails (e.g. upstream changed the file), the build continues with a warning.
- **C11 atomics / vcruntime**: If you see errors about `vcruntime_c11_stdatomic.h` or C11 support, ensure the build agent has a recent Visual Studio 2022 and Windows SDK. We do not modify OpenRV source beyond the DAV1D build-time patch.

## OpenSSL and ffmpeg

- OpenRV **builds OpenSSL from source** on Windows (see upstream `cmake/dependencies/openssl.cmake`). It requires:
  - **Strawberry Perl**: set `WIN_PERL` (and optionally `RV_DEPS_WIN_PERL_ROOT`) to e.g. `C:/Strawberry/perl/bin` so `make_openssl.py` can run `perl Configure` and `nmake`.
  - **nmake** in PATH: the OpenSSL build uses MSVC’s `nmake`. CI uses `microsoft/setup-msbuild` so the VS environment (and thus `nmake`) is available. If building locally, run from a **Developer Command Prompt** or ensure the VC tools directory is on PATH.
- If OpenSSL is not built successfully, **ffmpeg** (which depends on OpenSSL) will fail, and the main `rv.exe` build will not complete.

## OpenTimelineIO / FileTracker

- Building Python wheels that compile C extensions (e.g. OpenTimelineIO) on Windows can hit **FileTracker** (MSVC) errors. CI mitigates by setting:
  - `CL=/FS` (force synchronous PDB writes)
  - `DISTUTILS_USE_SDK=1`
- If wheel build failures persist, consider using pre-built wheels where possible or updating the upstream `requirements.txt` / build isolation.
