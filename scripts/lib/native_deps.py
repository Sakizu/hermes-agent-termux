#!/usr/bin/env python3
"""Resolve the 11 native deps from the target checkout's uv.lock.

For each native dep needed on android, prints a JSON list of:
  {"name", "version", "kind": "sdist"|"git", "url", "sha256", "rev"}

- "sdist": download url + sha256 from the lock's sdist entry (verified).
- "git":   psutil's android pin (git rev); sdist is null in the lock.

Marker evaluation uses the android target env, so the git-sourced psutil
(android) is picked over the registry 7.2.2 (non-android). Versions are NOT
hardcoded here: upstream dep bumps in uv.lock are followed automatically.

Usage: native_deps.py <uv.lock>
"""
from __future__ import annotations

import json
import sys
import tomllib

try:
    from packaging.markers import Marker
except ImportError:
    print("native_deps.py: needs the 'packaging' module", file=sys.stderr)
    raise SystemExit(2)

ENV = {
    "sys_platform": "android",
    "python_version": "3.14",
    "python_full_version": "3.14.6",
    "platform_machine": "aarch64",
    "platform_python_implementation": "CPython",
    "implementation_name": "cpython",
    "os_name": "posix",
    "platform_system": "Linux",
}

# name -> build track
TRACKS = {
    "cffi": "c", "httptools": "c", "markupsafe": "c",
    "pillow-heif": "c", "psutil": "c",
    "jiter": "rust", "pydantic-core": "rust", "watchfiles": "rust",
    "firecrawl-anydoc": "rust", "cryptography": "rust", "rpds-py": "rust",
    "resvg-py": "pypi-android",  # prebuilt android abi3 wheel on PyPI
}


def marker_ok(marker: str | None) -> bool:
    if not marker:
        return True
    try:
        return Marker(marker).evaluate(ENV)
    except Exception:  # noqa: BLE001
        return False


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: native_deps.py <uv.lock>", file=sys.stderr)
        return 2
    with open(sys.argv[1], "rb") as f:
        lock = tomllib.load(f)
    by_name: dict[str, list[dict]] = {}
    for p in lock["package"]:
        by_name.setdefault(p["name"], []).append(p)

    # hermes-agent's own dependency edges carry the markers; e.g. psutil
    # appears twice in the lock (7.2.2 registry for non-android, 8.0.0 git
    # for android) and the edge markers pick the right one.
    root = next(p for p in lock["package"] if p["name"] == "hermes-agent")
    edges: dict[str, list[dict]] = {}
    for dep in root.get("dependencies", []):
        if marker_ok(dep.get("marker")):
            edges.setdefault(dep["name"], []).append(dep)

    out = []
    for name, track in TRACKS.items():
        cands = by_name.get(name, [])
        if not cands:
            # dep dropped upstream in this revision
            print(f"NOTE: {name} not in uv.lock; skipping", file=sys.stderr)
            continue
        chosen = None
        for edge in edges.get(name, []):
            for c in cands:
                if edge.get("version") and c["version"] != edge["version"]:
                    continue
                if edge.get("source") and c["source"] != edge["source"]:
                    continue
                chosen = c
                break
            if chosen:
                break
        if chosen is None:
            # no edge (transitive-only dep): take the highest version
            chosen = sorted(cands, key=lambda c: c["version"])[-1]

        src = chosen.get("source", {})
        sdist = chosen.get("sdist")
        if "git" in src:
            import re
            m = re.search(r"[?&]rev=([0-9a-f]{40})", src["git"])
            rev = m.group(1) if m else src["git"].split("#")[-1]
            out.append({"name": name, "version": chosen["version"], "kind": "git",
                        "url": src["git"].split("?")[0], "rev": rev, "track": track})
        elif sdist:
            url, h = sdist["url"], sdist["hash"]
            assert h.startswith("sha256:"), f"unexpected hash format for {name}: {h}"
            out.append({"name": name, "version": chosen["version"], "kind": "sdist",
                        "url": url, "sha256": h.split(":", 1)[1], "track": track})
        else:
            print(f"ERROR: {name}@{chosen['version']}: no sdist and no git source", file=sys.stderr)
            return 1

    print(json.dumps(out, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
