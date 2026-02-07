# Agent guidance for OpenRV-builds

This file guides AI assistants (Cursor, Codex, etc.) working in this repository.

## Scope

This repo contains **only** build and CI configuration and scripts for building [Open RV](https://github.com/AcademySoftwareFoundation/OpenRV) from **upstream**. We do **not** modify or assume ownership of OpenRV source code; it is cloned at build time from `AcademySoftwareFoundation/OpenRV`.

## Key paths

- **`ci/linux/`** – Linux builds: `Dockerfile.rocky8-extended`, `Dockerfile.ubuntu22.04`, `Dockerfile.rocky9-cy2024` (extended images only; vanilla from upstream), `build_in_container.sh`, `detect_qt.sh`, `patches/`, `KNOWN_ISSUES.md`
- **`ci/windows/`** – Windows builds: `build_windows.ps1`, `package_windows.ps1`
- **`.github/workflows/openrv-release.yml`** – Tag-triggered release workflow

## Build architecture

### Linux (Rocky 9)
- **Two-step image build**: (1) Build the **vanilla** image from upstream `dockerfiles/Dockerfile.Linux-Rocky9-CY2024` (tag: `openrv-rocky9-base`). (2) Build the **extended** image from `ci/linux/Dockerfile.rocky9-cy2024`, which `FROM openrv-rocky9-base` and installs missing deps (mesa-libGL-devel, libglvnd-devel, libdrm-devel, pkg-config) to fix GLEW PFNGL* redefinitions and configure checks. The run step uses the extended image (`openrv-build-rocky9`). Upstream Dockerfile is never edited.
- **Build script**: Our `ci/linux/build_in_container.sh` is mounted into the container and handles cloning, patching, building, and packaging. When `OPENRV_BUILD_CACHE_DIR` is set (CI), the workflow mounts the build cache at that path (e.g. `/home/rv/openrv-build-cache`) and the script symlinks `OpenRV/_build` to it after cloning, so Docker never creates `OpenRV` as root. Without `OPENRV_BUILD_CACHE_DIR`, the script preserves an existing `_build` mount during clone (see Caching).
- **DAV1D on Linux**: We apply a build-time patch to the cloned OpenRV's `cmake/dependencies/dav1d.cmake` so dav1d is fetched via **GIT** instead of URL zip. That gives the dependency a `.git` directory so Meson can generate `include/vcs_version.h` without "fatal: not a git repository". The build script tries `dav1d_use_git.patch` (upstream main: CONFIGURE_COMMAND split across two lines) then `dav1d_use_git_oneline.patch` (older tags: CONFIGURE_COMMAND on one line).
- **GLEW on Linux**: We upgrade GLEW to **2.3.0** at build time by editing the cloned `cmake/dependencies/glew.cmake` (version string, URL hash, and library version). GLEW 2.3.0 fixes the duplicate variable definitions (Issue #449); no GLEW patches are applied.
- **GC (bdwgc) on Linux**: bdwgc may install headers flat (`include/gc.h`) while OpenRV expects `include/gc/gc.h`. After `rvcfg`, the script builds the `dependencies` target, then if `OPENRV_FIX_GC_INCLUDE` is not `0` (default `1`), it creates `install/include/gc/` and copies `gc.h` and `gc_allocator.h` there when needed. Set **`OPENRV_FIX_GC_INCLUDE=0`** to skip this fix (e.g. if your bdwgc already installs the nested layout).
- **Caching**: (1) The OpenRV clone is cached by **tag + commit SHA** (`openrv-rocky9-<tag>-<sha>`). (2) Docker layer cache: Buildx `scope=rocky9` for the vanilla image, `scope=rocky9-ext` for the extended image. (3) Build cache: the host directory `openrv-build-cache-rocky9` is mounted at `/home/rv/openrv-build-cache` and `OPENRV_BUILD_CACHE_DIR` is set so the script symlinks `OpenRV/_build` to it (avoids Docker creating `OpenRV` as root). Cache is restored/saved via `actions/cache` with a **tag + SHA prefix** for incremental resumes.

### Linux (Rocky 8)
- **Two-step image build**: (1) Build the **vanilla** image from upstream `dockerfiles/Dockerfile.Linux-Rocky8` in the cloned repo (tag: `openrv-rocky8-base`). (2) Build the **extended** image from `ci/linux/Dockerfile.rocky8-extended`, which `FROM openrv-rocky8-base` and installs mesa-libGL-devel, libglvnd-devel, libdrm-devel, pkg-config. Upstream Dockerfile is never edited.
- **VFX platform**: Rocky 8 job passes `RV_VFX_PLATFORM=CY2023`; `detect_qt.sh` supports CY2023 and finds Qt 5.15 in `~/Qt/5.15.2/gcc_64`. Artifact runs on Rocky 8 (and typically on Rocky 9) due to older glibc.
- **Caching**: Buildx `scope=rocky8` for vanilla; build cache mounted at `/home/rv/openrv-build-cache` with `OPENRV_BUILD_CACHE_DIR` (same pattern as Rocky 9). Build cache key `openrv-rocky8-build-<tag>-<sha>-...`.

### Linux (Ubuntu 22.04, experimental)
- **Custom Dockerfile**: `ci/linux/Dockerfile.ubuntu22.04` is a translation of the upstream Rocky 9 Dockerfile with equivalent Ubuntu packages.
- **Package mapping**: See the Dockerfile for Rocky 9 → Ubuntu package mappings. Critical packages for GLEW/OpenGL include `libgl-dev`, `libglvnd-dev`, `libdrm-dev`.
- **OpenSSL on Ubuntu**: Upstream `make_openssl.py` installs to `install/lib64` for CY2024 on Linux, while `openssl.cmake` expects `install/lib` when `RHEL_VERBOSE` is unset (Ubuntu has no `/etc/redhat-release`). After building the dependencies target, `build_in_container.sh` copies `RV_DEPS_OPENSSL/install/lib64` into `install/lib` when needed so the linker finds `libcrypto.so.3` / `libssl.so.3`.

### Windows
- **Pure PowerShell**: `build_windows.ps1` uses a pure PowerShell approach to avoid interpreter nesting issues (no bash/cmd/PowerShell chains).
- **VS environment**: The script's `Initialize-BuildEnv` function detects if the VS environment is already initialized (by checking for `cl.exe` in PATH). If so, it skips calling `vcvarsall.bat` and uses the existing environment. This is important for GitHub Actions where `ilammy/msvc-dev-cmd@v1` pre-initializes the VS environment. For local builds without a pre-set environment, it calls `vcvarsall.bat` to set up MSVC (`cl`, `link`, INCLUDE, LIB). The script sets `CC=cl` and `CXX=cl` so Meson and other dependency builds use MSVC instead of probing for "icl" or POSIX toolchains.
- **DAV1D on Windows**: We apply a build-time patch to the cloned OpenRV's `cmake/dependencies/dav1d.cmake` (in the Configure phase) to add `-Denable_asm=false` for the Meson build, avoiding pthread/POSIX detection issues. Patch: `ci/windows/patches/dav1d_windows_meson.patch`. We do not modify upstream source except this applied patch on the clone.
- **No alias reliance**: CMake configure and build are called directly, not via `rvcmds.sh` aliases, for reliable exit code handling.
- **Build cache**: `C:\OpenRV\_build` is restored/saved via `actions/cache/{restore,save}` with a **tag + SHA prefix**. The workflow always runs `BuildDependencies`, and CMake ExternalProject stamps skip already completed deps and resume from partial progress on failures. Overwriting a tag (new SHA) invalidates the cache. The cache save step includes a guard (`hashFiles('CMakeCache.txt') != ''`) to only save when configure has successfully run.

## Conventions

- **Shell scripts**: Bash-compatible; safe to `source` where noted (e.g. `detect_qt.sh`).
- **Windows scripts**: PowerShell (`build_windows.ps1`, `package_windows.ps1`). Avoid nested interpreters.
- **VFX platform**: CY2024 (Rocky 9, Ubuntu, Windows); CY2023 (Rocky 8). **Qt**: 6.5.x (CY2024), 5.15.x (CY2023); msvc2019_64 on Windows.
- **Artifact names**: `OpenRV-${TAG}-<platform>-x86_64.<zip|tar.gz>`  
  Examples: `OpenRV-v3.2.1-windows-x86_64.zip`, `OpenRV-v3.2.1-linux-rocky9-x86_64.tar.gz`, `OpenRV-v3.2.1-linux-rocky8-x86_64.tar.gz`, `OpenRV-v3.2.1-linux-ubuntu22.04-x86_64.tar.gz`.
- **Build output**: OpenRV's staged binary tree is `_build/stage/`; the `rv` executable is at `_build/stage/app/bin/rv` (Linux) or `_build/stage/app/bin/rv.exe` (Windows).

## Upstream build flow

- Clone `https://github.com/AcademySoftwareFoundation/OpenRV.git`, checkout tag, `git submodule update --init --recursive`.
- **Linux/macOS**: `source rvcmds.sh` then `rvbootstrap` (first time) or `rvmk` (incremental). Set `RV_VFX_PLATFORM=CY2024` and `QT_HOME` (or `CMAKE_PREFIX_PATH`) before sourcing.
- **Windows (our approach)**: We bypass `rvcmds.sh` aliases and call cmake directly for reliability. See `build_windows.ps1`.

## Testing

- **Local Linux (Rocky 9)**: Clone OpenRV, build vanilla image from upstream `dockerfiles/Dockerfile.Linux-Rocky9-CY2024` (tag e.g. `openrv-rocky9-base`), then build extended image from `ci/linux/Dockerfile.rocky9-cy2024`, run container with `build_in_container.sh` and `ci/linux` mounted at `/ci`, mount `/out` to collect artifacts.
- **Local Linux (Rocky 8)**: Clone OpenRV, build vanilla image from `openrv-src/dockerfiles/Dockerfile.Linux-Rocky8` (tag `openrv-rocky8-base`), then extended from `ci/linux/Dockerfile.rocky8-extended` (tag `openrv-build-rocky8`). Run with `-e DISTRO_SUFFIX=linux-rocky8 -e RV_VFX_PLATFORM=CY2023` and same volume mounts as Rocky 9.
- **Local Windows**: Install prerequisites (VS 2022, Python 3.11, CMake, Qt 6.5.3, Perl, Rust, MSYS2); run `build_windows.ps1` then `package_windows.ps1`.
- **CI**: Push a tag matching `v*` (e.g. `v3.2.1`) to trigger the workflow; artifacts are published to the GitHub Release for that tag.

## Caching

- **Linux**: Docker layer cache via Buildx (`cache-from`/`cache-to` type=gha, with `scope` per distro). Build cache: host directory (e.g. `openrv-build-cache-rocky8`) is mounted at `/home/rv/openrv-build-cache`; the script symlinks `OpenRV/_build` to it when `OPENRV_BUILD_CACHE_DIR` is set. Cache is restored/saved via `actions/cache` with tag + SHA prefix for incremental resumes.
- **Windows**: `actions/cache` for Qt, Strawberry Perl, Rust, MSYS2, and pip. Build cache uses `actions/cache/restore` + `actions/cache/save` for `C:\OpenRV\_build`, keyed by tag + commit SHA prefix so ExternalProject stamps skip completed deps.

## Optional dependencies (BMD DeckLink, NDI)

- **CI**: To build **with** Blackmagic and/or NDI, set repository secrets **BMD_DECKLINK_SDK_ZIP_URL** and/or **NDI_SDK_URL** (direct download URLs). The workflow downloads the SDKs and passes them into the build. If unset, those plugins are skipped and the usual CMake messages appear (non-fatal).
- **rvcmds.sh patch**: On Linux, `build_in_container.sh` patches `rvcmds.sh` to append `${RV_CFG_EXTRA}` to the cmake invocation.
- **Windows**: `build_windows.ps1` passes BMD/NDI paths directly to cmake via command-line arguments.
- **Local builds**: See README for passing BMD zip path and NDI_SDK_ROOT when building outside CI.

## Error handling

- **Linux**: `build_in_container.sh` searches for errors in ExternalProject logs (e.g., `*GLEW*build*.log`) and outputs them on failure. If the build fails, it also dumps the RV_DEPS_GC install `include/` contents and any GC build logs to help diagnose `gc/gc.h: No such file or directory`.
- **Windows**: `build_windows.ps1` scans `_build` for `*.log` files containing error patterns on failure.

## Known issues

- **GLEW build failures**: Usually caused by missing OpenGL development packages. Ensure `libgl-dev`, `libglvnd-dev`, `libdrm-dev` (Ubuntu) or equivalent packages are installed.
- **gc/gc.h: No such file or directory**: The bdwgc (GC) dependency may install headers to `include/` instead of `include/gc/`. The script fixes this when `OPENRV_FIX_GC_INCLUDE` is not `0` (default). If the error persists, check the RV_DEPS_GC install dir and build logs printed on failure.
- **Windows exit code 0 but no rv.exe**: Previously caused by alias expansion issues in nested bash. Now resolved by using direct cmake calls.

## Support policy

- **Rocky 9** artifact: supported.
- **Rocky 8** artifact: supported (CY2023, runs on Rocky 8 and typically on Rocky 9).
- **Windows** artifact: supported.
- **Ubuntu 22.04** artifact: experimental; job uses `continue-on-error` and does not block releases.
