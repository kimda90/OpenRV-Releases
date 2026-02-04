# Agent guidance for OpenRV-builds

This file guides AI assistants (Cursor, Codex, etc.) working in this repository.

## Scope

This repo contains **only** build and CI configuration and scripts for building [Open RV](https://github.com/AcademySoftwareFoundation/OpenRV) from **upstream**. We do **not** modify or assume ownership of OpenRV source code; it is cloned at build time from `AcademySoftwareFoundation/OpenRV`.

## Key paths

- **`ci/linux/`** – Linux builds: `Dockerfile.rocky9`, `Dockerfile.ubuntu22.04`, `build_in_container.sh`, `detect_qt.sh`, `KNOWN_ISSUES.md`
- **`ci/windows/`** – Windows builds: `build_windows.ps1`, `package_windows.ps1`
- **`.github/workflows/openrv-release.yml`** – Tag-triggered release workflow

## Conventions

- **Shell scripts**: Bash-compatible; safe to `source` where noted (e.g. `detect_qt.sh`).
- **Windows scripts**: PowerShell (`build_windows.ps1`, `package_windows.ps1`).
- **VFX platform**: CY2024. **Qt**: 6.5.3 (gcc_64 on Linux, msvc2019_64 on Windows).
- **Artifact names**: `OpenRV-${TAG}-<platform>-x86_64.<zip|tar.gz>`  
  Examples: `OpenRV-v3.2.1-windows-x86_64.zip`, `OpenRV-v3.2.1-linux-rocky9-x86_64.tar.gz`, `OpenRV-v3.2.1-linux-ubuntu22.04-x86_64.tar.gz`.
- **Build output**: OpenRV’s staged binary tree is `_build/stage/`; the `rv` executable is at `_build/stage/app/bin/rv` (Linux/Windows).

## Upstream build flow

- Clone `https://github.com/AcademySoftwareFoundation/OpenRV.git`, checkout tag, `git submodule update --init --recursive`.
- **Linux/macOS**: `source rvcmds.sh` then `rvbootstrap` (first time) or `rvmk` (incremental). Set `RV_VFX_PLATFORM=CY2024` and `QT_HOME` (or `CMAKE_PREFIX_PATH`) before sourcing.
- **Windows**: Use a bash environment (e.g. MSYS2 MinGW64 or Git Bash) with PATH set for VS, Python, CMake, Qt, Perl, Rust, MSYS2; same `source rvcmds.sh` and `rvbootstrap`. Clone to a short path (e.g. `C:\OpenRV`) to avoid MAX_PATH issues.

## Testing

- **Local Linux (Rocky 9)**: Build image from `ci/linux/Dockerfile.rocky9`, run container with `build_in_container.sh`, mount `/out` to collect artifacts.
- **Local Windows**: Install prerequisites (VS 2022, Python 3.11, CMake, Qt 6.5.3, Perl, Rust, MSYS2); run `build_windows.ps1` then `package_windows.ps1` from a suitable environment.
- **CI**: Push a tag matching `v*` (e.g. `v3.2.1`) to trigger the workflow; artifacts are published to the GitHub Release for that tag.

## Caching

- **Linux**: Docker layer cache via Buildx (`cache-from`/`cache-to` type=gha). No manual cache keys.
- **Windows**: `actions/cache` for Qt, Strawberry Perl, Rust, MSYS2, and pip. Cache keys are in `.github/workflows/openrv-release.yml` (e.g. `openrv-msys2-v1`). When changing the MSYS2 pacman package list or Qt version, bump the corresponding cache key so the next run repopulates the cache.

## Support policy

- **Rocky 9** artifact: supported.
- **Windows** artifact: supported.
- **Ubuntu 22.04** artifact: experimental; job uses `continue-on-error` and does not block releases.
