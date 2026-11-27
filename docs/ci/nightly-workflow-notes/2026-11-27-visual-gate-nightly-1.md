# 2026-11-27-visual-gate-nightly-1

Above `- name: Claim a tour slot on this Mac` (job `visual-gate-nightly`) in `.github/workflows/nightly.yml`.

The media tour's slots (scripts/ci/media_tag_lock.py): the gate builds
into a warm slot's head DerivedData and holds the slot's lock until
this job's Runner.Worker exits, so it never builds beside a tour.
