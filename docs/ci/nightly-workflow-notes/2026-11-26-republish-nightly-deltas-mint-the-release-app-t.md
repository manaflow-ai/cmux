# republish-nightly-deltas: Mint the release App token that reads the Dev ring switch

Where: the `republish-nightly-deltas` job in `.github/workflows/nightly.yml`, above `- name: Mint the release App token that reads the Dev ring switch`.

The release App with every permission it has (Variables: read); the job's other App token
is contents-only. A failed mint leaves it empty, and the ring reads off.
