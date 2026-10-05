# hermes-agent-termux

Unofficial Termux-native `.deb` port of [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent):
the Hermes Agent CLI, TUI, and messaging gateway, packaged for Termux on
Android (aarch64). It uses Termux's own Python and Node — no vendored
runtimes, no proot, no Docker.

## Requirements

- Termux on Android 7 or newer, `aarch64` (virtually all modern phones)
- About 150 MB free space

## Install

1. Download the latest `.deb` from the
   [releases page](https://github.com/Sakizu/hermes-agent-termux/releases).
2. In Termux:

```sh
apt update
apt install ./hermes-agent_<version>_aarch64.deb
```

Use `apt install`, not `dpkg -i` — that way dependencies
(`python`, `python-pillow`, `nodejs`, `bash`, `libffi`, `libheif`,
`openssl`) resolve automatically.

3. Verify:

```sh
hermes --version
hermes doctor
```

That's it. Three commands are now on your `PATH`: `hermes`, `hermes-agent`,
and `hermes-acp`.

## Update

Download the newer `.deb` from the releases page and install it the same
way — `apt` upgrades the package in place. (A signed APT repository is
planned so updates will eventually arrive through plain
`apt update && apt upgrade`.)

## What's included, what's not

Included: the CLI, the prebuilt TUI (`hermes --tui`, needs `nodejs`), the
messaging gateway, and the ACP adapter.

Left out on purpose: the Electron desktop app, anything needing a Docker
daemon, and the local-Chromium browser profile — none of those have a
backend on Android. Where upstream assumed a desktop Linux, small patches
adapt it (Android platform detection, Termux paths, deferred optional
imports). Features that can't work on Android fail the way upstream designed
them to, instead of crashing.

`hermes update` is wired to defer to the package manager, so it will never
try to self-update over your installed package.

## Troubleshooting

**`hermes: command not found` after install** — open a new shell, or run
`hash -r`. The installer only creates the symlinks; your shell may have
cached the old `PATH` lookup.

**Native import errors (`*.so: cannot open shared object file`)** — make
sure dependencies actually installed: `apt install -f` fixes a partial
install.

**`hermes doctor` reports something odd** — paste the full output when
reporting it; most checks are informational.

**TTS setup** — `hermes setup tts` installs Termux's `espeak` package
(`pkg install espeak`) when no TTS engine is found.

## Uninstall

```sh
apt remove hermes-agent
```

This removes the package files and the three `PATH` symlinks. Your data
under `~/.hermes` is left alone — delete it yourself if you want a clean
slate.

## Building from source

See [docs/BUILD.md](docs/BUILD.md) for the reproducible build pipeline,
versioning, and CI. The audit report for this port lives at
[docs/AUDIT-2026-10-05.md](docs/AUDIT-2026-10-05.md).
