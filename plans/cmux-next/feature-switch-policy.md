# Feature switch policy

Status: binding from 2026-10-28 (cmux-ad, fundamentals-perf decision 3). Owner: the Performance Lead.
Applies to every switch in `schemas/features/features.d/` (the registry: [schemas/features/README.md](../../schemas/features/README.md)).
The table of every switch: [feature-switch-table.md](feature-switch-table.md).

## Why

On 2026-10-28, 140 of the 147 switches (150 by the evening) were off in DEV, NIGHTLY and Release. Only a
hand-made dogfood list (`FeatureDogfoodSet.chromeParity`) turned them on. The result: most merged perf work
shipped dark, nobody used the new paths day to day, and every switch was two code paths to test. Chrome keeps a
feature behind a flag only while it is measured: it is on for the builds people test with, it ramps to Stable,
and then the flag and its old code go.

## Chrome's lifecycle, and how cmux maps it

| Chrome | cmux |
| --- | --- |
| `BASE_FEATURE(kX, FEATURE_DISABLED_BY_DEFAULT)` lands with its tests | A `features.d/<name>.json` file with `defaults` all false, an `owner` and, for a perfPath, an `expires` date and lab `stories` |
| `fieldtrial_testing_config.json` turns the trial on in developer and test builds; server-side Finch field trials then enable it for a share of Canary and Dev, then Beta | `defaults.dev` and `defaults.nightly` true: every DEV, tagged and NIGHTLY build runs the new path |
| Finch ramp on Stable (1 %, 10 %, 50 %, 100 %), with a server-side off | a cmux field trial (`FieldTrials`, step 5 of the resolution order in `FeatureList.swift`) or `defaults.release` true when the spec says it is release-ready; a signed remote flags document can still turn it off |
| `FEATURE_ENABLED_BY_DEFAULT` in code after the launch | `defaults` all true |
| Feature cleanup: the flag and the old code path are removed a milestone or two later | the switch and its old path are removed (rule 4) |
| `flag-metadata.json`: every about://flags entry has owners and an expiry milestone | every switch has `owner` and, for a perfPath, `expires` in its JSON; `gen-features.py` warns after `expires` |
| A study that fails its metrics is stopped and its code removed | a perf switch with no passing bench in 7 days goes off and its new path is removed (rule 3) |

## Terms

- **Perf claim:** a switch whose reason to exist is speed, memory or energy: every `kind: perfPath` switch,
  and any `labs` switch whose description promises less work, memory or power. A UI, telemetry display,
  correctness or keep-alive rule is not a perf claim. Decided (cmux-ad, 2026-10-28): "no passing bench"
  applies to perf claims only; a UI, labs or other switch that is not a perf claim needs a passing behavior test
  and a named owner instead of a bench. The table says which switches are perf claims.
- **Optimized build:** a Release or `-O` build of the commit (the optimized dogfood build of `cp/dogfood-optimized`
  or a fleet Release build). A Debug (`-Onone`) build never gives a bench result.
- **Passing bench:** the switch's lab story (its `stories`) or the bench its plan task names, run on optimized
  builds on one host, at least 5 rounds per arm, with three arms:
  - **on:** the commit with the switch on: an optimized DEV or NIGHTLY build where it is on by default, or a
    Release-channel build launched with `CMUX_ENABLE_FEATURES=<name>`; for a `benchOnly` switch, which only
    DEBUG and `CMUX_BENCH_HOOKS` builds declare, an `-O` build with `CMUX_BENCH_HOOKS`;
  - **trunk:** the perf/chrome-parity tip the switch's branch is based on, which for a landed switch is the same
    build with the switch off (`CMUX_DISABLE_FEATURES`);
  - **classic:** classic cmux (main) running the same story. When classic cannot run the story (it has no such
    pane, page or process), the result says `classic: cannot run <story>` and the lead accepts it in the table.
  It passes when, against trunk, the claimed metric's p50 and p95 improve by more than the trunk arm's
  round-to-round range of that statistic, and no other metric of the story is worse at p50, p95 or p99 by more
  than that range or 5 %, whichever is larger. The classic arm is recorded; it does not decide the pass. The result
  (bench name, builds, host, rounds, p50/p95/p99/max per arm) goes in the commit and the table.
- **Owner:** the `owner` field names an OWNERS.md owner or a `PL-*` workstream. A switch has **no owner** when
  that owner has no running agent or person who answers for it (the lead decides, and writes it in the table).
  The catch-all owner `Performance Lead`, and a workstream that OWNERS.md does not list, count as no owner for a
  switch until the lead writes in the table the agent or workstream that answers for it.
- **Landed:** the day the switch's JSON file first reached perf/chrome-parity or feat-cmux-next, whichever is first.

## Speed claims

Every speed, memory or energy claim, in a commit, a PR, a plan, a status report or the table, about a switch or
not, names its bench and gives numbers from optimized builds on one host against trunk and against classic cmux
(the three arms above, same rounds and statistics). A number from a Debug build, from one arm, or with no bench
name is not a claim: write it as "not measured".

## The rules

1. **On in DEV and NIGHTLY within 24 hours.** A switch turns on in `dev` and `nightly` when both are true:
   - Its unit tests pass on the fleet at the head that turns it on (`cmux-ci run --class light --script
     scripts/ci/package-test-lane.sh --arg=suite ...`, or a cargo lane for a daemon switch), and at least one of
     them reads the switch or the code it gates. A switch with no such test gets one, red first, before it turns
     on. The commit or the branch's description names the job.
   - It is not a perf claim, or it has a passing bench.
   The owner, or the lead when the owner is quiet, makes the change in a reviewed branch with a test that pins
   the new defaults. The 24 hours start when the last condition is met.
2. **Measurement window.** The lead may turn a perf claim on in DEV and NIGHTLY when its unit tests pass but
   before its bench, so that the optimized dogfood build can measure it (Chrome's Canary field trial). This does
   not move the date of rule 3: the 7 days still count from the day the switch landed.
3. **Off and removed 7 days after it landed.** Any switch with no named owner (perf claim or not), a perf claim
   with no passing bench, or any switch with no passing behavior test (a unit test that reads the switch or the
   code it gates; cmux-ad's decision for switches that are not perf claims, the lead's addition for perf claims),
   7 days after it landed (for switches that landed before 2026-10-28:
   on 2026-11-04), goes off on every channel and is removed: the JSON file, the generated handle and the new code
   path, which only ran when the switch was on. An owner keeps a switch past the date only with a passing bench
   (or, for a switch that is not a perf claim, a passing behavior test) in the branch that keeps it. A switch that
   loses its owner after the date goes 7 days after the lead writes "no owner" in the table. `benchOnly`
   switches follow this rule too. A perf claim that is already on in every channel and has no passing bench on
   its date goes off on every channel and its new path is removed like the others, unless the lead writes in the
   table that it ships for a reason other than speed (it is then not a perf claim, for example a product choice).
4. **Cleanup after launch.** A switch that is on in DEV, NIGHTLY and Release for 14 days, and is kept under
   rule 3, is removed with its old path, the one that ran when it was off (Chrome's feature cleanup). Only
   `killSwitch` switches stay.
5. **Release stays off** until the switch's own spec or plan task says it is release-ready and it has run in
   NIGHTLY for 7 days with no new hang report or crash cluster. User-visible behavior of the `risk:high` tier
   ships behind a default-off setting, as the risk tiers say.
6. **Dogfood = the channel defaults.** A tagged dogfood build is a DEV-kind build, so it resolves DEV defaults,
   then the person's own local choices (Labs page, Debug tunables a feature `replaces`). A switch's `dev` and
   `nightly` defaults are equal, so a dogfood build runs what NIGHTLY runs; the one exception today is
   `traceControl` (DEV only, a telemetry control that NIGHTLY does not serve yet), and any new exception is
   named in the table. The special list (`FeatureDogfoodSet.chromeParity`, chosen by the `chrome-parity-` tag
   prefix) is removed once every switch it holds is on in DEV and NIGHTLY or removed under rule 3, and on
   2026-11-04 at the latest; a dogfood build then has no list of its own. `benchOnly` switches in the list
   (`cefHelperHost`, `chromiumHostIdleExit`) do not count toward that condition: rule 7 never turns them on.
7. **Never on by default** (lead's additions, 2026-10-28): bench-only switches (`benchOnly`, for example
   `perfLabCanary`, which delays every key). Every `perfLab` switch is off by default in every channel, `perfLabKillProbe`
   too (cmux-ad, 2026-10-29: a kill probe on in release must never reach feat-cmux-next); a bench turns it on for one
   launch, and FeatureRegistryGeneratedTests.noPerfLabSwitchIsOnByDefaultInAnyChannel keeps it so.
   What the kill switch proof (p12 done check 13) loses: with the probe off by default, a remote `off` turns off a switch
   that is already off, so the proof no longer shows that a remote `off` beats a default that is on, which is what a
   real kill switch must do. Turning the probe on for one launch with `CMUX_ENABLE_FEATURES` does not restore it: the
   environment (resolution layer 2) beats the remote document (layer 4), so the remote `off` would lose. Proposed path
   (not built): a perf lab build-default set at layer 6, under the remote document. A `FeatureDogfoodSet` with its own tag
   prefix for the lab's bench builds (for example `perf-lab-`), holding only `perfLabKillProbe`, composed in
   AppServices beside `chromeParity`. In a lab bench build the probe then resolves `on source=buildDefault`, the off
   document turns it `off source=remote`, and the proof again shows a remote `off` overriding a default that is on. Every
   channel default stays off, and no shipped build has the set or the probe (benchOnly). Switches whose own description says to wait for something (for
   example `hangReportsSchema3` waits for the server); and switches that change socket, relay, permission or
   auth policy, until they have the `risk:high` review receipt.

## The switch table

[feature-switch-table.md](feature-switch-table.md) lists every switch: task, owner, state per channel, tests,
whether it is a perf claim, bench result, the day it landed and its removal date. The lead rebuilds it at each
policy pass.
