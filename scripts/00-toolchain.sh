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
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.env"

: "${HERMES_WORK:?set HERMES_WORK}"
TC_DIR="$HERMES_WORK/toolchain"
mkdir -p "$TC_DIR"
cd "$TC_DIR"

fetch() { # $1=url $2=sha256 $3=dest
    if [ -f "$3" ]; then
        echo "have $3"
    else
        curl -sSL --retry 3 -o "$3" "$1"
    fi
    echo "$2  $3" | sha256sum -c -
}

# --- NDK ---
fetch "$NDK_URL" "$NDK_SHA256" "android-ndk-r27c-linux.zip"
if [ ! -x "android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]; then
    unzip -q android-ndk-r27c-linux.zip \
        'android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/*'
fi
"$TC_DIR/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" --version | head -1

# --- Termux python (headers + lib) ---
fetch "$TERMUX_PYTHON_DEB_URL" "$TERMUX_PYTHON_SHA256" "python_termux.deb"
if [ ! -f "termux-py/data/data/com.termux/files/usr/include/python3.14/Python.h" ]; then
    rm -rf termux-py && mkdir termux-py
    dpkg-deb -x python_termux.deb termux-py
fi
# Loud version check: wheels link libpython3.14.so; refuse a 3.15+ python.
PY_VER="$(ls termux-py/data/data/com.termux/files/usr/lib/libpython3.1*.so 2>/dev/null | head -1)"
case "$PY_VER" in
    *libpython3.14.so) echo "target python: 3.14 OK" ;;
    *) echo "00-toolchain.sh: expected Termux python 3.14, found: $PY_VER" >&2; exit 1 ;;
esac
test -f "termux-py/data/data/com.termux/files/usr/include/python3.14/Python.h"

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
TC="$TC_DIR/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64"
PYINC="$TC_DIR/termux-py/data/data/com.termux/files/usr"
"$TC/bin/aarch64-linux-android24-clang" -shared -fPIC \
    -I"$PYINC/include/python3.14" pyext_test.c -o pyext_test.so
file pyext_test.so | grep -q "ARM aarch64" || { echo "toolchain smoke test FAILED"; exit 1; }
echo "toolchain OK: NDK + Termux python 3.14 + libs + patchelf"
