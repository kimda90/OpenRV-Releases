#!/usr/bin/env bash
# Detect Qt for VFX platform: Qt 6.5.x (CY2024) or Qt 5.15.x (CY2023 e.g. Rocky 8).
# Safe to source. Idempotent. Used inside Linux build containers.
set -e

export RV_VFX_PLATFORM="${RV_VFX_PLATFORM:-CY2024}"
if [[ "${RV_VFX_PLATFORM}" == "CY2023" ]]; then
  QT_WANT_VERSION="5.15"
  QT_CORE_LIB="libQt5Core.so"
  QT_GREP_PATTERN="5\.15"
else
  QT_WANT_VERSION="6.5"
  QT_CORE_LIB="libQt6Core.so"
  QT_GREP_PATTERN="6\.5"
fi

_if_set_use() {
  if [[ -n "$QT_HOME" && -d "$QT_HOME" ]]; then
    if [[ "$QT_HOME" == *"${QT_WANT_VERSION}"* ]]; then
      export CMAKE_PREFIX_PATH="${QT_HOME};${CMAKE_PREFIX_PATH}"
      export PATH="${QT_HOME}/bin:${PATH}"
      return 0
    fi
  fi
  return 1
}

# 1. Already set and valid
if _if_set_use; then
  echo "Using existing QT_HOME=$QT_HOME"
  return 0 2>/dev/null || true
  exit 0
fi

# 2. ASWF image: Conan Qt in /tmp/qttemp (or similar). Only use if path looks like
#    a standard Qt install (has bin/ and contains version) so OpenRV's QT_HOME check accepts it.
for candidate in /tmp/qttemp /opt/qt /usr/local; do
  if [[ -d "$candidate" ]]; then
    # Prefer gcc_64-style path so OpenRV accepts QT_HOME (it validates the path)
    gcc64=$(find "$candidate" -maxdepth 4 -type d -path '*/gcc_64' 2>/dev/null | grep -E "${QT_GREP_PATTERN}" | sort -V | tail -1)
    if [[ -n "$gcc64" && -f "$gcc64/lib/${QT_CORE_LIB}" ]]; then
      export QT_HOME="$gcc64"
      export CMAKE_PREFIX_PATH="${QT_HOME};${CMAKE_PREFIX_PATH}"
      export PATH="${QT_HOME}/bin:${PATH}"
      echo "Found Qt at QT_HOME=$QT_HOME"
      return 0 2>/dev/null || true
      exit 0
    fi
    # Conan may put Qt in a flat prefix (Qt6 only for CY2024)
    qt_core=$(find "$candidate" -maxdepth 4 -name 'Qt6Config.cmake' 2>/dev/null | head -1)
    [[ -z "$qt_core" ]] && qt_core=$(find "$candidate" -maxdepth 4 -name 'Qt5Config.cmake' 2>/dev/null | head -1)
    if [[ -n "$qt_core" ]]; then
      qt_prefix=$(dirname "$(dirname "$(dirname "$(dirname "$qt_core")")")")
      if [[ "$qt_prefix" == *"${QT_WANT_VERSION}"* && -d "${qt_prefix}/bin" ]]; then
        export QT_HOME="$qt_prefix"
        export CMAKE_PREFIX_PATH="${QT_HOME};${CMAKE_PREFIX_PATH}"
        export PATH="${QT_HOME}/bin:${PATH}"
        echo "Found Qt at QT_HOME=$QT_HOME (ASWF/Conan)"
        return 0 2>/dev/null || true
        exit 0
      fi
      # Conan layout without 6.5 in path or no bin/: use for CMake only, skip QT_HOME
      export CMAKE_PREFIX_PATH="${qt_prefix};${CMAKE_PREFIX_PATH}"
      export PATH="${qt_prefix}/bin:${PATH}"
      echo "Found Qt (Conan) at $qt_prefix; CMAKE_PREFIX_PATH set (QT_HOME not set, will use ~/Qt or aqtinstall)"
    fi
    # Direct gcc_64-style layout
    gcc64=$(find "$candidate" -maxdepth 3 -type d -path '*/gcc_64' 2>/dev/null | grep -E "${QT_GREP_PATTERN}" | sort -V | tail -1)
    if [[ -n "$gcc64" && -f "$gcc64/lib/${QT_CORE_LIB}" ]]; then
      export QT_HOME="$gcc64"
      export CMAKE_PREFIX_PATH="${QT_HOME};${CMAKE_PREFIX_PATH}"
      export PATH="${QT_HOME}/bin:${PATH}"
      echo "Found Qt at QT_HOME=$QT_HOME"
      return 0 2>/dev/null || true
      exit 0
    fi
  fi
done

# 3. Standard locations ~/Qt/<version>*/gcc_64
if [[ -d "${HOME}/Qt" ]]; then
  QT_HOME=$(find "${HOME}/Qt" -maxdepth 4 -type d -path '*/gcc_64' 2>/dev/null | grep -E "${QT_GREP_PATTERN}" | sort -V | tail -1)
  if [[ -n "$QT_HOME" && -f "$QT_HOME/lib/${QT_CORE_LIB}" ]]; then
    export QT_HOME
    export CMAKE_PREFIX_PATH="${QT_HOME};${CMAKE_PREFIX_PATH}"
    export PATH="${QT_HOME}/bin:${PATH}"
    echo "Found Qt at QT_HOME=$QT_HOME"
    return 0 2>/dev/null || true
    exit 0
  fi
fi

# 4. Not found
echo "Error: Qt ${QT_WANT_VERSION} (${RV_VFX_PLATFORM}) not found. Set QT_HOME or install Qt (e.g. aqtinstall) to ~/Qt or /opt/qt." >&2
return 1 2>/dev/null || exit 1
