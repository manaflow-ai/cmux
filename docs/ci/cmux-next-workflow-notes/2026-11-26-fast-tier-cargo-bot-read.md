# 2026-11-26-fast-tier-cargo-bot-read

Above the step `Mint a read token` (job `fast-tier-cargo`) in `.github/workflows/cmux-next.yml`.

Every artifact lookup of this job (the rebuild mirror's candidate lookup inside `Fingerprint this job's inputs`,
the same-input lookup and the trusted planner lookup) listed artifacts with `github.token`, which shares one
hourly core budget with every run in the repository. On 2026-11-26 that budget read `5000 used, 0 remaining` in
the job's own gh-call line, so every lookup was a 403, every mirror observation was `uncertain`, no
observation ever counted as complete, and promotion evidence (`rebuild_mirror.py verify-evidence`) could never
be built: the planner path never skipped a run. swift-test, generated-files and release-compile already list
with a cmux-bot read token for this reason (note-222); this job now does too.

The token is minted only on a feat-cmux-next push or dispatch (never on a pull request run, which keeps the
workflow token), with `actions: read` only. A missing app id or a failed mint falls back to `github.token`. Kill switch:
`vars.CI_FAST_TIER_CARGO_BOT_READ = 0` keeps the workflow token.
