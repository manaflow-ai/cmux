# cmux-next.yml fast-tier: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `fast-tier` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-199`

This job's tests can start acpmux daemons: they get a home of the job's

## 2

Stood above: `echo "ACPMUX_SOCKET=" >> "$GITHUB_ENV"`

An inherited socket would still name another home's daemon; empty is unset.
