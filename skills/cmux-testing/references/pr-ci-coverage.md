# PR CI coverage and labels

Use this when deciding whether a pull request needs more CI than it gets by
default. First identify the lanes the change needs, then use the routed checks
or targeted validation that already cover them.

## Labels

| Label | Effect |
| --- | --- |
| `full-ci` | Requests the expensive full macOS suite lanes. |

Normal PR routing already runs the Swift package and CLI checks a diff touches.
`full-ci` is not shorthand for normal PR checks, relevant tests, review
readiness or permission to merge. The rule for when to add it lives in the root
[CLAUDE.md](../../../CLAUDE.md#ci-review-and-merge): only for a requested or
agreed broad plan, naming the extra lanes and why. The old `no-full-ci` label
and its `suite-coverage` job were removed.

The label permits lanes; it does not force them. Path routing, release routing
and job dependencies still apply, and it does not request every repository test.
Adding or removing a label affects new event runs, not the label snapshot of an
existing run or a rerun of that event.

## Reading the result

Inspect the tests that actually executed on the current SHA. A green skipped job
is not coverage.
