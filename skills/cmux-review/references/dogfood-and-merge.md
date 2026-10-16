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

**Evidence on the PR.** A clip or screenshot belongs in the PR, not in a local
directory or a chat message. `scripts/pr-media.py --pr <number> <files>` puts
each file on the `pr-media` branch under that PR's number and prints the
Markdown to paste; `--dry-run` shows the plan first. An mp4 is also converted to
a gif, because GitHub renders a gif inline from a raw URL and will not render an
mp4, so a reviewer sees the motion without clicking. `cmux record --gif` output
needs no conversion. A gif has to stay under 5 MiB or GitHub renders a broken
image, so lower `--gif-fps` or `--gif-width` if the tool refuses one; replacing
evidence already uploaded for that PR needs `--force`.

**Merge fast, not blind.** `main` is our nightly: stack fixes, do not revert.
Before merging, wait for the checks that judge the change (macOS compile
admission plus the app-host suites CI selected for it) and skip slow unrelated
lanes. If you merge without them, say on the PR what was not verified; the merge
receipt (`merge_receipt.py`) records it and labels the PR `merged-unverified`. A
main-regression comment on your PR (`main_regression_attribution.py`) is a
fix-forward ask.

**Look at the PR media.** App PRs get screenshots and a GIF of their build in
the dogfood comment ([PR media](../../cmux-testing/references/dogfood-scenarios.md#pr-media)).
Before merging, confirm they are of the head you merge and look at each frame
critically; a blank or wrong frame, or no tour that reaches the change, is a
finding to fix, not a pass.

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

