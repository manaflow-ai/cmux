# 2026-11-27-build-nightly-app-9

Above `- name: Sanitize Swift package cache` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

Only after the restore above. The warm builder's kept checkouts carry this workspace's own
paths; dropping their state re-fetched every package (32-222 s, runs 41444184160, 41439348303).
