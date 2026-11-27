# 2026-11-27-nightly-next-one-6

Above `- name: Ask main's nightly-next tick at notarization` (job `nightly-next-one`) in `.github/workflows/nightly.yml`.

The next run sets up while this one notarizes. Why: docs/ci/nightly-workflow-notes.md#note-26
.publish-tooling is this commit's scripts: an older build tree may predate scripts/ci/timeout.sh.
