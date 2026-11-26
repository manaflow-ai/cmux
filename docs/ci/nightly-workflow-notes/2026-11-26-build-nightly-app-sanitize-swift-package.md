# build-nightly-app: Sanitize Swift package cache

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `- name: Sanitize Swift package cache`.

Only after the restore above. The warm builder's kept checkouts carry this workspace's own
paths; dropping their state re-fetched every package (32-222 s, runs 41444184160, 41439348303).
