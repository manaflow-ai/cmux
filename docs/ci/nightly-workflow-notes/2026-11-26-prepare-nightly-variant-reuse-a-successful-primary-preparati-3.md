# nightly.yml: job `prepare-nightly-variant`, step "Reuse a successful primary preparation"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

download-artifact reads each blob over one connection. Fetch all three
signing inputs over ranged HTTP concurrently, while retaining the
action downloads as per-artifact fallbacks if a ranged request fails.
