# PR CI coverage and labels

Use this when deciding whether a pull request needs more CI than it gets by
default. First identify the lanes the change needs, then use the routed checks
or targeted validation that already cover them.

## What normal PR CI runs

Normal PR CI already runs routed tests, including Swift package and CLI wrapper
checks, without any label:

- A `cmuxTests/` diff runs the suites it declares or extends.
- An app-source diff runs the suites whose tests mention what it changed
  (`reverse_test_impact.py`, #14418), in one changed-suites batch. Edited suites
  over the batch budget take all seven shards.
- A change to how the suites are laid out over the workers (the timings file,
  the sharder, the batch runner, or the job's matrix and shard env) runs every
  app-host suite on its own.
- No PR job runs `cmuxUITests/`.

## Labels

| Label | Effect |
| --- | --- |
| `unit-ci` | Runs every app-host suite across all seven workers. |
| `full-ci` | Requests the expensive full macOS suite policy: `unit-ci` plus the other lanes (eligible app-host shards, lag builds and other full-suite lanes). |
| `no-full-ci` | Records a deliberate skip for `suite-coverage`. |

Neither `unit-ci` nor `full-ci` is needed to test edited suites that normal PR
routing runs. The exception is `cmuxUITests/`: no PR job runs all of it, so the
`suite-coverage` job fails a `cmuxUITests/` diff until `full-ci` runs its
selected UI regression targets or `no-full-ci` records the deliberate skip.
`full-ci` does not run every edited `cmuxUITests/` target.

`full-ci` is not shorthand for normal PR checks, relevant tests, review
readiness or permission to merge. Do not add it as a generic review or merge
requirement. Add it only when the user or an agreed validation plan explicitly
calls for the broad suite, and state which additional lanes are needed and why.

The label permits lanes; it does not force them. Path routing, release routing
and job dependencies still apply, and it does not request every repository test.
Adding or removing a label affects new event runs, not the label snapshot of an
existing run or a rerun of that event.

## Reading the result

Inspect the tests that actually executed on the current SHA. A green skipped job
is not coverage.
