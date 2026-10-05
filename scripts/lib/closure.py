#!/usr/bin/env python3
"""Compute the android/aarch64/CPython-3.14 dependency closure from uv.lock.

Generalized from the 2026-10-04 port build (was closure.py with hardcoded paths).

Usage: closure.py <uv.lock> [--json]
Prints {"pure": [(name, ver, url, sha256)], "native": [...], "unknown": [...]} as JSON.
"unknown" is fatal (exit 3): a native dep outside NATIVE_KNOWN must break the
build loudly, never ship a .deb that ImportErrors on the phone.
"""
from __future__ import annotations

import json
import sys
import tomllib

try:
    from packaging.markers import Marker
except ImportError:
    print("closure.py: needs the 'packaging' module", file=sys.stderr)
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

# Native deps we know how to provide for android (cross-built wheel or PyPI
# android wheel); everything else with no pure wheel is reported as unknown.
NATIVE_KNOWN = {
    "cryptography", "cffi", "httptools", "watchfiles", "pillow", "pillow-heif",
    "firecrawl-anydoc", "jiter", "pydantic-core", "markupsafe", "psutil", "resvg-py",
}


def marker_ok(dep: dict) -> bool:
    m = dep.get("marker")
    if not m:
        return True
    try:
        return Marker(m).evaluate(ENV)
    except Exception as e:  # noqa: BLE001 - a failed eval must not kill the walk
        print(f"MARKER-EVAL-FAIL {dep['name']}: {m} ({e})", file=sys.stderr)
        return False


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: closure.py <uv.lock>", file=sys.stderr)
        return 2
    with open(sys.argv[1], "rb") as f:
        lock = tomllib.load(f)
    by_name: dict[str, list[dict]] = {}
    for p in lock["package"]:
        by_name.setdefault(p["name"], []).append(p)

    def pick(dep) -> dict:
        name = dep["name"] if isinstance(dep, dict) else dep
        cands = by_name[name]
        if len(cands) == 1:
            return cands[0]
        want_ver = dep.get("version") if isinstance(dep, dict) else None
        want_src = dep.get("source") if isinstance(dep, dict) else None
        for c in cands:
            if want_ver and c["version"] != want_ver:
                continue
            if want_src and c["source"] != want_src:
                continue
            return c
        raise KeyError(f"no candidate for {dep}")

    closure: dict[str, tuple[str, dict]] = {}
    stack: list = [{"name": "hermes-agent"}]
    while stack:
        edge = stack.pop()
        name = edge["name"]
        if name in closure:
            continue
        pkg = pick(edge)
        closure[name] = (pkg["version"], pkg["source"])
        for dep in pkg.get("dependencies", []):
            if marker_ok(dep) and dep["name"] not in closure:
                stack.append(dep)

    pure, native, unknown = [], [], []
    for name, (ver, _src) in sorted(closure.items()):
        if name == "hermes-agent":
            continue
        pkg = pick({"name": name, "version": ver})
        wheels = pkg.get("wheels", [])
        # keep (url, sha256) pairs: pip download would otherwise resolve for
        # the host platform and may fetch a platform wheel (e.g.
        # charset-normalizer cp312 manylinux) instead of the pure one
        pure_wheels = [
            (w["url"], w["hash"].split(":", 1)[1])
            for w in wheels
            if isinstance(w, dict) and "none-any" in w.get("url", "")
            and w.get("hash", "").startswith("sha256:")
        ]
        if pure_wheels:
            url, sha256 = sorted(pure_wheels)[0]
            pure.append([name, ver, url, sha256])
        elif name in NATIVE_KNOWN:
            native.append([name, ver])
        else:
            unknown.append([name, ver])

    result = {"pure": pure, "native": native, "unknown": unknown}
    if unknown:
        print(f"FATAL: {len(unknown)} deps have no pure wheel and are not in NATIVE_KNOWN: "
              f"{[n for n, _ in unknown]}", file=sys.stderr)
        print("Add a cross-build recipe (or a Depends:) for them, or extend NATIVE_KNOWN.",
              file=sys.stderr)
        return 3
    print(json.dumps(result, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
