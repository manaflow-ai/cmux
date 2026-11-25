# cmux-next.yml macos-placement: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `macos-placement` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `timeout-minutes: 19`

Its own 8 minutes plus the PR quiet period step's 11 (the wait is at most 10 minutes).

## 2

Stood above: `- name: Wait until the pull request has had no push for the quiet period`

The PR quiet period: a step here, not a job of its own (until 2026-11-21 the pr-quiet-period job took a
runner for the sleep on every pull request run, 1.64% of pull request runner-minutes over 11-13..19 with no
verdict of its own: cmuxterm-hq#16094). Only the Mac jobs wait for it (Leo, 2026-11-08) and every one of them
follows this job, so the Linux jobs still start at once, a change that reaches no Mac tier sleeps on no
runner, and the routing before this job counts toward the wait. Why: docs/ci/cmux-next-workflow-notes.md#note-1
