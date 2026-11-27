# 2026-11-26-publish-nightly-2

Above `refused: ${{ steps.gate.outputs.refused == 'true' || steps.recheck.outputs.superseded == 'true' || steps.upload_next_appcasts.outputs.publication_refused == 'true' }}` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

The final gate refused: a recovered build failed its lineage check, or
this pipeline is not the nightly-next writer (NIGHTLY_NEXT_WRITER read
live is not mac, or is unreadable).
A superseded build (recheck or feed CAS) publishes nothing and is no failure: every job that would
republish it reads refused, and report-nightly-failure reads refusal_reason, which it leaves empty.
