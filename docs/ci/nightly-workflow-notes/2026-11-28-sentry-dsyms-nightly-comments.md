# nightly.yml sentry-dsyms-nightly: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `environment: ${{ github.ref == 'refs/heads/main' && 'ci-cache-writer' || '' }}`:

    # The environment build-nightly-app gives its own in-job Sentry upload.

Above `- *wait-through-github-api-rate-l-2`:

    # 2026-11-28 06:29Z (Finish run 46116773791): this job's first gh call died on "API rate limit exceeded for
    # installation" because it had no waiter and no spare pool, while keep-published-dsyms beside it had both.
    # No release App token here: its secrets live only in release/release-next, not this job's environment.

Above `- name: Wait for API budget before the dSYM download`:

    # The action below cannot wait through a limit itself: wait here until the budget has room for its calls.

Above `- name: Download the build's dSYMs (parallel, waits through a rate limit)`:

    # 2026-11-28 10:53Z (run 46137161280): the action below died on "API rate limit exceeded for installation"
    # with no retry. The script waits through the reset (and tries the spares first); the action stays as fallback.
