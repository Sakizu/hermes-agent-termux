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
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.env"

: "${HERMES_WORK:?set HERMES_WORK}"
: "${HERMES_SRC:?set HERMES_SRC}"

TC_DIR="$HERMES_WORK/toolchain"
R_DIR="$HERMES_WORK/wheels-rust"
WHEELS_OUT="$HERMES_WORK/wheelhouse"
mkdir -p "$R_DIR" "$WHEELS_OUT" "$R_DIR/src" "$R_DIR/dist"

LIB="$SCRIPT_DIR/lib"
# venv from the C track (10-wheels-c.sh runs first); has `packaging`
# installed, which native_deps.py needs.
VPY="$HERMES_WORK/wheels-c/venv/bin/python"
export HERMES_TC="$TC_DIR/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64"
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
    if [ ! -f "$3" ]; then curl -sSL --retry 3 -o "$3" "$1"; fi
    echo "$2  $3" | sha256sum -c -
}

verify_wheel() { # $1=wheel
    tmp="$R_DIR/verify"; rm -rf "$tmp"; mkdir -p "$tmp"
    (cd "$tmp" && unzip -q -o "$1" '*.so')
    find "$tmp" -name '*.so' | while read -r so; do
        file "$so" | grep -q "ARM aarch64" || { echo "NOT aarch64: $so"; exit 1; }
    done
    case "$1" in *abi3*) : ;; # abi3 wheels need not link libpython
        *) "$HERMES_TC/bin/llvm-readelf" -d "$tmp"/*/*.so "$tmp"/*.so 2>/dev/null \
               | grep -q "libpython3.14.so" || echo "note: no libpython3.14.so NEEDED in $1";;
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
    mkdir -p "$shim/lib/python3.14"
    ln -sf "$pylib/libpython3.14.so" "$shim/lib/python3.14/libpython3.14.so"
    # pyo3 abi3 emits -lpython3 (stable-ABI name); Termux ships no such stub.
    ln -sf "libpython3.14.so" "$shim/lib/python3.14/libpython3.so"
    local scd; scd="$(echo "$pylib"/python3.14/_sysconfigdata__android*.py | head -1)"
    ln -sf "$scd" "$shim/lib/python3.14/"
    mkdir -p "$shim/include" && ln -sfn "$HERMES_TERMUX_PY/include/python3.14" "$shim/include/python3.14"
    export PYO3_CROSS_LIB_DIR="$shim"
}

# --- main -------------------------------------------------------------
DEPS_JSON="$("$VPY" "$LIB/native_deps.py" "$HERMES_SRC/uv.lock")"
get() { # $1=name $2=field
    echo "$DEPS_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(p['$2'] for p in d if p['name']=='$1'))"
}

for name in jiter pydantic-core watchfiles firecrawl-anydoc cryptography; do
    ver="$(get "$name" version)"; url="$(get "$name" url)"; sha="$(get "$name" sha256)"
    srcdir="$R_DIR/src/${name}-${ver}"
    if [ ! -d "$srcdir" ]; then
        tarball="$R_DIR/src/$(basename "$url")"
        fetch_sdist "$url" "$sha" "$tarball"
        tar --no-same-owner -xzf "$tarball" -C "$R_DIR/src"
    fi
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
