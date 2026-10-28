# Feature switch policy

Status: binding from 2026-10-28 (cmux-ad, fundamentals-perf decision 3). Owner: the Performance Lead.
Applies to every switch in `schemas/features/features.d/` (the registry: [schemas/features/README.md](../../schemas/features/README.md)).

## Why

On 2026-10-28, 140 of the 147 switches were off in DEV, NIGHTLY and Release. Only a hand-made dogfood
list (`FeatureDogfoodSet.chromeParity`) turned them on. The result: most merged perf work shipped dark,
nobody used the new paths day to day, and every switch was two code paths to test. Chrome does not work
like this. A Chrome feature is on in Canary soon after it lands, and it does not stay a flag for long.

## Chrome's lifecycle, and how cmux maps it

| Chrome | cmux |
| --- | --- |
| `BASE_FEATURE(kX, FEATURE_DISABLED_BY_DEFAULT)` lands with its tests | A `features.d/<name>.json` file with `defaults` all false, an `owner`, and for a perfPath an `expires` date and lab `stories` |
| Field trial on Canary and Dev (`fieldtrial_testing_config.json`): the feature is on for the people who build and test Chrome | `defaults.dev` and `defaults.nightly` true |
| Finch ramp on Beta, then Stable at 1 %, 10 %, 50 %, 100 % | `defaults.release` true when the spec says it is release-ready (a remote flags document can turn it off: the kill-switch path) |
| `FEATURE_ENABLED_BY_DEFAULT` in code after the launch | the same: `defaults` all true |
| Feature cleanup: the flag and its old code path are removed one or two milestones later | the switch and its old path are removed (below) |
| `flag-metadata.json`: every flag has owners and an expiry milestone; expired flags leave about:flags | `owner` and `expires` in the JSON; `gen-features.py` warns after `expires` |
| A launch that fails its experiment is stopped, and its code is removed | a switch with no passing bench in 7 days is removed with its new path |

## The rules

1. **On in DEV and NIGHTLY within 24 hours.** A switch turns on in `dev` and `nightly` when both are true:
   - Its unit tests pass on the fleet at the head that turns it on (`cmux-ci run --class isolated --script
     scripts/ci/package-test-lane.sh --arg=suite ...`, or the cargo lane for a daemon switch). The commit names
     the job.
   - It is not a perf claim (a correctness, UI or plumbing switch), or it has a passing bench: the bench named
     in its `stories`, on an optimized build (Release or `-O`), on one host, against trunk and against classic
     cmux (decision 5). A Debug build never counts. A perfPath switch is a perf claim. A memory or energy saving
     is a perf claim (`bench_memory.py`, `bench_power.py`).
   The owner, or the lead when the owner is quiet, makes the flip in a reviewed branch with a test that pins the
   new defaults. The 24 hours start when the last of the two conditions is met.
2. **Release stays off** until the switch's own spec or plan task says it is release-ready, and it has run in
   NIGHTLY with no new hang report or crash cluster for at least 7 days. Release-ready user-visible behavior of
   the `risk:high` tier ships behind a default-off setting, as the risk tiers say.
3. **Removal in 7 days.** A switch with no owner, or a perf claim with no passing bench (rule 1), 7 days after
   it lands (for switches that exist today: 7 days after this policy, 2026-11-04) is removed: the JSON file,
   the generated handle and the code path that only ran when it was on. The removal is a reviewed branch like any other change. An owner
   can keep a switch past the date only with a measured bench result in the branch that keeps it.
4. **Cleanup after launch.** A switch that is on in DEV, NIGHTLY and Release for 14 days is removed with its
   old path (Chrome's feature cleanup). Only a switch of kind `killSwitch` stays as a remote off.
5. **Dogfood = NIGHTLY defaults.** A dogfood build uses the channel defaults, with no special list. When the
   NIGHTLY defaults hold the switches of `FeatureDogfoodSet.chromeParity`, that list is removed, and dogfood
   builds stop passing switch names through `CMUX_ENABLE_FEATURES`.
6. **Not on by default:** bench-only switches (`benchOnly`, for example `perfLabCanary` and `perfLabKillProbe`),
   switches whose own description says to wait for something (for example `hangReportsSchema3` waits for the
   server), and switches that change socket, relay, permission or auth policy until they have the `risk:high`
   review receipt.

## The switch table

The table of every switch (owner, state per channel, tests, bench, date added, removal date) is rebuilt at
each policy pass. The first one is the lead's handoff `switch-table.md` of 2026-10-28.
