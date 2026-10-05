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
#      (patchelf --add-needed libpython${HERMES_PYVER}.so)
#
# Env: HERMES_WORK, HERMES_SRC (pristine upstream checkout, read-only use).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${HERMES_WORK:?set HERMES_WORK}"
: "${HERMES_SRC:?set HERMES_SRC (pristine upstream checkout)}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/build_env.sh"  # versions.env + derived paths

TC_DIR="$HERMES_WORK/toolchain"
C_DIR="$HERMES_WORK/wheels-c"
WHEELS_OUT="$HERMES_WORK/wheelhouse"
mkdir -p "$C_DIR" "$WHEELS_OUT" "$C_DIR/src" "$C_DIR/tools"

LIB="$SCRIPT_DIR/lib"
export HERMES_TC="$HERMES_NDK_DIR"
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
# produce a bogus srcdir that breaks confusingly much later
tarball_topdir() { # $1=tarball -> prints top dir name
    local top
    top="$(tar -tzf "$1" | head -1)" || { echo "tarball_topdir: cannot list $1" >&2; return 1; }
    top="${top#./}"
    top="${top%%/*}"
    [ -n "$top" ] || { echo "tarball_topdir: empty top dir in $1" >&2; return 1; }
    printf '%s' "$top"
}

verify_so() { # $1=wheel
    tmp="$C_DIR/verify"; rm -rf "$tmp"; mkdir -p "$tmp"
    (cd "$tmp" && unzip -q -o "$1" '*.so')
    find "$tmp" -name '*.so' | while read -r so; do
        file "$so" | grep -q "ARM aarch64" || { echo "NOT aarch64: $so"; exit 1; }
        "$HERMES_TC/bin/llvm-readelf" -d "$so" | grep -q "libpython${HERMES_PYVER}.so" \
            || echo "note: $so has no libpython${HERMES_PYVER}.so NEEDED (abi3?)"
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
        srcdir="$C_DIR/src/$(tarball_topdir "$tarball")"
    else
        srcdir="$C_DIR/src/${name}-${ver}"
    fi
    if [ ! -d "$srcdir" ]; then
        fetch_sdist "$url" "$sha" "$tarball"
        tar --no-same-owner -xzf "$tarball" -C "$C_DIR/src"
        srcdir="$C_DIR/src/$(tarball_topdir "$tarball")"
    fi
    [ -d "$srcdir" ] || { echo "build_one: no source dir for $name" >&2; exit 1; }
    cd "$srcdir"
    # drop stale wheels of this dist so re-runs never bundle old versions
    rm -f "$WHEELS_OUT/${name//-/_}-"*.whl

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
    # exactly one build/lib.* dir must exist; anything else is a broken build
    shopt -s nullglob
    local buildlibs=(build/lib.*)
    shopt -u nullglob
    [ "${#buildlibs[@]}" -eq 1 ] || { echo "build_one($name): expected 1 build/lib.*, found ${#buildlibs[@]}" >&2; exit 1; }
    local buildlib="${buildlibs[0]}"
    if [ "$extra" = "abi3" ]; then
        "$VPY" "$LIB/assemble_wheel.py" --src "$srcdir" --build-lib "$buildlib" \
            --dist "$name" --version "$ver" --out "$WHEELS_OUT" \
            --abi3-tag "cp38-abi3-android_${HERMES_ANDROID_API}_arm64_v8a"
        local whl="$WHEELS_OUT/${name//-/_}-${ver}-cp38-abi3-android_${HERMES_ANDROID_API}_arm64_v8a.whl"
    else
        "$VPY" "$LIB/assemble_wheel.py" --src "$srcdir" --build-lib "$buildlib" \
            --dist "$name" --version "$ver" --out "$WHEELS_OUT" \
            --tag "cp${HERMES_PYVER//./}-cp${HERMES_PYVER//./}-android_${HERMES_ANDROID_API}_arm64_v8a"
        local whl="$WHEELS_OUT/${name//-/_}-${ver}-cp${HERMES_PYVER//./}-cp${HERMES_PYVER//./}-android_${HERMES_ANDROID_API}_arm64_v8a.whl"
    fi
    # repair_wheel via upstream's script (read-only import from pristine checkout)
    HERMES_WHL="$whl" HERMES_SRC_DIR="$HERMES_SRC" HERMES_PYLIB="$HERMES_TERMUX_LIB/libpython${HERMES_PYVER}.so" \
    PATH="$HERMES_TOOLS:$PATH" "$VPY" <<'EOF'
import os, sys
sys.path.insert(0, os.environ["HERMES_SRC_DIR"] + "/scripts/termux")
from pathlib import Path
from python_linkage import repair_wheel
whl = Path(os.environ["HERMES_WHL"])
n = repair_wheel(whl, Path(os.environ["HERMES_PYLIB"]))
print(f"linkage repair: {n} extensions touched")
EOF
    verify_so "$whl"
    unset PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR LIBHEIF_ROOT HERMES_CROSS_BUILD HERMES_WHL HERMES_SRC_DIR HERMES_PYLIB || true
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
    shopt -s nullglob
    local buildlibs=(build/lib.*)
    shopt -u nullglob
    [ "${#buildlibs[@]}" -eq 1 ] || { echo "build_psutil: expected 1 build/lib.*, found ${#buildlibs[@]}" >&2; exit 1; }
    local buildlib="${buildlibs[0]}"
    "$VPY" "$LIB/assemble_wheel.py" --src "$srcdir" --build-lib "$buildlib" \
        --dist psutil --version "$ver" --out "$WHEELS_OUT" \
        --abi3-tag "cp38-abi3-android_${HERMES_ANDROID_API}_arm64_v8a"
    local whl="$WHEELS_OUT/psutil-${ver}-cp38-abi3-android_${HERMES_ANDROID_API}_arm64_v8a.whl"
    # drop stale psutil wheels so re-runs never bundle old versions
    rm -f "$WHEELS_OUT"/psutil-*.whl
    HERMES_WHL="$whl" HERMES_SRC_DIR="$HERMES_SRC" HERMES_PYLIB="$HERMES_TERMUX_LIB/libpython${HERMES_PYVER}.so" \
    PATH="$HERMES_TOOLS:$PATH" "$VPY" <<'EOF'
import os, sys
sys.path.insert(0, os.environ["HERMES_SRC_DIR"] + "/scripts/termux")
from pathlib import Path
from python_linkage import repair_wheel
whl = Path(os.environ["HERMES_WHL"])
n = repair_wheel(whl, Path(os.environ["HERMES_PYLIB"]))
print(f"linkage repair: {n} extensions touched")
EOF
    verify_so "$whl"
}

# --- main: cffi FIRST (unblocks nothing here, but keep the proven order) ---
DEPS_JSON="$("$VPY" "$LIB/native_deps.py" "$HERMES_SRC/uv.lock")"
get() { # $1=name $2=field -> value, or empty if upstream dropped the dep
    echo "$DEPS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
ms = [p['$2'] for p in d if p['name'] == '$1']
print(ms[0] if ms else '')
"
}

for name in cffi httptools markupsafe pillow-heif; do
    ver="$(get "$name" version)"
    if [ -z "$ver" ]; then
        echo "10-wheels-c.sh: upstream dropped '$name'; skipping"
        continue
    fi
    build_one "$name" "$ver" "$(get "$name" url)" "$(get "$name" sha256)"
done
psutil_ver="$(get psutil version)"
if [ -z "$psutil_ver" ]; then
    echo "10-wheels-c.sh: upstream dropped 'psutil'; skipping"
else
    build_psutil "$psutil_ver" "$(get psutil url)" "$(get psutil rev)"
fi

echo "C track complete: $(ls "$WHEELS_OUT"/*.whl | wc -l) wheels in $WHEELS_OUT"
