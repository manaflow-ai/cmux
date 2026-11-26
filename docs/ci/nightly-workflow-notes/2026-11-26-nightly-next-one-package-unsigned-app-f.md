# nightly-next-one: Package unsigned app for signer shadow

Where: the `nightly-next-one` job in `.github/workflows/nightly.yml`, above `- name: Package unsigned app for signer shadow`.

Signer-service experiment (docs/design/signer-service.md, migration step 1).
It is shadow-only: the current in-job signing path remains authoritative, and
the upload is skipped unless the repository variable is explicitly `on`.
