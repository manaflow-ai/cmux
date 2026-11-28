# 2026-11-25-fleet-fallback

The "Say why this runs on a Mac (fleet fallback)" steps of `swift-canary`, `release-compile` and
`cmux-scheme-compile` in `.github/workflows/cmux-next.yml`, and `scripts/ci/fleet_fallback.py`.

Leo, 2026-11-25: "linux... more motherfucking linux, better motherfucking caching".

Each of these Mac jobs has a fleet job partner that answers first; when the partner is skipped, fails or gives no
usable verdict, the Mac does the work itself. That fall was silent when the partner never ran: cmux#55653's scheme
compile took 27.1 Mac minutes because `cmux app scheme compile (build fleet)` was skipped by its
`vars.CI_SCHEME_COMPILE_FLEET` off switch, and nothing in the run said so. Now the Mac job's first step after checkout,
whenever it did not take the fleet answer, logs a `fleet fallback` warning, a step summary line and one
`fleet-fallback: {json}` log line naming the fleet job and the reason: a gate that was false (the workflow passes each
gate of the fleet job's `if:` as a label and its value, a variable as presence only), a skip though every gate held, a
failed or cancelled fleet job, or a verdict other than pass. Grep run logs for `fleet-fallback:` to count falls by
reason. The step never fails the job.
