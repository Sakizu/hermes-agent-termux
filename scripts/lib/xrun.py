#!/usr/bin/env python3
"""Run a setup.py under a sanitized sysconfig for Android cross-compilation.

Reconstructed from the 2026-10-04 build log (WB track, quirk 3).

Problem: on an x86_64 Linux host, ``build_ext.finalize_options`` appends the
host ``LIBDIR`` (``/usr/lib/x86_64-linux-gnu``) to ``library_dirs``. The NDK
``ld.lld`` then finds the host ``libc.so`` *linker script* and dies with::

    ld.lld: error: --fix-cortex-a53-843419 is only supported on AArch64 targets

Fix: before setup.py runs, rewrite the ``LIBDIR``/``LIBPL`` config vars to
point at the Termux target lib dir. Both ``get_config_var`` and the
``get_config_vars`` dict are patched, since distutils consults both.

Usage: xrun.py <setup.py args...>
Env:   HERMES_TERMUX_LIB - target $PREFIX/lib (Termux python lib dir)
"""
from __future__ import annotations

import os
import sys
import sysconfig

TERMUX_LIB = os.environ.get("HERMES_TERMUX_LIB")
if not TERMUX_LIB:
    raise SystemExit("xrun.py: HERMES_TERMUX_LIB is not set")

_REWRITTEN = {"LIBDIR", "LIBPL"}

_orig_var = sysconfig.get_config_var
_orig_vars = sysconfig.get_config_vars


def _get_config_var(name: str):
    if name in _REWRITTEN:
        return TERMUX_LIB
    return _orig_var(name)


def _get_config_vars(*args):
    d = _orig_vars(*args)
    if isinstance(d, dict):
        for k in _REWRITTEN:
            if k in d:
                d[k] = TERMUX_LIB
    return d


sysconfig.get_config_var = _get_config_var  # type: ignore[assignment]
sysconfig.get_config_vars = _get_config_vars  # type: ignore[assignment]

# distutils.sysconfig caches via its own get_config_var wrapper in some
# versions; patch that too if present.
try:
    import distutils.sysconfig as dsc

    dsc.get_config_var = _get_config_var  # type: ignore[assignment]
except ImportError:
    pass

sys.argv = ["setup.py", *sys.argv[1:]]
with open("setup.py", "rb") as f:
    code = compile(f.read(), "setup.py", "exec")
exec(code, {"__name__": "__main__", "__file__": os.path.abspath("setup.py")})
