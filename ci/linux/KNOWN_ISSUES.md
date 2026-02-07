# Known issues (Linux CI)

## Ubuntu 22.04 (experimental)

- Ubuntu is **not** an officially supported OpenRV build target.
- This job is best-effort and uses `continue-on-error: true` in CI; it does **not** block releases.
- Document any recurring failures here (e.g. missing libs, Qt path differences).
- **TwkQtChat AUTOMOC path**: CMake AUTOMOC can generate a wrong include path for `Client.h` (duplicate `TwkQtChat` in path, e.g. `.../TwkQtChat/TwkQtChat/Client.h`). The build script clears CMake cache and `*_autogen` dirs under `_build/src` when `DISTRO_SUFFIX` is Ubuntu and cache is present, so AUTOMOC is regenerated with correct paths while keeping dependency cache.
