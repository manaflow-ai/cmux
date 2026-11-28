# nightly.yml: job `build-nightly-app`, step "Install Zig for fast cmux-tui client"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Job-local install: this warm mini also runs classic jobs that need
the Zig 0.16.0 in /usr/local/bin, so never replace it from here.
