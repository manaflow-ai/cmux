# 2026-11-26-fixit-handoff-1

Above `report-nightly-failure:` (job `fixit-handoff`) in `.github/workflows/nightly.yml`.

A cancelled job (a timeout reports as cancelled) counts as a failure. On
nightly-next the signed release notes are part of the publication: a
published build whose notes jobs did not both succeed is reported too
(run 37526646874 published with its notes job cancelled and no alarm).
