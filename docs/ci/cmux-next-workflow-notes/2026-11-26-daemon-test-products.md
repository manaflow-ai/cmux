# daemon-test: CMUX_SWIFT_TEST_PRODUCTS

Where: the `daemon-test` job's "Build package and tests" step env, `CMUX_SWIFT_TEST_PRODUCTS`.

Fleet-built test bundles for this commit (scripts/ci/fleet-test-products.py), off unless
vars.CI_FAST_TIER_PRODUCTS_FLEET is 1. The generated-files checks need the whole build, so a job
that folds them builds here as before; so does any job the fleet has no products for.
