# 2026-11-28-sentry-dsyms-nightly-wait-through-github-api-rate-l-2

Where: `.github/workflows/nightly.yml`, job `sentry-dsyms-nightly`: above `- *wait-through-github-api-rate-l-2`.

2026-11-28 06:29Z (Finish run 46116773791): this job's first gh call died on "API rate limit exceeded for installation" because it had no waiter and no spare pool, while keep-published-dsyms beside it had both. No release App token here: its secrets live only in release/release-next, not this job's environment.
