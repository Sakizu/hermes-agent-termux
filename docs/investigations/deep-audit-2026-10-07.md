# Deep Audit Report: Termux Patch Coverage (2026-10-07)

**Method:** 4 parallel independent workers + 1 cross-check worker. All
evidence read from actual code at upstream `1298c8e7`.

## sys.platform Correction

**`sys.platform == "android"` on Termux Python 3.14** (PEP 738, Python 3.13+),
NOT `"linux"` as previously believed.

Decisive evidence: on-device build log showed
`Building psutil @ git+https://...` — this only happens when the
`sys_platform == 'android'` marker in `pyproject.toml` evaluates TRUE.
Upstream `pm/store.py:92` confirms: pre-3.13 → `"linux"`, 3.13+ → `"android"`.

Consequence: all 12 patches gating on `sys.platform == "android"` DO fire
and are needed. Patch 28's comment claiming `"linux"` was fixed in v7.

## 28-Patch Audit Results

| Verdict | Count | Patches |
|---------|-------|---------|
| NEEDED | 27 | 01-21, 23-25, 27-28 (26 counted as harmless) |
| OBSOLETE | 1 | 22 (`hermes_state_lockguard`): `F_OFD_SETLK` native since CPython 3.12; fallback dict never consulted on 3.14 |
| QUESTIONABLE | 1 | 26 (`tools_environments_file_sync`): defensive `try/except` for psutil; harmless, no longer strictly needed |

All 28 patches apply cleanly. No conflicts.

## New Patches Added

**Patch 29** (`pm_bionic_gaps_ldpath`):
- **P1-2**: `Gh.fetch_url` bionic gap — was `ValueError: too many values
  to unpack` on `linux-arm64-bionic`; now clean `n/a` verdict.
- **P1-3**: `LD_LIBRARY_PATH` in `activation_environment()`
  (`pm/environments.py:441`) — same bug class as the pm venv fix, for
  `hermes pm activate` shell integration.

**Launcher fix** (`launchers/launcher.sh.in`):
- Exports `LD_LIBRARY_PATH="$PREFIX/lib"` — main CLI's `site/` natives
  (`cryptography`, `pillow_heif`) need `libssl.so.3`/`libheif.so.1`.
- Verified on-device: `cryptography OK`.

**cffi fix** (`scripts/30-assemble.sh`):
- `cffi` was wrongly removed from `site/` as "dead" (assumption: only
  brotlicffi uses it). Actually `cryptography`'s Rust bindings import
  `_cffi_backend` at load time. Removed from `SITE_DEAD_PKGS`.

## False Positives Rejected

1. **"Patches 02,03,05,06,07,08,09,12,14,15,16,18 are inert dead code"**
   — FALSE. They contain `sys.platform == "android"` checks which DO fire
   (proven above). All are live, working patches.
2. **"Git needs bionic gap"** — NOT A BUG. `pm/packages.py:624` class `Git`
   is Windows-only by design; POSIX uses system git (deliberate gap).
   `? git: not installed` is graceful, not a crash.
3. **"M3: plugin git broken"** — FALSE POSITIVE. `plugins_cmd.py`
   already uses `shutil.which("git")` first. No patch needed.
4. **"pm update 404"** — UNVERIFIED. No code path located. Do not act
   without evidence.

## Remaining (Not Blocking)

- **P2-2**: `shell=True` crash claims — no repro provided, do not patch blindly.
- **M4**: TUI clipboard has no native Termux backend (OSC 52 fallback works).
- **M5**: TTS playback has no working player on Termux (feature gap).
- **M6**: Pinch-zoom transient misrender (self-heals, cosmetic).

## Verification

All verified on-device (termux9):
- `hermes pm install` ✓ (11 wheels, no source builds)
- `hermes pm repair` ✓ ("dependency environment repaired")
- `hermes pm doctor` ✓ (proper `n/a` verdicts)
- `cryptography` import ✓
