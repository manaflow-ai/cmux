# publish-nightly: refused: ${{ steps.gate.outputs.refused == 'true' || steps.recheck.outputs.super

Where: the `publish-nightly` job in `.github/workflows/nightly.yml`, above `refused: ${{ steps.gate.outputs.refused == 'true' || steps.recheck.outputs.superseded == 'true' || s…`.

The final gate refused: a recovered build failed its lineage check, or
this pipeline is not the nightly-next writer (NIGHTLY_NEXT_WRITER read
live is not mac, or is unreadable).
A superseded build (recheck or feed CAS) publishes nothing and is no failure: every job that would
republish it reads refused, and report-nightly-failure reads refusal_reason, which it leaves empty.
