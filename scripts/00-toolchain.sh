#!/usr/bin/env bash
# 00-toolchain.sh — fetch + verify the cross toolchain.
#
# Produces under $HERMES_WORK/toolchain/:
#   android-ndk-r27c/            (only the LLVM prebuilt is extracted)
#   termux-py/                   (Termux python prefix: headers + libpython)
#   termux-libs/{libffi,libheif,openssl}/  (extracted Termux debs for linking)
#   tools/                       (patchelf binary)
#
# Env: HERMES_WORK (writable work dir). Reads versions.env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${HERMES_WORK:?set HERMES_WORK}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/build_env.sh"  # versions.env + derived paths

TC_DIR="$HERMES_WORK/toolchain"
mkdir -p "$TC_DIR"
cd "$TC_DIR"

fetch() { # $1=url $2=sha256 $3=dest
    # --fail: a 404 must not be cached as a "successful" HTML download.
    # If the cached file fails the hash check it is corrupt/stale: delete
    # it and re-download once instead of aborting every future re-run.
    if [ -f "$3" ] && ! echo "$2  $3" | sha256sum -c - >/dev/null 2>&1; then
        echo "fetch: cached $(basename "$3") failed sha256; re-downloading"
        rm -f "$3"
    fi
    if [ -f "$3" ]; then
        echo "have $3"
    else
        curl -sSL --fail --retry 3 -o "$3" "$1"
    fi
    echo "$2  $3" | sha256sum -c -
}

# --- NDK ---
NDK_ZIP="android-ndk-${NDK_VERSION}-linux.zip"
fetch "$NDK_URL" "$NDK_SHA256" "$NDK_ZIP"
if [ ! -x "$HERMES_NDK_DIR/bin/clang" ]; then
    unzip -q "$NDK_ZIP" \
        "android-ndk-${NDK_VERSION}/toolchains/llvm/prebuilt/linux-x86_64/*"
fi
"$HERMES_NDK_DIR/bin/clang" --version | head -1

# --- Termux python (headers + lib) ---
fetch "$TERMUX_PYTHON_DEB_URL" "$TERMUX_PYTHON_SHA256" "python_termux.deb"
if [ ! -f "termux-py/data/data/com.termux/files/usr/include/python${HERMES_PYVER}/Python.h" ]; then
    rm -rf termux-py && mkdir termux-py
    dpkg-deb -x python_termux.deb termux-py
fi
# Loud version check: wheels link libpythonX.Y.so; refuse a wrong python.
PY_VER="$(ls termux-py/data/data/com.termux/files/usr/lib/libpython${HERMES_PYVER}.so 2>/dev/null | head -1)"
case "$PY_VER" in
    *libpython${HERMES_PYVER}.so) echo "target python: $HERMES_PYVER_FULL OK" ;;
    *) echo "00-toolchain.sh: expected Termux python $HERMES_PYVER_FULL, found: $PY_VER" >&2; exit 1 ;;
esac
test -f "termux-py/data/data/com.termux/files/usr/include/python${HERMES_PYVER}/Python.h"

# --- Termux system libs needed at wheel link time ---
# (runtime copies come from the .deb Depends:, these are link-time only)
for lib in libffi libheif openssl; do
    if [ ! -d "termux-libs/$lib" ]; then
        read -r url sha < <(python3 "$REPO_ROOT/scripts/lib/termux_deb.py" "$lib")
        fetch "$url" "$sha" "${lib}_termux.deb"
        mkdir -p "termux-libs/$lib"
        dpkg-deb -x "${lib}_termux.deb" "termux-libs/$lib"
    fi
done
test -f "termux-libs/libffi/data/data/com.termux/files/usr/include/ffi.h"
test -f "termux-libs/libheif/data/data/com.termux/files/usr/include/heif/heif.h" \
  || test -f "termux-libs/libheif/data/data/com.termux/files/usr/include/libheif/heif.h"

# --- patchelf (for python_linkage wheel repair) ---
if [ ! -x "tools/patchelf" ]; then
    mkdir -p tools
    python3 -m pip download --no-deps -d tools "patchelf==$PATCHELF_PYPI_VERSION" 2>/dev/null || \
        pip download --no-deps -d tools "patchelf==$PATCHELF_PYPI_VERSION"
    (cd tools && unzip -o -q patchelf-*.whl '*/patchelf' \
        && mv patchelf-*.data/scripts/patchelf . && rm -rf patchelf-*.data \
        && chmod +x patchelf)
fi
./tools/patchelf --version

# --- smoke test: compile a trivial Python.h extension for the target ---
cat > pyext_test.c <<'EOF'
#include <Python.h>
static PyModuleDef m = {PyModuleDef_HEAD_INIT, "pyext_test", NULL, -1, NULL};
PyMODINIT_FUNC PyInit_pyext_test(void) { return PyModule_Create(&m); }
EOF
TC="$HERMES_NDK_DIR"
PYINC="$TC_DIR/termux-py/data/data/com.termux/files/usr"
"$TC/bin/${HERMES_TARGET_TRIPLE}-clang" -shared -fPIC \
    -I"$PYINC/include/python${HERMES_PYVER}" pyext_test.c -o pyext_test.so
file pyext_test.so | grep -q "ARM aarch64" || { echo "toolchain smoke test FAILED"; exit 1; }
echo "toolchain OK: NDK + Termux python $HERMES_PYVER_FULL + libs + patchelf"
