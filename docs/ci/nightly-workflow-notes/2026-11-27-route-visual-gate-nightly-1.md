# 2026-11-27-route-visual-gate-nightly-1

Above `- name: Mint the owned-pool routing token` (job `route-visual-gate-nightly`) in `.github/workflows/nightly.yml`.

Idle runners are read live, as side_lane_placement.py does. Any
failure leaves the token empty, and the gate is skipped.
