# Feature switch policy

Status: binding from 2026-10-28 (cmux-ad, fundamentals-perf decision 3). Owner: the Performance Lead.
Applies to every switch in `schemas/features/features.d/` (the registry: [schemas/features/README.md](../../schemas/features/README.md)).

## Why

On 2026-10-28, 140 of the 147 switches were off in DEV, NIGHTLY and Release. Only a hand-made dogfood
list (`FeatureDogfoodSet.chromeParity`) turned them on. The result: most merged perf work shipped dark,
nobody used the new paths day to day, and every switch was two code paths to test. Chrome keeps a feature
behind a flag only while it is measured: it is on for the builds people test with, it ramps to Stable,
and then the flag and its old code go.

## Chrome's lifecycle, and how cmux maps it

| Chrome | cmux |
| --- | --- |
| `BASE_FEATURE(kX, FEATURE_DISABLED_BY_DEFAULT)` lands with its tests | A `features.d/<name>.json` file with `defaults` all false, an `owner` and, for a perfPath, an `expires` date and lab `stories` |
| `fieldtrial_testing_config.json` turns the trial on in developer and test builds; server-side Finch field trials then enable it for a share of Canary and Dev, then Beta | `defaults.dev` and `defaults.nightly` true: every DEV, tagged and NIGHTLY build runs the new path |
| Finch ramp on Stable (1 %, 10 %, 50 %, 100 %), with a server-side off | `defaults.release` true when the spec says it is release-ready; a signed remote flags document can still turn it off |
| `FEATURE_ENABLED_BY_DEFAULT` in code after the launch | `defaults` all true |
| Feature cleanup: the flag and the old code path are removed a milestone or two later | the switch and its old path are removed (rule 4) |
| `flag-metadata.json`: every flag has owners and an expiry milestone | `owner` and `expires` in the JSON; `gen-features.py` warns after `expires` |
| A study that fails its metrics is stopped and its code removed | a perf switch with no passing bench in 7 days goes off and its new path is removed (rule 3) |

## Terms

- **Perf claim:** a switch whose reason to exist is speed, memory or energy: every `kind: perfPath` switch,
  and any `labs` switch whose description promises less work, memory or power. A UI, telemetry display,
  correctness or keep-alive rule is not a perf claim.
- **Passing bench:** the switch's lab story (its `stories`) or the bench its plan task names, run on an
  optimized build (Release or `-O`, never Debug), on one host, with the switch on against the same build with it
  off (trunk) and against classic cmux where classic has the same feature (no classic arm for Chromium-only
  switches). It passes when the on arm is no worse than the off arm on every metric the story checks and better
  on the one the switch claims, beyond the run-to-run spread. The result (bench name, build, host, numbers)
  goes in the commit or the plan.
- **Owner:** the `owner` field names an OWNERS.md owner or a `PL-*` workstream. A switch has **no owner** when
  that owner has no running agent or person who answers for it (the lead decides, and writes it in the table).

## The rules

1. **On in DEV and NIGHTLY within 24 hours.** A switch turns on in `dev` and `nightly` when both are true:
   - Its unit tests pass on the fleet at the head that turns it on (`cmux-ci run --class light --script
     scripts/ci/package-test-lane.sh --arg=suite ...`, or a cargo lane for a daemon switch). The commit or the
     branch's description names the job.
   - It is not a perf claim, or it has a passing bench.
   The owner, or the lead when the owner is quiet, makes the change in a reviewed branch with a test that pins
   the new defaults. The 24 hours start when the last condition is met.
2. **Measurement window.** The lead may turn a perf claim on in DEV and NIGHTLY when its unit tests pass but
   before its bench, so that the optimized dogfood build can measure it (Chrome's Canary field trial). The
   7 days of rule 3 still run from that day: no passing bench by then, and it goes off.
3. **Off and removed in 7 days.** A switch with no owner, or a perf claim with no passing bench, 7 days after it
   lands (for switches that exist on 2026-10-28: on 2026-11-04) goes off on every channel and is removed: the
   JSON file, the generated handle and the new code path, which only ran when the switch was on. An owner keeps a
   switch past the date only with a passing bench in the branch that keeps it. A switch that is already on in
   every channel is not removed this way: rule 4 applies to it.
4. **Cleanup after launch.** A switch that is on in DEV, NIGHTLY and Release for 14 days is removed with its
   old path, the one that ran when it was off (Chrome's feature cleanup). Only `killSwitch` switches stay.
5. **Release stays off** until the switch's own spec or plan task says it is release-ready and it has run in
   NIGHTLY for 7 days with no new hang report or crash cluster. User-visible behavior of the `risk:high` tier
   ships behind a default-off setting, as the risk tiers say.
6. **Dogfood = the channel defaults.** A tagged dogfood build is a DEV-kind build, so it resolves DEV defaults;
   rules 1 to 3 keep DEV and NIGHTLY the same, so it runs what NIGHTLY runs. The special list
   (`FeatureDogfoodSet.chromeParity`, chosen by the `chrome-parity-` tag prefix) is removed once the switches it
   holds are on in DEV and NIGHTLY or removed under rule 3, and a dogfood build then has no list of its own.
7. **Never on by default** (lead's additions, 2026-10-28): bench-only switches (`benchOnly`, for example
   `perfLabCanary` and `perfLabKillProbe`); switches whose own description says to wait for something (for
   example `hangReportsSchema3` waits for the server); and switches that change socket, relay, permission or
   auth policy, until they have the `risk:high` review receipt.

## The switch table

The table of every switch (owner, state per channel, tests, bench, date added, removal date) is rebuilt at
each policy pass. The first one is the lead's handoff `switch-table.md` of 2026-10-28.
