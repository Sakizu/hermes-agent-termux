#!/usr/bin/env bash
# build.sh — master orchestrator for the hermes-agent Termux-native .deb.
#
# Usage: build.sh [--ref <tag|commit>] [--work <dir>]
#
#   --ref   upstream tag (e.g. v2026.9.24) or 40-hex commit to build from.
#           Default: latest upstream release tag from the GitHub API.
#   --work  writable build directory. Default: <repo>/.build-work.
#
# Pipeline (each step must succeed; failure names the step and aborts):
#   00-toolchain.sh  NDK + Termux python headers/libs + patchelf
#   10-wheels-c.sh   setuptools-C native wheels (cffi, httptools, …)
#   11-wheels-rust.sh maturin native wheels (jiter, pydantic-core, …)
#   20-tui.sh        prebuilt TUI bundle
#   30-assemble.sh   patches + site/ + launchers + dpkg-deb + QA
#
# Re-running with the same --work dir is cheap: every step skips work that
# is already done (verified downloads, existing venvs, extracted trees).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.env"

REF=""
WORK="${HERMES_WORK:-$REPO_ROOT/.build-work}"
while [ $# -gt 0 ]; do
    case "$1" in
        --ref)  REF="${2:?--ref needs a value}"; shift 2 ;;
        --work) WORK="${2:?--work needs a value}"; shift 2 ;;
        -h|--help)
            sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "build.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# --- resolve the ref (default: latest upstream release tag) ---
if [ -z "$REF" ]; then
    REF="$(curl -sSL --retry 3 \
        "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
    echo "build.sh: no --ref given; using latest upstream release: $REF"
fi

# --- fresh upstream checkout at the ref ---
mkdir -p "$WORK"
HERMES_WORK="$(cd "$WORK" && pwd)"   # absolute, no matter how --work was given
SRC="$HERMES_WORK/upstream"
rm -rf "$SRC"
if [[ "$REF" =~ ^[0-9a-f]{40}$ ]]; then
    # raw commit: tags can't address it, so clone fully then check out
    git clone -q "https://github.com/${UPSTREAM_REPO}.git" "$SRC"
    git -C "$SRC" checkout -q "$REF"
else
    git clone -q --depth 1 --branch "$REF" \
        "https://github.com/${UPSTREAM_REPO}.git" "$SRC"
fi
ACTUAL_REF="$(git -C "$SRC" rev-parse HEAD)"
echo "build.sh: upstream $UPSTREAM_REPO @ $ACTUAL_REF (ref: $REF)"

# --- deb version follows upstream (tags) or the commit (untagged) ---
# A caller (e.g. CI) may pre-set DEB_VERSION to control the Debian revision;
# otherwise derive it here (revision defaults to 1).
if [ -z "${DEB_VERSION:-}" ]; then
    DEB_VERSION="$(python3 "$SCRIPT_DIR/deb_version.py" "$REF")"
fi
echo "build.sh: deb version $DEB_VERSION"

# --- run the pipeline ---
export HERMES_WORK HERMES_SRC="$SRC" UPSTREAM_REF="$REF" DEB_VERSION

run_step() { # $1=script name under scripts/
    echo "=== build.sh: step $1 ==="
    if ! bash "$SCRIPT_DIR/$1"; then
        echo "build.sh: FAILED at step $1" >&2
        exit 1
    fi
}

run_step 00-toolchain.sh
run_step 10-wheels-c.sh
run_step 11-wheels-rust.sh
run_step 20-tui.sh
run_step 30-assemble.sh

# --- final artifact check ---
DEB="$HERMES_WORK/hermes-agent_${DEB_VERSION}_aarch64.deb"
if [ ! -f "$DEB" ]; then
    echo "build.sh: expected artifact missing: $DEB" >&2
    exit 1
fi
echo "build.sh: DONE -> $DEB ($(du -h "$DEB" | cut -f1))"
