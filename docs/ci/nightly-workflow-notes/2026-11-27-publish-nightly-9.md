# 2026-11-27-publish-nightly-9

Above `- name: Write the build manifest for this app-input digest` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

Clean-sheet CI RFD hq#26225: a write-once manifest per app-input digest beside the build. Nothing reads it yet;
it cannot fail or change the publish (the script exits 0 on any error, each call is time-bounded).
