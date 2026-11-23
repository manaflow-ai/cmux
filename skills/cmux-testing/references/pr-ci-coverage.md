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

The `ran` line of the PR's **cmux status** comment says which workflows the diff
started and the changed file that started each one, then the workflows that start
on every PR whatever the diff, then how many did not start
(`scripts/ci/pr_ran_line.py`, written by the red-checks comment job). Read it
before asking why a check ran or did not. To see it for a diff before you push:

```bash
git diff --name-only origin/feat-cmux-next... > /tmp/changed.txt
python3 scripts/ci/pr_ran_line.py --base-branch feat-cmux-next --changed-files /tmp/changed.txt
```

A workflow listed under "on every PR" should earn that: if it cannot fail for
most diffs, give it a path filter, or route its jobs the way `cmux-next.yml`
(`scripts/ci/cmux_next_route.py`) and `cmux-tui-spec.yml`
(`scripts/ci/affected_jobs.py`) do. A workflow that produces a check required on
the base branch must keep starting (`tests/test_ci_required_checks_have_no_path_filters.py`).
