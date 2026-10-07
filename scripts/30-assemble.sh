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
#   4. build site/ from: 52 pure wheels (uv.lock closure) + 10 cross-built
#      wheels; prune dead weight (3d test/stub cleanup, 3e dead packages)
#   5. compile native/fts5_cjk -> lib/libfts5_cjk.so (NDK clang), drop sources
#   6. mint launchers + install-stamp.json
#   7. normalize file modes
#   8. DEBIAN/ (Installed-Size measured last) + dpkg-deb --build + QA
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
# Dead weight excluded 2026-10-06 (docs/investigations/slim-pyc.md): every
# entry below was grep-verified to have zero runtime readers. git-archive
# :(exclude)<name> matches top-level only (verified: nested gateway/assets/
# and evals/postmortem/tests/ survive an :(exclude)assets / :(exclude)tests).
INERT="tests tests-js website evals .github nix docker apps ui-tui web scripts"
# ~22MB uncompressed: release-tooling data, the unactivated skill catalog
# (skills install falls back to GitHub via the Hub), and packaging artwork.
INERT="$INERT contributors optional-skills assets"
# Root dev files: exact names only (a bare *.md would also kill nested
# SKILL.md files, which the skills system reads at runtime).
# NOTE: uv.lock is deliberately NOT in this list — pm/packages.py
# _uv_lock_digest() stats it unconditionally at runtime (hermes pm install
# crashes without it). 1.2MB, ships with the app.
ROOT_DEV="AGENTS.md SOUL.md CONTRIBUTING.md CONTRIBUTING.es.md README.md README.es.md README.ur-pk.md README.zh-CN.md SECURITY.md SECURITY.es.md Dockerfile docker-compose.yml docker-compose.windows.yml flake.lock package-lock.json"
git -C "$HERMES_SRC" archive --format=tar "$UPSTREAM_REF" -- \
    $(for d in $INERT; do printf ':(exclude)%s ' "$d"; done) \
    $(for f in $ROOT_DEV; do printf ':(exclude)%s ' "$f"; done) \
    | tar --no-same-owner -x -C "$APP"
test -f "$APP/pyproject.toml" || { echo "snapshot failed: no pyproject.toml"; exit 1; }
# optional-skills/migration/ is the ONE live consumer inside optional-skills/:
# claw.py and setup_migration.py exec the openclaw migration script from it
# (existence-guarded). Restore just that subtree from the same ref.
git -C "$HERMES_SRC" archive --format=tar "$UPSTREAM_REF" -- optional-skills/migration \
    | tar --no-same-owner -x -C "$APP"
test -f "$APP/optional-skills/migration/openclaw-migration/scripts/openclaw_to_hermes.py" \
    || { echo "snapshot failed: optional-skills/migration not restored"; exit 1; }
# Round 2 (2026-10-06, docs/investigations/redundant-audit.md): the
# hermes-achievements plugin's docs/ (2.7MB of PNGs) is unreachable on-device —
# the dashboard only serves <plugin>/dashboard/ (hermes_cli/web_server_dashboard.py
# _discover_dashboard_plugins + web_routers/dashboard_ui.py serve_plugin_asset,
# traversal-blocked), and the PNGs are referenced solely by the plugin's own
# README.md (rendered on the external docs site, never on the phone).
rm -rf "$APP/plugins/hermes-achievements/docs"
# the TUI bundle was built from the full tree before exclusion; stage it now
cp -r "$HERMES_WORK/tui/hermes_cli/tui_dist" "$APP/hermes_cli/tui_dist"

# --- 2. patches ---
bash "$REPO_ROOT/patches/apply.sh" "$APP"
# Purge stale bytecode at the source: apply.sh's py_compile syntax check runs
# on the host Python 3.12 and litters cpython-312.pyc into the tree. The
# phone's 3.14 would silently ignore those (different cache tag), and with
# PYTHONPYCACHEPREFIX set the launcher ignores source-adjacent bytecode
# entirely — so any .pyc here ships as pure dead weight.
find "$APP" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$APP" -type f -name '*.pyc' -delete

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
# --- 3c2. ship the wheelhouse itself for `hermes pm` ---------------------
# `hermes pm install` runs `uv sync` in a fresh venv; without these wheels
# uv tries to build Rust/C extensions from source, which fails on Android
# (no rustup target, no NDK). The pm patch points uv at this dir via
# --find-links. Only our cross-built wheels live here (pure-Python comes
# from PyPI as usual).
WH_DIR="$STAGE/data/data/com.termux/files/usr/lib/hermes-agent/wheelhouse"
mkdir -p "$WH_DIR"
cp "$HERMES_WORK"/wheelhouse/*.whl "$WH_DIR/"
echo "wheelhouse: $(ls "$WH_DIR"/*.whl | wc -l) wheels shipped"
# --- 3c3. QA: wheelhouse must not be empty (native wheels for `hermes pm`)
# Full per-package version check is done by CI via native_deps.py; here we
# just assert the copy above actually landed wheels.
_wc=$(ls "$WH_DIR"/*.whl 2>/dev/null | wc -l)
[ "$_wc" -ge 11 ] || { echo "FATAL: wheelhouse has $_wc wheels, expected >= 11" >&2; exit 1; }
echo "wheelhouse QA: $_wc wheels present"
# --- 3d. site/ dead weight: test trees and type stubs are never imported at
# runtime. dist-info license files are KEPT (legal hygiene) — they cost ~0.3MB.
find "$SITE" -name '*.pyi' -delete
find "$SITE" -type d \( -name 'tests' -o -name 'test' \) -prune -exec rm -rf {} +
# --- 3e. site/ dead packages (round 2, 2026-10-06) ---------------------------
# docs/investigations/redundant-audit.md. Wheels ship packages that nothing in
# the .deb imports — each verified with zero importers across app/ + site/
# (static, dynamic, and try/except greps), including the excluded dev dirs:
# - resvg_py: sole importer is scripts/generate_icons.py (excluded from package)
# - cffi: its only consumer brotlicffi is absent from site/ (messaging extra
#   not installed); _cffi_backend.so is imported only by cffi itself
# - pycparser: imported only by cffi/cparser.py (transitively dead)
# - pathspec, tenacity: declared in pyproject but zero importers in the entire
#   upstream tree (app, site, scripts, apps, website, evals)
SITE_DEAD_PKGS="resvg_py cffi pycparser pathspec tenacity"
for _p in $SITE_DEAD_PKGS; do rm -rf "$SITE/${_p:?}"; done
unset _p
rm -f "$SITE"/_cffi_backend*.so
# their dist-info dirs go with them (the licenses/ subdirs inside are KEPT
# per the legal-hygiene rule — only the package metadata dirs are removed)
for _p in $SITE_DEAD_PKGS; do rm -rf "$SITE"/${_p:?}-*.dist-info; done
unset _p
# pytz/zoneinfo/tzdata.zi: zero references in app/ + site/; pytz opens the
# individual zoneinfo/<name> files, which stay
rm -f "$SITE/pytz/zoneinfo/tzdata.zi"
# fastapi/.agents: agent-doc skill files; zero .py readers
rm -rf "$SITE/fastapi/.agents"
# Cython/C build sources: the compiled .so files ship separately; .c/.pyx/.pxd
# are never read at runtime
rm -f "$SITE/markupsafe/_speedups.c" "$SITE/websockets/speedups.c"
rm -f "$SITE"/httptools/parser/*.pyx "$SITE"/httptools/parser/*.pxd
# tqdm.1: man page; no man reader on Termux (tqdm itself stays — live importer)
rm -f "$SITE/tqdm/tqdm.1"
# urllib3 emscripten worker: imported only under sys.platform == "emscripten"
# (urllib3/__init__.py); never on Android
rm -f "$SITE/urllib3/contrib/emscripten/emscripten_fetch_worker.js"
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
# The C sources served their purpose (the .so above); the runtime only ever
# loads the compiled .so (best-effort, never raises when absent) — drop the
# 0.7MB of build sources from the package.
rm -rf "$APP/native/fts5_cjk"

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

# --- 7. normalize file modes (the build env's umask must not leak in) ---
# dirs 755, data files 644; executables: launchers + DEBIAN scripts only
find "$STAGE/data" -type d -exec chmod 755 {} +
find "$STAGE/data" -type f -exec chmod 644 {} +
chmod 755 "$STAGE"/data/data/com.termux/files/usr/lib/hermes-agent/bin/*
# .so files need no exec bit; keep them readable
find "$STAGE/data" -name '*.so' -exec chmod 644 {} +

# --- 8. DEBIAN/ + build + QA ---------------------------------------------
# Installed-Size MUST be measured AFTER every staging step: the removed 7a
# precompile step used to land 57MB of .pyc after the size was computed, so the
# .deb under-reported installed size by ~95MB.
INSTALLED_SIZE="$(du -sk "$STAGE/data" | cut -f1)"
sed -e "s/@VERSION@/$DEB_VERSION/" -e "s/@SIZE@/$INSTALLED_SIZE/" \
    "$REPO_ROOT/DEBIAN/control.in" > "$STAGE/DEBIAN/control"
cp "$REPO_ROOT/DEBIAN/postinst" "$REPO_ROOT/DEBIAN/prerm" "$STAGE/DEBIAN/"
chmod 755 "$STAGE/DEBIAN" "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

OUT="$HERMES_WORK/hermes-agent_${DEB_VERSION}_aarch64.deb"
# Pin zstd -19 explicitly: it is already the dpkg default here, but pinning
# makes the compression level deterministic across build hosts.
dpkg-deb -Zzstd -z19 --build "$STAGE" "$OUT"

echo "--- QA ---"
# NOTE: no `| head` on dpkg-deb --info: it prints 15 lines, and piping to head
# SIGPIPEs under `set -o pipefail`, aborting the build with no diagnostic
# (same bug class as 2965d7a). The full 15 lines are short enough to print.
dpkg-deb --info "$OUT" || { echo "QA FAIL: dpkg-deb --info" >&2; exit 1; }
# no stray absolute paths outside the Termux prefix or DEBIAN
bad="$(dpkg-deb -c "$OUT" | awk '{print $6}' | grep -v -e '^\./$' -e '^\./DEBIAN' -e '^\./data/$' -e '^\./data/data/$' -e '^\./data/data/com.termux/' || true)"
if [ -n "$bad" ]; then
    printf '%s\n' "$bad" # no `| head`: SIGPIPE under pipefail would hide the diagnostic below
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
# no .pyc ships in the .deb, by design: the launcher sets PYTHONPYCACHEPREFIX,
# so source-adjacent bytecode is never read (verified 2026-10-06) — any .pyc
# here would be dead weight, most likely stale cpython-312 litter from
# patches/apply.sh's host-side py_compile syntax check. No pipes here:
# `find | head` SIGPIPEs under `set -o pipefail` (same bug class as 2965d7a).
stale_pyc="$(find "$STAGE/data" -name '*.pyc' -print)"
if [ -n "$stale_pyc" ]; then
    echo "stale .pyc files (first 500 chars): ${stale_pyc:0:500}"
    echo "QA FAIL: .pyc files would ship as dead weight" >&2; exit 1
fi
echo "QA: no .pyc in package (bytecode compiles on-device into the prefix cache)"
# guardrail: round-2 dead weight must not resurrect (e.g. after a uv.lock bump
# re-adds a package). Each entry documents why it is dead in 3e above.
for _p in resvg_py cffi pycparser pathspec tenacity; do
    if [ -e "$SITE/$_p" ]; then echo "QA FAIL: dead package resurrected: $_p" >&2; exit 1; fi
done
unset _p
if [ -e "$APP/plugins/hermes-achievements/docs" ]; then
    echo "QA FAIL: achievements docs resurrected" >&2; exit 1
fi
echo "QA: round-2 dead weight absent"
# guardrail: uv.lock must ship — pm/packages.py _uv_lock_digest() stats it
# unconditionally; hermes pm install crashes with FileNotFoundError without
# it (regression caught on-device 2026-10-06, fixed by un-excluding it above).
test -f "$APP/uv.lock" || { echo "QA FAIL: uv.lock missing (pm hard-requires it)" >&2; exit 1; }
echo "QA: uv.lock present"
# pure-python smoke test on host (native .so load fails on x86_64: expected);
# the import result is checked directly — never piped through tail.
# PYTHONDONTWRITEBYTECODE=1: the import must not re-litter __pycache__ into the
# stage tree after the purge (step 2) and the zero-.pyc QA gate above.
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$APP:$SITE" python3 -c "
import sys; sys.path.insert(0, '$APP'); sys.path.insert(0, '$SITE')
import hermes_cli; print('import hermes_cli OK')" || { echo "QA FAIL: import hermes_cli failed" >&2; exit 1; }
echo "QA PASS: $OUT ($(du -h "$OUT" | cut -f1))"
