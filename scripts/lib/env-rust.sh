#!/usr/bin/env bash
# Cross-compilation environment for the maturin/Rust wheel track.
# Values transcribed from the 2026-10-04 build log (WA track).
#
# Required env before sourcing:
#   HERMES_TC        - $BASE/android-ndk-$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64
#   HERMES_TERMUX_PY - extracted Termux python prefix (data/data/com.termux/files/usr)
#   HERMES_CARGO_HOME- cargo home (rustup-installed toolchain lives here)
#   HERMES_WORK      - writable work dir for CARGO_TARGET_DIR/TMPDIR
#                      (NOT /tmp: some runners mount /tmp as a small tmpfs)
#   HERMES_TARGET_TRIPLE - e.g. aarch64-linux-android24 (from build_env.sh)
#   HERMES_ANDROID_API   - e.g. 24 (from build_env.sh)
#   HERMES_PYVER         - e.g. 3.14 (from build_env.sh)
set -eu

: "${HERMES_TC:?set HERMES_TC}"
: "${HERMES_TERMUX_PY:?set HERMES_TERMUX_PY}"
: "${HERMES_CARGO_HOME:?set HERMES_CARGO_HOME}"
: "${HERMES_WORK:?set HERMES_WORK}"
: "${HERMES_TARGET_TRIPLE:?set HERMES_TARGET_TRIPLE}"
: "${HERMES_ANDROID_API:?set HERMES_ANDROID_API}"
: "${HERMES_PYVER:?set HERMES_PYVER}"

TC="$HERMES_TC"
PY="$HERMES_TERMUX_PY"

export PATH="$HERMES_CARGO_HOME/bin:$PATH"
# rustup honors CARGO_HOME/RUSTUP_HOME for where it installs; without these
# it lands in ~/.cargo while every script looks in $HERMES_CARGO_HOME.
export CARGO_HOME="$HERMES_CARGO_HOME"
export RUSTUP_HOME="$HERMES_CARGO_HOME"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TC/bin/${HERMES_TARGET_TRIPLE}-clang"
export CC_aarch64_linux_android="$TC/bin/${HERMES_TARGET_TRIPLE}-clang"
export CXX_aarch64_linux_android="$TC/bin/${HERMES_TARGET_TRIPLE}-clang++"
export AR_aarch64_linux_android="$TC/bin/llvm-ar"
export CFLAGS_aarch64_linux_android="--sysroot=$TC/sysroot"
export CXXFLAGS_aarch64_linux_android="--sysroot=$TC/sysroot"
export LDFLAGS_aarch64_linux_android="--sysroot=$TC/sysroot"
# Fallbacks for build scripts that ignore the _target-suffixed vars:
export CC="$TC/bin/${HERMES_TARGET_TRIPLE}-clang"
export CXX="$TC/bin/${HERMES_TARGET_TRIPLE}-clang++"
export AR="$TC/bin/llvm-ar"

export ANDROID_API_LEVEL="$HERMES_ANDROID_API"
export PYO3_CROSS_LIB_DIR="$PY/lib"
export PYO3_CROSS_PYTHON_VERSION="$HERMES_PYVER"
export CARGO_NET_RETRY=10
export CARGO_TARGET_DIR="$HERMES_WORK/cargo-target"
export TMPDIR="$HERMES_WORK/tmp"
mkdir -p "$CARGO_TARGET_DIR" "$TMPDIR"
