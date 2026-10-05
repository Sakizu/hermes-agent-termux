# Keeping the .deb slim WITH the .pyc startup win

**Date:** 2026-10-06 · **Status:** research only, no build changes made
**Baseline:** build step 7a in `scripts/30-assemble.sh` precompiles all ~5.2k `.py` → `.pyc`
(CPython 3.14, magic `2b0e0d0a` verified == Termux python 3.14.6).
**Measured cost:** .deb 30.7 MB → 54.6 MB (+24 MB); installed ~150 MB → ~243 MB (+~93 MB).
Five parallel research workers investigated; this report synthesizes their findings.

---

## 1. Headline findings (read these first)

### 1a. The shipped `.pyc` files are currently NEVER read — the +24 MB buys zero cold-start benefit today

Two workers independently verified this. `bin/hermes*` launchers export
`PYTHONPYCACHEPREFIX=$HOME/.cache/hermes-pycache` (from `launchers/launcher.sh.in`,
no documented rationale). With that variable set, CPython resolves bytecode **only**
under the prefix mirror and ignores source-adjacent `__pycache__/*.pyc` entirely
(verified in CPython 3.14 `importlib/_bootstrap_external.py::cache_from_source`
and empirically: `python -v` showed `# code object from .../mod.py` — compiled from
source — and wrote a fresh `.pyc` into the prefix mirror, ignoring the shipped one).

**Consequence:** every module is recompiled from source into `~/.cache/hermes-pycache`
on first import regardless of what step 7a ships. The phone A/B test the user asked
for would currently measure ~zero difference. **Nothing in sections 3–5 matters
until this gate is resolved** (see §2).

### 1b. The .deb already uses zstd -19 — compression is near-optimal, don't chase it

`dpkg-deb --build` with no flags on this host (Ubuntu, dpkg 1.22.6) produces
byte-identical output to explicit `-Zzstd -z19` (Ubuntu vendor patch sets zstd-19
as the dpkg default; upstream Debian defaults to zstd -3). The 54.6 MB is already
near the practical floor: `-z22` saves only ~3.1 MB for +4 min build and 779 MB RAM;
`xz -9e` saves ~6 MB but decompresses ~5–10× slower on the phone. **Pin `-Zzstd -z19`
explicitly for determinism** (zero cost), then stop.

### 1c. ~24.5 MB of provably-dead weight exists — removable with clean one-line changes

The dead-weight audit measured the staged tree and grep-verified runtime usage for
each candidate. Safe removals needing **no code patches** (all via `INERT`-style
exclusions in `scripts/30-assemble.sh`):

| Candidate | Size (uncompressed) | Evidence of deadness |
|---|---|---|
| `app/contributors/` (emails/) | 6.9 MB | Release-tooling data; zero runtime reads (only deny-list mentions) |
| `app/optional-skills/` | 13.0 MB | Not activated by default; all consumers guard on dir existence; `hermes skills install` falls back to GitHub. Keep `migration/` (340 KB) → save 12.7 MB |
| `app/native/fts5_cjk/` (build sources) | 0.7 MB | Runtime loads the compiled `lib/libfts5_cjk.so`; sources never read |
| `app/assets/` (packaging artwork) | 0.8 MB | Zero code references |
| `app/` root dev files (uv.lock, package-lock.json, Dockerfiles, READMEs…) | 2.2 MB | All greps resolve to user-project contexts, never the app's own files |
| `site/` test files + `*.pyi` stubs + `*.dist-info/licenses/` | ~0.9 MB | Never imported / never read at runtime (dist-info roots kept) |

**Total: ~24.5 MB uncompressed, ≈ 6–8 MB in the .deb** (using the measured
~0.22–0.28 payload→.deb ratio; honest estimate, not measured — the real number
comes from rebuilding after removal). Installed footprint drops by the full
~24.5 MB.

> **Correction to an overclaim:** one worker wrote that this "fully offsets" the
> 30.7 MB pyc growth. That compared mismatched bases (24.5 MB *uncompressed* vs
> 30.7 MB *compressed*). It does not. It offsets roughly a quarter of the .deb
> growth and a quarter of the installed growth — still the best value/effort/risk
> ratio of any option.

Plus optionally: `app/locales/` non-English trim (+~5.8 MB uncompressed) — needs a
one-line `SUPPORTED_LANGUAGES` tuple patch in `agent/i18n.py` paired with the file
trim (files degrade to English gracefully per-key, but the tuple would otherwise
still advertise removed languages).

The audit also verified **do-not-touch traps**: `pytz` 2.7 MB (croniter top-level
import), `snowballstemmer` 2.0 MB (tool search), `anydoc` 7.2 MB (document reading),
`plugin-catalog` 1.7 MB, `tui_dist/entry.js` (single copy, alive), `dist-info` roots.

### 1d. Two real bugs found along the way (fix regardless of path)

1. **`Installed-Size` is computed before step 7a** (`scripts/30-assemble.sh` line ~201):
   the shipped .deb declares 151,312 KiB vs true 248,972 KiB — a 95 MB under-report.
   Move the computation below step 7b.
2. `patches/apply.sh`'s `py_compile` syntax check runs on host Python 3.12 and litters
   `cpython-312.pyc` into the staged tree (this is what the new QA magic-check caught
   on the first 7a build). Step 7a now cleans stale `__pycache__` before compiling —
   keep that ordering.

---

## 2. Decision 0 — the gate: two mutually exclusive paths

| | Path K: keep shipped `.pyc` | Path R: remove shipped `.pyc` |
|---|---|---|
| Change | Drop `PYTHONPYCACHEPREFIX` from `launchers/launcher.sh.in` (1 line). Shipped `.pyc` then actually get read. | Delete step 7a; add Termux-native debscripts: postinst `py3compile`, prerm `py3clean` (~4 lines, mirrors `termux_step_create_python_debscripts.sh`). |
| .deb | ~54.6 MB → ~47 MB after dead-weight removal | ~30.7 MB → ~24 MB after dead-weight removal |
| Cold start | Build-time compile; fastest possible first run | First run compiles on-device into the standard cache (one-time cost), then identical |
| Precedent | None among distros (Debian policy §4.7 *forbids* shipping `.pyc*; Termux ported the postinst pattern tree-wide in PR #23652) | **The textbook answer**: Debian, Termux, pex (`--compile` at deploy), Briefcase (ship source) all compile on target |
| Fragility | Build-host 3.14 must forever track Termux's python minor, or the .deb silently ships ignored bytecode (the QA magic-check is the guardrail) | None — the target's own interpreter always produces correct bytecode |

**Recommendation:** measure first (§6). If the phone A/B shows a large cold-start win
(e.g. 8 s → 3 s), Path K is justified and the dead-weight removal pays for most of
it. If the win is marginal, take Path R — the textbook answer — and pocket the
simplification. Do not decide on aesthetics; the numbers decide.

---

## 3. Ranked options (within Path K — keeping shipped bytecode)

| Rank | Option | .deb saving (measured basis) | Behavior risk | Code-quality verdict |
|---|---|---|---|---|
| 1 | **Dead-weight removal** (§1c) | ~6–8 MB (est. from 24.5 MB uncompressed) | None — every candidate usage-verified | Exemplary: one-line INERT additions, zero behavior change |
| 2 | **Sourceless `.pyc`** (ship `pkg/mod.pyc`, delete `.py`) | **−12.3 MB** (zstd-19 measured) | Medium — needs a source keep-list (see below); tracebacks lose source lines | Hack-ish: works, but every future direct-script-exec becomes a landmine without a CI guardrail; not upstreamable |
| 3 | **`-OO` (strip asserts + docstrings)** | **−3.3 MB** (zstd-19 measured) | Low-medium — zero crashes found, but docstring-derived text silently degrades (see below) | One flag; distro-avoided; needs validation before shipping |
| 4 | **Selective precompilation** (static import graph, re-derived per build) | **−3.2 to −4.9 MB** (xz-measured, ~transferable) | Benign — missed modules just compile on first use (ms-scale, one-time) | Principled and anti-rot, but ~150 lines of new build tooling for 6–9% — questionable ROI |
| 0 | **Pin `-Zzstd -z19` + fix `Installed-Size`** | 0 MB (determinism + correctness) | None | Just do it |
| — | `-O` (strip asserts only) | ~40 KB | Removes 1,678 runtime checks | Rejected: pointless |
| — | zipimport | **+11.6 MB worse** (deflate) / neutral (stored) | Severe — silently breaks bundled plugin discovery (`Path(__file__)` under zip) | Rejected: hack, zero upstreamability |

### 3a. Sourceless `.pyc` — detail

*Mechanism (verified empirically):* default timestamp-based `.pyc` work sourceless
with no special flags (`SourcelessFileLoader` skips validation — staleness becomes
undetectable, `.pyc` always trusted). Layout must be legacy (`pkg/mod.pyc`;
`__pycache__`-only without source → `ModuleNotFoundError`). **Bonus: sourceless
bypasses the `PYTHONPYCACHEPREFIX` problem** (verified) — the only diet option that
also fixes the §1a gate.

*Breakage (all with file:line evidence):*
- `app/hermes_cli/_old_updater.py:134` — self-update execs
  `hermes_cli/_update_takeover.py` as a script → **self-update breaks**
- `app/tools/tts_tool_local.py:64` — NeuTTS spawns `tools/neutts_synth.py` as a
  script → **NeuTTS TTS breaks**
- `app/hermes_cli/_startup_fast.py:158–172` — reads `openai/_version.py` as text →
  `hermes --version` prints "OpenAI SDK: Not installed" (cosmetic, startup path)
- Tracebacks still show file/line but omit source lines; `pdb list` empty;
  `inspect.getsource` raises (on-device debugging degraded)
- Graceful: `site/fastapi/routing.py:249–251`, `site/fire/inspectutils.py:224`,
  `site/rich/traceback.py:835`, pydantic `_docs_extraction.py:99` (all try/except)

*Keep-list minimum:* `_update_takeover.py`, `neutts_synth.py`, `openai/_version.py`,
plus a CI grep for new `sys.executable … *.py` / `open(*.py)` patterns.
*Verdict:* biggest single saving and fixes the gate — but only acceptable with the
keep-list + CI guardrail. Otherwise the next person who adds a script-exec gets a
silent breakage.

### 3b. `-OO` — detail

*Measured:* full tree raw 76.06 MB → 66.21 MB (−13.0%); zstd-19 → **−3.3 MB** off
the .deb. `-O` alone saves ~40 KB — not worth discussing further.

*Risk — no crashes found, but docstring-derived text silently degrades* (relevant:
this is an agent; some text is LLM-visible):
- `site/pydantic/json_schema.py:891`, `:1659–1662`, `site/pydantic/fields.py:1858`,
  `_generate_schema.py:414,844,851` — enum/model docstrings → JSON-schema
  descriptions. Real docstring'd enums exist in app
  (`agent/backend_identity.py:23`, `agent/error_classifier.py:34`) — whether they
  reach an LLM was **not** traced end-to-end (conditional risk)
- `site/fastapi/routing.py:667` — endpoint docstring → OpenAPI description
  (gateway/dashboard docs go blank)
- `site/fire/inspectutils.py:303` — `inspect.getdoc()` feeds fire CLI usage text
  (`app/cli.py:1797`, `batch_runner.py`, `mini_swe_runner.py`,
  `trajectory_compressor.py`) → help text gutted
- `app/hermes_cli/source_check.py:438`, `source_completion.py:132`,
  `update_restart_recovery.py:441`, `pm/build_env.py:13` + ~30 skills scripts —
  `argparse(description=__doc__)` → blank descriptions
- Safe: hermes's own MCP tool registration uses explicit `description=` strings;
  `agent/lazy_forward.py:24` assigns `__doc__` at runtime (unaffected);
  doctests only run under `__main__` (never on import)

*Verdict:* best effort-to-risk ratio of the pure-flag options — one build-flag
change. But it **requires** a JSON-schema diff + `--help` smoke test before
shipping, and no distro does this by default (documented breakage register:
xgboost #12094, jsonpath-ng/PLY, toolr refuses `-OO`).

### 3c. Selective precompilation — detail

*Recommended mechanism (only if pursued):* AST-based static import graph from
entry points + string-literal harvest (`importlib.import_module("lit")`) + bounded
dynamic roots, **re-derived every build from the staged tree** — no checked-in
module list to rot. Entries derived from the `bin/*` launchers the same build
mints (`from <mod> import main`); dynamic roots = `app/plugins`, `app/skills`,
`app/tools` (whole dirs, still re-derived). ~150 lines stdlib-only Python in
`scripts/lib/` (`select_pyc.py` + `launcher_entries.py`); step 7a compiles the
emitted file list instead of the whole tree; QA asserts every traced file has a
`.pyc` and every launcher entry resolved (tracer regressions fail loudly).

*Measured:* static-reachable set = 3831/5193 files (73.8%) → xz −4.89 MB (−21.6%);
with dynamic roots 4090/5193 (78.8%) → xz −3.20 MB (−14.1%). Excluded: lazy SDK
tails (`openai`, `prompt_toolkit`, `fastapi`…), win/mac-only modules, gateway bits.

*Why the saving is small:* the import wall is huge — `hermes_cli/main.py` has a
96-import module-level wall, so even `hermes --version` pulls most of the graph.
*Verdict:* principled, fail-safe (a miss just means one-time on-demand compile),
maintainable — but 150 lines of tooling for 6–9% is weak ROI next to the 24.5 MB
dead-weight removal. Do it only after the bigger wins.

### 3d. Rejected with prejudice

- **zipimport:** deflated zip inside a zstd .deb = double compression (+11.6 MB
  *worse*); stored zip = neutral. And it **silently breaks bundled plugin
  discovery** (`hermes_cli/plugins.py:75` — `Path(__file__).parent/"plugins"` under
  zipimport resolves inside the zip, `is_dir()` False → zero bundled plugins,
  including model-providers). 12 native `.so` can't live in a zip anyway.
- **`-O`:** ~40 KB saving for removing 1,678 asserts. Pointless.

---

## 4. Recommended sequencing

1. **Now (path-independent, pure wins):** dead-weight INERT additions (§1c rows 1–8);
   pin `-Zzstd -z19` in the `dpkg-deb --build` invocation; move `Installed-Size`
   computation below step 7b. Optionally the locales trim (one-line tuple patch +
   file list).
2. **Then (measurement):** drop `PYTHONPYCACHEPREFIX` from the launcher template,
   rebuild, run the phone A/B protocol in §6. This single datapoint decides Path K
   vs Path R.
3. **If Path K (large win):** keep step 7a; consider `-OO` only after the
   schema/`--help` validation; consider selective precompile only if the last
   few MB matter.
4. **If Path R (marginal win):** delete step 7a; add postinst `py3compile` /
   prerm `py3clean` mirroring Termux's `termux_step_create_python_debscripts.sh`.
5. **Sourceless:** only if maximum diet is required *and* the keep-list + CI
   guardrail are accepted. Not the default recommendation.

Expected outcome of steps 1+2+Path K: .deb ≈ 54.6 − ~7 (dead weight) − ~3.3 (−OO,
optional) ≈ **~44 MB with the full startup win** (vs 30.7 MB baseline without it).
Path R + step 1: ≈ **~24 MB**, textbook-clean, one-time on-device compile cost.

---

## 5. What the workers could not verify (honest gaps)

- **The actual cold-start delta on-device.** Only the phone can prove it —
  and any measurement taken *before* the §1a prefix fix measures ~zero by construction.
- **Whether docstring'd pydantic enums/models reach the LLM** via JSON schema
  (−OO risk is conditional on this; needs a schema-diff test).
- **Exact .deb delta of dead-weight removal** — the ~6–8 MB figure is estimated
  from the payload→.deb ratio, not measured. Rebuild to get the real number.
- **Selective-precompile ground truth** — the static set (3831 files) vs the true
  phone import set; needs the `-X importtime` capture in §6.
- **3.14 bytecode-diet ratios** — diet measurements used host 3.12 with ratio
  transfer to the real 3.14 payload (3.14 `.pyc` are ~17% larger than 3.12's for
  the same files); absolute 3.14 numbers need a build-host re-run.

---

## 6. Phone measurement protocol (before/after cold-start timing)

**Prerequisite:** the A/B is only valid with the §1a prefix fix in the test build.
Recommended builds: A = `0.0.0+1298c8e` (no `.pyc`, current release), B =
`0.0.0+1298c8e-2` rebuilt **with `PYTHONPYCACHEPREFIX` dropped from the launcher**
(same upstream commit — the only variable is bytecode availability).

```sh
# --- Step 0: confirm the prefix bug on the CURRENT build (expect: pyc ignored)
P=/data/data/com.termux/files/usr/lib/hermes-agent
PYTHONPATH=$P/app:$P/site python -v -c "import hermes_cli.main" 2>&1 \
  | grep -m2 "code object from"
# Bug present if lines say:  # code object from '.../hermes_cli/main.py'
# Bug fixed if lines say:    # code object from '.../__pycache__/main.cpython-314.pyc'

# --- Step 1: cold-start timing, 3 runs each, cache cleared between runs
for i in 1 2 3; do rm -rf ~/.cache/hermes-pycache; time hermes --version; done
# --- Step 2: warm timing (cache hot — second-run experience)
for i in 1 2 3; do time hermes --version; done
# --- Step 3: heavier import path
rm -rf ~/.cache/hermes-pycache; time hermes doctor
```

Report the median `real` time per step for build A vs build B. Decision rule (suggested):
**B cold ≥ 30% faster than A cold → Path K** (keep shipped `.pyc`, slim via §3);
otherwise **Path R** (delete step 7a, postinst `py3compile`).

```sh
# --- Step 4 (optional): ground-truth import set for selective-precompile validation
rm -rf ~/.cache/hermes-pycache
P=/data/data/com.termux/files/usr/lib/hermes-agent
PYTHONPATH=$P/app:$P/site python -X importtime -c \
  "import sys; sys.argv=['hermes','--version']; from hermes_cli.main import main; main()" \
  2> importtime-version.log
# repeat with sys.argv=['hermes','doctor']; for chat use: timeout 20 ... ['hermes','chat']
# (kill at first prompt; importtime streams as imports happen)
# Union of the three logs = ground truth; diff against the static 3831-file set.
```

```sh
# --- Step 5: verify shipped .pyc are actually consumed (post-fix build)
find $P -name '*.pyc' | wc -l          # before first run
rm -rf ~/.cache/hermes-pycache; hermes --version
find $P -name '*.pyc' | wc -l          # after — same count, and no mtime changes,
ls ~/.cache/hermes-pycache 2>/dev/null # ideally absent/empty = nothing recompiled
```

**Do not** run the A/B on the current `-2` build and conclude anything: with the
prefix still set, B will measure ~identical to A, which proves the §1a bug but
says nothing about the value of precompilation itself.

---

## Appendix: worker coverage

| Worker | Thread | Verdict headline |
|---|---|---|
| 1/5 | Bytecode diet | `-OO` −3.3 MB ok-with-validation; sourceless −12.3 MB +fixes gate but needs guardrails; `-O` pointless; zipimport rejected |
| 2/5 | Selective precompilation | **Prefix bug found** (shipped `.pyc` never read); selective saves only 3–5 MB; AST-graph mechanism specified |
| 3/5 | Prior art | Debian policy forbids shipping `.pyc`; Termux has tree-wide postinst `py3compile`; textbook = compile on target |
| 4/5 | Packaging/compression | Already at zstd −19 (Ubuntu dpkg default) — pin it; fix `Installed-Size` (95 MB under-report) |
| 5/5 | Dead-weight audit | 24.5 MB removable, zero code patches, all usage-verified (+5.8 MB locales with one-line patch) |

*All workers were instructed evidence-first; every number above is either measured
(with method stated) or explicitly flagged as estimated. Nothing in the repo was
modified except this report.*
