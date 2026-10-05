#!/usr/bin/env bash
# 11-wheels-rust.sh — maturin/Rust wheel track
# (jiter, pydantic-core, watchfiles, firecrawl-anydoc, cryptography),
# cross-compiled for aarch64-linux-android (API 24).
#
# Recipe (from the 2026-10-04 build log, WA track):
#   maturin build --release --target aarch64-linux-android
# under env-rust.sh (PYO3_CROSS_LIB_DIR + PYO3_CROSS_PYTHON_VERSION, no -i
# flag needed: maturin 1.15 cross path emits cp314/abi3 + android tags).
# Do NOT use `pip wheel` / maturin pep517 here: they build for the host.
#
# Env: HERMES_WORK, HERMES_SRC (pristine upstream checkout, read-only).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${HERMES_WORK:?set HERMES_WORK}"
: "${HERMES_SRC:?set HERMES_SRC}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/build_env.sh"  # versions.env + derived paths

TC_DIR="$HERMES_WORK/toolchain"
R_DIR="$HERMES_WORK/wheels-rust"
WHEELS_OUT="$HERMES_WORK/wheelhouse"
mkdir -p "$R_DIR" "$WHEELS_OUT" "$R_DIR/src" "$R_DIR/dist"

LIB="$SCRIPT_DIR/lib"
# venv from the C track (10-wheels-c.sh runs first); has `packaging`
# installed, which native_deps.py needs.
VPY="$HERMES_WORK/wheels-c/venv/bin/python"
export HERMES_TC="$HERMES_NDK_DIR"
export HERMES_TERMUX_PY="$TC_DIR/termux-py/data/data/com.termux/files/usr"
export HERMES_CARGO_HOME="$HERMES_WORK/cargo-home"
export HERMES_WORK="$HERMES_WORK"
# shellcheck disable=SC1091
source "$LIB/env-rust.sh"

# --- Rust toolchain ---
if [ ! -x "$HERMES_CARGO_HOME/bin/rustc" ]; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain "$RUST_TOOLCHAIN"
fi
"$HERMES_CARGO_HOME/bin/rustup" target add aarch64-linux-android

# --- maturin in an isolated venv (host pip may be PEP-668-blocked) ---
if [ ! -x "$HERMES_WORK/tools-venv/bin/maturin" ]; then
    python3 -m venv "$HERMES_WORK/tools-venv"
    "$HERMES_WORK/tools-venv/bin/pip" install -q "maturin==$MATURIN_VERSION"
fi
export PATH="$HERMES_WORK/tools-venv/bin:$PATH"
maturin --version

# --- helpers ----------------------------------------------------------
fetch_sdist() { # $1=url $2=sha256 $3=dest
    # --fail: a 404 must not be cached as a "successful" HTML download.
    # If the cached file fails the hash check it is corrupt/stale: delete
    # it and re-download once instead of aborting every future re-run.
    if [ -f "$3" ] && ! echo "$2  $3" | sha256sum -c - >/dev/null 2>&1; then
        echo "fetch_sdist: cached $(basename "$3") failed sha256; re-downloading"
        rm -f "$3"
    fi
    if [ ! -f "$3" ]; then curl -sSL --fail --retry 3 -o "$3" "$1"; fi
    echo "$2  $3" | sha256sum -c -
}

# top dir of a tarball, validated: tar failures must abort here, not
# produce a bogus srcdir that breaks confusingly much later.
# NB: no `| head -1` pipe here — under `set -o pipefail` tar exits 141
# (SIGPIPE) when head closes the pipe, which would false-positive.
tarball_topdir() { # $1=tarball -> prints top dir name
    local listing
    if ! listing="$(tar -tzf "$1" 2>/dev/null)"; then
        echo "tarball_topdir: cannot list $1" >&2; return 1
    fi
    local top="${listing%%$'\n'*}"
    top="${top#./}"
    top="${top%%/*}"
    [ -n "$top" ] || { echo "tarball_topdir: empty top dir in $1" >&2; return 1; }
    printf '%s' "$top"
}

verify_wheel() { # $1=wheel
    tmp="$R_DIR/verify"; rm -rf "$tmp"; mkdir -p "$tmp"
    (cd "$tmp" && unzip -q -o "$1" '*.so')
    find "$tmp" -name '*.so' | while read -r so; do
        file "$so" | grep -q "ARM aarch64" || { echo "NOT aarch64: $so"; exit 1; }
    done
    case "$1" in *abi3*) : ;; # abi3 wheels need not link libpython
        *) "$HERMES_TC/bin/llvm-readelf" -d "$tmp"/*/*.so "$tmp"/*.so 2>/dev/null \
               | grep -q "libpython${HERMES_PYVER}.so" || echo "note: no libpython${HERMES_PYVER}.so NEEDED in $1";;
    esac
    echo "verify OK: $(basename "$1")"
}

# --- cryptography extras (from the build log, quirk 5) ----------------
setup_cryptography_env() {
    local ossldir="$TC_DIR/termux-libs/openssl/data/data/com.termux/files/usr"
    export OPENSSL_DIR="$ossldir"
    export OPENSSL_NO_PKG_CONFIG=1
    # host build-time deps: cryptography's build.rs runs host python
    # (../../_cffi_src/build_openssl.py, imports cffi) to generate _openssl.c
    "$HERMES_WORK/tools-venv/bin/pip" install -q "cffi==2.1.1" setuptools
    # PYO3_CROSS_LIB_DIR shim: cryptography's build.rs, pyo3-build-config and
    # maturin's mixed-project path each expect a different layout; this shim
    # satisfies all three (see build log quirk 5).
    local shim="$R_DIR/pyo3-cross"
    local pylib="$HERMES_TERMUX_PY/lib"
    mkdir -p "$shim/lib/python${HERMES_PYVER}"
    ln -sf "$pylib/libpython${HERMES_PYVER}.so" "$shim/lib/python${HERMES_PYVER}/libpython${HERMES_PYVER}.so"
    # pyo3 abi3 emits -lpython3 (stable-ABI name); Termux ships no such stub.
    ln -sf "libpython${HERMES_PYVER}.so" "$shim/lib/python${HERMES_PYVER}/libpython3.so"
    local scd; scd="$(echo "$pylib"/python${HERMES_PYVER}/_sysconfigdata__android*.py | head -1)"
    ln -sf "$scd" "$shim/lib/python${HERMES_PYVER}/"
    mkdir -p "$shim/include" && ln -sfn "$HERMES_TERMUX_PY/include/python${HERMES_PYVER}" "$shim/include/python${HERMES_PYVER}"
    # cryptography-cffi's build.rs derives the Python include dir from
    # PYO3_CROSS_LIB_DIR as <prefix>/include/<last-path-component>, so it
    # must point at <shim>/lib/python3.14 (not $shim itself) for the
    # include to resolve to $shim/include/python${HERMES_PYVER}.
    export PYO3_CROSS_LIB_DIR="$shim/lib/python${HERMES_PYVER}"
}

# --- main -------------------------------------------------------------
DEPS_JSON="$("$VPY" "$LIB/native_deps.py" "$HERMES_SRC/uv.lock")"
get() { # $1=name $2=field -> value, or empty if upstream dropped the dep
    echo "$DEPS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ms = [p['$2'] for p in d if p['name'] == '$1']
print(ms[0] if ms else '')
"
}

# fresh dist dir: only wheels built by this run are collected below,
# so a removed/bumped dep never leaves a stale wheel behind
rm -f "$R_DIR"/dist/*.whl

for name in jiter pydantic-core watchfiles firecrawl-anydoc cryptography; do
    ver="$(get "$name" version)"
    if [ -z "$ver" ]; then
        echo "11-wheels-rust.sh: upstream dropped '$name'; skipping"
        continue
    fi
    url="$(get "$name" url)"; sha="$(get "$name" sha256)"
    tarball="$R_DIR/src/$(basename "$url")"
    # the sdist top dir may normalize -/_ differently than $name
    # (e.g. pydantic_core-2.46.4.tar.gz extracts to pydantic_core-2.46.4/)
    if [ -f "$tarball" ]; then
        srcdir="$R_DIR/src/$(tarball_topdir "$tarball")"
    else
        srcdir="$R_DIR/src/${name}-${ver}"
    fi
    if [ ! -d "$srcdir" ]; then
        fetch_sdist "$url" "$sha" "$tarball"
        tar --no-same-owner -xzf "$tarball" -C "$R_DIR/src"
        srcdir="$R_DIR/src/$(tarball_topdir "$tarball")"
    fi
    [ -d "$srcdir" ] || { echo "11-wheels-rust.sh: no source dir for $name" >&2; exit 1; }
    # drop stale wheels of this dist so re-runs never bundle old versions
    rm -f "$WHEELS_OUT/${name//-/_}-"*.whl
    if [ "$name" = "cryptography" ]; then setup_cryptography_env; fi
    (cd "$srcdir" && maturin build --release --target aarch64-linux-android \
        --out "$R_DIR/dist")
    if [ "$name" = "cryptography" ]; then
        # restore the plain PYO3_CROSS_LIB_DIR for any later crates
        export PYO3_CROSS_LIB_DIR="$HERMES_TERMUX_PY/lib"
        unset OPENSSL_DIR OPENSSL_NO_PKG_CONFIG
    fi
done

# collect wheels (keep the tags exactly as maturin produced them)
for whl in "$R_DIR"/dist/*.whl; do
    cp "$whl" "$WHEELS_OUT/"
    verify_wheel "$WHEELS_OUT/$(basename "$whl")"
done

echo "Rust track complete: $(ls "$WHEELS_OUT"/*.whl | wc -l) wheels in $WHEELS_OUT"
