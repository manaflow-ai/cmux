# find-nightly-next-recovery: environment:

Where: the `find-nightly-next-recovery` job in `.github/workflows/nightly.yml`, above `environment:`.

The owned pick mints the routing token (GLAEDA_ROUTE_APP_KEY), so the key is read in the
routing environment, as pick-nightly-sign-runner does.
