#!/usr/bin/env python3
"""Assemble an Android wheel from setuptools build output.

Reconstructed from the 2026-10-04 build log (WB track).

Why this exists: the host python is 3.12/x86_64 while the target is
CPython 3.14/aarch64-android, so plain ``setup.py bdist_wheel`` would tag
``cp312`` and name extensions ``.cpython-312-x86_64-linux-gnu.so`` — not
importable on the phone. Instead we run ``build_py`` + ``build_ext`` under
the cross env (see xenv.sh/xrun.py) and assemble the wheel manually with
the honest filenames and tags.

Usage:
    assemble_wheel.py --src <sdist-dir> --build-lib <build/lib.*>
                      --dist <name> --version <ver> --out <dir>
                      [--tag cp314-cp314-android_24_arm64_v8a]
                      [--abi3-tag cp38-abi3-android_24_arm64_v8a]

  --src       extracted sdist (or source checkout); must contain PKG-INFO
  --build-lib setuptools build lib dir holding the compiled tree
  --tag       WHEEL tag + extension suffix for the normal (cp314) case
  --abi3-tag  when given, extensions keep the ``.abi3.so`` suffix and the
              wheel is tagged with this value instead
"""
from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import io
import os
import re
import shutil
import sys
import zipfile

ANDROID_EXT_SUFFIX = ".cpython-314-aarch64-linux-android.so"
ABI3_EXT_SUFFIX = ".abi3.so"


def _android_ext_suffix(tag: str) -> str:
    # derive ".cpython-314-aarch64-linux-android.so" from a tag like
    # "cp314-cp314-android_24_arm64_v8a" so a python bump flows through
    m = re.match(r"cp(\d+)-", tag)
    return f".cpython-{m.group(1) if m else '314'}-aarch64-linux-android.so"


def _b64sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return "sha256=" + base64.urlsafe_b64encode(h.digest()).rstrip(b"=").decode()


def _rename_ext(basename: str, abi3: bool, tag: str) -> str:
    # 'parser.cpython-312-x86_64-linux-gnu.so' -> 'parser.cpython-314-aarch64-linux-android.so'
    # (or 'parser.abi3.so' in abi3 mode)
    stem = basename.split(".", 1)[0]
    return stem + (ABI3_EXT_SUFFIX if abi3 else _android_ext_suffix(tag))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--build-lib", required=True)
    ap.add_argument("--dist", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--tag", default="cp314-cp314-android_24_arm64_v8a")
    ap.add_argument("--abi3-tag", default=None)
    args = ap.parse_args()

    abi3 = args.abi3_tag is not None
    tag = args.abi3_tag or args.tag
    dist = args.dist.replace("-", "_")
    dist_info = f"{dist}-{args.version}.dist-info"
    wheel_name = f"{dist}-{args.version}-{tag}.whl"

    pkg_info = os.path.join(args.src, "PKG-INFO")
    if not os.path.isfile(pkg_info):
        print(f"assemble_wheel.py: no PKG-INFO in --src {args.src}", file=sys.stderr)
        return 1

    stage = os.path.abspath("_assemble_stage")
    if os.path.isdir(stage):
        shutil.rmtree(stage)
    os.makedirs(stage)

    # 1. copy the built tree, renaming extensions to the android suffix
    renamed = 0
    for root, _dirs, files in os.walk(args.build_lib):
        for fn in files:
            src = os.path.join(root, fn)
            rel = os.path.relpath(src, args.build_lib)
            if fn.endswith(".so"):
                d, base = os.path.split(rel)
                rel = os.path.join(d, _rename_ext(base, abi3, tag))
                renamed += 1
            dst = os.path.join(stage, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
    if renamed == 0:
        print("assemble_wheel.py: warning: no .so files found in build-lib", file=sys.stderr)

    # 2. dist-info: METADATA from the sdist PKG-INFO, plus WHEEL
    di = os.path.join(stage, dist_info)
    os.makedirs(di, exist_ok=True)
    shutil.copy2(pkg_info, os.path.join(di, "METADATA"))
    with open(os.path.join(di, "WHEEL"), "w") as f:
        f.write(
            "Wheel-Version: 1.0\n"
            "Generator: hermes-agent-termux assemble_wheel\n"
            "Root-Is-Purelib: false\n"
            f"Tag: {tag}\n"
        )

    # 3. RECORD with recomputed hashes
    records: list[tuple[str, str, str]] = []
    for root, _dirs, files in os.walk(stage):
        for fn in files:
            p = os.path.join(root, fn)
            rel = os.path.relpath(p, stage).replace(os.sep, "/")
            if rel == f"{dist_info}/RECORD":
                continue
            records.append((rel, _b64sha256(p), str(os.path.getsize(p))))
    records.sort()
    records.append((f"{dist_info}/RECORD", "", ""))
    with open(os.path.join(stage, dist_info, "RECORD"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerows(records)

    # 4. zip it
    os.makedirs(args.out, exist_ok=True)
    out_path = os.path.join(os.path.abspath(args.out), wheel_name)
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for root, _dirs, files in os.walk(stage):
            for fn in files:
                p = os.path.join(root, fn)
                rel = os.path.relpath(p, stage).replace(os.sep, "/")
                zi = zipfile.ZipInfo(rel)
                zi.external_attr = (0o644 << 16)
                with open(p, "rb") as fh:
                    z.writestr(zi, fh.read())

    # 5. verify RECORD hashes against the zip
    with zipfile.ZipFile(out_path) as z:
        for rel, digest, size in records:
            if not digest:
                continue
            data = z.read(rel)
            h = "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
            if h != digest or str(len(data)) != size:
                print(f"assemble_wheel.py: RECORD mismatch for {rel}", file=sys.stderr)
                return 1

    print(f"assembled {wheel_name} ({renamed} extensions renamed)")
    shutil.rmtree(stage)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
