# 2026-11-27-nightly-next-one-3

Above `- name: Leave the push slot to a newer nightly-next push` (job `nightly-next-one`) in `.github/workflows/nightly.yml`.

Latest wins at the slot too, with no wait on this Mac: it asks main's tick and leaves; bounded gh calls,
never a rate-limit wait. Why: docs/ci/nightly-workflow-notes.md#note-16
