#!/usr/bin/env bash
# Build OpenRV inside container and package _build/stage to /out.
# Env: OPENRV_TAG (required), OPENRV_REPO (default upstream), DISTRO_SUFFIX (default linux-rocky9).
# Usage: docker run -e OPENRV_TAG=v3.2.1 -v /host/out:/out ...
set -e

OPENRV_TAG="${OPENRV_TAG:?OPENRV_TAG is required}"
OPENRV_REPO="${OPENRV_REPO:-https://github.com/AcademySoftwareFoundation/OpenRV.git}"
DISTRO_SUFFIX="${DISTRO_SUFFIX:-linux-rocky9}"
CI_SCRIPT_DIR="${CI_SCRIPT_DIR:-/ci}"
OUT_DIR="${OUT_DIR:-/out}"

echo "Building OpenRV ${OPENRV_TAG} (${DISTRO_SUFFIX}) from ${OPENRV_REPO}"

WORKDIR="${WORKDIR:-/work}"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Clone and checkout tag
if [[ ! -d OpenRV ]]; then
  git clone --recursive "$OPENRV_REPO" OpenRV
fi
cd OpenRV
git fetch --tags
git checkout "refs/tags/${OPENRV_TAG}"
git submodule update --init --recursive

# Qt and VFX environment
source "${CI_SCRIPT_DIR}/detect_qt.sh"
export RV_VFX_PLATFORM="${RV_VFX_PLATFORM:-CY2024}"
export RV_BUILD_TYPE="${RV_BUILD_TYPE:-Release}"

# Build using upstream scripts (expand_aliases so rvbootstrap alias works in non-interactive script)
shopt -s expand_aliases 2>/dev/null || true
source rvcmds.sh
rvbootstrap

# Post-build check
RV_BIN="_build/stage/app/bin/rv"
if [[ ! -f "$RV_BIN" ]]; then
  echo "Error: Expected binary not found: $RV_BIN" >&2
  exit 1
fi
echo "Post-build check OK: $RV_BIN exists"

# Package
ARCHIVE_NAME="OpenRV-${OPENRV_TAG}-${DISTRO_SUFFIX}-x86_64.tar.gz"
mkdir -p "$OUT_DIR"
tar -C _build -czvf "${OUT_DIR}/${ARCHIVE_NAME}" stage
echo "Created ${OUT_DIR}/${ARCHIVE_NAME}"
