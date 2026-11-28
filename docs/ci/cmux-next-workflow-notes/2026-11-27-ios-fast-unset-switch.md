# iOS fast verdict with an unset switch

Above `ios-fast-runner: if` in `.github/workflows/pr-pipeline.yml`.

The fast verdict is enabled unless `CI_IOS_FAST_VERDICT` explicitly contains `0`. An unset Actions variable can
be null; comparing that directly to the string `'0'` coerces both to numeric zero and skips the runner, while the
Python router treats the empty environment value as enabled and announces a pending verdict. Format the variable
as a string before comparing, preserving both the enabled default and the explicit off switch.

The temporary hosted probe at `7d18e976df0614cf96dd1f341f595f66d8a2ddd6`,
[run 45977860851](https://github.com/manaflow-ai/cmux/actions/runs/45977860851), compared a reusable workflow called
through a skipped optional dependency with a direct call. In both calls, raw-variable roots skipped with and
without `!cancelled()`, while normalized and unconditional roots passed. The result job `140434174876` passed;
the temporary workflows were removed after recording the result. Detector:
`WorkflowTest.test_the_default_on_switch_normalizes_an_unset_variable` in `tests/test_ci_ios_fast_verdict.py`.
