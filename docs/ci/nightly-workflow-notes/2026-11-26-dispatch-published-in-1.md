# 2026-11-26-dispatch-published-in-1

Above `env: *dispatch-pools` (job `dispatch-published-in`) in `.github/workflows/nightly.yml`.

No loop (tests/test_ci_no_github_token_polling.py). A 4xx fails this job (report-nightly-failure lists it).
A 5xx may or may not have made the run (45693929930: HTTP 500, no tail, no notes, no comments): look once
for a tail started since, and ask once more only if none did, so an accepted dispatch never gets two.
