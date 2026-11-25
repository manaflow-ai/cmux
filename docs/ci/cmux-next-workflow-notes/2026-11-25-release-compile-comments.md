# cmux-next.yml release-compile: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `release-compile` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-289`

A feat-cmux-next push or dispatch lists the pass artifacts with a cmux-bot token,

## 2

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-67`

On a mini, the compile reads the fleet's shared compile cache (glaeda fleet-cas, the store
