# cmux-next.yml pure-checks-coalesce: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `pure-checks-coalesce` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `pure-checks-coalesce:`

One run per 30-minute window on the feat-cmux-next tip for checks whose result
does not publish a per-commit artifact. Pull requests, dispatches and reruns
keep the existing behavior because base-coalesce only coalesces base pushes.
Publishing and per-landing jobs intentionally do not depend on this gate.

## 2

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-11`

feat-cmux-next push CI is the Swift app build only (Lawrence, 2026-10-10): its
