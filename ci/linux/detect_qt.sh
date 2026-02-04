#!/usr/bin/env bash
# Detect Qt 6.5.x for VFX CY2024 and export QT_HOME, CMAKE_PREFIX_PATH, PATH.
# Safe to source. Idempotent. Used inside Linux build containers.
set -e

export RV_VFX_PLATFORM="${RV_VFX_PLATFORM:-CY2024}"
QT_WANT_VERSION="6.5"

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

# 2. ASWF image: Conan Qt in /tmp/qttemp (or similar)
for candidate in /tmp/qttemp /opt/qt /usr/local; do
  if [[ -d "$candidate" ]]; then
    # Conan may put Qt in a subdir; look for libQt6Core or Qt6Config.cmake
    qt_core=$(find "$candidate" -maxdepth 4 -name 'Qt6Config.cmake' 2>/dev/null | head -1)
    if [[ -n "$qt_core" ]]; then
      # Qt6Config.cmake is in <prefix>/lib/cmake/Qt6/ -> prefix is 3 dirnames up
      QT_HOME=$(dirname "$(dirname "$(dirname "$(dirname "$qt_core")")")")
      if [[ "$QT_HOME" == *"${QT_WANT_VERSION}"* || -f "${QT_HOME}/lib/libQt6Core.so" || -f "${QT_HOME}/lib/cmake/Qt6/Qt6Config.cmake" ]]; then
        export QT_HOME
        export CMAKE_PREFIX_PATH="${QT_HOME};${CMAKE_PREFIX_PATH}"
        export PATH="${QT_HOME}/bin:${PATH}"
        echo "Found Qt at QT_HOME=$QT_HOME (ASWF/Conan)"
        return 0 2>/dev/null || true
        exit 0
      fi
    fi
    # Direct gcc_64-style layout
    gcc64=$(find "$candidate" -maxdepth 3 -type d -path '*/gcc_64' 2>/dev/null | grep -E "6\.5" | sort -V | tail -1)
    if [[ -n "$gcc64" && -f "$gcc64/lib/libQt6Core.so" ]]; then
      export QT_HOME="$gcc64"
      export CMAKE_PREFIX_PATH="${QT_HOME};${CMAKE_PREFIX_PATH}"
      export PATH="${QT_HOME}/bin:${PATH}"
      echo "Found Qt at QT_HOME=$QT_HOME"
      return 0 2>/dev/null || true
      exit 0
    fi
  fi
done

# 3. Standard locations ~/Qt/6.5*/gcc_64
if [[ -d "${HOME}/Qt" ]]; then
  QT_HOME=$(find "${HOME}/Qt" -maxdepth 4 -type d -path '*/gcc_64' 2>/dev/null | grep -E "6\.5" | sort -V | tail -1)
  if [[ -n "$QT_HOME" && -f "$QT_HOME/lib/libQt6Core.so" ]]; then
    export QT_HOME
    export CMAKE_PREFIX_PATH="${QT_HOME};${CMAKE_PREFIX_PATH}"
    export PATH="${QT_HOME}/bin:${PATH}"
    echo "Found Qt at QT_HOME=$QT_HOME"
    return 0 2>/dev/null || true
    exit 0
  fi
fi

# 4. Not found
echo "Error: Qt ${QT_WANT_VERSION} not found. Set QT_HOME or install Qt (e.g. aqtinstall) to ~/Qt or /opt/qt." >&2
return 1 2>/dev/null || exit 1
