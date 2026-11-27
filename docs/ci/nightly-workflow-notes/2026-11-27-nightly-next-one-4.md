# 2026-11-27-nightly-next-one-4

Above `- name: Package unsigned app for signer shadow` (job `nightly-next-one`) in `.github/workflows/nightly.yml`.

Signer-service experiment (docs/design/signer-service.md, migration step 1).
It is shadow-only: the current in-job signing path remains authoritative, and
the upload is skipped unless the repository variable is explicitly `on`.
