# Known issues (Windows CI)

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
