# 2026-11-27-find-nightly-next-recovery-2

Above `- name: Pick a drained owned Mac for the recovery jobs` (job `find-nightly-next-recovery`) in `.github/workflows/nightly.yml`.

As pick-nightly-sign-runner's sign-owned: a drained owned Mac, never Blacksmith. Any failure leaves it
empty and the recovery jobs take the signer's label.
