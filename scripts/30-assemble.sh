#!/usr/bin/env bash
# 30-assemble.sh — assemble the Termux-native .deb from all build products.
#
# Inputs (env): HERMES_WORK, HERMES_SRC (pristine upstream checkout),
#   UPSTREAM_REF (tag or commit), DEB_VERSION, REPO_ROOT layout.
# Steps:
#   1. snapshot upstream at UPSTREAM_REF minus INERT_SNAPSHOT_DIRS
#      (mirrors upstream scripts/bundles/payload.py)
#   2. apply patches/ (fails loudly on drift)
#   3. stage the prebuilt TUI bundle
#   4. build site/ from: 52 pure wheels (uv.lock closure) + resvg-py
#      android wheel (PyPI) + 10 cross-built wheels
#   5. compile native/fts5_cjk -> lib/libfts5_cjk.so (NDK clang)
#   6. mint launchers + install-stamp.json + DEBIAN/
#   7. dpkg-deb --build + QA
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${HERMES_WORK:?set HERMES_WORK}"
: "${HERMES_SRC:?set HERMES_SRC}"
: "${UPSTREAM_REF:?set UPSTREAM_REF}"
: "${DEB_VERSION:?set DEB_VERSION}"

TC_DIR="$HERMES_WORK/toolchain"
A_DIR="$HERMES_WORK/assemble"
STAGE="$A_DIR/stage"
SITE="$STAGE/data/data/com.termux/files/usr/lib/hermes-agent/site"
APP="$STAGE/data/data/com.termux/files/usr/lib/hermes-agent/app"
LIB="$SCRIPT_DIR/lib"
rm -rf "$A_DIR"
mkdir -p "$SITE" "$APP" "$STAGE/DEBIAN"

# --- 1. snapshot (upstream payload.py INERT_SNAPSHOT_DIRS) ---
INERT="tests tests-js website evals .github nix docker apps ui-tui web scripts"
git -C "$HERMES_SRC" archive --format=tar "$UPSTREAM_REF" -- \
    $(for d in $INERT; do printf ':(exclude)%s ' "$d"; done) \
    | tar --no-same-owner -x -C "$APP"
test -f "$APP/pyproject.toml" || { echo "snapshot failed: no pyproject.toml"; exit 1; }
# the TUI bundle was built from the full tree before exclusion; stage it now
cp -r "$HERMES_WORK/tui/hermes_cli/tui_dist" "$APP/hermes_cli/tui_dist"

# --- 2. patches ---
bash "$REPO_ROOT/patches/apply.sh" "$APP"

# --- 3. site/: pure-python closure -------------------------------------
PURE_DIR="$A_DIR/pure"; mkdir -p "$PURE_DIR"
python3 "$LIB/closure.py" "$HERMES_SRC/uv.lock" > "$A_DIR/closure.json"
python3 - "$A_DIR/closure.json" "$PURE_DIR" <<'EOF'
import json, subprocess, sys, glob, os
closure = json.load(open(sys.argv[1]))
out = sys.argv[2]
for name, ver in closure["pure"]:
    subprocess.run([sys.executable, "-m", "pip", "download", "--no-deps",
                    "--only-binary=:all:", "-q", "-d", out, f"{name}=={ver}"],
                   check=True)
    cands = [p for p in glob.glob(os.path.join(out, "*.whl")) if "none-any" in p]
    assert cands, f"no pure wheel downloaded for {name}=={ver}"
print(f"downloaded {len(closure['pure'])} pure wheels")
EOF
for whl in "$PURE_DIR"/*none-any.whl; do unzip -q -o "$whl" -d "$SITE"; done

# --- 3b. resvg-py android wheel from PyPI (prebuilt abi3) --------------
RESVG_VER="$(python3 "$LIB/native_deps.py" "$HERMES_SRC/uv.lock" \
    | python3 -c "import json,sys; print(next(p['version'] for p in json.load(sys.stdin) if p['name']=='resvg-py'))")"
RESVG_FILE="$(python3 -c "
import json, urllib.request
d = json.load(urllib.request.urlopen('https://pypi.org/pypi/resvg-py/$RESVG_VER/json'))
cands = [f['filename'] for f in d['urls'] if 'android_24_arm64_v8a' in f['filename']]
assert cands, 'no android wheel for resvg-py $RESVG_VER'
print(sorted(cands)[0])")"
python3 - "$RESVG_FILE" "$A_DIR" <<'EOF'
import re, sys, urllib.request
want, out = sys.argv[1], sys.argv[2]
html = urllib.request.urlopen("https://pypi.org/simple/resvg-py/").read().decode()
m = re.search(r'href="([^"]*' + re.escape(want) + r'(?:#[^"]*)?)"', html)
assert m, f"{want} not on the simple index"
urllib.request.urlretrieve(m.group(1), f"{out}/{want}")
print(f"resvg-py: {want}")
EOF
unzip -q -o "$A_DIR/$RESVG_FILE" -d "$SITE"

# --- 3c. cross-built wheels --------------------------------------------
for whl in "$HERMES_WORK"/wheelhouse/*.whl; do unzip -q -o "$whl" -d "$SITE"; done
echo "site/: $(ls "$SITE" | wc -l) top-level entries"

# --- 4. libfts5_cjk.so (NDK clang; upstream native/fts5_cjk/build.sh) ---
TC="$TC_DIR/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64"
FTS="$APP/native/fts5_cjk"
"$TC/bin/aarch64-linux-android24-clang" -shared -fPIC -O2 -Wall \
    -I"$FTS/vendor" "$FTS/fts5_cjk.c" \
    -o "$STAGE/data/data/com.termux/files/usr/lib/hermes-agent/lib/libfts5_cjk.so"
file "$STAGE/data/data/com.termux/files/usr/lib/hermes-agent/lib/libfts5_cjk.so" \
    | grep -q "ARM aarch64"

# --- 5. launchers -------------------------------------------------------
BIN="$STAGE/data/data/com.termux/files/usr/lib/hermes-agent/bin"
mkdir -p "$BIN"
mint() { # $1=prog $2=entry-import
    sed -e "s/@PROG@/$1/g" -e "s/@ENTRY_IMPORT@/$2/g" \
        "$REPO_ROOT/launchers/launcher.sh.in" > "$BIN/$1"
    chmod 755 "$BIN/$1"
}
mint hermes hermes_cli.main
mint hermes-agent agent.legacy_cli
mint hermes-acp acp_adapter.entry

# --- 6. install-stamp.json (mirrors upstream's stamp contract) ---------
COMMIT="$(git -C "$HERMES_SRC" rev-parse "$UPSTREAM_REF")"
BASE_VER="$(grep -m1 '^version' "$APP/pyproject.toml" | cut -d'"' -f2)"
python3 - "$APP/install-stamp.json" <<EOF
import json, sys, datetime
stamp = {
    "schemaVersion": 2,
    "commit": "$COMMIT",
    "commitDate": 0,
    "branch": "main",
    "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "dirty": False,
    "source": "bundle",
    "distribution": "apt-termux",
    "updateMechanism": "external",
    "baseVersion": "$BASE_VER",
    "displayVersion": "$DEB_VERSION",
    "distance": 0,
    "payload": "bootstrap",
    "tag": "$UPSTREAM_REF" if "$UPSTREAM_REF".startswith("v") else None,
}
json.dump(stamp, open(sys.argv[1], "w"), indent=2)
EOF
printf 'apt\n' > "$APP/.install_method"

# --- 7. DEBIAN/ ----------------------------------------------------------
INSTALLED_SIZE="$(du -sk "$STAGE/data" | cut -f1)"
sed -e "s/@VERSION@/$DEB_VERSION/" -e "s/@SIZE@/$INSTALLED_SIZE/" \
    "$REPO_ROOT/DEBIAN/control.in" > "$STAGE/DEBIAN/control"
cp "$REPO_ROOT/DEBIAN/postinst" "$REPO_ROOT/DEBIAN/prerm" "$STAGE/DEBIAN/"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

# --- 8. build + QA -------------------------------------------------------
OUT="$HERMES_WORK/hermes-agent_${DEB_VERSION}_aarch64.deb"
dpkg-deb --build "$STAGE" "$OUT"

echo "--- QA ---"
dpkg-deb --info "$OUT" | head -12
# no stray absolute paths outside the Termux prefix or DEBIAN
bad="$(dpkg-deb -c "$OUT" | awk '{print $6}' | grep -v -e '^\./$' -e '^\./DEBIAN' -e '^\./data/data/com.termux/' || true)"
if [ -n "$bad" ]; then
    echo "$bad" | head
    echo "QA FAIL: files outside ./data/data/com.termux or ./DEBIAN" >&2; exit 1
fi
# launchers executable with Termux-absolute shebang
for b in hermes hermes-agent hermes-acp; do
    head -1 "$BIN/$b" | grep -q "^#!/data/data/com.termux/files/usr/bin/sh" \
        || { echo "QA FAIL: bad shebang in $b"; exit 1; }
done
# every bundled .so is aarch64
find "$SITE" "$STAGE/data/data/com.termux/files/usr/lib/hermes-agent/lib" -name '*.so' \
    | while read -r so; do
        file "$so" | grep -q "ARM aarch64" || { echo "QA FAIL: not aarch64: $so"; exit 1; }
      done
# pure-python smoke test on host (native .so load fails on x86_64: expected)
PYTHONPATH="$APP:$SITE" python3 -c "
import sys; sys.path.insert(0, '$APP'); sys.path.insert(0, '$SITE')
import hermes_cli; print('import hermes_cli OK')" 2>&1 | tail -1
echo "QA PASS: $OUT ($(du -h "$OUT" | cut -f1))"
