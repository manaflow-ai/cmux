# visual-gate-nightly: Claim a tour slot on this Mac

Where: the `visual-gate-nightly` job in `.github/workflows/nightly.yml`, above `- name: Claim a tour slot on this Mac`.

The media tour's slots (scripts/ci/media_tag_lock.py): the gate builds
into a warm slot's head DerivedData and holds the slot's lock until
this job's Runner.Worker exits, so it never builds beside a tour.
