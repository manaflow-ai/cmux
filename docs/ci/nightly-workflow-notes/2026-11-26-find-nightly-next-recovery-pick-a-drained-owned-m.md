# find-nightly-next-recovery: Pick a drained owned Mac for the recovery jobs

Where: the `find-nightly-next-recovery` job in `.github/workflows/nightly.yml`, above `- name: Pick a drained owned Mac for the recovery jobs`.

As pick-nightly-sign-runner's sign-owned: a drained owned Mac, never Blacksmith. Any failure leaves it
empty and the recovery jobs take the signer's label.
