#!/usr/bin/env bash
# Build OpenRV inside container and package _build/stage to /out.
# Env: OPENRV_TAG (required), OPENRV_REPO (default upstream), DISTRO_SUFFIX (default linux-rocky9).
# Usage: docker run -e OPENRV_TAG=v3.2.1 -v /host/out:/out ...
set -e

# Enable verbose output for debugging
set -x

OPENRV_TAG="${OPENRV_TAG:?OPENRV_TAG is required}"
OPENRV_REPO="${OPENRV_REPO:-https://github.com/AcademySoftwareFoundation/OpenRV.git}"
DISTRO_SUFFIX="${DISTRO_SUFFIX:-linux-rocky9}"
CI_SCRIPT_DIR="${CI_SCRIPT_DIR:-/ci}"
OUT_DIR="${OUT_DIR:-/out}"

echo "========================================"
echo "OpenRV Linux Build"
echo "Tag: ${OPENRV_TAG}"
echo "Distro: ${DISTRO_SUFFIX}"
echo "Repo: ${OPENRV_REPO}"
echo "========================================"

# Determine work directory based on user (upstream Dockerfile uses /home/rv)
if [[ -d /home/rv && -w /home/rv ]]; then
    WORKDIR="${WORKDIR:-/home/rv}"
else
    WORKDIR="${WORKDIR:-/work}"
fi
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Clone and checkout tag
echo "[1/6] Cloning OpenRV..."
if [[ ! -d OpenRV ]]; then
    git clone --recursive "$OPENRV_REPO" OpenRV
fi
cd OpenRV
git fetch --tags
git checkout "refs/tags/${OPENRV_TAG}"
git submodule update --init --recursive

# Patch rvcmds.sh to append RV_CFG_EXTRA so we can pass BMD/NDI CMake args
echo "[2/6] Patching rvcmds.sh for RV_CFG_EXTRA support..."
if ! grep -q 'RV_CFG_EXTRA' rvcmds.sh; then
    # Try both patterns that might exist in different versions
    sed -i 's/-DRV_DEPS_WIN_PERL_ROOT=\${WIN_PERL}\x27/-DRV_DEPS_WIN_PERL_ROOT=\${WIN_PERL} \${RV_CFG_EXTRA}\x27/' rvcmds.sh 2>/dev/null || true
    sed -i 's/-DRV_VFX_PLATFORM=\${RV_VFX_PLATFORM}\x27/-DRV_VFX_PLATFORM=\${RV_VFX_PLATFORM} \${RV_CFG_EXTRA}\x27/' rvcmds.sh 2>/dev/null || true
fi

# Patch dav1d to use GIT instead of URL zip so Meson has .git for vcs_version.h (fix "fatal: not a git repository")
if [[ -f "${CI_SCRIPT_DIR}/patches/dav1d_use_git.patch" ]]; then
    echo "[2b/6] Patching dav1d.cmake to use GIT (fix vcs_version.h when building from release zip)..."
    if patch -p1 --forward -r - < "${CI_SCRIPT_DIR}/patches/dav1d_use_git.patch" 2>/dev/null; then
        echo "dav1d.cmake patched successfully"
    else
        echo "dav1d patch not applied (may already be applied or upstream changed); continuing"
    fi
fi

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
#!/bin/sh
args=""
version_only=0
for a in "\$@"; do
    case "\$a" in
        -V|-qversion|-version) version_only=1 ;;
        *) args="\${args} \${a}" ;;
    esac
done
if [ "\$version_only" = 1 ] && [ -z "\$(echo "\$args" | tr -d ' ')" ]; then
    exec $real --version
else
    exec $real \$args
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

# Run rvsetup (creates venv and installs requirements)
echo "Running rvsetup..."
rvsetup || {
    echo "ERROR: rvsetup failed" >&2
    exit 1
}

# Run rvmk (cmake configure + build)
echo "Running rvmk (configure + build)..."
rvmk || build_failed=1

# On failure or missing binary, dump error logs so CI shows the real error
RV_BIN="_build/stage/app/bin/rv"
if [[ -n "${build_failed:-}" || ! -f "$RV_BIN" ]]; then
    echo "" >&2
    echo "========================================" >&2
    echo "BUILD FAILED - Searching for error logs" >&2
    echo "========================================" >&2
    
    # Check for CMake error summary
    if [[ -f _build/error_summary.txt ]]; then
        echo "=== _build/error_summary.txt ===" >&2
        cat _build/error_summary.txt >&2
    fi
    
    # Check for build_errors.log
    if [[ -f _build/build_errors.log ]]; then
        echo "=== Last 150 lines of _build/build_errors.log ===" >&2
        tail -150 _build/build_errors.log >&2
    fi
    
    # Search for ExternalProject build logs (e.g., GLEW, OpenSSL, etc.)
    echo "" >&2
    echo "=== Searching ExternalProject logs for errors ===" >&2
    find _build -type f -name "*.log" 2>/dev/null | while read -r logfile; do
        if grep -qiE "(error|fatal|failed|undefined reference)" "$logfile" 2>/dev/null; then
            echo "" >&2
            echo "--- Errors in: $logfile ---" >&2
            grep -iE "(error|fatal|failed|undefined reference)" "$logfile" | head -50 >&2
        fi
    done
    
    # Specifically check GLEW logs (common failure point)
    GLEW_BUILD_LOG=$(find _build -path "*GLEW*" -name "*build*.log" 2>/dev/null | head -1)
    if [[ -n "$GLEW_BUILD_LOG" && -f "$GLEW_BUILD_LOG" ]]; then
        echo "" >&2
        echo "=== GLEW build log (last 100 lines) ===" >&2
        tail -100 "$GLEW_BUILD_LOG" >&2
    fi
    
    # Check CMakeError.log
    CMAKE_ERROR_LOG="_build/CMakeFiles/CMakeError.log"
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
ARCHIVE_NAME="OpenRV-${OPENRV_TAG}-${DISTRO_SUFFIX}-x86_64.tar.gz"
mkdir -p "$OUT_DIR"
tar -C _build -czvf "${OUT_DIR}/${ARCHIVE_NAME}" stage
echo ""
echo "========================================"
echo "PACKAGING COMPLETE"
echo "Artifact: ${OUT_DIR}/${ARCHIVE_NAME}"
echo "========================================"
