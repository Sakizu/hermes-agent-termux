# Building hermes-agent-termux

Reproducible build pipeline. For installing the ready-made package, see
[README.md](../README.md).

## Idea

This repo holds only the port: patches, build scripts, launchers, packaging
templates, and CI. Upstream source
([NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent))
is fetched at build time, so the repo stays small and tracks upstream.
The daily CI run picks up new upstream tags automatically.

## Layout

| Path                 | Contents                                                     |
|----------------------|--------------------------------------------------------------|
| `patches/`           | 29 numbered `.patch` files + `apply.sh` (fails loudly on drift) |
| `scripts/`           | Build stages `00`–`30`, `deb_version.py`, `build.sh`         |
| `scripts/lib/`       | Helpers: cross-compile envs, wheel assembler, `uv.lock` resolvers |
| `launchers/`         | `launcher.sh.in` template for the three launchers            |
| `DEBIAN/`            | `control.in`, `postinst`, `prerm`                             |
| `.github/workflows/` | `build-deb.yml`, `publish.yml`                               |
| `docs/`              | This file, audit reports, investigations                      |

## How a build runs

`bash scripts/build.sh --ref <upstream-tag-or-commit>` runs five stages.
Re-running with the same `--work` dir is cheap: every step skips work that
is already done.

1. **Toolchain** (`00-toolchain.sh`): downloads Android NDK r27c and the
   Termux Python 3.14 package (SHA-256 verified), extracts headers and
   target libraries.
2. **C wheels** (`10-wheels-c.sh`): cross-compiles five setuptools-C
   extensions (cffi, httptools, markupsafe, pillow-heif, psutil), assembles
   honest `android_24_arm64_v8a` wheels.
3. **Rust wheels** (`11-wheels-rust.sh`): builds six maturin crates (jiter,
   pydantic-core, watchfiles, firecrawl-anydoc, cryptography, rpds-py) for
   `aarch64-linux-android`. ~77% of build time.
4. **TUI** (`20-tui.sh`): `npm ci` on the `ui-tui` workspace, esbuilds the
   entry point.
5. **Assemble** (`30-assemble.sh`): snapshots upstream, applies `patches/`,
   unpacks the dependency closure (pure-Python wheels from `uv.lock`, the
   prebuilt `resvg-py` Android wheel, eleven cross-built wheels), ships the
   wheelhouse for `hermes pm`, mints launchers and `install-stamp.json`,
   builds the `.deb`, runs QA.

Wheel versions and sdist hashes come from the target checkout's `uv.lock`
at build time, so upstream dependency bumps need no repo edits. Pillow is
not bundled: Termux's `python-pillow` satisfies it via `Depends`.

Target: Android API 24, aarch64, CPython 3.14. Bionic is backward
compatible, so one build covers Android 7 through current.

## Patches

Where upstream assumes desktop Linux, small patches adapt it for
Termux/Android: `sys.platform == "android"` admitted alongside `"linux"`
for `/proc` features, `bash` resolved via `shutil.which`, `psutil` imports
deferred so startup never fails where it is unavailable. `patches/apply.sh`
dry-runs everything first — upstream drift fails loudly, never half-patched.

Key Termux-specific patches:
- **28** (`pm_sync_wheelhouse`): `hermes pm install`/`repair` exclude
  wheelhouse natives from `uv sync` via `--no-install-package` and install
  the 11 cross-built wheels directly; exports `LD_LIBRARY_PATH` so the
  pm-managed Python finds `libssl.so.3` for `cryptography`.
- **29** (`pm_bionic_gaps_ldpath`): bionic gap for `gh`; `LD_LIBRARY_PATH`
  in `activation_environment()` for shell integration.
- Launchers (`launchers/launcher.sh.in`) export
  `LD_LIBRARY_PATH="$PREFIX/lib"` so `site/` natives (`cryptography`,
  `pillow_heif`) load under the main CLI.
- `cffi` is kept in `site/` (not dead): `cryptography`'s Rust bindings
  import `_cffi_backend` at load time.

## Versioning

`scripts/deb_version.py` maps upstream refs to deb versions:

- `v2026.9.24` → `2026.9.24-1`
- `v2026.9.24+canary.<ts>` → `2026.9.24~canary.<ts>-1`
- untagged commit → `<latest-release-semver>+<short-sha>` (e.g.
  `0.21.5+1298c8e`; falls back to `0.0.0` if the release lookup fails)

No Debian revision on commit builds — the `+<sha>` already disambiguates.

GitHub releases are tagged `<short-sha>-termux<N>` (commits) or
`<upstream-tag>-termux<N>` (tags), titled `Hermes Agent Termux v0.21.5
(v2026.9.24)`, no release notes. The version and date are fetched live
from the upstream repo on every build.

`Depends` pins `python (>= 3.14), python (<< 3.15)`: shipped extensions
link `libpython3.14.so`, so the package is rebuilt per CPython minor.

## CI

**`build-deb.yml`**: daily at 04:00 UTC + manual dispatch (optional `ref`
input; empty = latest upstream release tag). Scheduled runs skip when the
newest upstream tag already has a `-termux` release. On success a GitHub
release is created with the `.deb` and `.sha256` attached. Needs only the
automatic `GITHUB_TOKEN`.

Build caching (`actions/cache`): the NDK toolchain and the cargo
registry/target dir are cached. The cargo key includes the upstream commit
SHA — a new pin always rebuilds from scratch; rebuilds of the same commit
skip ~5 minutes of Rust compilation.

**`publish.yml`**: on every published release, builds a signed APT repo and
uploads it to Cloudflare R2. Note: releases created by `GITHUB_TOKEN` do
not trigger `release: published` workflows (GitHub anti-loop) — see the
workflow header. Requires:

| Secret                 | Purpose                                |
|------------------------|----------------------------------------|
| `GPG_PRIVATE_KEY`      | ASCII-armored key signing the APT repo |
| `GPG_PASSPHRASE`       | Passphrase (may be empty)              |
| `R2_ACCOUNT_ID`        | Cloudflare account ID                  |
| `R2_ACCESS_KEY_ID`     | R2 API token access key                |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret                    |
| `R2_BUCKET`            | Bucket hosting the APT repo            |
| `R2_PUBLIC_URL`        | Public base URL of the bucket          |
