#!/usr/bin/env bash
# Build OpenRV inside container and package _build/stage to /out.
# Env: OPENRV_TAG (required), OPENRV_REPO (default upstream), DISTRO_SUFFIX (default linux-rocky9).
# Usage: docker run -e OPENRV_TAG=v3.1.0 -v /host/out:/out ...
set -e

# Enable verbose output for debugging
set -x

OPENRV_TAG="${OPENRV_TAG:?OPENRV_TAG is required}"
OPENRV_REPO="${OPENRV_REPO:-https://github.com/AcademySoftwareFoundation/OpenRV.git}"
DISTRO_SUFFIX="${DISTRO_SUFFIX:-linux-rocky9}"
CI_SCRIPT_DIR="${CI_SCRIPT_DIR:-/ci}"
OUT_DIR="${OUT_DIR:-/out}"
SUPPORTED_OPENRV_TAG="v3.1.0"

echo "========================================"
echo "OpenRV Linux Build"
echo "Tag: ${OPENRV_TAG}"
echo "Distro: ${DISTRO_SUFFIX}"
echo "Repo: ${OPENRV_REPO}"
echo "========================================"

if [[ "${OPENRV_TAG}" != "${SUPPORTED_OPENRV_TAG}" ]]; then
    echo "ERROR: This commit supports OpenRV ${SUPPORTED_OPENRV_TAG} only. For other tags, checkout the matching OpenRV-builds release commit."
    exit 1
fi

# Determine work directory based on user (upstream Dockerfile uses /home/rv)
if [[ -d /home/rv && -w /home/rv ]]; then
    WORKDIR="${WORKDIR:-/home/rv}"
else
    WORKDIR="${WORKDIR:-/work}"
fi
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Clone and checkout tag (handle pre-existing _build mount from cache)
echo "[1/6] Cloning OpenRV..."
if [[ ! -d OpenRV/.git ]]; then
    # _build may be a Docker bind mount with cached artifacts - preserve it during clone
    if [[ -d OpenRV ]]; then
        # If the OpenRV directory was implicitly created by Docker (due to a subdir bind mount),
        # it may be owned by root and not writable by the 'rv' user. Fail loudly instead of
        # silently continuing with a broken (non-git) checkout.
        if [[ ! -w OpenRV ]]; then
            echo "FATAL: ${WORKDIR}/OpenRV exists but is not writable."
            echo "This commonly happens when mounting a volume to /home/rv/OpenRV/_build before /home/rv/OpenRV exists."
            ls -ld OpenRV || true
            exit 1
        fi
        # Remove everything except _build
        find OpenRV -mindepth 1 -maxdepth 1 ! -name '_build' -exec rm -rf {} + 2>/dev/null || true
    else
        mkdir -p OpenRV
    fi
    # Clone into temp dir, then move contents into OpenRV (preserving _build mount)
    git clone --recursive "$OPENRV_REPO" OpenRV_tmp
    # Move all contents from temp to OpenRV (excluding _build if it happens to exist in temp)
    shopt -s dotglob
    # Move .git first so a failure is obvious (and to avoid ending up in a non-git directory).
    mv OpenRV_tmp/.git OpenRV/.git
    mv OpenRV_tmp/* OpenRV/
    shopt -u dotglob
    rm -rf OpenRV_tmp
fi
cd OpenRV
if [[ ! -d .git ]]; then
    echo "FATAL: OpenRV checkout is missing .git after clone/move. Cannot continue."
    ls -ld . || true
    ls -la . || true
    exit 1
fi
git fetch --tags
git checkout "refs/tags/${OPENRV_TAG}"
git submodule update --init --recursive

# Wire OpenRV/_build to a mounted host cache dir when requested.
# This allows dependency/externalproject progress to survive failed CI attempts.
if [[ -n "${OPENRV_BUILD_CACHE_DIR:-}" ]]; then
    echo "Using build cache dir: ${OPENRV_BUILD_CACHE_DIR}"
    mkdir -p "${OPENRV_BUILD_CACHE_DIR}"
    if [[ -L _build ]]; then
        rm -f _build
    elif [[ -d _build ]]; then
        rm -rf _build
    fi
    ln -s "${OPENRV_BUILD_CACHE_DIR}" _build
fi

# Ubuntu: clear CMake and AUTOMOC state so moc paths are regenerated
# (avoids duplicated-path include errors in generated Qt MOC files).
if [[ "$DISTRO_SUFFIX" == *ubuntu* ]] && { [[ -f _build/CMakeCache.txt ]] || [[ -d _build/CMakeFiles ]]; }; then
    echo "Clearing CMake and AUTOMOC state for Ubuntu (fix TwkQtChat include path)..."
    rm -f _build/CMakeCache.txt
    rm -rf _build/CMakeFiles
    find _build/src -type d -name '*_autogen' -exec rm -rf {} + 2>/dev/null || true
fi

apply_required_patch() {
    local patch_path="$1"
    local patch_name
    patch_name="$(basename "$patch_path")"
    echo "Applying patch: ${patch_name}"
    if [[ ! -f "${patch_path}" ]]; then
        echo "ERROR: Missing required patch: ${patch_path}"
        exit 1
    fi
    if ! patch -p1 --forward -r - < "${patch_path}"; then
        echo "ERROR: Required patch failed: ${patch_name}"
        exit 1
    fi
}

PATCH_SET_DIR="${CI_SCRIPT_DIR}/patches/openrv-v3.1.0"
echo "[2/6] Applying patch set from ${PATCH_SET_DIR}..."
apply_required_patch "${PATCH_SET_DIR}/rvcmds_rv_cfg_extra.patch"
apply_required_patch "${PATCH_SET_DIR}/dav1d_use_git.patch"
apply_required_patch "${PATCH_SET_DIR}/glew_2_3_0.patch"

# Optional BMD and NDI: download when URLs provided and set CMake args
echo "[3/6] Processing optional SDKs..."
RV_CFG_EXTRA="${RV_CFG_EXTRA:-}"
if [[ -n "${BMD_DECKLINK_SDK_ZIP_URL:-}" ]]; then
    echo "Downloading Blackmagic DeckLink SDK..."
    curl -sL -o "$WORKDIR/BMD_DeckLink_SDK.zip" "$BMD_DECKLINK_SDK_ZIP_URL"
    RV_CFG_EXTRA="${RV_CFG_EXTRA} -DRV_DEPS_BMD_DECKLINK_SDK_ZIP_PATH=$WORKDIR/BMD_DeckLink_SDK.zip"
fi
if [[ -n "${NDI_SDK_URL:-}" ]]; then
    echo "Downloading NDI SDK..."
    curl -sL -o "$WORKDIR/ndi_sdk.tar.gz" "$NDI_SDK_URL" || curl -sL -o "$WORKDIR/ndi_sdk.zip" "$NDI_SDK_URL"
    if [[ -f "$WORKDIR/ndi_sdk.tar.gz" ]]; then
        tar -xzf "$WORKDIR/ndi_sdk.tar.gz" -C "$WORKDIR"
        rm "$WORKDIR/ndi_sdk.tar.gz"
    else
        unzip -q -o "$WORKDIR/ndi_sdk.zip" -d "$WORKDIR"
        rm "$WORKDIR/ndi_sdk.zip"
    fi
    # NDI SDK often extracts to a single dir (e.g. NDI SDK for Linux)
    NDI_TOP=$(find "$WORKDIR" -maxdepth 1 -type d -name '*NDI*' 2>/dev/null | head -1)
    if [[ -n "$NDI_TOP" ]]; then
        export NDI_SDK_ROOT="$NDI_TOP"
        RV_CFG_EXTRA="${RV_CFG_EXTRA} -DNDI_SDK_ROOT=$NDI_TOP"
    else
        export NDI_SDK_ROOT="$WORKDIR"
        RV_CFG_EXTRA="${RV_CFG_EXTRA} -DNDI_SDK_ROOT=$WORKDIR"
    fi
fi
export RV_CFG_EXTRA

# Qt and VFX environment
echo "[4/6] Configuring Qt and VFX environment..."
if [[ -f "${CI_SCRIPT_DIR}/detect_qt.sh" ]]; then
    source "${CI_SCRIPT_DIR}/detect_qt.sh"
elif [[ -n "${QT_HOME:-}" ]]; then
    echo "Using pre-set QT_HOME=$QT_HOME"
    export CMAKE_PREFIX_PATH="${QT_HOME};${CMAKE_PREFIX_PATH:-}"
    export PATH="${QT_HOME}/bin:${PATH}"
else
    # Try to find Qt in standard locations for upstream Docker image
    for qt_candidate in /home/rv/Qt/6.5.*/gcc_64 /opt/qt/6.5.*/gcc_64 ~/Qt/6.5.*/gcc_64; do
        if [[ -d $qt_candidate && -f "$qt_candidate/lib/libQt6Core.so" ]]; then
            export QT_HOME="$qt_candidate"
            export CMAKE_PREFIX_PATH="${QT_HOME};${CMAKE_PREFIX_PATH:-}"
            export PATH="${QT_HOME}/bin:${PATH}"
            echo "Found Qt at QT_HOME=$QT_HOME"
            break
        fi
    done
fi

export RV_VFX_PLATFORM="${RV_VFX_PLATFORM:-CY2024}"
export RV_BUILD_TYPE="${RV_BUILD_TYPE:-Release}"

# Autoconf/libtool in deps (e.g. RV_DEPS_RAW/LibRaw) may invoke CC/CXX with Intel-only flags
# (-V, -qversion, -version), which GCC rejects. Use wrappers that strip those and use --version.
WRAP_DIR="${WORKDIR}/.ci_cc_wrap"
mkdir -p "$WRAP_DIR"
# Resolve real compiler paths before we prepend WRAP_DIR to PATH
GCC_REAL=$(command -v gcc 2>/dev/null || echo "gcc")
GXX_REAL=$(command -v g++ 2>/dev/null || echo "g++")
for cmd in gcc g++; do
    if [ "$cmd" = "gcc" ]; then real=$GCC_REAL; else real=$GXX_REAL; fi
    cat > "${WRAP_DIR}/${cmd}" << WRAPEOF
#!/bin/bash
args=()
version_only=0
for a in "\$@"; do
    case "\$a" in
        -V|-qversion|-version) version_only=1 ;;
        *) args+=("\$a") ;;
    esac
done
if [ "\$version_only" = 1 ] && [ \${#args[@]} -eq 0 ]; then
    exec $real --version
else
    exec $real "\${args[@]}"
fi
WRAPEOF
    chmod +x "${WRAP_DIR}/${cmd}"
done
export PATH="${WRAP_DIR}:${PATH}"
export CC="${WRAP_DIR}/gcc"
export CXX="${WRAP_DIR}/g++"
# Also sanitize CFLAGS/CXXFLAGS in case they contain Intel flags
for var in CFLAGS CXXFLAGS LDFLAGS; do
    eval "val=\${$var:-}"
    val=$(echo " $val " | sed 's/ -V / /g; s/ -qversion / /g; s/ -version / /g; s/^ //; s/ $//')
    eval "export $var=\"$val\""
done

echo "QT_HOME=$QT_HOME"
echo "RV_VFX_PLATFORM=$RV_VFX_PLATFORM"
echo "CC=$CC CXX=$CXX"
echo "RV_CFG_EXTRA=$RV_CFG_EXTRA"

# Build using upstream scripts
echo "[5/6] Running rvbootstrap..."
shopt -s expand_aliases 2>/dev/null || true

# Source rvcmds.sh and run the build
# We capture exit codes properly to handle partial failures
source rvcmds.sh
RV_BUILD_DIR_EFFECTIVE="${RV_BUILD_DIR:?RV_BUILD_DIR is not set by rvcmds.sh}"

# Run rvsetup (creates venv and installs requirements)
echo "Running rvsetup..."
rvsetup || {
    echo "ERROR: rvsetup failed" >&2
    exit 1
}

# Configure (so we can build dependencies next)
echo "Running rvcfg (configure)..."
rvcfg || {
    echo "ERROR: rvcfg failed" >&2
    exit 1
}

# Build dependencies first, then fix bdwgc include layout if needed (set OPENRV_FIX_GC_INCLUDE=0 to skip)
# bdwgc may install headers flat to include/; OpenRV expects include/gc/gc.h
if [[ "${OPENRV_FIX_GC_INCLUDE:-1}" != "0" ]]; then
    echo "Building dependencies and fixing bdwgc include layout (OPENRV_FIX_GC_INCLUDE=${OPENRV_FIX_GC_INCLUDE:-1})..."
    rvenv && cmake --build "${RV_BUILD_DIR_EFFECTIVE}" --config Release --parallel="${RV_BUILD_PARALLELISM}" --target dependencies
    GC_INC="${RV_BUILD_DIR_EFFECTIVE}/RV_DEPS_GC/install/include"
    if [[ -d "${RV_BUILD_DIR_EFFECTIVE}/RV_DEPS_GC" ]] && [[ -f "${GC_INC}/gc.h" ]] && [[ ! -f "${GC_INC}/gc/gc.h" ]]; then
        mkdir -p "${GC_INC}/gc"
        cp -f "${GC_INC}/gc.h" "${GC_INC}/gc/" 2>/dev/null || true
        cp -f "${GC_INC}/gc_allocator.h" "${GC_INC}/gc/" 2>/dev/null || true
        echo "Fixed bdwgc include layout (include/gc/gc.h)"
    fi
fi

# Fix OpenSSL lib path: make_openssl.py installs to lib64 for CY2024 on Linux, but openssl.cmake
# expects install/lib when RHEL_VERBOSE is not set (e.g. on Ubuntu, which has no /etc/redhat-release).
# Copy lib64 -> lib so the linker finds libcrypto.so.3 / libssl.so.3.
if [[ "${RV_VFX_PLATFORM}" = "CY2024" ]] && [[ -d "${RV_BUILD_DIR_EFFECTIVE}/RV_DEPS_OPENSSL/install/lib64" ]]; then
  if [[ ! -f "${RV_BUILD_DIR_EFFECTIVE}/RV_DEPS_OPENSSL/install/lib/libcrypto.so.3" ]] && [[ -f "${RV_BUILD_DIR_EFFECTIVE}/RV_DEPS_OPENSSL/install/lib64/libcrypto.so.3" ]]; then
    echo "Fixing OpenSSL lib path (lib64 -> lib) for CY2024 non-RHEL..."
    mkdir -p "${RV_BUILD_DIR_EFFECTIVE}/RV_DEPS_OPENSSL/install/lib"
    cp -an "${RV_BUILD_DIR_EFFECTIVE}/RV_DEPS_OPENSSL/install/lib64/"* "${RV_BUILD_DIR_EFFECTIVE}/RV_DEPS_OPENSSL/install/lib/" 2>/dev/null || true
  fi
fi

# Build main executable
echo "Running rvbuild..."
rvbuild || build_failed=1

# On failure or missing binary, dump error logs so CI shows the real error
RV_BIN="${RV_BUILD_DIR_EFFECTIVE}/stage/app/bin/rv"
if [[ -n "${build_failed:-}" || ! -f "$RV_BIN" ]]; then
    echo "" >&2
    echo "========================================" >&2
    echo "BUILD FAILED - Searching for error logs" >&2
    echo "========================================" >&2
    
    # Check for CMake error summary
    if [[ -f "${RV_BUILD_DIR_EFFECTIVE}/error_summary.txt" ]]; then
        echo "=== ${RV_BUILD_DIR_EFFECTIVE}/error_summary.txt ===" >&2
        cat "${RV_BUILD_DIR_EFFECTIVE}/error_summary.txt" >&2
    fi
    
    # Check for build_errors.log
    if [[ -f "${RV_BUILD_DIR_EFFECTIVE}/build_errors.log" ]]; then
        echo "=== Last 150 lines of ${RV_BUILD_DIR_EFFECTIVE}/build_errors.log ===" >&2
        tail -150 "${RV_BUILD_DIR_EFFECTIVE}/build_errors.log" >&2
    fi
    
    # Search for ExternalProject build logs (e.g., GLEW, OpenSSL, etc.)
    echo "" >&2
    echo "=== Searching ExternalProject logs for errors ===" >&2
    find "${RV_BUILD_DIR_EFFECTIVE}" -type f -name "*.log" 2>/dev/null | while read -r logfile; do
        if grep -qiE "(error|fatal|failed|undefined reference)" "$logfile" 2>/dev/null; then
            echo "" >&2
            echo "--- Errors in: $logfile ---" >&2
            grep -iE "(error|fatal|failed|undefined reference)" "$logfile" | head -50 >&2
        fi
    done
    
    # Specifically check GLEW logs (common failure point)
    GLEW_BUILD_LOG=$(find "${RV_BUILD_DIR_EFFECTIVE}" -path "*GLEW*" -name "*build*.log" 2>/dev/null | head -1)
    if [[ -n "$GLEW_BUILD_LOG" && -f "$GLEW_BUILD_LOG" ]]; then
        echo "" >&2
        echo "=== GLEW build log (last 100 lines) ===" >&2
        tail -100 "$GLEW_BUILD_LOG" >&2
    fi

    # GC (bdwgc) dependency: show install dir and logs when build failed (helps diagnose gc/gc.h missing)
    if [[ -d "${RV_BUILD_DIR_EFFECTIVE}/RV_DEPS_GC" ]]; then
        echo "" >&2
        echo "=== RV_DEPS_GC install include dir ===" >&2
        ls -la "${RV_BUILD_DIR_EFFECTIVE}/RV_DEPS_GC/install/include/" 2>/dev/null || true >&2
        ls -la "${RV_BUILD_DIR_EFFECTIVE}/RV_DEPS_GC/install/include/gc/" 2>/dev/null || true >&2
        GC_BUILD_LOG=$(find "${RV_BUILD_DIR_EFFECTIVE}" -path "*RV_DEPS_GC*" -name "*.log" 2>/dev/null | head -5)
        if [[ -n "$GC_BUILD_LOG" ]]; then
            echo "=== GC (bdwgc) build logs (last 80 lines each) ===" >&2
            for f in $GC_BUILD_LOG; do echo "--- $f ---"; tail -80 "$f" 2>/dev/null; done >&2
        fi
    fi

    # OpenSSL: show install lib/lib64 when build failed (helps diagnose libcrypto.so.3 not found on Ubuntu)
    if [[ -d "${RV_BUILD_DIR_EFFECTIVE}/RV_DEPS_OPENSSL" ]]; then
        echo "" >&2
        echo "=== RV_DEPS_OPENSSL install lib dirs ===" >&2
        ls -la "${RV_BUILD_DIR_EFFECTIVE}/RV_DEPS_OPENSSL/install/lib/" 2>/dev/null || true >&2
        ls -la "${RV_BUILD_DIR_EFFECTIVE}/RV_DEPS_OPENSSL/install/lib64/" 2>/dev/null || true >&2
    fi
    
    # Check CMakeError.log
    CMAKE_ERROR_LOG="${RV_BUILD_DIR_EFFECTIVE}/CMakeFiles/CMakeError.log"
    if [[ -f "$CMAKE_ERROR_LOG" ]]; then
        echo "" >&2
        echo "=== CMakeError.log ===" >&2
        cat "$CMAKE_ERROR_LOG" >&2
    fi
    
    echo "" >&2
    echo "Build failed or expected binary not found: $RV_BIN" >&2
    exit 1
fi

echo ""
echo "========================================"
echo "BUILD SUCCESSFUL"
echo "Binary: $RV_BIN"
echo "========================================"

# Package
echo "[6/6] Packaging..."
ARCHIVE_FORMAT="${OPENRV_ARCHIVE_FORMAT:-xz}"
mkdir -p "$OUT_DIR"

case "$ARCHIVE_FORMAT" in
    xz)
        if command -v xz >/dev/null 2>&1; then
            ARCHIVE_NAME="OpenRV-${OPENRV_TAG}-${DISTRO_SUFFIX}-x86_64.tar.xz"
            tar -C "${RV_BUILD_DIR_EFFECTIVE}" -cJf "${OUT_DIR}/${ARCHIVE_NAME}" stage
        else
            echo "WARNING: xz not found; falling back to gzip packaging."
            ARCHIVE_NAME="OpenRV-${OPENRV_TAG}-${DISTRO_SUFFIX}-x86_64.tar.gz"
            tar -C "${RV_BUILD_DIR_EFFECTIVE}" -czf "${OUT_DIR}/${ARCHIVE_NAME}" stage
        fi
        ;;
    gz|gzip)
        ARCHIVE_NAME="OpenRV-${OPENRV_TAG}-${DISTRO_SUFFIX}-x86_64.tar.gz"
        tar -C "${RV_BUILD_DIR_EFFECTIVE}" -czf "${OUT_DIR}/${ARCHIVE_NAME}" stage
        ;;
    *)
        echo "ERROR: unsupported OPENRV_ARCHIVE_FORMAT='${ARCHIVE_FORMAT}' (supported: xz, gz)"
        exit 1
        ;;
esac
echo ""
echo "========================================"
echo "PACKAGING COMPLETE"
echo "Artifact: ${OUT_DIR}/${ARCHIVE_NAME}"
echo "========================================"
