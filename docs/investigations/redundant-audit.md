# Redundant dead-weight re-audit — hermes-agent Termux .deb

Date: 2026-10-06. Upstream ref: `1298c8e74baa73e1a2b90124228d017261ac6bc4`
(rev-parse verified by all 4 workers before auditing).
Audited artifact: `hermes-agent_0.0.0+1298c8e-3_aarch64.deb` (26.4 MB),
via its stage tree at `.build-work/assemble/stage/.../usr/lib/hermes-agent/`
(`app/` 59–64 MB, `site/` 54–62 MB across workers' measurements).

Method: 4 parallel workers (A: desktop/GUI stragglers, B: non-Android
platform binaries, C: content duplication, D: adversarial INERT
re-verification + site/ bloat). Coordinator cross-checked the two largest
claims independently (resvg_py, cffi) with fresh greps. Standard: evidence
or it didn't happen — every row below has a size and a reader analysis.

Builds on `docs/investigations/slim-pyc.md` §1c; does not redo it.

## Remove candidates (ranked by size × certainty / risk)

| # | Path (in package) | Size (uncompressed) | Evidence of deadness | Risk | Verdict |
|---|---|---|---|---|---|
| 1 | `app/plugins/hermes-achievements/docs/` (2 PNGs: `achievements-dashboard-hd.png`, `achievements-tier-showcase-hd.png`) | 2,842,733 B | Zero `.py` readers in staged tree (only hit: unrelated comment about external docs site in `tools/mcp_oauth.py`). Dashboard static endpoint `app/hermes_cli/web_routers/dashboard_ui.py:385-415` serves **only** each plugin's `dashboard/` dir, blocks traversal (`resolve().is_relative_to()`), and 404s READMEs (line 375). Only in-tree reference is the plugin's own `README.md`; README rendering happens on the external docs site from the pinned commit (`hermes_cli/plugin_catalog.py:89`), never on-device. | Negligible — one-line INERT-style exclusion in `30-assemble.sh`; upstream repo untouched so GitHub README rendering is unaffected. | **remove** (see note) |
| 2 | `site/resvg_py/` | 2,384,355 B | Zero importers in staged `app/`, `launchers/`, `patches/` (grep-verified by worker D and coordinator). Only upstream importers live in excluded `scripts/` (`generate_icons.py`, `build/icon_environment.py`) and excluded `tests/`. `app/pyproject.toml:182-187` comment confirms purpose: "SVG rendering for the icon generator (scripts/generate_icons.py). Source builds render icons with the runtime interpreter (`hermes desktop`, `hermes update`)". Both consumers are dead on Termux: `scripts/` is excluded, `hermes desktop` degrades gracefully without `apps/` (worker D: `main_desktop.py:1787-1795`), and `hermes update` is external on this build (`install-stamp.json`: `updateMechanism: external`). No dynamic imports (`importlib`/`__import__` greps empty). | Low — build-script change only: skip step 3b download + note in `scripts/lib/closure.py` (which lists it as expected dep). | **remove** |
| 3 | `site/cffi/` + `site/_cffi_backend.cpython-314-aarch64-linux-android.so` | 379,948 + 333,873 = 713,821 B | Declared dep of `brotlicffi` (uv.lock), which is absent from `site/` and explicitly excluded by app code (`plugins/model-providers/kimi-coding/__init__.py:16`: "httpx's brotlicffi backend has a streaming decode bug"). Zero `import cffi` / `from cffi` in staged `app/`+`site/` (coordinator grep). `_cffi_backend` imported only by `site/cffi/api.py` itself → orphaned when cffi goes. | Low — prune from closure + delete. No app code patch. | **remove** |
| 4 | `site/pycparser/` | 192,843 B | Imported only by `cffi/cparser.py` → transitively dead once cffi is removed. | Low (bundled with #3). | **remove** |
| 5 | `site/pathspec/` | 129,896 B | Zero Python importers in entire upstream tree; every "pathspec" mention is a git CLI `--pathspec` flag. | Low. | **remove** |
| 6 | `site/pytz/zoneinfo/tzdata.zi` | 104,433 B | Zero references in `site/`+`app/`; pytz loads individual `zoneinfo/<name>` files via `open_resource` (`pytz/__init__.py:190-194`). The individual zone files stay. | Low. | **remove** |
| 7 | `site/tenacity/` | 72,331 B | Zero mentions anywhere in upstream (not even comments). Declared but never used. | Low. | **remove** |
| 8 | `*-dist-info/` of the 5 removed pkgs (resvg_py, cffi, pycparser, pathspec, tenacity) | 148,369 B | Go with their packages. | Low. | **remove** |
| 9 | `site/fastapi/.agents/` | 13,665 B | Agent-doc skill files; zero `.py` readers. | Low. | **remove** |
| 10 | C build sources (`markupsafe/_speedups.c`, `websockets/speedups.c`, `httptools/*.pyx|*.pxd`) | 35,363 B | No runtime readers; the compiled `.so` files ship separately. | Low. | **remove** |
| 11 | `site/tqdm/tqdm.1` | 7,538 B | Man page; no man reader on Termux (tqdm itself stays — live via `openai/cli/_progress.py`). | Negligible. | **remove** |
| 12 | `site/urllib3/contrib/emscripten/emscripten_fetch_worker.js` | 3,677 B | Referenced only from emscripten-only `fetch.py:206`; dead on Android. | Negligible. | **remove** |

**Remove-verdict total: ≈ 6.81 MB uncompressed** (2.84 + 2.38 + 0.71 + 0.19 + 0.13 + 0.10 + 0.07 + 0.15 + 0.01 + 0.04 + 0.01 + 0.00).
At the §1c-measured ~0.22–0.28 payload→.deb ratio: **≈ 1.5–1.9 MB off the .deb** (estimate, not measured).
Combined with the §1c slim (30.7 → 26.4 MB), a further slimmed build would land near **~24.5–25 MB**.

### Needs-decision (not auto-remove)

| Path | Size | Conflict |
|---|---|---|
| `site/*/dist-info/licenses/` (47 dirs) | 160,823 B | Worker D proved zero *runtime* readers. But the 2026-10-06 §1c follow-up explicitly decided to KEEP these for legal hygiene. Runtime-dead ≠ legally safe to strip. Parent already ruled; D's evidence doesn't overturn the legal rationale. Keep unless the parent flips. |
| Candidate #1 (achievements docs PNGs) | (in total above) | Worker A: remove (strong no-reader evidence). Worker B: "needs-decision" (product/docs call — the PNGs illustrate the plugin's README). Coordinator: the on-device evidence supports remove (nothing on the phone can reach them); the residual question is product taste, not function. Listed under remove but flagged here for visibility. |

### Needs-code-patch (build hygiene, not shipping weight)

- **Smoke-test bytecode litter** (worker B): `scripts/30-assemble.sh`'s final smoke test
  `PYTHONPATH="$APP:$SITE" python3 -c "import hermes_cli"` runs on host Python 3.12
  **after** both the `__pycache__` purge and the zero-`.pyc` QA gate, re-littering the
  stage tree with `app/hermes_cli/__pycache__/__init__.cpython-312.pyc` (3,919 B).
  The shipped `.deb` is clean (verified: `dpkg-deb --fsys-tarfile ... | tar -t |
  grep -c '\.pyc$'` → 0), so this is a QA-honesty wart, not a shipping defect.
  Fix: `PYTHONDONTWRITEBYTECODE=1` on the smoke test (one line), or run it before the gate.
- **Uncommitted-changes caveat** (worker B): the audited stage tree was built from
  uncommitted working-tree changes to `scripts/30-assemble.sh` (+82/−19 vs HEAD).
  A clean-checkout build would use the old committed script without any slim work.
  (Known to parent — commit/push pending approval.)

## Traps — looks dead, is live (do NOT remove)

- `app/plugins/kanban/dashboard/` (342 KB) + `app/plugins/hermes-achievements/dashboard/` (120 KB):
  served live by `dashboard_ui.py:385-415` at `/dashboard-plugins/...` (worker A).
- `app/tools/bot_desktop/` incl. `wallpaper.png` (122 KB): computer-use sandbox-desktop
  backend — readers in `sandbox_host.py:232`, `launcher.sh:64`, `pyproject.toml:846` (worker A).
- `app/gateway/assets/telegram-botfather-threads-settings.jpg` (118 KB): sent during
  Telegram forum-topic setup (`gateway/run_topics.py:246-258`) (worker A).
- `app/tools/neutts_samples/jo.wav` (576 KB): default `--ref-audio` (`tts_tool_local.py:67`) (worker A).
- `app/tools/wakewords/hey_hermes.tflite` (207 KB): default wake-word model (`wake_word.py:85-86`) (worker A).
- `hermes_cli/main_desktop.py` + `linux_desktop_entry.py` + `desktop_*.py` + `gui_uninstall.py`:
  code, not assets; `main_desktop.py` live-imported by `main.py:883` (worker A).
- pytz `zoneinfo/` individual files: name-addressed (`pytz.timezone("GB")` ≠ `pytz.timezone("Europe/London")`
  despite identical bytes) — deleting aliases breaks lookups (worker C).
- `site/dateutil/zoneinfo/dateutil-zoneinfo.tar.gz` (153 KB): fallback reader
  `dateutil/tz/tz.py:1654-1655` when system tzdata lacks a zone — real on phones (worker D).
- `site/snowballstemmer/` (766 KB): `tools/tool_search_catalog.py:48`; trimming needs a code
  patch (worker D) — not recommended as-is.
- `site/certifi/cacert.pem` (231 KB): TLS trust store, top-level import (worker D).
- All 14 `.so` files: `file`-verified `ELF 64-bit LSB shared object, ARM aarch64` — zero
  non-Android native code ships (worker B).
- `app/plugins/image_gen/openai/` vs `site/openai/`: coincidental naming; the former is a
  live provider plugin imported as `plugins.image_gen.openai` (worker C).
- Zero top-level name overlaps between `app/` and `site/`; no `.pth` files; no split
  namespace packages; no orphan `.pyc` in the `.deb` (workers B, C).

## Adversarial INERT re-verification (worker D)

Every current exclusion was attacked with greps over staged `app/` + `launchers/` + `patches/`.
**Zero traps found.** All INERT dirs (`tests`, `tests-js`, `website`, `evals`, `.github`, `nix`,
`docker`, `apps`, `ui-tui`, `web`, `scripts`, `contributors`, `optional-skills`, `assets`),
all 16 ROOT_DEV files, and the `native/fts5_cjk/` source drop: **CONFIRMED** — no runtime
reader; the readers that exist (`website/` in `model_catalog.py:331`, `apps/` in
`main_desktop.py:1787-1795`, `web/` in `main_web_build.py:130-131`, `scripts/` in
`whatsapp_common.py:294-309`) all degrade gracefully with no crash path in normal flows.

## Implementation sketch (build-script only, no app patches)

1. Skip step 3b (`resvg-py` download) in `30-assemble.sh`; note in `scripts/lib/closure.py`
   (~line 37-38, which lists cffi/resvg-py as expected deps).
2. Add a prune step after 3c (cross-built wheels): `rm -rf` for
   `site/cffi site/_cffi_backend*.so site/pycparser site/pathspec site/tenacity`
   + their `*.dist-info` dirs, `site/pytz/zoneinfo/tzdata.zi`,
   `site/fastapi/.agents`, `site/tqdm/tqdm.1`, the C sources, the emscripten JS.
   (Decide on `dist-info/licenses/` separately — see needs-decision.)
3. Extend the INERT-style exclusion with `plugins/hermes-achievements/docs`
   (or a targeted `rm -rf "$APP/plugins/hermes-achievements/docs"` post-snapshot).
4. One-line: `PYTHONDONTWRITEBYTECODE=1` on the QA smoke test.

## Worker errors / failures

None. All 4 workers completed: upstream rev-parse matched on all four, every
planned path existed, no tool call failed, no silent skips. (Worker A re-ran one
over-broad grep scoped to `*.py` after a truncation; worker D had one grep exceed
10 s, backgrounded, then completed.)
