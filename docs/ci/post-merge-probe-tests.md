# Post-merge probe tests stay offline

Probe planning reads earlier workflow runs to reuse a verdict. Tests that invoke
the plan CLI must supply that history, even when they assert only its comparison
base. Fleet job `a3f7ef4f9f700ca60e7155c8` at `9cb7c6d9865a` exposed an
unmocked lookup by failing to launch `gh` on a worker without it.

`tests/test_ci_post_merge_batch.py::RateLimitTest.test_a_probe_is_judged_against_its_known_good_commit`
supplies empty history and asserts that the lookup occurs. The existing
`ReuseVerdictTest` supplies explicit histories for reused, missing and unreadable
verdicts. Run the suite without GitHub credentials; it must not read live runs.

## Job-level cancellation guards

Fleet `a1097b0a6af0bfd03b17b096` at `cf5407b4bdb3` passed the offline probe
suite and then exposed a workflow-level concurrency assumption. Chat-open
measurements already cancel per PR in the `report` job; a push with no measured
change must leave the prior report running. Its `changed` gate finishes within
three minutes without joining that group.

`test_ci_required_checks_are_bounded.py` and
`test_ci_pr_runs_cancel_superseded.py` share `job_groups_problem`: only the named
short gate is exempt, and every other job must have a per-PR cancelling group
that does not collide with branch measurements. The evaluator's self-checks
reject a missing or longer gate timeout, a report without cancellation, an
additional uncancelled job, and a missing report. This replaces the stale
workflow-wide exception without changing the measurement workflow.

Cloud Chief proof cancels superseded PR runs while manual runs retain their
own groups. Its existing SIGINT/SIGTERM handler deletes the temporary machine.
