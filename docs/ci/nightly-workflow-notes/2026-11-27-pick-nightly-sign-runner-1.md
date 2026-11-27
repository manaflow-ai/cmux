# 2026-11-27-pick-nightly-sign-runner-1

Above `environment:` (job `pick-nightly-sign-runner`) in `.github/workflows/nightly.yml`.

The owned pick mints the routing token (GLAEDA_ROUTE_APP_KEY), so the key is read in the
routing environment, as pick-nightly-build-runner does (tests/test_supplychain_security.py).
