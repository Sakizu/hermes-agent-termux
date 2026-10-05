#!/usr/bin/env python3
"""Resolve a Termux .deb's download URL + sha256 from the live Packages index.

Usage: termux_deb.py <package-name>
Prints "<url> <sha256>". Fails if the package is not in the index
(404 on build.sh == not shipped, per the dep-mapping method).
"""
from __future__ import annotations

import os
import sys
import urllib.request

PACKAGES_URL = os.environ.get(
    "TERMUX_PACKAGES_URL",
    "https://packages.termux.dev/apt/termux-main/dists/stable/main/binary-aarch64/Packages",
)
POOL_BASE = "https://packages.termux.dev/apt/termux-main/"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: termux_deb.py <package-name>", file=sys.stderr)
        return 2
    want = sys.argv[1]
    with urllib.request.urlopen(PACKAGES_URL) as r:
        text = r.read().decode()
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
