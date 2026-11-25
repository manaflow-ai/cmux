# cmux-next.yml dev-landing-compile: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `dev-landing-compile` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-333`

A host build packed its compile cache: put it in the shared store and record its digest
