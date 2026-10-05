# hermes-agent-termux

Unofficial Termux-native `.deb` port of [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent).
It cross-builds the agent for Android (aarch64) and packages it so it installs
on Termux with `apt`, using Termux's own Python and Node instead of vendored
runtimes.

This repo holds only the port: patches, build scripts, and CI. Upstream source
is fetched at build time, so the repo stays small and tracks upstream releases
automatically.

## What you get

Three launchers, installed as symlinks in `$PREFIX/bin`:

| Command       | Entry point          |
|---------------|----------------------|
| `hermes`      | `hermes_cli.main`    |
| `hermes-agent`| `agent.legacy_cli`   |
| `hermes-acp`  | `acp_adapter.entry`  |

The package ships the CLI, the prebuilt TUI bundle (needs `nodejs` on the
phone), the messaging gateway, and the ACP adapter. `install-stamp.json`
marks the distribution as `apt-termux` with `updateMechanism: external`, so
`hermes update` defers to the package manager instead of trying to
self-update. `postinst` creates the `$PREFIX/bin` symlinks and refuses to
clobber files it does not own.

## What is intentionally left out

The snapshot step excludes upstream's inert directories (`tests`,
`tests-js`, `website`, `evals`, `.github`, `nix`, `docker`, `apps`, `ui-tui`,
`web`, `scripts`). In practice that means:

- No Electron desktop app and no desktop installer scaffolding.
- No Docker-related files; anything needing a Docker daemon has no backend
  on Android.
- No local Chromium and no desktop-only services.
- The TUI ships as a prebuilt bundle rather than a buildable workspace.

Where upstream code assumed a desktop Linux, 26 small patches adapt it:
`sys.platform == "android"` is admitted next to `"linux"` for the
`/proc`-based features Android actually has, `bash` is resolved with
`shutil.which` instead of a hardcoded `/bin/bash`, and `psutil` imports are
deferred so startup never fails where it is unavailable. Features that still
cannot work on Android degrade the way upstream designed them to, or are
excluded at packaging time.

## Repo layout

| Path                  | Contents                                                        |
|-----------------------|-----------------------------------------------------------------|
| `patches/`            | 26 numbered `.patch` files plus `apply.sh` (fails loudly on drift) |
| `scripts/`            | Build stages `00`–`30`, `deb_version.py`, `build.sh`            |
| `scripts/lib/`        | Helpers: cross-compile envs, wheel assembler, `uv.lock` resolvers |
| `launchers/`          | `launcher.sh.in` template used to mint the three launchers      |
| `DEBIAN/`             | `control.in`, `postinst`                                        |
| `.github/workflows/`  | `build-deb.yml`, `publish.yml`                                  |
| `versions.env`        | Toolchain pins (NDK, Termux Python, build tools)                |

## How a build runs

`bash scripts/build.sh --ref <upstream-tag-or-commit>` runs five stages:

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

Target: Android API 24, aarch64, CPython 3.14.

## Versioning

Deb versions follow upstream release tags through `scripts/deb_version.py`:

- `v2026.9.24` → `2026.9.24-1`
- `v2026.9.24+canary.20261005T120000Z` → `2026.9.24~canary.20261005T120000Z-1`
  (`~` sorts below the stable release in dpkg ordering)
- untagged commit → `0.0.0+<short-sha>`

One caveat: upstream's own `scripts/termux/deb_version.py` rejects the CalVer
tags upstream actually publishes (its regex caps the major version at three
digits). This repo keeps the same mapping idea with a regex that accepts
them.

GitHub releases here are tagged `<upstream-tag>-termux<N>`, where `N`
increments on rebuilds of the same upstream tag and maps to the Debian
revision (`-1`, `-2`, …).

## CI

- **`build-deb.yml`**: runs daily at 04:00 UTC and on manual dispatch.
  An empty `ref` input resolves to the latest upstream release tag.
  Scheduled runs skip when the newest upstream tag already has a `-termux`
  release. On success the `.deb` is uploaded as a workflow artifact and a
  GitHub release is created with it attached.
- **`publish.yml`**: on every published release, builds a signed APT repo
  (`Packages`, `InRelease`) and uploads it to Cloudflare R2.

Manual build: Actions → `build-deb` → Run workflow → optional `ref`.

## Secrets required for publishing

Set these in repo Settings → Secrets and variables → Actions before
`publish.yml` can succeed:

| Secret               | Purpose                                    |
|----------------------|--------------------------------------------|
| `GPG_PRIVATE_KEY`    | ASCII-armored key that signs the APT repo  |
| `GPG_PASSPHRASE`     | Passphrase for that key (may be empty)     |
| `R2_ACCOUNT_ID`      | Cloudflare account ID                      |
| `R2_ACCESS_KEY_ID`   | R2 API token access key                    |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret                      |
| `R2_BUCKET`          | Bucket hosting the APT repo                |
| `R2_PUBLIC_URL`      | Public base URL of the bucket              |

The build workflow needs no secrets beyond the automatic `GITHUB_TOKEN`.

## Install on the phone

Download the `.deb` from the GitHub releases page, then in Termux:

```sh
apt update
apt install ./hermes-agent_<version>_aarch64.deb
```

Use `apt install`, not `dpkg -i`, so dependencies
(`python >= 3.14`, `python-pillow`, `nodejs`, `bash`, `libffi`, `libheif`,
`openssl`) resolve automatically. Then:

```sh
hermes --version
hermes doctor
```

## APT repo (once publishing is configured)

```
deb [signed-by=/usr/share/keyrings/hermes-agent-termux.gpg] https://<R2_PUBLIC_URL> stable main
```

The public signing key is published at the repo root as
`hermes-agent-termux.gpg`. After that, updates arrive through the normal
flow: `apt update && apt upgrade hermes-agent`.
