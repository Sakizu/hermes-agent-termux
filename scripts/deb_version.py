#!/usr/bin/env python3
"""Derive a Debian package version from a hermes-agent release tag or commit.

Follows upstream's intent (scripts/termux/deb_version.py: tag -> deb version)
but handles the CalVer tags upstream actually cuts (v2026.9.24), which the
upstream regex rejects (it caps the major at 3 digits).

Mapping:
    v2026.9.24                          -> 2026.9.24-1
    v2026.9.24+canary.20261005T120000Z  -> 2026.9.24~canary.20261005T120000Z-1
    <40-hex commit> (untagged build)    -> 0.0.0+<short7>

The ``~`` ranks a canary below the corresponding stable in dpkg's version
ordering. Debian revision ``-1`` is our packaging revision; bump to -2, -3…
for rebuilds of the same upstream tag.
"""

from __future__ import annotations

import re
import sys

_TAG_RE = re.compile(
    r"^v(?P<major>0|[1-9]\d*)\.(?P<minor>0|[1-9]\d*)\.(?P<patch>0|[1-9]\d*)"
    r"(?:\+canary\.(?P<ts>20\d{6}T\d{6}Z))?$"
)
_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")


def deb_version_for_tag(tag: str, deb_revision: int = 1) -> str:
    m = _TAG_RE.match(tag)
    if m is None:
        raise ValueError(
            f"malformed release tag {tag!r}: expected v<MAJOR>.<MINOR>.<PATCH> "
            "or v<MAJOR>.<MINOR>.<PATCH>+canary.<UTC timestamp>"
        )
    base = f"{m.group('major')}.{m.group('minor')}.{m.group('patch')}"
    ts = m.group("ts")
    if ts is None:
        return f"{base}-{deb_revision}"
    return f"{base}~canary.{ts}-{deb_revision}"


def deb_version_for_commit(commit: str, deb_revision: int = 1) -> str:
    if not _COMMIT_RE.match(commit):
        raise ValueError(f"not a 40-hex commit: {commit!r}")
    base = f"0.0.0+{commit[:7]}"
    # Same convention as tags: -1 is the first packaging; -2, -3... for
    # rebuilds of the same upstream commit (e.g. build-system changes like
    # .pyc precompilation that don't change the upstream ref).
    return base if deb_revision <= 1 else f"{base}-{deb_revision}"


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print("usage: deb_version.py <tag|commit> [debian-revision]", file=sys.stderr)
        return 2
    ref, rev = argv[1], int(argv[2]) if len(argv) == 3 else 1
    try:
        print(deb_version_for_tag(ref, rev) if ref.startswith("v") else deb_version_for_commit(ref, rev))
    except ValueError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
