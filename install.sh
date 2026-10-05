#!/data/data/com.termux/files/usr/bin/sh
# install.sh — install hermes-agent on Termux (aarch64).
#
# One-liner:
#   curl -sSL https://raw.githubusercontent.com/Sakizu/hermes-agent-termux/main/install.sh | sh
#
# Options:
#   --tag <tag>   install a specific release (default: latest)
#   --deb <file>  install a local .deb instead of downloading one
#   -h, --help    show this help
set -eu

REPO="Sakizu/hermes-agent-termux"
TAG=""
LOCAL_DEB=""

while [ $# -gt 0 ]; do
    case "$1" in
        --tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
        --deb) LOCAL_DEB="${2:?--deb needs a value}"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "install.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
done

# --- sanity checks: Termux on aarch64 only ---
if [ -z "${PREFIX:-}" ] || [ ! -d "$PREFIX/bin" ]; then
    echo "install.sh: this script only runs on Termux (PREFIX not set)" >&2
    exit 1
fi
if [ "$(uname -m)" != "aarch64" ]; then
    echo "install.sh: only aarch64 builds are published (this device is $(uname -m))" >&2
    exit 1
fi
command -v apt >/dev/null 2>&1 || { echo "install.sh: apt not found" >&2; exit 1; }

echo "==> installing dependencies"
apt update
apt install -y python python-pillow nodejs bash libffi libheif openssl curl

# --- locate the .deb ---
if [ -n "$LOCAL_DEB" ]; then
    DEB="$LOCAL_DEB"
    [ -f "$DEB" ] || { echo "install.sh: file not found: $DEB" >&2; exit 1; }
else
    if [ -z "$TAG" ]; then
        API_URL="https://api.github.com/repos/$REPO/releases/latest"
    else
        API_URL="https://api.github.com/repos/$REPO/releases/tags/$TAG"
    fi
    echo "==> resolving .deb from $API_URL"
    DEB_URL="$(curl -sSL --retry 3 "$API_URL" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for a in d.get("assets", []):
    if a["name"].endswith("_aarch64.deb"):
        print(a["browser_download_url"])
        break
')"
    if [ -z "$DEB_URL" ]; then
        echo "install.sh: no aarch64 .deb asset found in that release" >&2
        exit 1
    fi
    TMPD="$(mktemp -d)"
    trap 'rm -rf "$TMPD"' EXIT INT TERM
    DEB="$TMPD/$(basename "$DEB_URL")"
    echo "==> downloading $(basename "$DEB_URL")"
    curl -fSL --retry 3 -o "$DEB" "$DEB_URL"
fi

# apt needs a path (not a bare name) for local files
case "$DEB" in
    */*) ;;
    *) DEB="./$DEB" ;;
esac

echo "==> installing $DEB"
apt install -y "$DEB"

echo "==> verifying"
hermes --version
echo "install.sh: done — run 'hermes doctor' to check the setup"
