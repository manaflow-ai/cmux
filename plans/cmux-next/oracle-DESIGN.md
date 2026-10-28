# Correctness oracle: one behavior corpus, base against head, on Linux and the fleet

Status: design, 2026-10-26 (Chrome-parity push, program p15-oracle). Owner: PL-oracle ([OWNERS.md](OWNERS.md)).
Branch: `perf/chrome-parity`, then `feat-cmux-next`.

The task list with files, acceptance and dependencies is the program spec
[chrome-parity/p15-oracle.md](chrome-parity/p15-oracle.md) (section 8 and the task details after it) and
`chrome-parity/design-result.json` (`programs["p15-oracle"]`). A number in parentheses below, such as (105), is the
task `p15-oracle-105` there. The spec records how its three reviews changed the design; this file is the design
a contributor reads before they add a case, a facet, a suite or a refactor switch.

Every count below has the command that gives it, run from the repository root. Counts marked "at 9dccb70" were
taken on `perf/chrome-parity` at `9dccb702bac`; run the command again for today's value.

## What the oracle is for

The Chrome-parity push changes how cmux schedules, renders, hosts processes and stores state, in parallel, in
72 hours. A refactor of that kind is correct when cmux does the same thing before and after it. The oracle makes
"the same thing" a value: a behavior corpus of JSON cases drives cmux through its real entrypoints (daemon
resource API, control socket, CLI, MCP, TUI, key presses), records a canonical model-state snapshot at each
checkpoint, and compares the snapshots of two builds.

- The default check is **base SHA against head SHA** (`oracle.py diff --base A --head B`). No refactor needs any
  setup for it.
- A **refactor switch** (old arm against new arm in one build) is used only where a refactor wants a runtime
  fallback (holder, CEF helper, layer hosting).
- Every pure-Swift package also builds on Linux, so its tests and the oracle replay tools run on the 360-core VM,
  next to the daemon cases.

Nothing in this program adds a GitHub CI job, step, gate, budget or test row (Lawrence 2026-10-23). Every run is
started by an agent on the VM or on the fleet, and an agent reports its own result.

## 1. Chrome reference

Paths are in chromium/src. Each row names what cmux takes from it.

| Chrome | File | cmux |
| --- | --- | --- |
| One conformance suite, many products: WPT runs against `chrome`, `headless_shell`, Android and WebView with per-product metadata | `third_party/blink/tools/run_wpt_tests.py`, `docs/testing/run_web_platform_tests.md` | A case lists the capabilities it `requires`; the product (`daemon`, `app`, `cli`, `headless`, `tui`, `mcp`) is a run parameter (section 3) |
| Baselines and expectations: `-expected.txt`, `TestExpectations` with `[ bug ] [ modifiers ] test [ results ]`, results `Pass Failure Crash Timeout Skip Slow`, several results mean flaky; "rebaseline instead of adding lines" | `docs/testing/web_tests.md`, `docs/testing/web_test_expectations.md`, `third_party/blink/tools/blinkpy/web_tests/lint_test_expectations.py` | `tests/oracle/Expectations.d/<suite>.txt` in the same line format, one file per suite (section 5) |
| Two-pass baseline fallback: `platform/<p>/virtual/<v>` -> `virtual/<v>` -> `platform/<p>/<base>` -> `<base>` | `docs/testing/web_test_baseline_fallback.md` | `baselines.py` lookup and `optimize` use the same order with arms in place of virtual suites |
| The same tests under a flag: `VirtualTestSuites`, `--flag-specific`, `FlagExpectations/NAME` | `third_party/blink/web_tests/VirtualTestSuites`, `docs/testing/web_tests.md` | A switch arm is a virtual suite; the switch's `expected_differences` is its FlagExpectations (section 6) |
| FeatureList frozen before the first read, passed to children on the command line; planned launch config of all studies at once; flags expire | `base/feature_list.h`, `testing/variations/fieldtrial_testing_config.json`, `chrome/browser/flag-metadata.json`, `tools/flags/generate_expired_list.py` | `RefactorSwitches` parsed once at launch and injected; `--arm launch-config`; 14-day expiry and `switches --expired` |
| Kombucha UI journeys: Action, WaitFor, Check on element ids; `WaitForState` instead of sleeps; `RunUntilIdle` "can lead to flaky tests" | `chrome/test/interaction/README.md`, `ui/base/interaction/interactive_test.h`, `docs/threading_and_tasks_testing.md` | A step's `waitFor` and the `settle` barrier; no sleeps anywhere (section 3) |
| One process per browser test, shards, serial retries, shuffle; the CQ blames a CL only after "with patch", "retry shards with patch" and "without patch" | `base/test/launcher/test_launcher.cc` (shards, retries, shuffle); the CQ retry and "without patch" steps are in the `chromium_tests` recipe module (`tools/build` repository, `recipes/recipe_modules/chromium_tests/`) | Shards, `--retry-limit`, `--shuffle --seed`, and `confirm` before a divergence reaches an owner (section 7) |
| A renderer crash fails a browser test unless allowed; leak expectations | `content/public/test/no_renderer_crashes_assertion.h` (`NoRendererCrashesAssertion`, `ScopedAllowRendererCrashes`; `browser_test_base.h` holds the member), `content/public/test/browser_test_utils.h` | The `crashes` facet, `allow_crashes` on a case, invariants I17 and I18 |
| Time controlled at the source, "without any test-specific seams in the product code" | `base/test/task_environment.h` (`TimeSource::MOCK_TIME`), `base/time/time_override.h` | Daemon virtual clock and seeded ids under the `oracle` cargo feature (185) |
| Coverage-guided fuzzing; shared validation data read by every binding | `testing/libfuzzer/README.md`, `mojo/docs/mojolpm.md`, `mojo/public/interfaces/bindings/tests/data/validation` | Resource-op sequence fuzzer (186); pane-protocol vectors run by Rust, TS and Swift (213) |
| Sanitizer bots run the same suites; incremental coverage per CL | `build/config/sanitizers/sanitizers.gni`, `docs/testing/code_coverage_in_gerrit.md` | `[ asan ]` and `[ tsan ]` modifiers (187); `oracle.py coverage` (190) |
| browser_tests on `linux-rel` with `dcheck_always_on` | `infra/config/subprojects/chromium/try/tryserver.chromium.linux.star` (the `linux-rel` try builder) | App cases run in bench config: Release optimization plus `debug.*` methods |
| Accessibility tree baselines per platform | `content/browser/accessibility/dump_accessibility_tree_browsertest.cc` | The `ax` facet and suite (216) |
| One command path for accelerators, menus and buttons | `chrome/browser/ui/browser_commands.h` (`chrome::ExecuteCommand`, `CommandUpdater`) | The `entrypoints` suite: one case per entrypoint of an action, all compared to each other (210) |
| History DB migrations tested from stored old versions | `components/test/data/history/history.N.sql`, `sql/test/test_helpers.h` | The `upgrades` suite: state roots written by older cmux-tui tags (208) |
| OS code in `*_mac.mm`, `*_posix.cc`, `*_linux.cc` behind one interface; small test hosts | `base/`, `content/shell/`, `headless/` | `CmuxNextCompat/Platform` seams and the Linux tier (section 8); `CmuxNextHeadless` (160-163) |
| Hermetic tests: an embedded server and a fresh profile per test | `net/test/embedded_test_server/` | `hermetic_env.py`, `CMUX_TUI_OFFLINE=1`, loopback-only fixtures (200, 222) |

## 2. What there is to cover

| Item | Count at 9dccb70 | Command |
| --- | --- | --- |
| Resource operations | 310 | `jq '.operations\|length' cmux-tui/spec/resource-operations-v2.json` |
| by class: mutation, read, connection_control, stream_open | 201, 90, 13, 6 | `jq -r '[.operations[].class]\|group_by(.)\|map("\(.[0]) \(length)")[]' cmux-tui/spec/resource-operations-v2.json` |
| ops with `idempotency: required` (keyed retry cases) | 201 | `jq '[.operations[]\|select(.idempotency=="required")]\|length' cmux-tui/spec/resource-operations-v2.json` |
| TUI actions | 50 | `jq '.tui_actions\|length' cmux-tui/spec/inventory.json` |
| App actions | 1,201 | `jq '.actions\|length' plans/cmux-next/action-surfaces.json` |
| actions the CLI offers | 688 | `jq '[.actions[]\|select(.cli=="offered")]\|length' plans/cmux-next/action-surfaces.json` |
| actions MCP offers | 606 | `jq '[.actions[]\|select(.mcp=="offered")]\|length' plans/cmux-next/action-surfaces.json` |
| actions with a default shortcut | 196 | `jq '[.actions[]\|select(.default_shortcut!=null)]\|length' plans/cmux-next/action-surfaces.json` |
| actions with 2 or more entrypoints (CLI, MCP, palette, menu, context menu, shortcut) | 986 | `jq '[.actions[]\|[(.cli=="offered"),(.mcp=="offered"),(.palette=="offered"),(.main_menu!=null),(.context_menu=="offered"),(.default_shortcut!=null)]\|map(select(.))\|length\|select(.>=2)]\|length' plans/cmux-next/action-surfaces.json` |
| sweep exclusions, gaps | 216, 84 | `jq '(.excluded\|length), (.gaps\|length)' scripts/cmux-next/every-action-gaps.json` |
| runnable actions (not excluded, not a gap) | 901 | `jq --slurpfile g scripts/cmux-next/every-action-gaps.json '[.actions[].id as $i\|select((($g[0].excluded\|has($i)) or ($g[0].gaps\|has($i)))\|not)]\|length' plans/cmux-next/action-surfaces.json` |
| UI journeys in ui-workflow-corpus.md | 12 | `grep -cE '^. .[a-z-]+. . P[0-2] .' plans/cmux-next/ui-workflow-corpus.md` |
| media tours | 23 | `ls scripts/cmux-next/media/tours/*.json \| wc -l` |
| e2e scripts (`.py`, `.sh`) | 64, 2 | `ls scripts/cmux-next/*-e2e.py \| wc -l; ls scripts/cmux-next/*-e2e.sh \| wc -l` |
| live scripts | 106 | `ls scripts/cmux-next \| grep -cE -- '-live(-check)?\.py$'` |
| TLA+ specs | 6 | `ls plans/cmux-next/formal/*.tla \| wc -l` |
| VT corpus cases | 7 | `git ls-files 'schemas/terminal-corpus/*.vt' \| wc -l` |
| classic API compat fixture cases (the vectors live in the Rust test, 636 lines) | 0 | `jq '.cases\|length' cmux-tui/spec/api-compat-fixtures.json; wc -l < cmux-tui/crates/cmux-api-compat/tests/api_compat.rs` |
| Rust tests in cmux-tui | 10,756 | `git grep -hE '#\[(tokio::)?test' -- cmux-tui \| wc -l` |
| Rust integration test crates (top level of `crates/<c>/tests/`); all `.rs` files under those folders | 393; 617 | `git ls-files ':(glob)cmux-tui/crates/*/tests/*.rs' \| wc -l; git ls-files ':(glob)cmux-tui/crates/*/tests/**/*.rs' \| wc -l` |
| CmuxNext `@Test` functions | 9,168 | `git grep -cE '@Test\b' -- Packages/macOS/CmuxNext/Tests \| awk -F: '{s+=$2} END {print s}'` |
| CmuxNext test directories | 57 | `ls -d Packages/macOS/CmuxNext/Tests/*/ \| wc -l` |
| CmuxNext source directories | 120 | `ls Packages/macOS/CmuxNext/Sources \| wc -l` |
| app `debug.*` control methods | 145 | `git grep -hoE '\.[a-zA-Z]+\("debug\.[a-z0-9_.]+"' -- Packages/macOS/CmuxNext/Sources \| sed -E 's/.*"(debug\.[^"]+)"/\1/' \| sort -u \| wc -l` |
| Shared and iOS packages the Linux CI builds | 15 | `grep -hoE 'Packages/(Shared\|iOS\|macOS)/[A-Za-z]+' .github/workflows/swift-packages-linux.yml .github/workflows/cmux-next-terminal.yml \| sort -u \| wc -l` |
| Settings files that import Design or Icons (block Settings on Linux) | 90 of 289 | `git grep -lE 'import CmuxNext(Design\|Icons)' -- Packages/macOS/CmuxNext/Sources/CmuxNextSettings \| wc -l; git ls-files 'Packages/macOS/CmuxNext/Sources/CmuxNextSettings/**.swift' \| wc -l` |
| Handlers without a UI import (headless candidates) | 114 of 191 | `git grep -L -E 'import (AppKit\|SwiftUI\|WebKit\|QuartzCore)' -- 'Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/*.swift' \| wc -l; git ls-files 'Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/**.swift' \| wc -l` |

Nondeterminism the oracle must normalize or remove at the source:

| Site | Count at 9dccb70 | Command |
| --- | --- | --- |
| `UUID()` in CmuxNext Sources | 247 | `git grep -cE '\bUUID\(\)' -- Packages/macOS/CmuxNext/Sources \| awk -F: '{s+=$2} END {print s}'` |
| `Date()` in CmuxNext Sources | 265 | `git grep -cE '\bDate\(\)' -- Packages/macOS/CmuxNext/Sources \| awk -F: '{s+=$2} END {print s}'` |
| `ContinuousClock()` in CmuxNext Sources | 143 | `git grep -cE '\bContinuousClock\(\)' -- Packages/macOS/CmuxNext/Sources \| awk -F: '{s+=$2} END {print s}'` |
| `SystemTime::now()` in cmux-tui, not tests | 178 | `git grep -n 'SystemTime::now()' -- 'cmux-tui/crates/**/*.rs' ':!**/tests/**' \| wc -l` |
| random ids and numbers in cmux-tui, not tests | 152 | `git grep -nE 'Uuid::new_v4\|rand::random\|thread_rng\|getrandom' -- 'cmux-tui/crates/**/*.rs' ':!**/tests/**' \| wc -l` |
| `HashMap` in cmux-tui-core | 590 | `git grep -n 'HashMap' -- cmux-tui/crates/cmux-tui-core \| wc -l` |

The `\|` in the table cells is Markdown escaping; type `|` in the shell.

## 3. Cases and snapshots

**Case** ([`schemas/oracle/case-v1.schema.json`](../../schemas/oracle/case-v1.schema.json), task 012). A case is
the [ui-workflow-corpus](ui-workflow-corpus.md#workflow-manifest) manifest plus the fields a runner needs:
`requires` (capabilities), `switches`, `platforms`, `allow_crashes`, and steps with an `op`, a `target`, `args`,
`expect`, `waitFor` and `checkpoint` (`before`, `turn`, `settled`). Offline fixtures may use loopback URLs only.
The checks JSON Schema cannot state (unique step ids, step references, crash scope) are in the stdlib
[`case_checks.py`](../../scripts/cmux-next/oracle/case_checks.py).

| Enum | Values | Command |
| --- | --- | --- |
| step ops (11) | `resource.call action.run key cli mcp tui.key settle snapshot kill restart advance_clock` | `jq -c '."$defs".step.properties.op.enum' schemas/oracle/case-v1.schema.json` |
| capabilities (8) | `resource_api actions keys gui chromium restart mcp tui` | `jq -c '."$defs".capability.enum' schemas/oracle/case-v1.schema.json` |
| crash kinds (6) | `renderer gpu browser utility daemon holder` | `jq -c '."$defs".crashKind.enum' schemas/oracle/case-v1.schema.json` |

**Snapshot** ([`schemas/oracle/snapshot-v1.schema.json`](../../schemas/oracle/snapshot-v1.schema.json), task 011;
[README](../../schemas/oracle/README.md)). Semantic facets, never pixels; private text only as `sha256:` hashes.
There are 20 facets (`jq '.properties.facets.properties|keys|length' schemas/oracle/snapshot-v1.schema.json`):
topology, daemon, focus, layout, sidebar, tabs, overlays, settings, intents, windows, history, notifications,
agents, terminals, webviews, ax, crashes, liveObjects, invariants, switches. Every field names its wire source
(`x-oracle-source`). A facet a build cannot give is `{"status": "not-comparable", ...}`, never a pass.

App facets come from `debug.oracle.snapshot`, `settle`, `wait_for`, `turns`, `recorder` and `switch_hits` (027, 030-044),
registered inside `#if DEBUG || CMUX_BENCH_HOOKS` next to the other `debug.*` methods, so
`ControlRouter.debugMethodsAllowed` refuses them in Release by name. Facet providers are values registered once in
AppServices; they build only on request and add no observer when nobody asks. The daemon facet is the public
`session.snapshot` plus `settings.snapshot` and the journal head as one cut, and `oracle-state` adds what that lacks
under the `oracle` cargo feature (021).

**v0 facets** (006) use only methods that exist at the push base (`snapshot.get`, `debug.focus`, `debug.desync`,
`debug.window_snapshot`, `debug.tunables`, `session.snapshot`, `settings.snapshot`), so any SHA of the push can be
captured. `--overlay` applies the oracle commits onto an old base for newer facets (202); a failed overlay makes
the facet not-comparable.

**Waiting.** Default runs have `ui.animations.enabled=false`; the `motion-on` virtual suite runs the same cases
with animation and must settle to the same snapshots (233). A step's `waitFor` resolves from facet change signals
(Kombucha `WaitForState`). `debug.oracle.settle` is the checkpoint barrier only: `ControlSnapshot.reflects`, intent
idle, `MotionClock` idle and one `CommitBoundary`, all continuation-based (029). A settle or wait timeout is the
`Timeout` result, and rebaseline refuses it.

**Normalization** ([`normalize.py`](../../scripts/cmux-next/oracle/normalize.py), 013; stdlib only, safe under
`python3 -I`). Ids relabeled per kind in first-seen order; a field is dropped only when the schema marks it
`x-oracle-volatile` with a reason; `$ROOT`, `$HOME`, `$WEB` path rewrites; numbers rounded to their
`x-oracle-precision`; `x-oracle-order: set` arrays sorted. A new rule needs a reason that names the source of the
nondeterminism. `normalize.py` is also the one schema validator: fleet minis have no `jsonschema`.

## 4. Suites

`tests/oracle/corpus/<suite>/<case>.json`. Generators are `scripts/cmux-next/oracle/gen_<suite>.py`
(`oracle.py gen`), and `oracle.py check --coverage` reads each generator's `coverage.json`.

| Suite | Class | Source | Target size |
| --- | --- | --- | --- |
| daemon-ops | differential | resource-operations-v2.json (060-070) | 201 mutations x (success + typed error) + 201 keyed retries |
| reads | differential | read ops against the daemon facet | 90 |
| streams | differential | stream_open + connection_control (204) | 19 |
| api-compat | differential | vectors extracted from cmux-api-compat tests (211) | all vectors |
| cli, mcp | differential | offered actions + resource verbs (048, 209) | 688+, 606+ |
| actions | differential | every-action-sweep setup, real entrypoint (071-087) | 901 -> >= 965 |
| entrypoints | differential | one case per entrypoint, compared to each other (210) | 986 actions |
| tui | differential | TUI actions and menus of inventory.json (234) | 50+ |
| walks, crash | differential | seeded walks, SIGKILL walks, ddmin (098, 207) | 10k-100k seeds |
| config | differential | Swift vs Rust effective config (212) | >= 2,000 files |
| journals | differential | input journals replayed by `oracle-replay` (104) | all saved journals |
| upgrades | golden | state roots of the last 5 cmux-tui tags (208) | 5 tags x stores |
| terminal | golden | VT corpus (101) | 7 -> >= 200 |
| pane-protocol | golden | shared vectors x Rust, TS, Swift (213) | all vectors |
| journeys | golden | 12 ui-workflow journeys + 4 Chromium failures + holder crash (088-090, 223, 224) | 17 |
| tours | golden | media tours (091) | 23 |
| e2e, live | golden | converted, or excluded with a reason (092-097, 225) | 66 + 106 |
| tla | golden | TLC simulate traces (100) | >= 200 per spec |
| ax | golden | AX tree of the journeys at 3 widths (216) | 36 |

**Two classes.** A differential suite is checked only as side against side (base against head, arm against arm,
product against product). It has no reviewed baseline and no Expectations budget: the base run is the oracle. A
golden suite keeps reviewed baselines and a 2 % budget. This keeps an agent from rebaselining wrong behavior to
meet a budget.

## 5. Baselines and expectations

- Baselines: `tests/oracle/baselines/<suite>/<case>.expected.jsonl` with platform and arm fallback dirs, searched
  `platform/<p>/arm/<case>` -> `arm/<case>` -> `platform/<p>/<case>` -> `<case>`
  ([`baselines.py`](../../scripts/cmux-next/oracle/baselines.py), 016). `rebaseline` requires proof that a case
  finished and refuses Timeout checkpoints; `optimize` uses the same order.
- Expectations: `tests/oracle/Expectations.d/<suite>.txt`, `NeverFix.d/<suite>.txt`, `SanitizerExpectations.d/`,
  one file per suite so parallel agents do not conflict ([format](../../tests/oracle/README.md),
  [`expectations.py`](../../scripts/cmux-next/oracle/expectations.py), 015):
  `[ task-id|#issue ] [ modifiers ] suite/case[/step][#/json/pointer] [ results ]`. A pointer suffix scopes the line
  to one value and keeps the rest of the snapshot strict.
- Policy: rebaseline when the new value is correct. A known-wrong value gets a pointer-scoped line with a task id,
  never a whole-case `Failure` unless the case cannot run. `oracle.py check` lints for a bug id on every line,
  duplicates, stale lines (`--stale`) and the golden budget.

## 6. Differential modes

[`oracle.py`](../../scripts/cmux-next/oracle/oracle.py) (017) runs cases; [`diff.py`](../../scripts/cmux-next/oracle/diff.py)
(014) reports the first divergence per case and refuses a host or OS mismatch.

1. **Base against head** (default). Daemon: [`linux_run.sh`](../../scripts/cmux-next/oracle/linux_run.sh) builds both
   SHAs with `--profile oracle --features oracle` in `/tmp` worktrees (024). App: `fleet.py` builds both tags with
   `cmux-ci build cmux --ref` in bench config and runs them back to back on the same host (050, 008).
2. **Switch arms** (`diff --switch NAME`, 111). App switches are a frozen `RefactorSwitches` value parsed once at
   launch from `--cmux-switches=` or `CMUX_NEXT_SWITCHES`, present in Release, injected through AppServices, with
   per-site hit counters (180, 027). Daemon switches are an immutable `Switches` value from `CMUX_TUI_SWITCHES`
   (020). A run with 0 hits on the requested arm is `arm-not-exercised`, not a pass. Registry:
   [`refactor-switches/`](refactor-switches/README.md), checked by
   [`switches.py`](../../scripts/cmux-next/oracle/switches.py) (018): owner, plan, `planned` arm, expiry at most
   14 days after `created`. `switches --expired` prints one deletion task per expired switch (171).
3. **Launch config** (`--arm launch-config`, 183): every switch at its `planned` arm against all defaults;
   `bisect-switches CASE` names the smallest switch set that causes a divergence.
4. **Parity**: port (Swift against Rust reducers), engine (WebKit against Chromium, 113), product (headless against
   app, MCP against CLI, entrypoint against entrypoint), platform (Linux against macOS daemon, 114).
5. **Confirm before route** (184, 118): a divergent case runs again on head with the same config and seed, then
   alone on base. Only "head fails twice, base passes" goes to an owner, through OWNERS.md. A head pass is a flake
   (MQ-flakes); a base failure goes to the base-red queue.
6. **Select and bisect** (009): `tests/oracle/suite-map.json` maps changed paths to suites; `bisect` runs one
   divergent case over the commits of a batch.

**Invariants** at every checkpoint (`invariants.py`; I1-I7 110, I8 204, I9 205, I10 206, I11-I15 217, I16 236, I17-I18 188):

| Id | Rule |
| --- | --- |
| I1 | each mutation gives exactly one receipt or one typed error |
| I2 | ids stay stable unless the step created or closed them |
| I3 | the turn projection equals the settled projection, or settled equals before plus a refusal |
| I4 | app topology equals the daemon tree at the same sequence |
| I5 | 0 `debug.desync` violations |
| I6 | no orphan processes or sockets at teardown |
| I7 | a hidden-workspace change does no view work (`debug.layout_counters`) |
| I8 | a client model folded from `session.events` equals the daemon facet at the same sequence |
| I9 | journal `restore_preview` equals the live daemon facet on the restorable sections |
| I10 | a retry with the same idempotency key gives the same result, no journal record, no state change |
| I11 | 0 new main-thread blocking violations (`debug.blocking`) |
| I12 | no hang over 250 ms (`debug.hangs`) |
| I13 | the action reached its commit in under 10 ms (`debug.action_budget`) |
| I14 | idle wakeups within budget after settle (`debug.wakeups`) |
| I15 | daemon fd, thread and child counts at teardown equal those after setup |
| I16 | daemon panic log empty, no lock-rank panic |
| I17 | 0 unexpected child exits unless `allow_crashes` covers the kind |
| I18 | live-object counts return to the fixture baseline after teardown |

I11-I14 failures go to the perf owner queue, not to a case baseline.

**Mutation strength.** 20 seeded mutants as patch files applied in the job worktree (026, 115), and `cargo mutants`
over cmux-tui-core store and router files with the daemon suites as the test command (191). Nothing is added to
Sources or crates for this.

## 7. Runners

- **VM**: one queue (`runnerd.py`, 007) joins identical (sha, suite, arm, profile) requests and runs under
  `systemd-run --scope -p CPUQuota=24000% -p MemoryMax=600G` and `nice -n 10`, with a per-SHA target cache.
  Each daemon case gets a hermetic env (`hermetic_env.py`), a state root `/tmp/o/<run6>/<case6>` (Linux `sun_path`
  is 108 bytes), `unshare -rn` and `CMUX_TUI_OFFLINE=1`.
- **Fleet**: `fleet.py` submits `cmux-ci run --class isolated --script scripts/measure/oracle.sh --ref SHA` per shard
  and, after a wait timeout, waits again; it never resubmits. Agents never use maclease.
- **Retries**: 0 for a filtered run; 3 for `--suite all` and diff runs. A pass on retry is Flaky: it does not fail
  the run, goes to MQ-flakes, and is left out of the comparison.
- **App driver** (047, 189): a reset check before each case, `--batch-limit K`, `--shuffle --seed N`.
- **Outputs** go outside the checkout: `receipt.json`, `checkpoints.jsonl`, `divergence.json` (the
  [review-finding shape](ui-workflow-corpus.md#what-future-agents-consume)), `events.jsonl`, `index.md`.

## 8. Linux tier

[`scripts/cmux-next/linux/`](../../scripts/cmux-next/linux/README.md): `setup-swift.sh` (CI's Linux Swift through
swiftly, 001), `setup-tools.sh` (Java/TLC, nightly Rust, nextest, cargo-mutants, cargo-fuzz, 230), `swift-tier.sh`
and `swift-shared.sh` with the compiler-error queue (004), `tier-imports.py` (005).

- `Packages/macOS/CmuxNext/linux-tier.json` lists build waves; with `CMUX_SWIFTPM_TARGET_LINUX=1` the manifest keeps
  the tier targets and their path dependencies and maps `CCmuxAppFFI` to `CCmuxAppFFILinux` (002, 003).
- Builds use a scratch copy with `Package.linux.resolved`; the checkout's `Package.resolved` is never written (229).
- OS code goes behind `CmuxNextCompat/Platform` seams (Libc, Mutex, Logger shim, OSSignposter no-op, kqueue or
  epoll, FSEvents or inotify), as Chrome's `base/` keeps `*_mac.mm` and `*_linux.cc` behind one interface. The
  Darwin branch of every seam is the code that exists today. AppKit helpers move down a layer into
  `CmuxNextCompatAppKit`, `CmuxNextWakeupsDisplay`, `CmuxNextActionsAppKit` and `CmuxNextControlDiagnostics`.
- All pure `git mv` moves and their manifest edits land in one coordinated commit (119) that names every owner.
  If an owner refuses, that target leaves the tier for the push.
- `oracle-replay` (104) and `oracle-input-walk` (105) are executables, not test targets (the 2026-10-10 ruling
  deleted the in-process suites). `oracle-replay` is `Sources/OracleReplay` (it replays
  `tests/oracle/corpus/journals/`, which driver_app.py fills from corpus runs); `oracle-input-walk` has not landed. On Linux, `oracle-input-walk` can rebuild only the attach
  part of the input fuzzer of [input-spec.md](input-spec.md#6-model-based-fuzzing): `TerminalAttachMachine`,
  `AttachOracle`, the input invariants and replay, which 102 and 103 move into `CmuxNextInputModel`. The focus,
  omnibar, `KeyRouter` and palette parts stay in `CmuxNextApp/Focus`, outside the tier, and so do the
  regressions B1-B15. Linux does not cover them until `FocusCoordinator` and its reducers move out of the app,
  and no p15 task does that yet.

## 9. Lifecycle of a refactor under the oracle

1. No runtime fallback wanted: land it; run `oracle.py select` and `oracle.py diff --base --head` on the VM and the
   fleet; `confirm` every divergence; fix it or add a pointer-scoped Expectations line with a task id.
2. Fallback wanted: add `refactor-switches/<name>.json`, land the new path at the old default, run
   `diff --switch` on both platforms, fix or list each divergence in `expected_differences`, flip the default, run
   `--arm launch-config`, then delete the old path and the switch before `expires`.

## 10. Rules

1. No CI: no `.github/workflows` change, no `tests/test-execution.toml` row, no gate. Check:
   `git diff --stat origin/feat-cmux-next -- .github/workflows | wc -l` is 0 for every p15 commit.
2. No compile or test on the person's Mac. Swift and Rust builds run on the VM or through `cmux-ci`.
3. Oracle app methods are `debug.oracle.*` inside `#if DEBUG || CMUX_BENCH_HOOKS`. `RefactorSwitches` parsing is
   the only oracle-related code in Release, because a switch must act the same in every channel.
4. No new singleton or static state: facet providers, recorder, switch values, hit counters, `OracleEnv` and id
   sources are values injected at the composition root (AppServices, the daemon owner start, HeadlessServices).
5. No sleeps, polls or timers to wait: typed receipts, `waitFor` and `settle` built on existing continuations.
6. Every normalization rule, `[ linux ]` line, `Skip` and excluded script has a written reason and a task id.
7. Facets read model values, never view frames or view trees, and never read the disk or SQLite on main.
8. One implementation each: the sweep and the oracle share setup (046); the Python cmux SDK is the one daemon
   client; `normalize.py` is the one validator.
9. A divergence reaches an owner only after `confirm`. A flaky case is never compared.
10. A change to an owned area tells its owner in the commit ([OWNERS.md](OWNERS.md)).
11. A bug the oracle finds gets a regression case, red on base and green on head.

## 11. Done checks

The spec's section 5 lists the 16 done checks with their commands. The five a reviewer runs first:

| Check | Command |
| --- | --- |
| Corpus coverage: 201/201 mutation ops, 90/90 reads, 19/19 streams, >= 965 action cases, 986/986 multi-entrypoint actions, 17/17 journeys, 0 schema and lint errors | `python3 -I scripts/cmux-next/oracle/oracle.py check --coverage` |
| Daemon determinism: 0 hash differences between 2 repeats outside Expectations, under 600 s | `python3 -I scripts/cmux-next/oracle/oracle.py run --product daemon --suite daemon-ops,streams,cli,walks,terminal --repeat 2 --jobs 200` |
| Base against head on the daemon in under 15 min, including 2 oracle-profile builds | `python3 -I scripts/cmux-next/oracle/oracle.py diff --product daemon --base origin/feat-cmux-next~20 --head HEAD` |
| Switch hygiene: 0 expired switches, every switch has an owner, plan and planned arm | `python3 -I scripts/cmux-next/oracle/switches.py --check; python3 -I scripts/cmux-next/oracle/switches.py --expired` |
| Linux tier: >= 30 CmuxNext source targets built, >= 1,500 `@Test` run | `bash scripts/cmux-next/linux/swift-tier.sh --all --receipt /tmp/oracle/linux-tier.json` |

Which p15 tasks are on the branch: `git log --format=%s origin/perf/chrome-parity | grep -oE 'p15-oracle-[0-9]+' | sort -u`.

## Related

- [chrome-parity/p15-oracle.md](chrome-parity/p15-oracle.md): the program spec, task details and machine queues.
- [ui-workflow-corpus.md](ui-workflow-corpus.md): journey manifests; the oracle case is their executable form.
- [input-spec.md](input-spec.md): input invariants; `oracle-input-walk` (planned) and `oracle-replay` run its attach-machine walk and replay on Linux.
- [refactor-switches/README.md](refactor-switches/README.md), [schemas/oracle/README.md](../../schemas/oracle/README.md),
  [tests/oracle/README.md](../../tests/oracle/README.md).
- [stability-DESIGN.md](stability-DESIGN.md): crash lab, sanitizers and the `cmux-tui/fuzz` workspace (PL-stability);
  oracle fuzz targets there go through that owner.
- [perf-lead.md](perf-lead.md): the perf owner queue for I11-I14.
