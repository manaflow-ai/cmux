# 2026-11-27-find-nightly-next-recovery-1

Above `environment:` (job `find-nightly-next-recovery`) in `.github/workflows/nightly.yml`.

The owned pick mints the routing token (GLAEDA_ROUTE_APP_KEY), so the key is read in the
routing environment, as pick-nightly-sign-runner does.
