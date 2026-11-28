# nightly.yml: job `verify-final-dmg-nightly`, step "Download final DMG (parallel ranges)"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A parallel-range read: one download-artifact stream took a p50 of 89 s
and up to 446 s here (run 41481821056, 7.4 of the job's 9 minutes). download-artifact takes over
when it fails.
