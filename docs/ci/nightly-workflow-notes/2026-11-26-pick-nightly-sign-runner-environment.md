# pick-nightly-sign-runner: environment:

Where: the `pick-nightly-sign-runner` job in `.github/workflows/nightly.yml`, above `environment:`.

The owned pick mints the routing token (GLAEDA_ROUTE_APP_KEY), so the key is read in the
routing environment, as pick-nightly-build-runner does (tests/test_supplychain_security.py).
