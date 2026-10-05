# hermes-agent-termux

Unofficial Termux-native `.deb` port of [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) —
the Hermes Agent CLI, TUI, and messaging gateway for Termux on Android (aarch64).

## Requirements

- Termux on Android 7+, aarch64
- About 150 MB free space

## Install

Download the latest `.deb` from the
[releases page](https://github.com/Sakizu/hermes-agent-termux/releases), then in Termux:

```sh
apt update
apt install ./hermes-agent_<version>_aarch64.deb
```

Use `apt install`, not `dpkg -i`, so dependencies install automatically.
Then verify:

```sh
hermes --version
hermes doctor
```

## Update

Install the newer `.deb` the same way — `apt` upgrades it in place.
(A signed APT repo is planned so updates will arrive via plain `apt upgrade`.)

## Uninstall

```sh
apt remove hermes-agent
```

Your data in `~/.hermes` is kept.

## Building from source

See [docs/BUILD.md](docs/BUILD.md).
