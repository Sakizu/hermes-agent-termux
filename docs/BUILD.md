# Building hermes-agent-termux

This document covers the reproducible build pipeline. For installing the
ready-made package, see [README.md](../README.md).

## Idea

The repository holds only the port: patches, build scripts, launchers,
packaging templates, and CI. Upstream source
([NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent))
is fetched at build time, so the repo stays small and tracks upstream
releases. New upstream tags are picked up automatically by the daily CI run.

## Repo layout

| Path                  | Contents                                                        |
|-----------------------|-----------------------------------------------------------------|
| `patches/`            | 26 numbered `.patch` files plus `apply.sh` (fails loudly on drift) |
| `scripts/`            | Build stages `00`–`30`, `deb_version.py`, `build.sh`            |
| `scripts/lib/`        | Helpers: cross-compile envs, wheel assembler, `uv.lock` resolvers |
| `launchers/`          | `launcher.sh.in` template used to mint the three launchers      |
| `DEBIAN/`             | `control.in`, `postinst`, `prerm`                               |
| `.github/workflows/`  | `build-deb.yml`, `publish.yml`                                  |
| `versions.env`        | Toolchain pins (NDK, Termux Python, build tools)                |
| `docs/`               | This file, plus dated audit reports                             |

## How a build runs

`bash scripts/build.sh --ref <upstream-tag-or-commit> [--work <dir>]` runs
five stages. Re-running with the same `--work` dir is cheap: every step
skips work that is already done.

1. **Toolchain** (`00-toolchain.sh`): downloads Android NDK r27c and the
   Termux Python 3.14.6 package (both SHA-256 verified), extracts the headers
   and target libraries, and smoke-compiles a test C extension for
   `aarch64-linux-android24`.
2. **C wheels** (`10-wheels-c.sh`): cross-compiles five setuptools-C
   extensions (cffi, httptools, markupsafe, pillow-heif, psutil from its
   Android-support git pin), assembles honest `android_24_arm64_v8a` wheels,
   and repairs their Python linkage with upstream's `python_linkage.py`.
3. **Rust wheels** (`11-wheels-rust.sh`): builds five maturin crates (jiter,
   pydantic-core, watchfiles, firecrawl-anydoc, cryptography) for
   `aarch64-linux-android`.
4. **TUI** (`20-tui.sh`): `npm ci` on the `ui-tui` workspace and esbuilds
   `hermes_cli/tui_dist/entry.js`, mirroring upstream's own plant step.
5. **Assemble** (`30-assemble.sh`): snapshots upstream minus the inert dirs,
   applies `patches/`, unpacks the dependency closure into `site/` (pure
   Python wheels from `uv.lock`, the prebuilt `resvg-py` Android wheel from
   PyPI, and the ten cross-built wheels), compiles `libfts5_cjk.so`, mints
   the launchers and `install-stamp.json`, builds the `.deb` with
   `dpkg-deb`, and runs QA (path containment, shebangs, aarch64 ELF check,
   import smoke test).

Wheel versions and sdist hashes are read from the target checkout's `uv.lock`
at build time (`scripts/lib/native_deps.py`), so upstream dependency bumps
are picked up without editing this repo. Pillow is deliberately not bundled:
Termux's `python-pillow` satisfies it through `Depends`.

Target: Android API 24, aarch64, CPython 3.14. One `.deb` per architecture;
there is no universal-ABI package (a single build already covers Android
7 through current — Bionic is backward compatible).

## The 26 patches

Where upstream code assumed a desktop Linux, small patches adapt it for
Termux/Android: `sys.platform == "android"` is admitted next to `"linux"`
for the `/proc`-based features Android actually has, `bash` is resolved with
`shutil.which` instead of a hardcoded `/bin/bash`, and `psutil` imports are
deferred so startup never fails where it is unavailable. None of the 26
paths are covered by upstream's own in-tree Termux handling (verified
2026-10-05) — every patch is still needed. `patches/apply.sh` dry-runs all
patches before applying any, so upstream drift fails loudly instead of
producing a half-patched tree.

## Versioning

Deb versions follow upstream release tags through `scripts/deb_version.py`:

- `v2026.9.24` → `2026.9.24-1`
- `v2026.9.24+canary.<timestamp>` → `2026.9.24~canary.<timestamp>-1`
  (`~` sorts below the stable release in dpkg ordering)
- untagged commit → `0.0.0+<short-sha>`

One caveat: upstream's own `scripts/termux/deb_version.py` rejects the CalVer
tags upstream actually publishes (its regex caps the major version at three
digits). This repo keeps the same mapping idea with a regex that accepts
them.

GitHub releases here are tagged `<upstream-tag>-termux<N>`, where `N`
increments on rebuilds of the same upstream tag and maps to the Debian
revision (`-1`, `-2`, …).

`Depends` pins `python (>= 3.14), python (<< 3.15)`: every shipped extension
hard-links `libpython3.14.so`, so an unbounded dependency would brick all
native imports on the first Termux python-minor upgrade. The package is
rebuilt per CPython minor as a matter of policy.

## CI

- **`build-deb.yml`**: runs daily at 04:00 UTC and on manual dispatch
  (Actions → `build-deb` → Run workflow, optional `ref` input; empty
  resolves to the latest upstream release tag). Scheduled runs skip when the
  newest upstream tag already has a `-termux` release. On success the `.deb`
  is uploaded as a workflow artifact and a GitHub release is created with it
  attached.
- **`publish.yml`**: on every published release, builds a signed APT repo
  (`Packages`, `InRelease`) and uploads it to Cloudflare R2. Note: releases
  created by `GITHUB_TOKEN` do not trigger `release: published` workflows
  (GitHub anti-loop behavior) — see the workflow header for the intended
  trigger setup.

## Secrets required for publishing

Set these in repo Settings → Secrets and variables → Actions before
`publish.yml` can succeed:

| Secret                 | Purpose                                   |
|------------------------|-------------------------------------------|
| `GPG_PRIVATE_KEY`      | ASCII-armored key that signs the APT repo |
| `GPG_PASSPHRASE`       | Passphrase for that key (may be empty)    |
| `R2_ACCOUNT_ID`        | Cloudflare account ID                     |
| `R2_ACCESS_KEY_ID`     | R2 API token access key                   |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret                       |
| `R2_BUCKET`            | Bucket hosting the APT repo               |
| `R2_PUBLIC_URL`        | Public base URL of the bucket             |

The build workflow needs no secrets beyond the automatic `GITHUB_TOKEN`.
