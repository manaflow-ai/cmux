# publish-nightly: Write the build manifest for this app-input digest

Where: the `publish-nightly` job in `.github/workflows/nightly.yml`, above `- name: Write the build manifest for this app-input digest`.

Clean-sheet CI RFD hq#26225: a write-once manifest per app-input digest beside the build. Nothing reads it yet;
it cannot fail or change the publish (the script exits 0 on any error, each call is time-bounded).
