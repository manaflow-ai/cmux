# nightly.yml: job `verify-final-dmg-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The static DMG verifier runs the license check, which reads
ghostty-next/build.zig.zon.
