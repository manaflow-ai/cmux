# tests/oracle

Data for the cmux correctness oracle ([p15-oracle spec](../../plans/cmux-next/chrome-parity/p15-oracle.md),
section 3E). The tool that reads the expectation files is
[`scripts/cmux-next/oracle/expectations.py`](../../scripts/cmux-next/oracle/expectations.py).

| Path | Contents |
| --- | --- |
| `Expectations.d/<suite>.txt` | Known results that are not Pass, for one suite |
| `NeverFix.d/<suite>.txt` | Cases that never run on a configuration (`[ Skip ]` only) |
| `corpus/<suite>/<case>.json` | Cases (task 012); the linter reads them for stale and budget checks |
| `corpus-store.json`, `corpus-store/` | The generated suites git does not carry (`tla`, `config`, `terminal`): `scripts/cmux-next/oracle/corpus_store.py ensure` writes them from their generator or from a pinned content-addressed tarball; every oracle tool calls it first |
| `blocked/<suite>/<case>.json` | Converted cases that no driver can run yet; no run reads them. The suite's `coverage.json` names what blocks each one |
| `baselines/` | Reviewed baselines of golden suites (task 016) |
| `engine-parity.json` | Engine parity (task 113): the WebKit vs Chromium differences that are the engine itself, each with its reason; `oracle.py diff --engine webkit,chromium` explains them; an engine arm's driver canonicalizes without the tabs' `engine` |
| `mutants/<product>/<name>.patch` | Seeded faults that a job applies before its build (task 026, [mutants/README.md](mutants/README.md)) |

Each suite has its own file, so agents that work in parallel do not change the same file.
The tool also reads a combined file (all suites in one file) with the same result.

## Line format

The format is the same as Blink's `TestExpectations` (chromium/src
`docs/testing/web_test_expectations.md`):

```
# comment
p15-oracle-035 [ linux daemon ] journeys/split-right/s2#/layout/panes/1/frame [ Failure ]  # off by one
#24990 [ mac app ] tours/sidebar [ Pass Timeout ]
p15-oracle-187 [ asan ] walks/seed-0042 [ Crash ]
p15-oracle-023 [ debug ] tla/trace-0001 [ Slow ]
p15-oracle-024 [ windows ] cli/* [ Skip ]
```

`bug [ tags ] suite/case[/step][#/json/pointer] [ results ]`

- **bug**: a WORK.tsv task ID (`p15-oracle-015`) or a cmux issue (`#1234`). Every line must have one.
  A line that starts with `#1234` is an expectation only when a `suite/case` target and its
  `[ results ]` bracket come next. Every other line that starts with `#` is a comment, so
  `#12 is the tracking issue` is a comment.
- **tags**: optional. Each tag is in one of these groups:

  | Group | Tags |
  | --- | --- |
  | platform | `linux mac windows` |
  | arm | `old new` (refactor switch arm) |
  | product | `daemon app cli headless tui mcp` |
  | build | `debug bench asan tsan` |

  A line applies to a run only when the run has each tag on the line. Two tags from the same
  group are an error, because no run can have both. Write two lines instead.
- **target**: `suite/case`, `suite/case/step`, or `suite/*` for all cases of a suite.
  A `suite/*` line cannot have `Failure`, because one line would then hide every divergence
  of the suite.
  A `#/json/pointer` suffix (RFC 6901) applies the line to that value and its subtree only.
  All other values of the snapshot stay strict.
- **results**: `Pass Failure Crash Timeout Skip Slow`.
  - Two or more results mean that the case is flaky; any one of those results is expected.
    There is no `Flaky` keyword.
  - `Skip` never runs the case. It must be the only result. You cannot skip one step.
  - `Slow` multiplies `settleMaxMs` by 5. It is a modifier, not a result: when any matching case,
    step or `suite/*` line has `Slow`, the run is slow, whichever line gives the result. A line
    with only `Slow` expects Pass and never hides a result line of the same case. (Chrome keeps
    slow tests in a separate `SlowTests` file.)
  - A pointer line can only have `Pass` and `Failure`.
  - If a case has a non-Pass line and passes, the run reports an **unexpected pass**. It does not
    fail the run, but it tells you to remove the line. A case or step line is an unexpected pass
    only when nothing in its scope diverged, and only a passing run gets the unexpected-pass outcome.
  - `Crash` and `Timeout` are results. If they are not on the line, they are unexpected failures.

When two or more lines match, the most specific line wins. The order is: pointer in a step,
then pointer, then step, then case, then `suite/*`. Then a deeper pointer wins.
Tags do not change the order. If two lines have the same target and one run can match both
tag sets, the run gets the results of both lines (typ `expectations_for`). The linter refuses
such lines (typ `check_for_conflicts`), so make their tag sets disjoint.

## Policy

Rebaseline when the new value is correct. If a value is known to be wrong, write a pointer
line for it with a task ID. Do not write a `Failure` line for the whole case: the linter warns
about it. If a case cannot run, use `Skip`, `Crash` or `Timeout`. Differential suites have no
reviewed baselines: the base run is the oracle. Their expectation lines are only for cases that
cannot run, crash or time out on a configuration.

## Lint

```
python3 -I scripts/cmux-next/oracle/expectations.py lint [--corpus DIR] [--results verdicts.jsonl ...]
python3 -I scripts/cmux-next/oracle/expectations.py query journeys/split-right --platform mac --product app
python3 -I scripts/cmux-next/oracle/expectations.py selftest
```

The lint refuses:

- a line without a task ID or `#issue`;
- syntax errors, unknown tags or results, and two tags from one group;
- duplicate lines, and two lines with one target whose tag sets can both match one run;
- a line in the wrong suite file, and an Expectations line that a NeverFix line skips on some
  run (same case or `suite/*`, and tag sets that can both match);
- stale lines: the suite, case or step is not in the corpus, or a non-Pass line passed in
  `--min-runs` (default 3) verdicts from `--results` and was never hit. A run that failed with
  a result the line does not list (`missed`), or that diverged under a more specific line
  (`shadowed`), does not count;
- golden-suite lines (Expectations + NeverFix, Slow-only lines not counted) that are more than
  2 % of the golden cases in the corpus. A `suite/*` line counts as every case of its suite.

`oracle.py check` (task 017) calls the same `lint()`.
