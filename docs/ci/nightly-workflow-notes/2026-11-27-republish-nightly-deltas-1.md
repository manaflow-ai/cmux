# 2026-11-27-republish-nightly-deltas-1

Above `- name: Mint the release App token that reads the Dev ring switch` (job `republish-nightly-deltas`) in `.github/workflows/nightly.yml`.

The release App with every permission it has (Variables: read); the job's other App token
is contents-only. A failed mint leaves it empty, and the ring reads off.
