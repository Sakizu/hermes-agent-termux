# Investigation: faster-whisper (+ ctranslate2) for Android aarch64 (Termux)

**Date:** 2026-10-05
**Verdict: BUILDABLE-WITH-EFFORT**

Local STT ("Local Whisper" provider, the recommended STT in `hermes setup`) can be
restored on the Termux port. Every native component in the chain either was directly
probe-built with the port's own NDK r27c today, or has an independent existence proof
of an Android build. The original exclusion reason ("av build path unavailable") does
not survive scrutiny — see §6.

## 1. Dependency chain (from uv.lock @ 1298c8e)

| Package | Version | Type | Needed? | Verdict |
|---|---|---|---|---|
| faster-whisper | 1.2.1 | pure Python (`py3-none-any`) | yes | trivially shippable |
| ctranslate2 | 4.8.1 | C++/CMake, **no sdist** (wheels only) | yes, top-level `import` | **BUILDABLE** (probed) |
| av (PyAV) | 18.1.0 | C/Cython, sdist available, needs FFmpeg | yes, top-level `import` (`audio.py:15`) | **FEASIBLE** (existence proof) |
| tokenizers | 0.23.1 | Rust/maturin, sdist only for cp314 | yes, top-level `import` (`transcribe.py:15`) | **FEASIBLE** (recipe exists) |
| onnxruntime | 1.29.0 | C++, huge | only for VAD (`vad.py:298`, **lazy** import) | **FEASIBLE-BUT-EXPENSIVE** — shippable without |
| huggingface-hub, tqdm, numpy | — | pure | yes | already in closure |

`faster-whisper` itself contains **zero** `sys.platform` gates (verified by grep over
1.2.1) — nothing in the pure-Python layer cares that `sys.platform == "android"`.

## 2. ctranslate2 4.8.1 — direct probe results (strongest evidence)

Probed today against the port's own toolchain
(`~/workspace/.hermes-build/toolchain/android-ndk-r27c`, `aarch64-linux-android24-clang`):

1. **CMake configure: SUCCESS** with
   `-DWITH_MKL=OFF -DOPENMP_RUNTIME=NONE -DWITH_RUY=ON -DENABLE_CPU_DISPATCH=OFF`
   `-DBUILD_CLI=OFF -DBUILD_SHARED_LIBS=ON`, `ANDROID_ABI=arm64-v8a`,
   `ANDROID_PLATFORM=android-24`. ("Configuring done / Generating done".)
   - Submodules needed: `third_party/ruy`, `third_party/cpuinfo` (nested inside ruy),
     `third_party/spdlog` — plain `git submodule update --init`.
   - Ruy is the ARM-optimized matmul backend (NEON); MKL/DNNL/CUDA are x86/GPU-only
     and correctly off.
2. **Blocker reproduced exactly:** `src/thread_pool.cc:89:24: error: use of undeclared
   identifier 'pthread_setaffinity_np'; did you mean 'sched_setaffinity'?`
   Bionic does not provide `pthread_setaffinity_np`. (Note: `__ANDROID__` implies
   `__linux__`, so the existing `#if !defined(__linux__)` guard does NOT save us —
   confirmed by reading the source, then by the compiler.)
3. **Blocker fixed and verified:** a 10-line `#elif defined(__ANDROID__)` branch using
   `sched_setaffinity(pthread_gettid_np(...), ...)` — the same approach as the
   hieunc278/ctranslate2 fork. After patching, `src/thread_pool.cc.o` **compiles clean**.
4. `src/models/whisper.cc.o` (the Whisper model TU — the one we actually need) also
   **compiles clean**.
5. The Python extension (`python/setup.py`) is a thin pybind11 wrapper linking
   `-lctranslate2`, honoring a `CTRANSLATE2_ROOT` env var — i.e. a standard two-stage
   recipe: CMake lib → setuptools ext. No Android-specific logic needed in setup.py
   (the `sys.platform == "linux"` branch fires on the Linux build host and just adds
   `-fPIC`, which is correct).

Independent corroboration:
- OpenNMT/CTranslate2 issue #1848 — working NDK recipe
  (`-DOPENMP_RUNTIME=COMP -DWITH_RUY=ON`, `android.toolchain.cmake`, `arm64-v8a`,
  `android-31`).
- Chaquopy PR #1253 — `ctranslate2-python` built for `android_21_arm64_v8a`
  (proves the **Python extension** builds for Android, not just the C++ lib).
- hieunc278/ctranslate2 fork — Bionic `pthread` fix, verified on a real arm64-v8a device.

**OpenMP decision:** `OPENMP_RUNTIME=NONE` avoids any `libomp` runtime dependency
(cleanest packaging). `COMP` (NDK's libomp) is the alternative if thread scaling
proves poor — it also neuters the `thread_pool.cc` issue via the `_OPENMP` guard,
but then `libomp.so` must ship in the wheel.

## 3. av 18.1.0 — feasible (independent existence proof)

Researched by worker; key points verified:
- **flet-dev/mobile-forge PR #122** ("recipe: av 18.1.0 + flet-libffmpeg 8.1.2"):
  12/12 wheels green (arm64-v8a × py3.12/3.13/3.14), on-device tests passed, and the
  recipe's single patch is an **iOS-only no-op on Android** — i.e. av 18.1.0 needed
  **zero source patches** for Android.
- `setup.py` (v18.1.0, L72–140) finds FFmpeg via **pkg-config only**
  (`libavformat/libavcodec/libavdevice/libavutil/libavfilter/libswscale/libswresample`);
  dynamic linking is mandatory (setup.py refuses static) — Termux's ffmpeg is
  `--enable-shared --disable-static`, satisfying this.
- **Termux ships what we need**: `ffmpeg` 8.1.x for aarch64/API-24, with headers and
  all 7 `.pc` files (Termux does not split `-dev` packages). PyAV 18.x tracks the
  FFmpeg 8.x ABI — version-compatible.
- Cython runs on the **host** at build time (`cython>=3.1.0,<4` in build requirements);
  no pre-generated C in the sdist, 49 modules cythonized during build.
- One known Android/Cython landmine to watch: Cython lowering `**` to `cpow()`/`clog()`
  (bionic gates those behind API 26); the av recipe did not hit it, but grep the
  cythonized output if a future Cython changes codegen.

## 4. tokenizers 0.23.1 — feasible (existing recipe track)

- sdist-only for cp314 (no cp314 wheels in uv.lock) — must build from source anyway.
- Rust + maturin: the port's `scripts/11-wheels-rust.sh` already cross-builds
  `jiter` and `pydantic-core` the same way. Mechanical.

## 5. onnxruntime 1.29.0 — feasible but expensive; SHIPPABLE WITHOUT

Researched by worker; claims spot-checked:
- No official Python-on-Android path (upstream documents only the Java AAR), but
  **two existence proofs**: (a) **termux/termux-packages `packages/onnxruntime/`**
  (verified present today; currently 1.30.0) — a maintained recipe with 6 patches
  producing an `android_aarch64`-tagged wheel installed into `$PREFIX`;
  (b) flet-dev/mobile-forge host-cross recipe (CI green 2026-10-04).
- **Build cost is the problem**: 1–2+ h wall-clock, ~16 GB RAM, ~30 GB disk —
  by far the heaviest wheel in the set, brushing the "no multi-hour builds" limit.
- **The escape hatch is clean**: `import onnxruntime` in faster-whisper is lazy
  (`vad.py:298`, inside `SileroVADModel.__init__`, try/except with a clear
  `RuntimeError`). It is touched **only** when VAD filtering runs. hermes defaults
  `stt.local.vad` to true, but honours `stt.local.vad: false`
  (`tools/transcription_local.py:209`, `config_defaults.py:1180`).
- Of hermes's 3-layer anti-hallucination hardening, only layer 1 (Silero VAD) needs
  ORT; layers 2 (`condition_on_previous_text=False`) and 3 (confidence gate on
  `no_speech_prob`/`avg_logprob` from the decode itself) work without it.
- **Recommendation:** phase 1 ships without onnxruntime, with the Termux port
  defaulting `stt.local.vad: false` (documented in release notes). Phase 2 attempts
  the ORT wheel from Termux's recipe as a follow-up. Zero-build alternative worth
  naming: `Depends: onnxruntime` (Termux package) + a one-line launcher tweak so
  hermes's closed site dir can see the system site-packages — couples the .deb to a
  system package, so prefer the bundled wheel long-term.

## 6. Why "av build path unavailable" was wrong

The original exclusion was never demonstrated with a build attempt. What we now know:
`av` does not bundle FFmpeg for this target — but it doesn't need to: Termux **is**
the FFmpeg provider (shared libs + headers + `.pc` files in the `ffmpeg` package),
and an independent team already shipped av 18.1.0 for Android with no source patches.
The "unavailable" was really "uninvestigated".

## 7. Recipe sketch (big steps, new `scripts/12-wheels-stt.sh`)

1. **ctranslate2** (new CMake track):
   - `git clone --depth 1 --branch v4.8.1` + submodules (`ruy`, `ruy/third_party/cpuinfo`,
     `cpu_features`, `spdlog`).
   - Apply `patches/27-ctranslate2-thread-pool-android.patch` (the validated Bionic fix).
   - CMake configure with the flags in §2 (note: the port's pruned NDK lacks
     `build/cmake/android.toolchain.cmake` — extract it from the NDK zip, or pass
     `-DCMAKE_SYSTEM_NAME=Android` + compiler paths directly as probed).
   - `cmake --build` (parallel; ~10–15 min expected, not hours).
   - Python ext: `CTRANSLATE2_ROOT=<stage> python setup.py build_ext` under `xenv.sh`
     (needs `pybind11` in the build env), then `assemble_wheel.py` with the
     `android_24_arm64_v8a` tag + `repair_wheel` linkage pass. Ship `libctranslate2.so`
     inside the wheel (or as a private lib dir with rpath).
2. **av**: stage Termux `ffmpeg` .deb (headers, `.so`, 7 `.pc` files) on the host;
   cross-build via the setuptools-C track with `PKG_CONFIG_LIBDIR` pointed at the
   staging dir and `cython>=3.1.0,<4` in the build venv; linkage repair; add
   `ffmpeg` to the .deb `Depends:` (system libs, not bundled).
3. **tokenizers**: add to the existing maturin/Rust track (`11-wheels-rust.sh`).
4. **faster-whisper**: pure wheel, pin URL+SHA256 from uv.lock like the other pure deps.
5. **closure.py**: add `ctranslate2`, `av`, `tokenizers` (+`onnxruntime` later) to
   `NATIVE_KNOWN`; seed the dependency walk with the `voice` extra so the STT closure
   resolves (currently the walk starts at `hermes-agent` root deps only, which is why
   the voice extra silently drops out).
6. **Config default**: Termux port ships `stt.local.vad: false` until the ORT wheel
   lands (phase 2).
7. **QA**: `python -c "import faster_whisper"` on the built wheelhouse (import pulls
   ctranslate2+av+tokenizers — the hard deps), plus a tiny-model transcription smoke
   test if a runner with the .deb is available. Whisper `base` model (~145 MB,
   ctranslate2 format) downloads from HuggingFace at first use — pure-Python
   `huggingface-hub`, no build impact.

## 8. Costs and caveats (non-blocking, but honest)

- **Size**: ~+25–30 MB to the .deb (ctranslate2 shared lib ~15–20 MB, av ~5 MB,
  tokenizers ~5 MB) — roughly doubles the current 30 MB artifact. Runtime model
  download (~145 MB for `base`) is separate, on first use.
- **onnxruntime deferred**: VAD filtering off by default until phase 2 (see §5).
- **New track debt**: one CMake recipe + one Bionic patch to maintain across
  ctranslate2 version bumps. The patch is 10 lines and upstreamable
  (guarded by `defined(__ANDROID__)`, zero effect on other platforms).
- **Upstream already half-expects this**: `pyproject.toml` notes faster-whisper's
  closure is "prebuilt-only" only because of *win_arm64* and *macOS x86_64* gaps —
  Android was simply never tried.

## 9. Backup plan: whisper.cpp (VIABLE-BACKUP, not needed now)

Researched by worker in case CTranslate2 had failed — it didn't, so this stays a backup:
- whisper.cpp Android builds are **proven** (upstream `examples/whisper.android`,
  production apps with pinned NDK 27, android-24 recipes).
- The clean integration is **not** the Python binding (pywhispercpp has no Android
  wheels, build unproven) but the **`whisper-cli` binary** driven through hermes's
  existing `local_command` STT provider — zero new Python native deps, no PyAV
  (audio prep already uses the `ffmpeg` binary), and whisper.cpp's built-in Silero
  VAD would even cover the onnxruntime gap.
- Cost if ever needed: NDK build of `whisper-cli` (minutes), a whisper.cpp-shaped
  command template, ggml model downloader. sherpa-onnx evaluated and rejected
  (weaker than whisper.cpp on every axis for this use case).

## 10. Evidence log

- Direct probe (this investigation): CTranslate2 v4.8.1 cmake configure **OK**
  (NDK r27c, android-24, arm64-v8a); `thread_pool.cc:89` Bionic error **reproduced**;
  Bionic patch **applied and compile-verified**; `whisper.cc` TU **compiles**.
- https://github.com/OpenNMT/CTranslate2/issues/1848 — Android NDK recipe
  (`WITH_MKL=OFF`, `OPENMP_RUNTIME=COMP`, `WITH_RUY=ON`, `ENABLE_CPU_DISPATCH=OFF`)
- https://github.com/chaquo/chaquopy/pull/1253 — `ctranslate2-python` for
  `android_21_arm64_v8a`
- https://github.com/hieunc278/ctranslate2 — Bionic `pthread` portability fix,
  verified on real arm64-v8a hardware
- https://github.com/flet-dev/mobile-forge/pull/122 — av 18.1.0 Android wheels,
  12/12 green, zero source patches for the Android lane
- https://github.com/termux/termux-packages/tree/master/packages/onnxruntime —
  maintained Android onnxruntime recipe (1.30.0), 6 patches, produces an
  `android_aarch64` Python wheel
- https://github.com/termux/termux-packages/blob/master/packages/ffmpeg/build.sh —
  Termux ffmpeg 8.1.x, `--enable-shared`, ships headers + `.pc` files
- PyPI: `pywhispercpp` 1.4.0 — 46 files, **0 android-tagged** (verified 2026-10-05)
- faster-whisper 1.2.1 wheel inspected: `import av` top-level (`audio.py:15`),
  `import tokenizers` top-level (`transcribe.py:15`), `import onnxruntime` lazy
  (`vad.py:298`); no `sys.platform` gates anywhere in the package
- hermes usage: `tools/transcription_local.py:209-215` (`vad_filter` default true,
  honors `stt.local.vad: false`); `hermes_cli/config_defaults.py:1180`
