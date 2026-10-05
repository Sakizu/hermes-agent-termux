#!/usr/bin/env bash
# Cross-compilation environment for the setuptools-C wheel track.
# Reconstructed from the 2026-10-04 build log (WB track); the recipe was:
#   CC=$TC/bin/aarch64-linux-android24-clang, Termux python headers FIRST
#   in CFLAGS, Termux lib dir in LDFLAGS, patchelf on PATH.
#
# Required env before sourcing:
#   HERMES_TC       - $BASE/android-ndk-$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64
#   HERMES_TERMUX_PY- extracted Termux python prefix (data/data/com.termux/files/usr)
#   HERMES_TOOLS    - dir holding helper binaries (patchelf)
#   HERMES_TARGET_TRIPLE - e.g. aarch64-linux-android24 (from build_env.sh)
#   HERMES_PYVER    - e.g. 3.14 (from build_env.sh)
set -eu

: "${HERMES_TC:?set HERMES_TC}"
: "${HERMES_TERMUX_PY:?set HERMES_TERMUX_PY}"
: "${HERMES_TOOLS:?set HERMES_TOOLS}"
: "${HERMES_TARGET_TRIPLE:?set HERMES_TARGET_TRIPLE}"
: "${HERMES_PYVER:?set HERMES_PYVER}"

TC="$HERMES_TC"
PY="$HERMES_TERMUX_PY"

export CC="$TC/bin/${HERMES_TARGET_TRIPLE}-clang"
export CXX="$TC/bin/${HERMES_TARGET_TRIPLE}-clang++"
export AR="$TC/bin/llvm-ar"
export RANLIB="$TC/bin/llvm-ranlib"
# LDSHARED must be the cross linker: otherwise host gcc links x86_64 output.
export LDSHARED="$CC -shared"
# Termux python headers FIRST so the NDK sysroot never shadows them.
export CFLAGS="-I$PY/include/python${HERMES_PYVER}"
export LDFLAGS="-L$PY/lib"
export PATH="$HERMES_TOOLS:$TC/bin:$PATH"
