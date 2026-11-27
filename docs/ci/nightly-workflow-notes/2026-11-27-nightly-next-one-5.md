# 2026-11-27-nightly-next-one-5

Above `- name: Refuse stray processes before secrets` (job `nightly-next-one`) in `.github/workflows/nightly.yml`.

Nothing a build script, a dependency or the app started may still run once a secret is present
(refuse_stray_processes.py). Again before the publication secrets, after the steps that run the app.
