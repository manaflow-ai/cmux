# 2026-11-27-attest-nightly-remote-daemon-3

Above `needs: [decide, build-nightly-app, build-nightly-remote-daemon, nightly-next-one]` (job `attest-nightly-remote-daemon`) in `.github/workflows/nightly.yml`.

Provenance is advisory, as it was inside the app job. No publishing job
needs this job: a quota wait must not delay the feed.
