# cmux-next.yml dev-daily-place: moved comments

Comments moved out of `.github/workflows/cmux-next.yml` job `dev-daily-place` to keep the file under GitHub's workflow
file size limit (`tests/test_ci_workflow_file_size.py`). Each section is one comment, numbered as its
`# Why:` line links it, with the line it stood above.

## 1

Stood above: `# Why: docs/ci/cmux-next-workflow-notes.md#note-scheme-fleet`

The cmux app scheme's Debug app, built by the build fleet's app recipe instead of xcodebuild on a Mac; the
Mac job below takes it and only runs what needs a Mac (the crash gate), or compiles as the logged fallback.
