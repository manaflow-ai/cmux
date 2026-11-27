# 2026-11-27-pick-nightly-sign-runner-4

Above `- name: Mint the owned-pool routing token` (job `pick-nightly-sign-runner`) in `.github/workflows/nightly.yml`.

As cmux-next-dev-daily.yml: idle owned runners read live with the routing App's own
budget. Any failure leaves the token empty, and the pick below then finds no owned Mac.
