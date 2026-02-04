# OpenRV-builds

CI/CD that builds [Open RV](https://github.com/AcademySoftwareFoundation/OpenRV) from **upstream tags** and publishes binaries to GitHub Releases. This repository is **not** a fork of OpenRV; it only contains build and release automation.

## Triggering a release

1. Create and push a tag matching `v*` (e.g. `v3.2.1`) on the **current repository**. The workflow builds the **upstream** [AcademySoftwareFoundation/OpenRV](https://github.com/AcademySoftwareFoundation/OpenRV) at that same tag.
2. Example:
   ```bash
   git tag v3.2.1
   git push origin v3.2.1
   ```
3. The [OpenRV Release](.github/workflows/openrv-release.yml) workflow runs: Linux (Rocky 9), Linux (Ubuntu 22.04, optional), and Windows builds, then creates a GitHub Release and attaches artifacts.

## Where artifacts appear

- **GitHub Releases**: For the tag you pushed (e.g. [Releases](https://github.com/YOUR_ORG/OpenRV-builds/releases)).
- **Artifact names**:
  - `OpenRV-<TAG>-windows-x86_64.zip`
  - `OpenRV-<TAG>-linux-rocky9-x86_64.tar.gz`
  - `OpenRV-<TAG>-linux-ubuntu22.04-x86_64.tar.gz` (if the Ubuntu job succeeded)

Archive contents are the contents of OpenRV’s `_build/stage/` directory (e.g. `app/bin/rv`, libraries, and support files).

## Local reproduction

### Linux (Rocky 9)

1. From the repo root:
   ```bash
   docker build -f ci/linux/Dockerfile.rocky9 -t openrv-build-rocky9 .
   mkdir -p out
   docker run --rm \
     -e OPENRV_TAG=v3.2.1 \
     -e OPENRV_REPO=https://github.com/AcademySoftwareFoundation/OpenRV.git \
     -e DISTRO_SUFFIX=linux-rocky9 \
     -v "$(pwd)/out:/out" \
     openrv-build-rocky9
   ```
2. The tarball is written to `out/OpenRV-<TAG>-linux-rocky9-x86_64.tar.gz`.

### Linux (Ubuntu 22.04, experimental)

Same idea with the Ubuntu Dockerfile:

```bash
docker build -f ci/linux/Dockerfile.ubuntu22.04 -t openrv-build-ubuntu .
docker run --rm -e OPENRV_TAG=v3.2.1 -e DISTRO_SUFFIX=linux-ubuntu22.04 -v "$(pwd)/out:/out" openrv-build-ubuntu
```

### Windows

1. **Prerequisites**: Visual Studio 2022 (Desktop C++, MSVC v143 14.40), Python 3.11 (as `python3.exe`), CMake 3.27+, Qt 6.5.3 (MSVC 2019 64-bit), Strawberry Perl, Rust 1.92+, MSYS2 with **MinGW64** and the pacman packages listed in the [OpenRV Windows docs](https://aswf-openrv.readthedocs.io/en/latest/build_system/config_windows.html) (autotools, glew, libarchive, make, meson, toolchain, autoconf, automake, bison, flex, git, libtool, nasm, p7zip, patch, unzip, zip).
2. **PATH order** (in the shell that runs the build): CMake → Python → Rust (`.cargo/bin`) → `msys64\mingw64\bin` → … → **Strawberry Perl last**. Set `ACLOCAL_PATH=/c/msys64/usr/share/aclocal` and `MSYSTEM=MINGW64` when using MSYS2 bash. **OpenSSL** is built from source by OpenRV and requires **Strawberry Perl** (`WIN_PERL` / `RV_DEPS_WIN_PERL_ROOT`); the CI sets these and uses `setup-msbuild` so `nmake` is available. For Python wheel build issues (e.g. OpenTimelineIO FileTracker errors), CI sets `CL=/FS` and `DISTUTILS_USE_SDK=1`.
3. Clone OpenRV to a **short path** (e.g. `C:\OpenRV`) to avoid path length limits.
4. From PowerShell (with `QT_HOME`, `WIN_PERL`, and `PATH` set as above):
   ```powershell
   .\ci\windows\build_windows.ps1 -Tag v3.2.1 -WorkDir C:\OpenRV
   .\ci\windows\package_windows.ps1 -OpenRVRoot C:\OpenRV -Tag v3.2.1 -OutDir dist
   ```
5. Output: `dist\OpenRV-<TAG>-windows-x86_64.zip`.

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
