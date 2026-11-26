# dispatch-published-in: env: *dispatch-pools

Where: the `dispatch-published-in` job in `.github/workflows/nightly.yml`, above `env: *dispatch-pools`.

No loop (tests/test_ci_no_github_token_polling.py). A 4xx fails this job (report-nightly-failure lists it).
A 5xx may or may not have made the run (45693929930: HTTP 500, no tail, no notes, no comments): look once
for a tail started since, and ask once more only if none did, so an accepted dispatch never gets two.
