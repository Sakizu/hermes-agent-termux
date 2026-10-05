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
#
# Environment:
#   NO_COLOR=1    disable colors
set -eu

REPO="Sakizu/hermes-agent-termux"
TAG=""
LOCAL_DEB=""
CHILD=""
STEP=0
TOTAL=6
TMPD=""

# Never block on a prompt: output is hidden behind the spinner, so a dpkg
# "keep or replace config file?" question must be answered automatically.
# Default is the same as dpkg's own: keep the file you already have.
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# ---------------------------------------------------------------- styling --
# One accent colour (progress), one muted grey (secondary text), and
# green / amber / red only for status. Edit the 256-colour codes to taste.
TTY=0
if [ -t 1 ]; then TTY=1; fi

if [ "$TTY" = 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    ESC="$(printf '\033')"
    RST="${ESC}[0m"
    BOLD="${ESC}[1m"
    DIM="${ESC}[38;5;245m"   # muted grey
    ACC="${ESC}[38;5;74m"    # steel blue  (spinner + progress bar)
    OK="${ESC}[38;5;108m"    # soft green  (success)
    WARN="${ESC}[38;5;179m"  # soft amber  (warnings)
    ERR="${ESC}[38;5;167m"   # soft red    (errors)
else
    RST=""; BOLD=""; DIM=""; ACC=""; OK=""; WARN=""; ERR=""
fi

COLS=80
if [ "$TTY" = 1 ]; then
    COLS="$(tput cols 2>/dev/null || echo "${COLUMNS:-80}")"
fi

usage() {
    cat <<EOF
Usage: install.sh [options]

Options:
  --tag <tag>   install a specific release (default: latest)
  --deb <file>  install a local .deb instead of downloading one
  -h, --help    show this help
EOF
}

die() {
    printf '  %s✗%s %s\n' "$ERR" "$RST" "$1" >&2
    exit "${2:-1}"
}

# ------------------------------------------------------------------ args --
while [ $# -gt 0 ]; do
    case "$1" in
        --tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
        --deb) LOCAL_DEB="${2:?--deb needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" 2 ;;
    esac
done

if [ -n "$LOCAL_DEB" ]; then
    TOTAL=4
    TARGET="local file"
elif [ -n "$TAG" ]; then
    TARGET="release $TAG"
else
    TARGET="latest release"
fi

# --------------------------------------------------------------- cleanup --
TMPD="$(mktemp -d)"
LOG="$TMPD/install.log"
: > "$LOG"

cleanup() {
    if [ -n "${CHILD:-}" ]; then kill "$CHILD" 2>/dev/null || true; fi
    if [ "$TTY" = 1 ]; then printf '\033[?25h'; fi
    rm -rf "$TMPD"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --------------------------------------------------------------- helpers --
clr() {
    if [ "$TTY" = 1 ]; then printf '\r\033[K'; fi
}

fmt_secs() {
    if [ "$1" -ge 60 ]; then
        printf '%dm %02ds' $(($1 / 60)) $(($1 % 60))
    else
        printf '%ds' "$1"
    fi
}

# bar <done-steps>  ->  ━━━━━─────  (accent filled, grey remainder)
bar() {
    w=10
    filled=$(($1 * w / TOTAL))
    i=0; fill=""; rest=""
    while [ "$i" -lt "$w" ]; do
        if [ "$i" -lt "$filled" ]; then fill="${fill}━"; else rest="${rest}─"; fi
        i=$((i + 1))
    done
    printf '%s%s%s%s%s' "$ACC" "$fill" "$DIM" "$rest" "$RST"
}

# run "Label" command [args...]
# Runs the command quietly (output goes to a log), shows a spinner while it
# works, and prints a one-line result. On failure it shows the log tail.
run() {
    label=$1; shift
    STEP=$((STEP + 1))
    t0="$(date +%s)"

    "$@" </dev/null >>"$LOG" 2>&1 &
    CHILD=$!

    if [ "$TTY" = 1 ]; then
        pb=""
        if [ "$COLS" -ge 56 ]; then pb="  $(bar $((STEP - 1)))"; fi
        while kill -0 "$CHILD" 2>/dev/null; do
            for f in ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏; do
                kill -0 "$CHILD" 2>/dev/null || break
                printf '\r\033[K  %s%s%s %s%s %s%d/%d%s' \
                    "$ACC" "$f" "$RST" "$label" "$pb" "$DIM" "$STEP" "$TOTAL" "$RST"
                sleep 0.1
            done
        done
    fi

    rc=0
    wait "$CHILD" || rc=$?
    CHILD=""
    secs=$(( $(date +%s) - t0 ))
    clr

    if [ "$rc" -ne 0 ]; then
        printf '  %s✗%s %s\n' "$ERR" "$RST" "$label"
        printf '%s' "$DIM"
        tail -n 12 "$LOG" | sed 's/^/    │ /'
        printf '%s\n' "$RST"
        saved="${HOME:-/tmp}/hermes-install.log"
        cp "$LOG" "$saved" 2>/dev/null && \
            printf '  %sFull log:%s %s\n\n' "$DIM" "$RST" "$saved"
        exit 1
    fi

    took=""
    if [ "$secs" -ge 1 ]; then took="  ${DIM}$(fmt_secs "$secs")${RST}"; fi
    printf '  %s✓%s %s%s\n' "$OK" "$RST" "$label" "$took"
}

# ----------------------------------------------------------------- steps --
check_env() {
    if [ -z "${PREFIX:-}" ] || [ ! -d "$PREFIX/bin" ]; then
        echo "this script only runs on Termux (PREFIX not set)" >&2
        return 1
    fi
    if [ "$(uname -m)" != "aarch64" ]; then
        echo "only aarch64 builds are published (this device is $(uname -m))" >&2
        return 1
    fi
    command -v apt >/dev/null 2>&1 || { echo "apt not found" >&2; return 1; }
    if [ -n "$LOCAL_DEB" ] && [ ! -f "$LOCAL_DEB" ]; then
        echo "file not found: $LOCAL_DEB" >&2
        return 1
    fi
}

install_deps() {
    # Finish any package left half-configured by an earlier interrupted run.
    dpkg --force-confold --configure -a
    apt update
    # shellcheck disable=SC2086
    apt install -y $APT_OPTS python python-pillow nodejs bash libffi libheif openssl curl
}

resolve_release() {
    if [ -z "$TAG" ]; then
        api="https://api.github.com/repos/$REPO/releases/latest"
    else
        api="https://api.github.com/repos/$REPO/releases/tags/$TAG"
    fi
    curl -fsSL --retry 3 -o "$TMPD/release.json" "$api"
    python3 - "$TMPD/release.json" >"$TMPD/urls" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
deb = sha = ""
for a in d.get("assets", []):
    n = a["name"]
    if n.endswith("_aarch64.deb"):
        deb = a["browser_download_url"]
    elif n.endswith("_aarch64.deb.sha256"):
        sha = a["browser_download_url"]
if not deb:
    sys.exit("no aarch64 .deb asset found in that release")
print(deb)
print(sha)
PY
}

fetch_pkg() {
    curl -fSL --retry 3 -o "$DEB" "$DEB_URL"
    if [ -n "$SHA_URL" ]; then
        curl -fSL --retry 3 -o "$TMPD/SHA256SUM" "$SHA_URL"
        # Compare hash values directly: the filename recorded inside the
        # .sha256 file may not match the downloaded name (some hosts
        # sanitize '+' -> '_' in asset filenames).
        want="$(awk '{print $1; exit}' "$TMPD/SHA256SUM")"
        got="$(sha256sum "$DEB" | awk '{print $1}')"
        if [ -z "$want" ] || [ "$want" != "$got" ]; then
            echo "sha256 mismatch — download may be corrupt" >&2
            return 1
        fi
    else
        : > "$TMPD/nosha"
    fi
}

verify_install() {
    hermes --version >"$TMPD/version" 2>&1
}

# ------------------------------------------------------------------ main --
START="$(date +%s)"
if [ "$TTY" = 1 ]; then printf '\033[?25l'; fi

printf '\n  %sHermes Agent%s %s· Termux installer%s\n' "$BOLD" "$RST" "$DIM" "$RST"
printf '  %s──────────────────────────────────%s\n' "$DIM" "$RST"
printf '  %starget%s  %s\n\n' "$DIM" "$RST" "$TARGET"

run "Checking environment" check_env
run "Installing dependencies" install_deps

if [ -n "$LOCAL_DEB" ]; then
    DEB="$LOCAL_DEB"
else
    run "Resolving release" resolve_release
    DEB_URL="$(sed -n 1p "$TMPD/urls")"
    SHA_URL="$(sed -n 2p "$TMPD/urls")"
    DEB="$TMPD/$(basename "$DEB_URL")"
    run "Downloading package" fetch_pkg
    if [ -f "$TMPD/nosha" ]; then
        printf '    %s!%s %sno .sha256 published — integrity check skipped%s\n' \
            "$WARN" "$RST" "$DIM" "$RST"
    fi
fi

# apt needs a path (not a bare name) for local files
case "$DEB" in
    */*) ;;
    *) DEB="./$DEB" ;;
esac

# shellcheck disable=SC2086
run "Installing hermes-agent" apt install -y $APT_OPTS "$DEB"
run "Verifying installation" verify_install

# --------------------------------------------------------------- summary --
elapsed=$(( $(date +%s) - START ))
VERSION="$(head -n 1 "$TMPD/version" 2>/dev/null || true)"

full=""; i=0
while [ "$i" -lt 10 ]; do full="${full}━"; i=$((i + 1)); done

printf '\n  %s%s%s %s100%%%s\n' "$ACC" "$full" "$RST" "$DIM" "$RST"
printf '  %s✓%s %sInstalled%s %s· %s%s\n' \
    "$OK" "$RST" "$BOLD" "$RST" "$DIM" "$(fmt_secs "$elapsed")" "$RST"
if [ -n "$VERSION" ]; then
    printf '    %s%s%s\n' "$DIM" "$VERSION" "$RST"
fi
printf '\n  %snext%s  hermes doctor\n\n' "$DIM" "$RST"
