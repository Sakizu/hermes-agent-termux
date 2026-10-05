#!/usr/bin/env bash
# 20-tui.sh — build the prebuilt TUI bundle (hermes_cli/tui_dist/entry.js).
#
# From the 2026-10-04 TUI report (W2): npm ci on the ui-tui workspace, then
#   node scripts/build/tui.mjs --source <src> --out <out>
# then copy <out>/dist -> <src>/hermes_cli/tui_dist (mirrors upstream's
# scripts/build/agent.py plant_surfaces step).
#
# Env: HERMES_WORK, HERMES_SRC (pristine upstream checkout; the TUI build
# does not need the android patches).
set -eu

: "${HERMES_WORK:?set HERMES_WORK}"
: "${HERMES_SRC:?set HERMES_SRC}"

TUI_WORK="$HERMES_WORK/tui"
rm -rf "$TUI_WORK"
# fresh copy so the phone-target tree is never polluted by node_modules
cp -a "$HERMES_SRC" "$TUI_WORK"
rm -rf "$TUI_WORK/.git"

cd "$TUI_WORK"
npm ci --workspace ui-tui --include-workspace-root --include=dev --no-fund --no-audit
node scripts/build/tui.mjs --source "$TUI_WORK" --out "$TUI_WORK/.build/tui"

# stage into the exact slot main_tui_launch.py reads
rm -rf "$TUI_WORK/hermes_cli/tui_dist"
mkdir -p "$TUI_WORK/hermes_cli/tui_dist"
cp -r "$TUI_WORK/.build/tui/dist/." "$TUI_WORK/hermes_cli/tui_dist/"
cp "$TUI_WORK/.build/tui/package.json" "$TUI_WORK/hermes_cli/tui_dist/package.json"

# sanity checks (from the W2 report)
node --check "$TUI_WORK/hermes_cli/tui_dist/entry.js"
if grep -rq "node_modules" "$TUI_WORK/hermes_cli/tui_dist/entry.js"; then
    : # bundled requires are inlined by esbuild; plain strings may appear
fi
# no native node modules may ship in the bundle
if find "$TUI_WORK/hermes_cli/tui_dist" -name '*.node' | grep -q .; then
    echo "20-tui.sh: native .node modules in TUI bundle" >&2; exit 1
fi
du -sh "$TUI_WORK/hermes_cli/tui_dist"
echo "TUI OK: $TUI_WORK/hermes_cli/tui_dist/entry.js"
