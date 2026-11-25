# cmux-next.yml swift-canary: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `swift-canary` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `swift-canary:`

Small package-only Swift edits get a mini-first type-check/build canary.
