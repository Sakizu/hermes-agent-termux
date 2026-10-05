#!/usr/bin/env python3
"""Resolve a Termux .deb's download URL + sha256 from the live Packages index.

Usage: termux_deb.py <package-name>
Prints "<url> <sha256>". Fails if the package is not in the index
(404 on build.sh == not shipped, per the dep-mapping method).
"""
from __future__ import annotations

import http.client
import os
import sys
import time
import urllib.request

PACKAGES_URL = os.environ.get(
    "TERMUX_PACKAGES_URL",
    "https://packages.termux.dev/apt/termux-main/dists/stable/main/binary-aarch64/Packages",
)
POOL_BASE = "https://packages.termux.dev/apt/termux-main/"
FETCH_TRIES = 5


def fetch_text(url: str) -> str:
    """Fetch a URL, retrying transient network failures (the sandbox egress
    proxy occasionally truncates long responses)."""
    last: Exception | None = None
    for attempt in range(1, FETCH_TRIES + 1):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return r.read().decode()
        except (
            http.client.IncompleteRead,
            http.client.RemoteDisconnected,
            ConnectionError,
            TimeoutError,
            OSError,
        ) as e:  # OSError covers urllib.error.URLError
            last = e
            print(
                f"termux_deb.py: fetch attempt {attempt}/{FETCH_TRIES} failed "
                f"({e}); retrying",
                file=sys.stderr,
            )
            time.sleep(2 * attempt)
    raise SystemExit(
        f"termux_deb.py: failed to fetch {url} after {FETCH_TRIES} tries: {last}"
    )


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: termux_deb.py <package-name>", file=sys.stderr)
        return 2
    want = sys.argv[1]
    text = fetch_text(PACKAGES_URL)
    pkg: dict[str, str] = {}
    for para in text.split("\n\n"):
        d: dict[str, str] = {}
        for line in para.splitlines():
            if ": " in line and not line.startswith(" "):
                k, v = line.split(": ", 1)
                d[k] = v
        if d.get("Package") == want and d.get("Architecture") == "aarch64":
            pkg = d
            break
    if not pkg:
        print(f"termux_deb.py: {want} not found in the aarch64 Packages index", file=sys.stderr)
        return 1
    print(f"{POOL_BASE}{pkg['Filename']} {pkg['SHA256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
