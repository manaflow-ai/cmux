# Post-merge probe tests stay offline

Probe planning reads earlier workflow runs to reuse a verdict. Tests that invoke
the plan CLI must supply that history, even when they assert only its comparison
base. Fleet job `a3f7ef4f9f700ca60e7155c8` at `9cb7c6d9865a` exposed an
unmocked lookup by failing to launch `gh` on a worker without it.

`tests/test_ci_post_merge_batch.py::RateLimitTest.test_a_probe_is_judged_against_its_known_good_commit`
supplies empty history and asserts that the lookup occurs. The existing
`ReuseVerdictTest` supplies explicit histories for reused, missing and unreadable
verdicts. Run the suite without GitHub credentials; it must not read live runs.
