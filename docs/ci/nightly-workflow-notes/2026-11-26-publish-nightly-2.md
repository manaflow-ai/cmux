# 2026-11-26-publish-nightly-2

Above `refused: ${{ steps.gate.outputs.refused == 'true' || steps.recheck.outputs.superseded == 'true' || steps.upload_next_appcasts.outputs.publication_refused == 'true' }}` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

The final gate refused: a recovered build failed its lineage check, or
this pipeline is not the nightly-next writer (NIGHTLY_NEXT_WRITER read
live is not mac, or is unreadable).
A superseded build (recheck or feed CAS) publishes nothing and is no failure: every job that would
republish it reads refused, and report-nightly-failure reads refusal_reason, which it leaves empty.

## nightly.yml: job `publish-nightly`

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

The release App key remains scoped to this protected environment. Publication uploads and writes feeds
at about one core (publish-nightly 64 s on 32 vCPU at 1.39 cores, .github/runners.json): with no owned
pool it takes the signing picker's Linux label, as keep-published-dsyms does, else the Linux 4 vCPU pool.
