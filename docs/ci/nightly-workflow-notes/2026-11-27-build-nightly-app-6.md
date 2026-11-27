# 2026-11-27-build-nightly-app-6

Above `- &x11` (job `build-nightly-app`) in `.github/workflows/nightly.yml`.

A persistent owned mini keeps the workspace between jobs. Checkout's
clean drops untracked output; remove the daemon handoff here too.
