# nightly.yml: job `build-nightly-app`, step "Build fast arm64 cmux-tui client"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Line tables in a separate .dSYM next to each binary, for Sentry:
the bundled binary is stripped (strip-release-bundle.sh), so without these a
crash in cmux-tui, its host or acpmux (linked into the same binary) shows no
function, file or line. The shipped binary does not grow.
