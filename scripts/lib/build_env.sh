#!/usr/bin/env bash
# build_env.sh — single source of truth for build versions.
#
# Sourced by 00/10/11/20/30 (after HERMES_WORK is set). Derives every
# version-dependent path from versions.env so that bumping a version there
# cannot silently desync from a hardcoded path elsewhere (the P1-18 trap:
# NDK_VERSION was read by zero scripts while `android-ndk-r27c` was
# hardcoded in 6 files).
#
# Exports:
#   TERMUX_PACKAGES_URL   read by scripts/lib/termux_deb.py via os.environ
#   HERMES_ANDROID_API    e.g. 24
#   HERMES_TARGET_TRIPLE  e.g. aarch64-linux-android24 (NDK clang prefix)
#   HERMES_NDK_DIR        e.g. $HERMES_WORK/toolchain/android-ndk-r27c/.../linux-x86_64
#   HERMES_PYVER          e.g. 3.14 (target python major.minor)
#   HERMES_PYVER_FULL     e.g. 3.14.6
#   HERMES_NODE_MAJOR     e.g. 24
set -eu

_BUILD_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$_BUILD_ENV_DIR/../../versions.env"
unset _BUILD_ENV_DIR

: "${HERMES_WORK:?set HERMES_WORK before sourcing build_env.sh}"

# this build is aarch64-only by design; fail fast if versions.env disagrees
[ "$ANDROID_ARCH" = "aarch64" ] || {
    echo "build_env.sh: ANDROID_ARCH=$ANDROID_ARCH not supported (only aarch64)" >&2
    exit 1
}

export TERMUX_PACKAGES_URL
export HERMES_ANDROID_API="$ANDROID_API"
export HERMES_TARGET_TRIPLE="aarch64-linux-android${ANDROID_API}"
export HERMES_NDK_DIR="$HERMES_WORK/toolchain/android-ndk-${NDK_VERSION}/toolchains/llvm/prebuilt/linux-x86_64"
export HERMES_PYVER="${TERMUX_PYTHON_VERSION%.*}"
export HERMES_PYVER_FULL="$TERMUX_PYTHON_VERSION"
export HERMES_NODE_MAJOR="$NODE_MAJOR"
