# OpenRV-builds

CI/CD that builds [Open RV](https://github.com/AcademySoftwareFoundation/OpenRV) from **upstream tags** and publishes binaries to GitHub Releases. This repository is **not** a fork of OpenRV; it only contains build and release automation.

## Triggering a release

Mainline is currently pinned to **OpenRV `v3.1.0`**.

1. Create and push tag `v3.1.0` on the **current repository**. The workflow builds the **upstream** [AcademySoftwareFoundation/OpenRV](https://github.com/AcademySoftwareFoundation/OpenRV) at that same tag.
2. Example:
   ```bash
   git tag v3.1.0
   git push origin v3.1.0
   ```
3. The [OpenRV Release](.github/workflows/openrv-release.yml) workflow runs: Linux (Rocky 9), Linux (Ubuntu 22.04, optional), and Windows builds, then creates a GitHub Release and attaches artifacts.

## Release-to-commit pinning

Each published release is tied to a specific `OpenRV-builds` commit.

- This commit supports **OpenRV `v3.1.0` only**.
- To build an older OpenRV tag, checkout the matching historical commit in this repository (from this repo's GitHub Releases/tags), then run the pipeline from that commit.
- Current mainline tracks only the latest maintained target tag.

## OpenRV 3.0.0 vs 3.1.0 (what changed for this pipeline)

This branch is pinned to `v3.1.0` because upstream build internals changed in ways that affect our CI patching/scripts.

- **Dependency version plumbing moved to central defaults**: many values that were hardcoded inside `cmake/dependencies/*.cmake` in `v3.0.0` are now provided through variables from defaults files (for example FFmpeg/GLEW/OpenSSL-related values).
- **FFmpeg dependency script was refactored**: `ffmpeg.cmake` in `v3.1.0` relies on `RV_DEPS_FFMPEG_VERSION*` variables and different configure/library naming logic, so our Windows full-file FFmpeg customization had to be rebased for `v3.1.0`.
- **`rvcmds.sh` changed significantly**: upstream alias/environment handling moved to the newer `RV_BUILD_DIR`-style flow and updated command aliases, so Linux-side patching/paths were aligned to that layout.
- **Qt configure usage is standardized**: `v3.1.0` expects `RV_DEPS_QT_LOCATION` in configure paths used by our scripts.

Practical result:

- The current scripts and patch assets in this commit target `v3.1.0` only.
- For `v3.0.0` or any other tag, use the matching historical `OpenRV-builds` commit from this repo's Releases/tags.

## Where artifacts appear

- **GitHub Releases**: For the tag you pushed (e.g. [Releases](https://github.com/YOUR_ORG/OpenRV-builds/releases)).
- **Artifact names**:
  - `OpenRV-<TAG>-windows-x86_64.zip`
  - `OpenRV-<TAG>-linux-rocky9-x86_64.tar.xz`
  - `OpenRV-<TAG>-linux-ubuntu22.04-x86_64.tar.xz` (if the Ubuntu job succeeded)

Archive contents are the contents of OpenRV’s `_build/stage/` directory (e.g. `app/bin/rv`, libraries, and support files).

## Local reproduction

### Linux (Rocky 9)

1. From the repo root:
   ```bash
   docker build -f ci/linux/Dockerfile.rocky9 -t openrv-build-rocky9 .
   mkdir -p out
   docker run --rm \
     -e OPENRV_TAG=v3.1.0 \
     -e OPENRV_REPO=https://github.com/AcademySoftwareFoundation/OpenRV.git \
     -e DISTRO_SUFFIX=linux-rocky9 \
     -v "$(pwd)/out:/out" \
     openrv-build-rocky9
   ```
2. The tarball is written to `out/OpenRV-<TAG>-linux-rocky9-x86_64.tar.xz`.
   - Set `OPENRV_ARCHIVE_FORMAT=gz` to use gzip instead (faster, larger files).

### Linux (Ubuntu 22.04, experimental)

Same idea with the Ubuntu Dockerfile:

```bash
docker build -f ci/linux/Dockerfile.ubuntu22.04 -t openrv-build-ubuntu .
docker run --rm -e OPENRV_TAG=v3.1.0 -e DISTRO_SUFFIX=linux-ubuntu22.04 -v "$(pwd)/out:/out" openrv-build-ubuntu
```

### Windows

1. **Prerequisites**: Visual Studio 2022 (Desktop C++, MSVC v143 14.40), Python 3.11 (as `python3.exe`), CMake 3.27+, Qt 6.5.3 (MSVC 2019 64-bit), Strawberry Perl, Rust 1.92+, MSYS2 with **MinGW64** and the pacman packages listed in the [OpenRV Windows docs](https://aswf-openrv.readthedocs.io/en/latest/build_system/config_windows.html) (autotools, glew, libarchive, make, meson, toolchain, autoconf, automake, bison, flex, git, libtool, nasm, p7zip, patch, unzip, zip).
2. **PATH order** (in the shell that runs the build): CMake → Python → Rust (`.cargo/bin`) → `msys64\mingw64\bin` → … → **Strawberry Perl last**. Set `ACLOCAL_PATH=/c/msys64/usr/share/aclocal` and `MSYSTEM=MINGW64` when using MSYS2 bash. **OpenSSL** is built from source by OpenRV and requires **Strawberry Perl** (`WIN_PERL` / `RV_DEPS_WIN_PERL_ROOT`); the CI sets these and uses `setup-msbuild` so `nmake` is available. For Python wheel build issues (e.g. OpenTimelineIO FileTracker errors), CI sets `CL=/FS` and `DISTUTILS_USE_SDK=1`.
3. Clone OpenRV to a **short path** (e.g. `C:\OpenRV`) to avoid path length limits.
4. From PowerShell (with `QT_HOME`, `WIN_PERL`, and `PATH` set as above):
   ```powershell
   .\ci\windows\build_windows.ps1 -Tag v3.1.0 -WorkDir C:\OpenRV
   .\ci\windows\package_windows.ps1 -OpenRVRoot C:\OpenRV -Tag v3.1.0 -OutDir dist
   ```
5. Output: `dist\OpenRV-<TAG>-windows-x86_64.zip`.

## Optional: Blackmagic Decklink and NDI (all platforms)

### Enabling in CI

To build **with** Blackmagic DeckLink and/or NDI SDK support in CI, add these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Description |
|--------|-------------|
| **BMD_DECKLINK_SDK_ZIP_URL** | Direct URL to download the Blackmagic DeckLink SDK zip (e.g. from your own hosting after downloading from [Blackmagic Desktop Video SDK](https://www.blackmagicdesign.com/desktopvideo_sdk)). |
| **NDI_SDK_URL** | Direct URL to download the NDI SDK zip or tarball for the platform (Linux: use the NDI SDK for Linux archive; Windows: use the Windows SDK zip from [ndi.video](https://ndi.video/)). |

When set, the workflow downloads the SDKs and passes them to the OpenRV build. If either secret is unset, that plugin is skipped (same as today) and you may see the expected CMake messages about the plugin being disabled.

### Building locally without CI

If you build locally **without** these SDKs, you will see these CMake messages (expected, non-fatal):

- `Blackmagic Decklink SDK path not specified, disabling Blackmagic output plugin.`
- `NDI SDK not found, disabling NDI output plugin.`

**Blackmagic DeckLink (local):**

1. Download the [Blackmagic Desktop Video SDK](https://www.blackmagicdesign.com/desktopvideo_sdk) and note the path to the zip.
2. Pass it when configuring:  
   `-DRV_DEPS_BMD_DECKLINK_SDK_ZIP_PATH='<path>/Blackmagic_DeckLink_SDK_14.1.zip'`  
   Example (after `source rvcmds.sh`):  
   `rvcfg -DRV_DEPS_BMD_DECKLINK_SDK_ZIP_PATH='/path/to/Blackmagic_DeckLink_SDK_14.1.zip'`

**NDI (local):**

1. Download the [NDI SDK](https://ndi.video/) and install or extract it.
2. Set **NDI_SDK_ROOT** to the root of the NDI SDK before running `rvcfg` or `cmake`, e.g.  
   `export NDI_SDK_ROOT=/path/to/NDI_SDK` (Linux/macOS) or  
   `$env:NDI_SDK_ROOT = "C:\path\to\NDI SDK"` (Windows PowerShell).
3. Run `rvcfg` (or pass `-DNDI_SDK_ROOT=...` to CMake).

## Support policy

| Platform        | Support        |
|----------------|----------------|
| **Rocky 9**    | Supported      |
| **Windows**    | Supported      |
| **Ubuntu 22.04** | Experimental; job uses `continue-on-error` and does not block releases |

## Caching and build time

To keep build times down, the workflow uses caches on all platforms:

- **Linux (Rocky 9 and Ubuntu)**  
  Docker layer cache is stored in GitHub Actions cache (`type=gha`). The first run builds the full image (base, CMake, Ninja, Python, Qt, etc.); later runs reuse layers so the image build is much faster. Only the final layers (e.g. `COPY ci/`) and the actual OpenRV compile run every time.

- **Windows**  
  These are cached and install steps are skipped on cache hit:
  - **Qt 6.5.3** (`C:\Qt`) — key `openrv-qt-6.5.3-msvc2019`
  - **Strawberry Perl** (`C:\Strawberry`) — key `openrv-strawberryperl`
  - **Rust** (`%USERPROFILE%\.cargo`, `%USERPROFILE%\.rustup`) — key `openrv-rust`
  - **MSYS2** (`C:\msys64`) — key `openrv-msys2-v1` (bump the key in the workflow if you change the pacman package list)
  - **pip** — cached by `actions/setup-python` with `cache: 'pip'`

  The first run installs everything and populates the cache; subsequent runs restore and only run the OpenRV build.

### Optional: Pre-built Docker images (Linux)

For even faster Linux builds, you can build a **deps-only** image once, push it to a registry (e.g. GitHub Container Registry), and use it as the build image so CI only runs the OpenRV build inside the container (no `docker build` of the full stack each time). To do that:

1. Add a Dockerfile that builds only the environment (no `COPY ci/` or entrypoint), or use a multi-stage build whose final stage is `FROM your-deps-image`.
2. Build and push that image on a schedule or when `ci/linux/` changes (e.g. in a separate workflow).
3. In the release workflow, pull that image and run the same `docker run ... /ci/build_in_container.sh` with the appropriate env and volume.

The current workflow does not depend on a pre-built image; it uses layer caching only.

## License

Apache License 2.0. See [LICENSE](LICENSE).

## Upstream

- [AcademySoftwareFoundation/OpenRV](https://github.com/AcademySoftwareFoundation/OpenRV)  
- [Open RV documentation](https://aswf-openrv.readthedocs.io/en/latest/)
