# nightly-next-one: Refuse stray processes before secrets

Where: the `nightly-next-one` job in `.github/workflows/nightly.yml`, above `- name: Refuse stray processes before secrets`.

Nothing a build script, a dependency or the app started may still run once a secret is present
(refuse_stray_processes.py). Again before the publication secrets, after the steps that run the app.
