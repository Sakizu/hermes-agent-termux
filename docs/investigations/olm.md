# Investigation: can python-olm build for Android aarch64 (Termux)?

Date: 2026-10-05
Status: investigation only (no full build attempted)
Verdict: **BUILDABLE-WITH-EFFORT** (python-olm itself); full Matrix E2EE feature is a bigger job.

## 1. What python-olm is and what hermes uses it for

- **Version pinned by hermes-agent:** `python-olm==3.2.16`
  (sdist `python-olm-3.2.16.tar.gz`, sha256 `a1c47fce2505b7a16841e17694cbed4ed484519646ede96ee9e89545a49643c9`, 2023-11-28 — from `uv.lock` in `~/workspace/.hermes-build/upstream`).
- **Architecture:** pure-Python package + cffi binding (`olm_build.py`). The native part is a **vendored copy of libolm** (the Matrix E2E C++ library, archived 2023) inside the sdist. `olm_build.py` compiles libolm (cmake first, GNU-make fallback) and statically links it into the `_libolm` cffi extension. Python-side dependency is only `cffi` (already cross-built for this port).
- **Used for:** Matrix gateway **E2EE** via `mautrix[encryption]`. `plugins/platforms/matrix/adapter.py::_check_e2ee_requirements()` requires four imports: `olm` (via `mautrix.crypto.OlmMachine`), `PgCryptoStore`, `asyncpg`, `aiosqlite`.
- **Without it:** Matrix gateway still works, unencrypted. The adapter has import-safe stubs; upstream documents "The matrix adapter degrades gracefully without mautrix (import stubs)." `hermes doctor` reports: *"Matrix E2EE extra is excluded on Termux (python-olm currently fails to build)."*

## 2. Why it was excluded — the documented failure

Upstream `pyproject.toml` (`~/workspace/.hermes-build/upstream`, lines 274–281) says verbatim:

> `mautrix[encryption]` pulls `python-olm`, whose vendored libolm (archived 2023)
> cannot build on Windows or modern macOS: no wheels for those targets AND the
> sdist fails to compile on current clang/MSVC (**olm/list.hh const-iterator error**)
> and on **CMake >= 4**.

Two distinct claims: (a) a C++ compile error in `olm/list.hh` on current compilers,
(b) `cmake_minimum_required(VERSION 3.4)` is rejected by CMake >= 4 (CMake 4.0 removed
compatibility with `< 3.5`).

## 3. Probe results (NDK r27c, clang 18.0.3, target aarch64-linux-android24)

Toolchain: the already-extracted `~/workspace/.hermes-build/toolchain/android-ndk-r27c`
(`Android clang version 18.0.3`). Method: compiled every libolm source file directly,
bypassing the sdist's host-oriented build script.

| Probe | Result |
|---|---|
| All 22 `libolm/src/*.cpp` with `-std=c++11` | ✅ compile clean — the `list.hh` const-iterator error **does not reproduce** with NDK clang 18 |
| All `libolm/src/*.c`, `lib/crypto-algorithms/*.{c,cpp}`, `lib/ed25519/src/*.c` | ✅ compile clean |
| Host `cmake . -Bbuild` (cmake 3.28.3) | ✅ configures (only a deprecation warning about `cmake_minimum_required(VERSION 3.4)`) |
| PyPI: any Android wheel for python-olm? | ❌ none — only manylinux cp37–cp312 (x86_64/aarch64/i686) + sdist (verified via PyPI JSON API) |

Two apparent failures during probing turned out to be build-system artifacts, not real
blockers (fixed by passing the flags CMake would normally supply):
- `src/olm.cpp`: `OLMLIB_VERSION_MAJOR` undeclared → needs `-DOLMLIB_VERSION_MAJOR=3 -DOLMLIB_VERSION_MINOR=2 -DOLMLIB_VERSION_PATCH=16` (CMake `add_definitions`).
- `src/crypto.cpp`: `crypto-algorithms/aes.h` not found → needs `-Ilib` (the sources live in `libolm/lib/crypto-algorithms/`).

**Conclusion of probes:** the C/C++ code itself is fully compilable for Android aarch64
with the port's pinned toolchain. Neither cited failure mode bites here.

## 4. Real (surmountable) blockers for a cross-compile recipe

1. **`olm_build.py` is host-oriented.** It shells out to `cmake . -Bbuild` / `make` with
   the *host* compiler and expects the static lib at `libolm/build/`. A recipe must
   bypass or patch this step: pre-build `libolm.a` with the NDK, then run the cffi
   portion with `CC`/`CXX` pointed at the NDK clang and Python headers from `termux-py`.
   (Follows the existing `HERMES_CROSS_BUILD` / per-package-quirk pattern in
   `scripts/10-wheels-c.sh`.)
2. **CMake >= 4 hard-fails** on `cmake_minimum_required(VERSION 3.4)`, and `olm_build.py`
   only falls back to `make` on `FileNotFoundError` — a *failing* cmake raises
   `CalledProcessError`, which propagates. Mitigations: pin `cmake<4` in the build env,
   patch the minimum to 3.5, or skip cmake entirely (direct compile + `llvm-ar`, as probed).
3. **Scope is bigger than olm.** E2EE needs `mautrix[encryption] + asyncpg + aiosqlite +
   aiohttp-socks`, and the entire `matrix` extra is gated `sys_platform == 'linux'` —
   which is **false** on Termux (`sys.platform == 'android'`), so the extra wouldn't even
   resolve. `asyncpg` has its own C extensions needing a separate cross-build recipe.
   Building python-olm alone does not restore the feature.
4. **Qualitative:** libolm is archived and deprecated by Matrix (superseded by
   `vodozemac`/Rust). Shipping an unmaintained crypto library inside a *security*
   feature deserves a deliberate decision, not a silent inclusion.
   - **Verified 2026-10-05:** the Matrix.org Foundation deprecated libolm officially
     in July 2024 ("all maintenance effort will go into vodozemac"; notice at
     gitlab.matrix.org/matrix-org/olm). The old `matrix-org/libolm` GitHub repo no
     longer exists (404; gone from search too).
   - Documented security issues in libolm were published Aug 2024
     (soatok.blog/2024/08/14/security-issues-in-matrixs-olm-library/) — no fix will
     land, the library is unmaintained.
   - Ecosystem consensus: `matrix-nio` 0.26 dropped the `python-olm`/`withOlm`
     dependency entirely; `cortexuvula/fresholm` exists as a drop-in
     `python-olm`-compatible wrapper over vodozemac (Rust) if a future port wants
     E2EE without the dead C++ code.
   - Note: this strengthens the skip recommendation — this is no longer just
     "archived"; it is a retired, known-vulnerable crypto implementation.

## 5. Recipe sketch (if pursued)

1. Fetch sdist; pin URL + sha256 from `uv.lock`.
2. Build `libolm.a` with the NDK (cmake < 4 with the NDK Android toolchain file,
   **or** direct: compile all of `src/*.cpp` (`-std=c++11`, `-DOLMLIB_VERSION_*`,
   `-Iinclude -Ilib`), `src/*.c`, `lib/crypto-algorithms/*`, `lib/ed25519/src/*`
   with `$NDK/bin/clang --target=aarch64-linux-android24`, then `llvm-ar rcs`).
3. Bypass `olm_build.py`'s cmake step (pre-place the archive at `libolm/build/libolm.a`
   or patch the script); run the cffi build with NDK `CC`/`CXX`, android24 target flags,
   and Termux Python headers.
4. Repair linkage / tag the wheel for `android_24_arm64_v8a` per the existing wheel pipeline.
5. Separately: cross-build `asyncpg` (+ pure `mautrix`, `aiosqlite`, `aiohttp-socks`) and
   ungate the `matrix` extra for `sys.platform == 'android'`.

## 6. Bottom line

- **python-olm: BUILDABLE-WITH-EFFORT.** The "fails to build" reputation comes from
  newer desktop toolchains (current clang/MSVC, CMake ≥ 4); the port's pinned NDK r27c
  toolchain compiles every source file cleanly (verified 2026-10-05).
- **Matrix E2EE feature: NOT restored by olm alone** — needs mautrix + asyncpg
  cross-builds and an extra-gate change.
- **Recommendation:** treat as low priority unless the user actually uses the Matrix
  gateway with E2EE. The graceful-degradation path (unencrypted Matrix) already works,
  and the crypto lib in question is archived upstream.
