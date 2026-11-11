#!/usr/bin/env python3
"""The one rule for a summary gate's `needs.<job>.result` values: a pass, a red, or no verdict.

A summary (aggregator) job turns its dependencies' results into one check. Only two results are verdicts:
`success` (passed) and `failure` (red). Every other value judged nothing: `cancelled` (a cancel or a timeout),
`skipped` where the job had to run, `abandoned` (a placed runner that never reported), an empty value, or one this
rule does not know. A summary with such a result and no failure gives NO VERDICT. That is never a pass, because
nothing stood behind it, and never the pull request's own red, because nothing was judged. The job still ends red
(exit 3), so no merger reads it as green, with one annotation that starts `no verdict: ` (NO_VERDICT_PREFIX).
scripts/ci/base_red_excuse.py reads that annotation and refuses the merge with "re-run it" instead of comparing it
with the base as a test red. A real failure among the results wins: it is a red (exit 1), with one annotation that
starts `summary red: ` (SUMMARY_RED_PREFIX) and names the failed jobs. That line is the same words in every summary,
so it is never evidence: base_red_excuse.py drops it from every signature and refuses a summary red with "compare
its failed children" (Guard status, whose children it compares route by route, is the one registered exception).

A summary may also hold reds that are not job results, such as an invalid route ("invalid route web=None"). An
entry whose first word is `failure` or `invalid` (a trailing colon is no part of the word) is a red; any other
entry is no verdict.

Why: on 2026-11-09 the cmux-next/fast-gates poster (#39743) and the `rust workspaces` summary (#39791) each turned an
`abandoned` dependency into a red that merge_hold read as the pull request's own, because every summary gate wrote
its own `== success` test. Status posters apply the same rule in their own terms: cmux-next-fast-gates.yml posts
pending.

Most summary jobs check nothing out, and adding a checkout step to each would add CI steps. So they carry
SHELL_RULE or PYTHON_RULE below, copied verbatim. tests/test_needs_verdict.py keeps every copy equal to this file
and runs the copies against the same table as `judge`.

    needs_verdict.py --what "rust workspaces" [--may-skip JOB[,JOB]] JOB=RESULT ...

`--may-skip` names the jobs whose `skipped` result is a pass (a routed-off or empty matrix). Exit 0: every job
passed; 1: a red; 3: no verdict.
"""
from __future__ import annotations

import argparse
import sys
from collections.abc import Iterable, Mapping

PASS, FAIL, NONE = "pass", "fail", "none"
NO_VERDICT_PREFIX = "no verdict: "
SUMMARY_RED_PREFIX = "summary red: "
EXIT_FAIL, EXIT_NO_VERDICT = 1, 3
RED_WORDS = ("failure", "invalid")

# The rule as a bash function, for a summary step with no checkout: `needs_verdict "WHAT" "job=$RESULT" ...`, one call
# with every result. A job whose `skipped` passes is named with a trailing `?` ("job?=$RESULT"), as MAY_SKIP does for
# the Python copy. One call per step (tests/test_needs_verdict.py): a second call would let the first one's no verdict
# end the step before the second sees a failure, and a failure always wins.
SHELL_RULE = """\
needs_verdict() {  # scripts/ci/needs_verdict.py SHELL_RULE, copied verbatim (tests/test_needs_verdict.py)
  local what=$1 failed="" unjudged="" pair name result; shift
  for pair in "$@"; do
    name=${pair%%=*}; result=${pair#*=}
    if [[ "$name" == *"?" ]]; then name=${name%"?"}; [[ "$result" == skipped ]] && result=success; fi
    case "${result%%[ :]*}" in
      success) ;;
      failure|invalid) failed+=" $name: $result;" ;;
      *) unjudged+=" $name ${result:-none}," ;;
    esac
  done
  if [[ -n "$failed" ]]; then echo "::error::summary red: $what:${failed%;}"; return 1; fi
  if [[ -n "$unjudged" ]]; then
    echo "::error::no verdict: $what:${unjudged%,}; nothing it summarizes was judged: re-run the run"; return 3
  fi
  echo "$what: every job passed"
}
"""

# The rule as a Python function, for a summary step with no checkout. RESULTS holds every entry the summary judges
# ({job: result}); MAY_SKIP names the jobs whose `skipped` passes. It returns when every entry passed and exits otherwise,
# so the step never compares a result with "success" itself. One call per step, with every result (see SHELL_RULE).
PYTHON_RULE = '''\
def exit_with_verdict(results, what, may_skip=()):
    """scripts/ci/needs_verdict.py PYTHON_RULE, copied verbatim (tests/test_needs_verdict.py)."""
    def word(r):
        return (r or "").replace(":", " ").split(" ", 1)[0]
    bad = {n: r for n, r in results.items() if word(r) != "success" and not (r == "skipped" and n in may_skip)}
    if not bad:
        return
    failed = {n: r for n, r in bad.items() if word(r) in ("failure", "invalid")}
    for n, r in bad.items():
        print(f"{n}: {r or 'none'}", file=sys.stderr)
    if failed:
        print(f"::error::summary red: {what}: " + "; ".join(f"{n}: {r}" for n, r in failed.items()))
        sys.exit(1)
    named = ", ".join(f"{n} {r or 'none'}" for n, r in bad.items())
    print(f"::error::no verdict: {what}: {named}; nothing it summarizes was judged: re-run the run")
    sys.exit(3)
'''


# A push's Mac jobs share one concurrency group per branch with cancel-in-progress off: the running job finishes, and
# GitHub keeps one waiting job, cancelling the older waiting one when a newer push queues ("Canceling since a higher
# priority waiting request for cmux-next-push-...-cmux-scheme-compile exists"). That cancel judged nothing, but it is
# not a run that needs a re-run either: the newer push's job takes the slot and carries the verdict. A summary step
# that reads such a job calls `superseded_push "WHAT"` only for a `cancelled` result, before its no verdict: it
# returns 0 with a notice when this run is a push and the branch head has moved past it (one `git ls-remote`, no API
# call), and 1 otherwise (not a push, the head unread or unmoved), so the step goes on to its no verdict.
# Why: feat-cmux-next runs 43032789758 (c66b1b5a) and 43037486374 (cc4ec159), 2026-11-11: each scheme compile was
# replaced while waiting, and `cmux-next crash ends the app` went red with "no verdict: crash gate: compile cancelled".
SUPERSEDED_RULE = """\
superseded_push() {  # scripts/ci/needs_verdict.py SUPERSEDED_RULE, copied verbatim (tests/test_needs_verdict.py)
  local what=$1 head
  [[ "${GITHUB_EVENT_NAME:-}" == push && -n "${GITHUB_SHA:-}" && -n "${GITHUB_REF:-}" ]] || return 1
  head="$(git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=15 ls-remote \\
    "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}.git" "$GITHUB_REF" 2>/dev/null \\
    | awk 'NR==1{print $1}')" || head=""
  [[ -n "$head" && "$head" != "$GITHUB_SHA" ]] || return 1
  echo "::notice title=$what: superseded::not judged at $GITHUB_SHA: a newer push ($head) replaced its waiting job, and that push's run carries the verdict"
}
"""


def classify(result: str | None, may_skip: bool = False) -> str:
    """PASS, FAIL or NONE for one entry."""
    value = (result or "").strip()
    word = value.replace(":", " ").split(" ", 1)[0]  # "invalid: not among the needs" is the word "invalid"
    if word == "success" or (value == "skipped" and may_skip):
        return PASS
    if word in RED_WORDS:
        return FAIL
    return NONE


def judge(results: Mapping[str, str | None], may_skip: Iterable[str] | bool = ()) -> tuple[str, dict, dict]:
    """(state, failed, unjudged) for RESULTS; MAY_SKIP is True for every job, or the names whose skip passes."""
    skippable = set() if isinstance(may_skip, bool) else set(may_skip)
    failed: dict[str, str] = {}
    unjudged: dict[str, str] = {}
    for name, result in results.items():
        state = classify(result, may_skip if isinstance(may_skip, bool) else name in skippable)
        if state == FAIL:
            failed[name] = result or ""
        elif state == NONE:
            unjudged[name] = result or ""
    return (FAIL if failed else NONE if unjudged else PASS), failed, unjudged


def exit_code(state: str) -> int:
    return {PASS: 0, FAIL: EXIT_FAIL, NONE: EXIT_NO_VERDICT}[state]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--what", required=True, help="the summary's check name")
    parser.add_argument("--may-skip", default="", help="comma-separated jobs whose skipped result passes")
    parser.add_argument("results", nargs="+", metavar="JOB=RESULT")
    args = parser.parse_args(argv)
    results: dict[str, str] = {}
    for pair in args.results:
        name, sep, result = pair.partition("=")
        if not sep or not name:
            parser.error(f"not JOB=RESULT: {pair!r}")
        results[name] = result
    state, failed, unjudged = judge(results, [n for n in args.may_skip.split(",") if n])
    if failed:
        print(f"::error::{SUMMARY_RED_PREFIX}{args.what}: " + "; ".join(f"{n}: {r}" for n, r in failed.items()))
    elif unjudged:
        named = ", ".join(f"{n} {r or 'none'}" for n, r in unjudged.items())
        print(f"::error::{NO_VERDICT_PREFIX}{args.what}: {named}; nothing it summarizes was judged: re-run the run")
    else:
        print(f"{args.what}: every job passed")
    return exit_code(state)


if __name__ == "__main__":
    sys.exit(main())
