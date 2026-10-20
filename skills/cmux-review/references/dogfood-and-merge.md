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
mp4, so a reviewer sees the motion without clicking. A gif has to stay under 5 MiB or GitHub renders a broken
image, so lower `--gif-fps` or `--gif-width` if the tool refuses one; replacing
evidence already uploaded for that PR needs `--force`.

**Merge fast, not blind.** `main` is our nightly: stack fixes, do not revert.
Look at the checks that judge the change (macOS compile admission plus the
package and CLI tests CI selected for it) and skip slow unrelated lanes. Only a
red the PR causes holds the merge; base reds, flakes and pending checks don't. If
you merge before the judging checks finish, say on the PR what was not verified;
the merge receipt (`merge_receipt.py`) records it and labels the PR `merged-unverified`.
On `main`, `gh-merge-green` still waits for the checks it requires; never get
around it with `--override` or the API merge path. A
main-regression comment on your PR is a fix-forward ask.

**When to merge.** The main agent owns dogfood, mergeability, the merge and
every pushed fix. On either branch, a PR merges when an independent review
subagent passes it and it causes no red of its own; base reds, flakes and pending
checks don't hold it. Don't wait for a person, for app, runtime and UI changes
too. Ship risky user-visible behavior behind a setting or Debug toggle, and fix a
bad default in the next nightly. Into `feat-cmux-next`, label it `ready-to-land`
after the review (again after any later push) and `next-autoland` merges that
exact head. The `risk:high` tier and merge freezes still hold.

**Red base.** A base that doesn't compile, or CI that's red on every PR, is
priority zero. Fix it directly in its own PR instead of noting it and leaving it
for an owner.

**Scope verification to the feature.** Local-backend builds can dogfood desktop
state, menus, and release-note rendering without a shared Cloud backend. Require
live authentication or transport only when the assertion depends on it. Record
the exact head, tag/artifact and exercised states; a build or an empty capture is
not an interaction result. Agents perform this verification; report an agent
verdict as such, never as a human's. A coordinator
acknowledgement is required only for an actual shared landing resource or freeze,
not simply for a reviewed fork branch.

**Re-dogfood.** If a fix changes runtime behavior mid-dogfood, rebuild the tag
and re-notify, since the earlier verdict covers only the build that was tested.
Re-dogfood when a later fix changes user-visible behavior beyond what was
dogfooded; skip it for internal, test-only or tightly scoped fixes. Either way,
say on the PR which you did and why. Re-dogfooding doesn't hold the merge.

