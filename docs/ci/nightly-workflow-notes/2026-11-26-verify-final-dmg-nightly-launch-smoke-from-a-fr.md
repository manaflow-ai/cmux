# verify-final-dmg-nightly: Launch smoke from a fresh home

Where: the `verify-final-dmg-nightly` job in `.github/workflows/nightly.yml`, above `- name: Launch smoke from a fresh home`.

Leo, 2026-10-29: "Just don't have that be the downloading thing." The app launched from a fresh
home must stay up with Home rendered: a crash fails this job, so publish-nightly puts none of
this build on the feed (scripts/ci/nightly-steps/launch-smoke-gate.sh; cannot-run never holds it).
