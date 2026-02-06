# Agent guidance for OpenRV-builds

This file guides AI assistants (Cursor, Codex, etc.) working in this repository.

## Scope

This repo contains **only** build and CI configuration and scripts for building [Open RV](https://github.com/AcademySoftwareFoundation/OpenRV) from **upstream**. We do **not** modify or assume ownership of OpenRV source code; it is cloned at build time from `AcademySoftwareFoundation/OpenRV`.

## Key paths

- **`ci/linux/`** – Linux builds: `Dockerfile.ubuntu22.04`, `Dockerfile.rocky9-cy2024` (extended image), `build_in_container.sh`, `detect_qt.sh`, `patches/dav1d_use_git.patch`, `patches/dav1d_use_git_oneline.patch`, `patches/glew_fix_duplicates.patch`, `patches/glew_fix_duplicates_main.patch`, `KNOWN_ISSUES.md`
- **`ci/windows/`** – Windows builds: `build_windows.ps1`, `package_windows.ps1`
- **`.github/workflows/openrv-release.yml`** – Tag-triggered release workflow

## Build architecture

### Linux (Rocky 9)
- **Two-step image build**: (1) Build the **vanilla** image from upstream `dockerfiles/Dockerfile.Linux-Rocky9-CY2024` (tag: `openrv-rocky9-base`). (2) Build the **extended** image from `ci/linux/Dockerfile.rocky9-cy2024`, which `FROM openrv-rocky9-base` and installs missing deps (mesa-libGL-devel, libglvnd-devel, libdrm-devel, pkg-config) to fix GLEW PFNGL* redefinitions and configure checks. The run step uses the extended image (`openrv-build-rocky9`). Upstream Dockerfile is never edited.
- **Build script**: Our `ci/linux/build_in_container.sh` is mounted into the container and handles cloning, patching, building, and packaging.
- **DAV1D on Linux**: We apply a build-time patch to the cloned OpenRV's `cmake/dependencies/dav1d.cmake` so dav1d is fetched via **GIT** instead of URL zip. That gives the dependency a `.git` directory so Meson can generate `include/vcs_version.h` without "fatal: not a git repository". The build script tries `dav1d_use_git.patch` (upstream main: CONFIGURE_COMMAND split across two lines) then `dav1d_use_git_oneline.patch` (older tags: CONFIGURE_COMMAND on one line).
- **GLEW on Linux**: The GLEW commit used by OpenRV (`e1a80a9f...`) has two issues: (1) duplicate variable definitions in `src/glew.c` (lines 2059-2068), and (2) the upstream CONFIGURE_COMMAND (`cd auto && make && cd .. && make`) runs GLEW's auto-generation from the OpenGL registry, which is fragile (needs network, Perl, and `make_header.pl` can fail with newer registries). Our patch adds a `PATCH_COMMAND` to `sed` out the duplicates and replaces CONFIGURE/BUILD/INSTALL to skip auto-generation and run from the extracted `glew-<version>/` subdirectory (the pre-generated `glew.c` and `glew.h` in the archive are sufficient). The build script tries `glew_fix_duplicates_main.patch` (upstream main: has OpenGL-Registry PATCH_COMMAND, 1-space indent) then `glew_fix_duplicates.patch` (older tags: no upstream PATCH_COMMAND, 2-space indent).
- **Caching**: (1) The OpenRV clone is cached by **tag + commit SHA** (`openrv-rocky9-<tag>-<sha>`). (2) Docker layer cache: Buildx `scope=rocky9` for the vanilla image, `scope=rocky9-ext` for the extended image.

### Linux (Ubuntu 22.04, experimental)
- **Custom Dockerfile**: `ci/linux/Dockerfile.ubuntu22.04` is a translation of the upstream Rocky 9 Dockerfile with equivalent Ubuntu packages.
- **Package mapping**: See the Dockerfile for Rocky 9 → Ubuntu package mappings. Critical packages for GLEW/OpenGL include `libgl-dev`, `libglvnd-dev`, `libdrm-dev`.

### Windows
- **Pure PowerShell**: `build_windows.ps1` uses a pure PowerShell approach to avoid interpreter nesting issues (no bash/cmd/PowerShell chains).
- **VS environment**: The script imports the VS 2022 x64 environment directly into PowerShell rather than using nested `cmd /c` calls. The workflow also runs `ilammy/msvc-dev-cmd@v1` so the runner has MSVC (`cl`, `link`, INCLUDE, LIB) in the environment; the script sets `CC=cl` and `CXX=cl` so Meson and other dependency builds use MSVC instead of probing for "icl" or POSIX toolchains.
- **DAV1D on Windows**: We apply a build-time patch to the cloned OpenRV's `cmake/dependencies/dav1d.cmake` (in the Configure phase) to add `-Denable_asm=false` for the Meson build, avoiding pthread/POSIX detection issues. Patch: `ci/windows/patches/dav1d_windows_meson.patch`. We do not modify upstream source except this applied patch on the clone.
- **No alias reliance**: CMake configure and build are called directly, not via `rvcmds.sh` aliases, for reliable exit code handling.
- **Dependencies cache**: `C:\OpenRV\_build` is cached by tag + commit SHA (`openrv-windows-deps-<tag>-<sha>`). The first run for a tag builds all ~1100 dependency targets (~40+ min); re-runs or the same tag (same SHA) restore the cache and skip the Dependencies step. Overwriting the tag (new SHA) invalidates the cache so deps are rebuilt.

## Conventions

- **Shell scripts**: Bash-compatible; safe to `source` where noted (e.g. `detect_qt.sh`).
- **Windows scripts**: PowerShell (`build_windows.ps1`, `package_windows.ps1`). Avoid nested interpreters.
- **VFX platform**: CY2024. **Qt**: 6.5.3 (gcc_64 on Linux, msvc2019_64 on Windows).
- **Artifact names**: `OpenRV-${TAG}-<platform>-x86_64.<zip|tar.gz>`  
  Examples: `OpenRV-v3.2.1-windows-x86_64.zip`, `OpenRV-v3.2.1-linux-rocky9-x86_64.tar.gz`, `OpenRV-v3.2.1-linux-ubuntu22.04-x86_64.tar.gz`.
- **Build output**: OpenRV's staged binary tree is `_build/stage/`; the `rv` executable is at `_build/stage/app/bin/rv` (Linux) or `_build/stage/app/bin/rv.exe` (Windows).

## Upstream build flow

- Clone `https://github.com/AcademySoftwareFoundation/OpenRV.git`, checkout tag, `git submodule update --init --recursive`.
- **Linux/macOS**: `source rvcmds.sh` then `rvbootstrap` (first time) or `rvmk` (incremental). Set `RV_VFX_PLATFORM=CY2024` and `QT_HOME` (or `CMAKE_PREFIX_PATH`) before sourcing.
- **Windows (our approach)**: We bypass `rvcmds.sh` aliases and call cmake directly for reliability. See `build_windows.ps1`.

## Testing

- **Local Linux (Rocky 9)**: Clone OpenRV, build vanilla image from upstream `dockerfiles/Dockerfile.Linux-Rocky9-CY2024` (tag e.g. `openrv-rocky9-base`), then build extended image from `ci/linux/Dockerfile.rocky9-cy2024`, run container with `build_in_container.sh` and `ci/linux` mounted at `/ci`, mount `/out` to collect artifacts.
- **Local Windows**: Install prerequisites (VS 2022, Python 3.11, CMake, Qt 6.5.3, Perl, Rust, MSYS2); run `build_windows.ps1` then `package_windows.ps1`.
- **CI**: Push a tag matching `v*` (e.g. `v3.2.1`) to trigger the workflow; artifacts are published to the GitHub Release for that tag.

## Caching

- **Linux**: Docker layer cache via Buildx (`cache-from`/`cache-to` type=gha, with `scope` per distro).
- **Windows**: `actions/cache` for Qt, Strawberry Perl, Rust, MSYS2, and pip. Cache keys are in `.github/workflows/openrv-release.yml` (e.g. `openrv-msys2-v1`). When changing the MSYS2 pacman package list or Qt version, bump the corresponding cache key so the next run repopulates the cache.

## Optional dependencies (BMD DeckLink, NDI)

- **CI**: To build **with** Blackmagic and/or NDI, set repository secrets **BMD_DECKLINK_SDK_ZIP_URL** and/or **NDI_SDK_URL** (direct download URLs). The workflow downloads the SDKs and passes them into the build. If unset, those plugins are skipped and the usual CMake messages appear (non-fatal).
- **rvcmds.sh patch**: On Linux, `build_in_container.sh` patches `rvcmds.sh` to append `${RV_CFG_EXTRA}` to the cmake invocation.
- **Windows**: `build_windows.ps1` passes BMD/NDI paths directly to cmake via command-line arguments.
- **Local builds**: See README for passing BMD zip path and NDI_SDK_ROOT when building outside CI.

## Error handling

- **Linux**: `build_in_container.sh` searches for errors in ExternalProject logs (e.g., `*GLEW*build*.log`) and outputs them on failure.
- **Windows**: `build_windows.ps1` scans `_build` for `*.log` files containing error patterns on failure.

## Known issues

- **GLEW build failures**: Usually caused by missing OpenGL development packages. Ensure `libgl-dev`, `libglvnd-dev`, `libdrm-dev` (Ubuntu) or equivalent packages are installed.
- **Windows exit code 0 but no rv.exe**: Previously caused by alias expansion issues in nested bash. Now resolved by using direct cmake calls.

## Support policy

- **Rocky 9** artifact: supported.
- **Windows** artifact: supported.
- **Ubuntu 22.04** artifact: experimental; job uses `continue-on-error` and does not block releases.
