# Dogfood and merge

**First pass.** A first pass ends when the change is implemented,
[scoped verification](../../cmux-testing/references/local-vs-ci-validation.md)
passed, and the PR is open. Native app and build-input changes need the tagged
build on the pushed HEAD and focused tests; `web/` PRs also need the live Vercel
preview URL. Docs and portable contributor tooling use their relevant checks
without an unrelated app build. Then hand off; do not sit watching CI or running
speculative review passes. Let required GitHub checks and review bots run
asynchronously, then address only concrete check failures and actionable
findings before merge.

**Merge fast, not blind.** `main` is our nightly: stack fixes, do not revert.
Before merging, wait for the checks that judge the change (macOS compile
admission plus the app-host suites CI selected for it) and skip slow unrelated
lanes. If you merge without them, say on the PR what was not verified; the merge
receipt (`merge_receipt.py`) records it and labels the PR `merged-unverified`. A
main-regression comment on your PR (`main_regression_attribution.py`) is a
fix-forward ask.

**Approval.** The main agent owns dogfood, approval, mergeability and every
pushed fix. Merging app, runtime or UI changes requires the user's explicit
approval after dogfood, or a direct merge directive that names the merge action
(`merge`, `merge it`, `auto-merge`; `finish`, `lgtm` and `ship it` are not).

**Re-dogfood.** If a fix changes runtime behavior mid-dogfood, rebuild the tag
and re-notify, since the earlier verdict covers only the build the user tested.
After a merge directive, re-dogfood (rebuild the tag and re-notify with the
checklist) when a later fix changes user-visible behavior beyond what was
dogfooded; skip it for internal, test-only or tightly scoped fixes. Either way,
say on the PR which you did and why.

