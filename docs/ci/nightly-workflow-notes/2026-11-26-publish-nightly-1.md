# 2026-11-26-publish-nightly-1

Above `concurrency:` (job `publish-nightly`) in `.github/workflows/nightly.yml`.

rc/** branches share one release. Serialize its mutable aliases and feeds
by channel, even when workflow-level groups have different branch names.
nightly-next takes a group of its own run and the R2 lease below instead:
a shared group cancelled run 41436891188's pending publish for a newer one.
