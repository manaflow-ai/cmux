# nightly.yml: job `attest-nightly-remote-daemon`, step "Put the pinned Node on PATH"

Moved out of `.github/workflows/nightly.yml` to keep it under GitHub's workflow file size limit (`tests/test_ci_workflow_file_size.py`); the workflow keeps a `# Why:` line where it stood.

Provenance is for `gh attestation verify`; no nightly step reads it. Signed here with no GitHub REST call
(sign.mjs: OIDC, Fulcio, Rekor) and kept as an artifact, so the shared installation budget never holds
this job: its --reserve 200 wait took 17.6 minutes in run 45562645699. The attestations API gets one try;
a refusal is a warning, and the kept bundle still verifies with `gh attestation verify FILE --bundle`.
