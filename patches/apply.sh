#!/usr/bin/env bash
# Apply all Termux-port patches to a pristine upstream checkout.
# Fails loudly if any patch does not apply (never silently skip).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_DIR="$SCRIPT_DIR"
SRC="${1:?usage: apply.sh <upstream-checkout>}"

# 1. dry-run everything first: all-or-nothing
for p in "$PATCH_DIR"/*.patch; do
    if ! patch -p1 --dry-run --silent -d "$SRC" < "$p" >/dev/null 2>&1; then
        echo "apply.sh: PATCH WOULD NOT APPLY CLEANLY: $(basename "$p")" >&2
        echo "apply.sh: refusing to apply any patches; upstream drifted?" >&2
        exit 1
    fi
done

# 2. apply for real
for p in "$PATCH_DIR"/*.patch; do
    patch -p1 --silent -d "$SRC" < "$p"
    echo "applied $(basename "$p")"
done

# 3. byte-compile check on every patched .py file
python3 - "$PATCH_DIR" "$SRC" <<'EOF'
import py_compile, re, sys
patch_dir, src = sys.argv[1], sys.argv[2]
files = set()
import glob
for p in sorted(glob.glob(patch_dir + "/*.patch")):
    with open(p) as f:
        for line in f:
            m = re.match(r"^\+\+\+ b/(.+\.py)$", line.strip())
            if m:
                files.add(src + "/" + m.group(1))
for path in sorted(files):
    py_compile.compile(path, doraise=True)
print(f"py_compile OK on {len(files)} patched files")
EOF
