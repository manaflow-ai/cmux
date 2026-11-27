# nightly.yml: job `nightly-next-one`, step "Fail when this build's publication was refused"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

A refused publication is red, not green: run 45607031207 built and signed, its shelf check died (ENOSPC),
the gate refused, and the job showed green with nothing published, so a 3.5 h stall read as healthy
(2026-11-25). A stand-down (writer linux or none, a known-bad commit), a superseded build and a left slot
publish nothing on purpose and stay green.
