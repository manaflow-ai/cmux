# cmux-next.yml compile-status: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `compile-status` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `if [[ -n "${PR:-}" ]]; then`

A controller that accepted this PR head for Release-at-land returns an awaiting_land
receipt. Read it without waiting so the per-tip job can finish before posting pending.

## 2

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-83`

Posts cmux-next/compile from the Mac Release compile when compile-status handed off to it.
