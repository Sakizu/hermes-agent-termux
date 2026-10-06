# Brief: Fix `hermes pm install` source-building native wheels on Termux

Repo: https://github.com/Sakizu/hermes-agent-termux
Pinned upstream: `1298c8e7` (v0.21.5+1298c8e). Target: Android API 24, aarch64, Termux CPython 3.14.6.

## 1. Goal

`hermes pm install` must finish on-device without compiling anything. Native
packages come from the wheelhouse the `.deb` already ships. No rustup, no NDK,
no maturin, no source builds on the phone.

## 2. Confirmed facts (verified, not hypothesized)

- `$PREFIX/lib/hermes-agent/wheelhouse/` ships 11 cross-built wheels, including
  `rpds_py-2026.6.3-cp314-cp314-android_24_arm64_v8a.whl` (verified in `.deb`
  contents and on-device via `ls`).
- Wheel tags are CORRECT. Termux CPython 3.14 reports
  `sysconfig.get_platform()` = `android-24-arm64_v8a`; its top compatible tag
  is `cp314-cp314-android_24_arm64_v8a`. Do NOT retag to `linux_aarch64`
  (different libc; not interchangeable).
- Patch 28 exists on-device (`grep -c find-links` = 3) and appends
  `--find-links <wheelhouse>` to the `uv sync` command in `pm/environment.py`.
- Patch 28 v1 (release `1298c8e-termux2`) gated on `sys.platform == "android"`,
  which is NEVER true on Termux (Termux Python reports `"linux"`). The gate
  was dead code. Patch 28 v2 (release `1298c8e-termux3`, commit `677b07e0`)
  removed the gate; the wheelhouse-path check alone is the guard.
- Despite the above, `uv sync` still emits `Building <native-pkg>==<ver>` for
  every native package and fails on maturin/rustup.

## 3. Symptom (device log, termux3)

```
Building cryptography==50.0.1 / firecrawl-anydoc==0.2.4 / jiter==0.16.0
Building watchfiles==1.2.0 / rpds-py==2026.6.3 / pydantic-core==2.46.4
Building cffi==2.1.1 / httptools==0.8.0
Building psutil @ git+https://github.com/giampaolo/psutil.git@380bd2b...
   Built httptools==0.8.0          <- source build SUCCEEDED (C ext works)
error: Failed to download and build `watchfiles==1.2.0`
  cause: Failed to build `maturin==1.15.0`
  "Target triple not supported by rustup: aarch64-unknown-linux-android"
```

Note `httptools` built from source successfully: C extensions CAN build
on-device; Rust extensions cannot. The fix must prevent ALL native source
builds, not just Rust ones.

## 4. Root-cause hypothesis (verify before coding)

`--find-links` is ineffective because `uv sync --frozen` resolves strictly
from the lock file. Upstream `uv.lock` records no `android_24_arm64_v8a`
wheels, so for every native package uv falls back to the locked sdist and
builds it. The wheelhouse is consulted too late or not at all for locked
packages.

Evidence for: every native package shows `Building`, including ones with
exact-version wheels in the wheelhouse.

Rule out first (cheap, on-device):
1. **Wrong .deb installed.** `grep -c "do NOT gate on sys.platform"
   $PREFIX/lib/hermes-agent/app/pm/environment.py` -> `1` means termux3
   (fixed patch); `0` means still termux2 (dead gate). If `0`, reinstall
   termux3 and re-test before any code change.
2. **Tag rejection.** `uv pip install --dry-run --no-deps --no-build
   --find-links $WHEELHOUSE "watchfiles==1.2.0"` with the SAME uv binary PM
   uses. Success -> tags fine, problem is the sync path. Failure -> uv
   version/tag issue (then check `uv --version`).
3. **Wrong uv binary.** Identify the exact uv PM invokes (`~/.hermes/`,
   `$PREFIX/lib/hermes-agent/`); do not assume `command -v uv`.

If (1) confirms termux3 and (2) succeeds, the hypothesis stands: fix the
sync path, not the wheels.

## 5. Fix design (patch 28 v3, edit in place)

Patches apply to pristine upstream `1298c8e7`; edit
`patches/28-pm_sync_wheelhouse.py.patch` in place, do not stack a new patch
on the same hunk.

Approach: sidestep the lock for native packages instead of fighting
`--find-links` semantics.

1. In `PythonEnvironment.sync()`, before running `uv sync`, compute the set
   of native packages that have an exact name+version wheel in the
   wheelhouse (derive the list from the wheel filenames present, matched
   against versions in `uv.lock` — do not hard-code versions).
2. Append `--no-install-package <name>` for each such package so uv never
   attempts to build them. (Verify the flag exists on the bundled uv
   version first; fall back to §6 if absent.)
3. After a successful sync, install the wheels directly:
   `uv pip install --no-deps --python <venv-python> <wheel paths>`.
   No resolution, no build.
4. If a native package required by the lock has NO matching wheel, fail fast
   with a clear message naming the package — never fall through to rustup.
5. Idempotent: run step 3 on every sync (`uv sync` is exact and may remove
   previously installed packages).
6. Guard everything on wheelhouse presence (Termux-specific path); no-op
   elsewhere. Do NOT gate on `sys.platform`. Set `UV_LINK_MODE=copy` in the
   uv env to silence the hardlink warning. Keep `--find-links` only if it
   still helps pure-Python resolution; it is not the mechanism for natives.

Fallback if `--no-install-package` is unavailable or misbehaves:
`uv export --frozen --no-hashes --no-emit-project`, rewrite the
`psutil @ git+...` line to plain `psutil`, then
`uv pip install --find-links $W --no-build -r req.txt` plus the project with
`--no-deps`. Do NOT use `--no-index` (pure-Python wheels are not in the
wheelhouse).

## 6. Guardrails (do NOT)

- No rustup/cargo/maturin/NDK on-device, ever, as a solution or fallback.
- No global `--only-binary :all:` (breaks the pinned `psutil` git source).
- No retagging `android_*` wheels to `linux_*`; they are not interchangeable.
- No bypassing the lockfile, no weakening SHA-256 verification.
- No behavior change off Termux.
- No downgrading packages to obtain wheels; no replacing PM with raw pip.
- Keep the patch minimal and `patch -p1` clean against `1298c8e7`.

## 7. Repo hygiene (same change set)

- `scripts/30-assemble.sh`: add a QA step — for every native dep that
  `scripts/lib/native_deps.py` resolves from `uv.lock` for android, assert a
  wheel with that exact name+version exists in the staged wheelhouse; fail
  the build otherwise.
- `scripts/lib/native_deps.py::TRACKS` is the single source of truth.
  `scripts/lib/closure.py::NATIVE_KNOWN` omits `rpds-py` and lists `pillow`
  (not built here) — reconcile.
- `docs/BUILD.md` says 10 cross-built wheels; there are 11. README/BUILD.md
  say 27 patches; there are 28. Fix the counts.
- Keep `patches/apply.sh` semantics: all-or-nothing dry-run, then
  `py_compile` on patched files.

## 8. Acceptance criteria

1. `patches/apply.sh` against pristine upstream `1298c8e7`: dry-run passes,
   applies, `py_compile` OK.
2. On device, `hermes pm install` exits 0 with NO `Building` line for any
   native package and no rustup/maturin output.
3. In the pm venv:
   `python -c "import rpds, watchfiles, jiter, pydantic_core, cryptography, psutil, httptools, cffi, markupsafe"`
   succeeds.
4. Second `hermes pm install` and pm re-sync also succeed (idempotency).
5. `hermes --version` and normal launch unaffected; desktop/server behavior
   unchanged.
6. Hygiene items in §7 done.

## 9. Verification commands (on the phone, after CI rebuild + apt install)

```sh
# 1. confirm the new patch is installed
grep -c "no-install-package" $PREFIX/lib/hermes-agent/app/pm/environment.py
# 2. the real test
hermes pm install
# 3. prove wheels were used, not built (no "Building" lines above), then:
~/.hermes/installs/*/environments/*/bin/python -c \
  "import rpds, watchfiles, jiter, pydantic_core, cryptography, psutil; print('native OK')"
```

## 10. Report format

```
ROOT CAUSE:   <one precise paragraph, confirmed or corrected>
PATCH:        <files changed + what changed>
WHY:          <why this fixes the confirmed failure>
VALIDATION:   <commands + results>
HYGIENE:      <§7 items done>
STILL NEEDS:  <what only an on-device run can prove>
```
