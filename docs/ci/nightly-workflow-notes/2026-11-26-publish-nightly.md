# nightly.yml: job `publish-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The final gate refused: a recovered build failed its lineage check, or
this pipeline is not the nightly-next writer (NIGHTLY_NEXT_WRITER read
live is not mac, or is unreadable).
A superseded build (recheck or feed CAS) publishes nothing and is no failure: every job that would
republish it reads refused, and report-nightly-failure reads refusal_reason, which it leaves empty.
