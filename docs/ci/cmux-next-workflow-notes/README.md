# cmux-next.yml notes: one file per note

A long comment moved out of `.github/workflows/cmux-next.yml` (to keep it under GitHub's workflow file size limit,
`tests/test_ci_workflow_file_size.py`) is its own file here, and the workflow keeps one line where it stood:
`# Why: docs/ci/cmux-next-workflow-notes/<file>.md`.

Why a directory: the single file, [`../cmux-next-workflow-notes.md`](../cmux-next-workflow-notes.md), numbered its
notes `## note-N` and took each new one at its end, so two open PRs both wrote the next number at the same line and
conflicted on GitHub (16 of the 64 PRs that edited it in the 14 days to 2026-11-25, 15 of them only adding a note;
`scripts/ci/conflict_hotspots.py`). Two new files never conflict and need no number. That file is frozen: its notes
and every `#note-N` link into it stay, and can be corrected in place, but a PR that grows it fails the fast gates'
"entry logs" check (`scripts/ci/entry_logs.py`).

- Name: `YYYY-MM-DD-<job-or-topic>.md`, for example `2026-11-25-fast-tier-spill.md`.
- Content: the note as it would have been under `## note-N`: where it stood (job and step), then the why.
