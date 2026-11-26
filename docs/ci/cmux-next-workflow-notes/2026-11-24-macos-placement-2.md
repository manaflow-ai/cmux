# 2026-11-24-macos-placement-2

Above the step `Wait until the pull request has had no push for the quiet period` (job `macos-placement`) in `.github/workflows/cmux-next.yml`.

The PR quiet period: a step here, not a job of its own (until 2026-11-21 the pr-quiet-period job took a
runner for the sleep on every pull request run, 1.64% of pull request runner-minutes over 11-13..19 with no
verdict of its own: cmuxterm-hq#16094). Only the Mac jobs wait for it (Leo, 2026-11-08) and every one of them
follows this job, so the Linux jobs still start at once, a change that reaches no Mac tier sleeps on no
runner, and the routing before this job counts toward the wait. Why: docs/ci/cmux-next-workflow-notes.md#note-1
