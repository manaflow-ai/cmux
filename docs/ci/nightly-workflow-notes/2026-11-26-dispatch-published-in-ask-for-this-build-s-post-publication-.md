# nightly.yml: job `dispatch-published-in`, step "Ask for this build's post-publication run"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

No loop (tests/test_ci_no_github_token_polling.py). A 4xx fails this job (report-nightly-failure lists it).
A 5xx may or may not have made the run (45693929930: HTTP 500, no tail, no notes, no comments): look once
for a tail started since, and ask once more only if none did, so an accepted dispatch never gets two.
