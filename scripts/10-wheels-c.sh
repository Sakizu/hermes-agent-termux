#!/usr/bin/env bash
# 10-wheels-c.sh — setuptools-C wheel track (cffi, httptools, markupsafe,
# pillow-heif, psutil), cross-compiled for aarch64-linux-android24, cp314.
#
# Recipe (from the 2026-10-04 build log, WB track):
#   1. sdist (or git checkout for psutil) per native_deps.py, sha-verified
#   2. build under a venv with modern setuptools (host setuptools is too old
#      for some pyproject.toml files)
#   3. xrun.py (sysconfig sanitize) + build_py build_ext under xenv.sh
#   4. assemble_wheel.py with the honest android tag
#   5. upstream scripts/termux/python_linkage.py::repair_wheel
#      (patchelf --add-needed libpython3.14.so)
#
# Env: HERMES_WORK, HERMES_SRC (pristine upstream checkout, read-only use).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/versions.env"

: "${HERMES_WORK:?set HERMES_WORK}"
: "${HERMES_SRC:?set HERMES_SRC (pristine upstream checkout)}"

TC_DIR="$HERMES_WORK/toolchain"
C_DIR="$HERMES_WORK/wheels-c"
WHEELS_OUT="$HERMES_WORK/wheelhouse"
mkdir -p "$C_DIR" "$WHEELS_OUT" "$C_DIR/src" "$C_DIR/tools"

LIB="$SCRIPT_DIR/lib"
export HERMES_TC="$TC_DIR/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64"
export HERMES_TERMUX_PY="$TC_DIR/termux-py/data/data/com.termux/files/usr"
export HERMES_TERMUX_LIB="$HERMES_TERMUX_PY/lib"
export HERMES_TOOLS="$TC_DIR/tools"
# shellcheck disable=SC1091
source "$LIB/xenv.sh"

# Build venv with a setuptools new enough to parse modern pyproject.toml.
if [ ! -x "$C_DIR/venv/bin/python" ]; then
    python3 -m venv "$C_DIR/venv"
    "$C_DIR/venv/bin/pip" install -q "setuptools==84.0.0" "wheel==0.48.0" "packaging"
fi
VPY="$C_DIR/venv/bin/python"

fetch_sdist() { # $1=url $2=sha256 $3=dest
    if [ ! -f "$3" ]; then curl -sSL --retry 3 -o "$3" "$1"; fi
    echo "$2  $3" | sha256sum -c -
}

verify_so() { # $1=wheel
    tmp="$C_DIR/verify"; rm -rf "$tmp"; mkdir -p "$tmp"
    (cd "$tmp" && unzip -q -o "$1" '*.so')
    find "$tmp" -name '*.so' | while read -r so; do
        file "$so" | grep -q "ARM aarch64" || { echo "NOT aarch64: $so"; exit 1; }
        "$HERMES_TC/bin/llvm-readelf" -d "$so" | grep -q "libpython3.14.so" \
            || echo "note: $so has no libpython3.14.so NEEDED (abi3?)"
    done
    echo "verify OK: $1"
}

# --- per-package build ------------------------------------------------
build_one() { # $1=name $2=version $3=url $4=sha256 $5=extra ("abi3"|"")
    local name="$1" ver="$2" url="$3" sha="$4" extra="${5:-}"
    local tarball="$C_DIR/src/$(basename "$url")"
    # the sdist top dir may normalize -/_ differently than $name
    # (e.g. pillow_heif-1.6.0.tar.gz extracts to pillow_heif-1.6.0/)
    local srcdir
    if [ -f "$tarball" ]; then
        srcdir="$C_DIR/src/$(tar -tzf "$tarball" | head -1 | cut -d/ -f1)"
    else
        srcdir="$C_DIR/src/${name}-${ver}"
    fi
    if [ ! -d "$srcdir" ]; then
        fetch_sdist "$url" "$sha" "$tarball"
        tar --no-same-owner -xzf "$tarball" -C "$C_DIR/src"
        srcdir="$C_DIR/src/$(tar -tzf "$tarball" | head -1 | cut -d/ -f1)"
    fi
    cd "$srcdir"

    # per-package quirks (from the build log)
    case "$name" in
        cffi)
            export PKG_CONFIG_PATH="$TC_DIR/termux-libs/libffi/data/data/com.termux/files/usr/lib/pkgconfig"
            export PKG_CONFIG_SYSROOT_DIR="$TC_DIR/termux-libs/libffi"
            ;;
        pillow-heif)
            export LIBHEIF_ROOT="$TC_DIR/termux-libs/libheif/data/data/com.termux/files/usr"
            export HERMES_CROSS_BUILD=1
            # setup.py's linux branch unconditionally adds /usr/include etc.;
            # the host headers shadow the NDK sysroot. Skip them when
            # cross-building.
            if grep -q 'HERMES_CROSS_BUILD' setup.py; then
                echo "pillow-heif setup.py already patched"
            elif grep -q '"/usr/include"' setup.py; then
                # the linux branch is a bare `else:` ("let's assume it's some
                # kind of linux"); guard the host /usr paths so they don't
                # shadow the NDK sysroot when cross-building. libheif itself
                # comes from LIBHEIF_ROOT (handled by setup.py).
                python3 - "$srcdir/setup.py" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''        else:  # let's assume it's some kind of linux
            # this old code waiting for refactoring, when time comes.
            self._add_directory(include_dirs, "/usr/local/include")
            self._add_directory(include_dirs, "/usr/include")
            self._add_directory(library_dirs, "/usr/local/lib")
            self._add_directory(library_dirs, "/usr/lib64")
            self._add_directory(library_dirs, "/usr/lib")
            self._add_directory(library_dirs, "/lib")
'''
new = '''        else:  # let's assume it's some kind of linux
            # this old code waiting for refactoring, when time comes.
            # HERMES_CROSS_BUILD: skip host paths when cross-compiling.
            if not os.environ.get("HERMES_CROSS_BUILD"):
                self._add_directory(include_dirs, "/usr/local/include")
                self._add_directory(include_dirs, "/usr/include")
                self._add_directory(library_dirs, "/usr/local/lib")
                self._add_directory(library_dirs, "/usr/lib64")
                self._add_directory(library_dirs, "/usr/lib")
                self._add_directory(library_dirs, "/lib")
'''
assert old in s, "pillow-heif setup.py linux-branch pattern not found"
open(p, "w").write(s.replace(old, new, 1))
print("patched pillow-heif setup.py for cross build")
EOF
            fi
            ;;
    esac

    rm -rf build
    "$VPY" "$LIB/xrun.py" build_py build_ext
    local buildlib
    buildlib="$(echo build/lib.*)"
    if [ "$extra" = "abi3" ]; then
        "$VPY" "$LIB/assemble_wheel.py" --src "$srcdir" --build-lib "$buildlib" \
            --dist "$name" --version "$ver" --out "$WHEELS_OUT" \
            --abi3-tag "cp38-abi3-android_24_arm64_v8a"
        local whl="$WHEELS_OUT/${name//-/_}-${ver}-cp38-abi3-android_24_arm64_v8a.whl"
    else
        "$VPY" "$LIB/assemble_wheel.py" --src "$srcdir" --build-lib "$buildlib" \
            --dist "$name" --version "$ver" --out "$WHEELS_OUT"
        local whl="$WHEELS_OUT/${name//-/_}-${ver}-cp314-cp314-android_24_arm64_v8a.whl"
    fi
    # repair_wheel via upstream's script (read-only import from pristine checkout)
    PATH="$HERMES_TOOLS:$PATH" "$VPY" - "$whl" "$HERMES_TERMUX_LIB/libpython3.14.so" <<EOF
import sys
sys.path.insert(0, "$HERMES_SRC/scripts/termux")
from pathlib import Path
from python_linkage import repair_wheel
n = repair_wheel(Path("$whl"), Path("$HERMES_TERMUX_LIB/libpython3.14.so"))
print(f"linkage repair: {n} extensions touched")
EOF
    verify_so "$whl"
    unset PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR LIBHEIF_ROOT HERMES_CROSS_BUILD || true
}

# --- psutil (git pin, abi3) -------------------------------------------
build_psutil() { # $1=version $2=git-url $3=rev
    local ver="$1" url="$2" rev="$3"
    local srcdir="$C_DIR/src/psutil-$ver"
    if [ ! -d "$srcdir/.git" ]; then
        rm -rf "$srcdir" && git clone -q "$url" "$srcdir"
    fi
    (cd "$srcdir" && git fetch -q origin && git checkout -q "$rev")
    cd "$srcdir"
    # PKG-INFO does not exist in a git checkout: generate via egg_info
    # (uses psutil's own scripts/internal/, no network). egg_info writes
    # psutil.egg-info/PKG-INFO; assemble_wheel.py wants top-level PKG-INFO.
    if [ ! -f PKG-INFO ]; then
        "$VPY" "$LIB/xrun.py" egg_info -e .
        cp psutil.egg-info/PKG-INFO PKG-INFO
    fi
    rm -rf build
    "$VPY" "$LIB/xrun.py" build_py build_ext
    local buildlib; buildlib="$(echo build/lib.*)"
    "$VPY" "$LIB/assemble_wheel.py" --src "$srcdir" --build-lib "$buildlib" \
        --dist psutil --version "$ver" --out "$WHEELS_OUT" \
        --abi3-tag "cp38-abi3-android_24_arm64_v8a"
    local whl="$WHEELS_OUT/psutil-${ver}-cp38-abi3-android_24_arm64_v8a.whl"
    PATH="$HERMES_TOOLS:$PATH" "$VPY" - <<EOF
import sys
sys.path.insert(0, "$HERMES_SRC/scripts/termux")
from pathlib import Path
from python_linkage import repair_wheel
n = repair_wheel(Path("$whl"), Path("$HERMES_TERMUX_LIB/libpython3.14.so"))
print(f"linkage repair: {n} extensions touched")
EOF
    verify_so "$whl"
}

# --- main: cffi FIRST (unblocks nothing here, but keep the proven order) ---
DEPS_JSON="$("$VPY" "$LIB/native_deps.py" "$HERMES_SRC/uv.lock")"
get() { # $1=name $2=field
    echo "$DEPS_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(p['$2'] for p in d if p['name']=='$1'))"
}

for name in cffi httptools markupsafe pillow-heif; do
    build_one "$name" "$(get "$name" version)" "$(get "$name" url)" "$(get "$name" sha256)"
done
build_psutil "$(get psutil version)" "$(get psutil url)" "$(get psutil rev)"

echo "C track complete: $(ls "$WHEELS_OUT"/*.whl | wc -l) wheels in $WHEELS_OUT"
