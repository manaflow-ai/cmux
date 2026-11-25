# cmux-next.yml request-cmux-next-dev-publish: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `request-cmux-next-dev-publish` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-339`

The fallback holds only GITHUB_TOKEN. A refusal for the rate limit waits

## 2

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-340`

The checks job's red sub-checks join the PR's red-checks line (pr-red-checks-comment.yml), each
