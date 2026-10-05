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
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${HERMES_WORK:?set HERMES_WORK}"
: "${HERMES_SRC:?set HERMES_SRC}"
: "${UPSTREAM_REF:?set UPSTREAM_REF}"
: "${DEB_VERSION:?set DEB_VERSION}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/build_env.sh"  # versions.env + derived paths

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
import hashlib, json, sys, os, time, urllib.request, urllib.parse
closure = json.load(open(sys.argv[1]))
out = sys.argv[2]
def fetch(url, dest, sha256):
    for attempt in range(4):
        try:
            urllib.request.urlretrieve(url, dest)
        except Exception:
            if attempt == 3:
                raise
            time.sleep(2 * (attempt + 1))
            continue
        h = hashlib.sha256()
        with open(dest, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        if h.hexdigest() == sha256:
            return
        os.unlink(dest)
        if attempt == 3:
            raise ValueError(f"sha256 mismatch for {url}")
        time.sleep(2 * (attempt + 1))
for name, ver, url, sha256 in closure["pure"]:
    # strip any ?query/#fragment before deriving the filename
    filename = urllib.parse.urlparse(url).path.rsplit("/", 1)[-1]
    assert filename.endswith("-none-any.whl"), \
        f"not a pure wheel URL for {name}=={ver}: {url}"
    dest = os.path.join(out, filename)
    if not os.path.exists(dest):
        fetch(url, dest, sha256)
    else:
        h = hashlib.sha256(open(dest, "rb").read()).hexdigest()
        assert h == sha256, f"cached {filename} failed sha256 check"
print(f"downloaded {len(closure['pure'])} pure wheels (sha256-verified)")
EOF
for whl in "$PURE_DIR"/*-none-any.whl; do unzip -q -o "$whl" -d "$SITE"; done

# --- 3b. resvg-py android wheel from PyPI (prebuilt abi3) --------------
RESVG_VER="$(python3 "$LIB/native_deps.py" "$HERMES_SRC/uv.lock" \
    | python3 -c "import json,sys; ds=[p for p in json.load(sys.stdin) if p['name']=='resvg-py']; print(ds[0]['version'] if ds else '')")"
if [ -n "$RESVG_VER" ]; then
RESVG_FILE="$(python3 -c "
import json, urllib.request
req = urllib.request.Request('https://pypi.org/pypi/resvg-py/$RESVG_VER/json')
d = json.load(urllib.request.urlopen(req, timeout=30))
cands = [(f['filename'], f['digests']['sha256']) for f in d['urls']
         if 'android_24_arm64_v8a' in f['filename'] and f['digests'].get('sha256')]
assert cands, 'no android wheel (with sha256) for resvg-py $RESVG_VER'
print(sorted(cands)[0][0])
print(sorted(cands)[0][1])")"
RESVG_NAME="$(printf '%s' "$RESVG_FILE" | head -1)"
RESVG_SHA="$(printf '%s' "$RESVG_FILE" | tail -1)"
python3 - "$RESVG_NAME" "$RESVG_SHA" "$A_DIR" <<'EOF'
import hashlib, re, sys, time, urllib.request
want, sha256, out = sys.argv[1], sys.argv[2], sys.argv[3]
def fetch(url, dest):
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "hermes-agent-termux"})
            with urllib.request.urlopen(req, timeout=60) as r, open(dest, "wb") as f:
                f.write(r.read())
            h = hashlib.sha256(open(dest, "rb").read()).hexdigest()
            assert h == sha256, f"sha256 mismatch for {want}"
            return
        except Exception:
            if attempt == 3:
                raise
            time.sleep(2 * (attempt + 1))
html = None
for attempt in range(4):
    try:
        html = urllib.request.urlopen("https://pypi.org/simple/resvg-py/", timeout=30).read().decode()
        break
    except Exception:
        if attempt == 3:
            raise
        time.sleep(2 * (attempt + 1))
m = re.search(r'href="([^"]*' + re.escape(want) + r'(?:#[^"]*)?)"', html)
assert m, f"{want} not on the simple index"
href = m.group(1)
if not href.startswith("http"):
    href = "https://pypi.org/simple/resvg-py/" + href.lstrip("/")
fetch(href, f"{out}/{want}")
print(f"resvg-py: {want} (sha256-verified)")
EOF
unzip -q -o "$A_DIR/$RESVG_NAME" -d "$SITE"
else
echo "resvg-py not in native deps; skipping"
fi

# --- 3c. cross-built wheels --------------------------------------------
for whl in "$HERMES_WORK"/wheelhouse/*.whl; do unzip -q -o "$whl" -d "$SITE"; done
echo "site/: $(ls "$SITE" | wc -l) top-level entries"

# --- 4. libfts5_cjk.so (NDK clang; upstream native/fts5_cjk/build.sh) ---
TC="$HERMES_NDK_DIR"
FTS="$APP/native/fts5_cjk"
mkdir -p "$STAGE/data/data/com.termux/files/usr/lib/hermes-agent/lib"
"$TC/bin/${HERMES_TARGET_TRIPLE}-clang" -shared -fPIC -O2 -Wall \
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
HERMES_COMMIT="$COMMIT" HERMES_BASE_VER="$BASE_VER" \
HERMES_DEB_VERSION="$DEB_VERSION" HERMES_UPSTREAM_REF="$UPSTREAM_REF" \
python3 - "$APP/install-stamp.json" <<'EOF'
import json, os, sys, datetime
commit = os.environ["HERMES_COMMIT"]
base_ver = os.environ["HERMES_BASE_VER"]
deb_version = os.environ["HERMES_DEB_VERSION"]
upstream_ref = os.environ["HERMES_UPSTREAM_REF"]
stamp = {
    "schemaVersion": 2,
    "commit": commit,
    "commitDate": 0,
    "branch": "main",
    "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "dirty": False,
    "source": "bundle",
    "distribution": "apt-termux",
    "updateMechanism": "external",
    "baseVersion": base_ver,
    "displayVersion": deb_version,
    "distance": 0,
    "payload": "bootstrap",
    "tag": upstream_ref if upstream_ref.startswith("v") else None,
}
json.dump(stamp, open(sys.argv[1], "w"), indent=2)
EOF
printf 'apt\n' > "$APP/.install_method"

# --- 7. DEBIAN/ ----------------------------------------------------------
INSTALLED_SIZE="$(du -sk "$STAGE/data" | cut -f1)"
sed -e "s/@VERSION@/$DEB_VERSION/" -e "s/@SIZE@/$INSTALLED_SIZE/" \
    "$REPO_ROOT/DEBIAN/control.in" > "$STAGE/DEBIAN/control"
cp "$REPO_ROOT/DEBIAN/postinst" "$REPO_ROOT/DEBIAN/prerm" "$STAGE/DEBIAN/"
chmod 755 "$STAGE/DEBIAN" "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

# --- 7b. normalize file modes (the build env's umask must not leak in) ---
# dirs 755, data files 644; executables: launchers + DEBIAN scripts only
find "$STAGE/data" -type d -exec chmod 755 {} +
find "$STAGE/data" -type f -exec chmod 644 {} +
chmod 755 "$STAGE"/data/data/com.termux/files/usr/lib/hermes-agent/bin/*
# .so files need no exec bit; keep them readable
find "$STAGE/data" -name '*.so' -exec chmod 644 {} +

# --- 8. build + QA -------------------------------------------------------
OUT="$HERMES_WORK/hermes-agent_${DEB_VERSION}_aarch64.deb"
dpkg-deb --build "$STAGE" "$OUT"

echo "--- QA ---"
dpkg-deb --info "$OUT" | head -12
# no stray absolute paths outside the Termux prefix or DEBIAN
bad="$(dpkg-deb -c "$OUT" | awk '{print $6}' | grep -v -e '^\./$' -e '^\./DEBIAN' -e '^\./data/$' -e '^\./data/data/$' -e '^\./data/data/com.termux/' || true)"
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
# pure-python smoke test on host (native .so load fails on x86_64: expected);
# the import result is checked directly — never piped through tail
PYTHONPATH="$APP:$SITE" python3 -c "
import sys; sys.path.insert(0, '$APP'); sys.path.insert(0, '$SITE')
import hermes_cli; print('import hermes_cli OK')" || { echo "QA FAIL: import hermes_cli failed" >&2; exit 1; }
echo "QA PASS: $OUT ($(du -h "$OUT" | cut -f1))"
