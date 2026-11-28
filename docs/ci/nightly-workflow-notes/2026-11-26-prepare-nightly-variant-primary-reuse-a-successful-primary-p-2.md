# nightly.yml: job `prepare-nightly-variant-primary`, step "Reuse a successful primary preparation"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Signing waits on this job's end. On a dedicated nightly Mac the default 5 blocks
at a time took 65-156 s (median 85 s, runs 41455121554-41488515134), against
3 s on Blacksmith Linux; 32 at a time, as the unsigned-app upload since #32343.
