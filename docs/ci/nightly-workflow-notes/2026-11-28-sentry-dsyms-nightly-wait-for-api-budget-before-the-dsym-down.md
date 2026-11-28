# 2026-11-28-sentry-dsyms-nightly-wait-for-api-budget-before-the-dsym-down

Where: `.github/workflows/nightly.yml`, job `sentry-dsyms-nightly`, step "Wait for API budget before the dSYM download": above `- name: Download the build's dSYMs (parallel, waits through a rate limit)`.

2026-11-28 10:53Z (run 46137161280): the action below died on "API rate limit exceeded for installation" with no retry. The script waits through the reset (and tries the spares first); the action stays as fallback.
