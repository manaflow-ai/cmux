# build-nightly-app: concurrency:

Where: the `build-nightly-app` job in `.github/workflows/nightly.yml`, above `concurrency:`.

One build slot per run: a newer push builds beside an older one and never
replaces it (a shared slot evicted waiting builds, 2026-10-19). publish-nightly's
recheck refuses a build no newer than both feeds.
