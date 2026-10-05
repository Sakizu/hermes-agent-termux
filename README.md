# hermes-agent-termux

Unofficial Termux-native `.deb` port of [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) — the Hermes Agent CLI, TUI, and messaging gateway for Termux on Android (aarch64).

- Native `apt` package — no proot, no chroot; TUI bundled
- 22 MB download, ~120 MB installed
- Tracks upstream `1298c8e` (2026-09-24); 26 Android/Termux compatibility patches ([`patches/`](patches/))

## Requirements

- [Termux](https://termux.dev/) from F-Droid, Android 7+, aarch64
- ~150 MB free space

## Install

```sh
curl -sSL https://raw.githubusercontent.com/Sakizu/hermes-agent-termux/main/install.sh | sh
```

Verify:

```sh
hermes --version
hermes doctor
```

## What's different from upstream

Excluded, deliberately:

- **Matrix E2EE** — `python-olm` has no Android build path and libolm is archived with unresolved security issues. Matrix works without E2EE.
- **Local faster-whisper STT** — CTranslate2 has no Android build path. Falls back to API STT (Groq/OpenAI), or `whisper.cpp` via `local_command`.

## Uninstall

```sh
apt remove hermes-agent
```

## Build from source

See [`docs/BUILD.md`](docs/BUILD.md).
