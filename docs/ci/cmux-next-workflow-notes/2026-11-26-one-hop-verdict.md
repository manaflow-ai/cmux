# One-hop PR verdict: the build fleet's app compile leaves the heads that are not landing

Where: `path_route` (`scripts/ci/cmux-next-steps/classify-pull-request-paths.sh`, the PR fast tier block) writes
`app_compile_pr=false`; `app-compile-placement` and `app-compile-fleet` skip when it is.

Leo, 2026-11-21: "help 100x ci speed and the decrease of needed minutes aka lower resources and lower wall time and
lower machine time while maintaining a partial semblance of checks. and we can infrequenrly have fuller checks."
Leo, 2026-11-25: "github actions is just there at the start and end or whatever maybe i guess, but we own the
in-between. all of it".

Why: the PR fast tier (`vars.CI_PR_FAST_ONLY`, #55022) already defers every Mac job, the cargo fast tier and web
bundles to the feat-cmux-next push run, but kept `cmux-next app compile (build fleet)`: a Linux job that holds a
runner while the build fleet compiles the Debug app, up to 22 min. On 2026-11-26 04:07Z it was the last check of
three of NOW's five slowest PR verdicts (#57557, #57538, #57638, none labelled full-ci), and the PR verdict's p50 was
21.6 min against a 0.64 min goal (cmuxterm-hq goals/ci-verdict-wall-100x.md).

A head that is not landing now gets its verdict from the Linux fast tier alone. The app compile still runs:

- at the head handed to land (`ready-to-land`), as before;
- with `full-ci`, as the Mac compile (`release-compile`), as before;
- in the feat-cmux-next push run (the batched tier), where a red is fixed forward.

`mac_release` is false in the same block, so `release-compile` does not pick the compile up on a Mac when the fleet
job is skipped. `vars.CI_PR_APP_COMPILE=1` keeps the fleet compile on every head; `vars.CI_PR_FAST_ONLY=0` turns the
whole PR fast tier off. Next hop: the remaining Linux jobs of the head's verdict (path routing, checks, the pr
pipeline's linux job) become one warm job that hands the routed steps to the fleet scheduler and reads one result.
