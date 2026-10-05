# hermes-agent-termux

Unofficial Termux-native `.deb` port of [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) —
the Hermes Agent CLI, TUI, and messaging gateway for Termux on Android (aarch64).

## Requirements

- Termux on Android 7+, aarch64
- About 150 MB free space

## Install

In Termux:

```sh
curl -sSL https://raw.githubusercontent.com/Sakizu/hermes-agent-termux/main/install.sh | sh
```

This installs the dependencies, downloads the latest `.deb` from the
[releases page](https://github.com/Sakizu/hermes-agent-termux/releases),
installs it, and verifies with `hermes --version`.

Prefer to do it manually? Download the `.deb` from the releases page, then:

```sh
sh install.sh --deb ./hermes-agent_<version>_aarch64.deb
```

## Update

Re-run the installer — it pulls the latest release and `apt` upgrades it in
place. (A signed APT repo is planned so updates will arrive via plain
`apt upgrade`.)

## Uninstall

```sh
apt remove hermes-agent
```

Your data in `~/.hermes` is kept.

## Building from source

See [docs/BUILD.md](docs/BUILD.md).
