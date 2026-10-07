# PR CI coverage and labels

Use this when deciding whether a pull request needs more CI than it gets by
default. First identify the lanes the change needs, then use the routed checks
or targeted validation that already cover them.

## Labels

| Label | Effect |
| --- | --- |
| `full-ci` | Requests the expensive full macOS suite lanes. |
| `no-full-ci` | Records a deliberate skip for `suite-coverage`. |

Normal PR routing already runs the Swift package and CLI checks a diff touches.
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
