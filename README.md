# hermes-agent-termux

Termux-native `.deb` port of [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) — CLI, TUI, and messaging gateway for Android (aarch64). Unofficial.

## Install

```sh
curl -sSL https://raw.githubusercontent.com/Sakizu/hermes-agent-termux/main/install.sh | sh
```

Requires: [Termux](https://termux.dev/) (F-Droid), Android 7+, aarch64, ~150 MB free.

## Notes

- Tracks upstream `1298c8e`, versioned `0.21.5+1298c8e` (upstream release semver + commit).
- 27 Android/Termux compatibility patches ([`patches/`](patches/)). Native `apt` package — no proot.
- Deliberately excluded: **Matrix E2EE** (libolm archived, no Android build) and **local faster-whisper STT** (CTranslate2 has no Android build). Matrix runs unencrypted; STT falls back to API.

## Uninstall

```sh
apt remove hermes-agent
```

## Build from source

See [`docs/BUILD.md`](docs/BUILD.md).
