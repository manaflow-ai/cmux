# pick-nightly-sign-runner: Mint the owned-pool routing token

Where: the `pick-nightly-sign-runner` job in `.github/workflows/nightly.yml`, above `- name: Mint the owned-pool routing token`.

As cmux-next-dev-daily.yml: idle owned runners read live with the routing App's own
budget. Any failure leaves the token empty, and the pick below then finds no owned Mac.
