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

**Polish the capture before uploading it.** `scripts/media/media_polish.py`
crops, pairs, grids, trims and redacts, and writes a `<output>.media.json`
sidecar for each output (what the warn-only `scripts/ci/pr_media_lint.py` reads):

```sh
python3 scripts/media/media_polish.py crop shot.png --out pane.png --bounds X,Y,W,H --scale 2   # CSS px, DPR stated
python3 scripts/media/media_polish.py pair before.png after.png --out-dir pair/                  # refuses mismatched sizes unless --fit
python3 scripts/media/media_polish.py grid off.png on.png --label off --label on --metric "p50 12 ms" --metric "p50 9 ms" --out grid.png
python3 scripts/media/media_polish.py trim clip.mov --out fold.mp4 --event-start-frame 40 --event-end-frame 70   # + fold.gif, fold.poster.png
python3 scripts/media/media_polish.py sbs before.mp4 after.mp4 --out diff.mp4   # before | after, cut to where they differ, <= 15 s
```

- Crop to the pane under test, from its `getBoundingClientRect()` or AX frame
  (`--bounds-json`), never a full screen. `--scale` is the capture's device
  pixel ratio and is required; a crop that leaves the source is refused.
- Capture before, after and every variant with the same crop, so `pair` and
  `grid` take them as they are; `--fit` letterboxes (never stretches) and says so.
- Cut each clip to the event under test (`trim`: about 300 ms either side).
- A before/after of the same scenario goes up as one clip: `sbs` compares the
  two frame by frame, keeps 2 s (`--pad`) around where they differ, and writes one
  labeled side-by-side clip of at most 15 s (`--max`) with its gif and poster. The
  sidecar's `trim` records the cut and the differing span. Clips that never differ
  are refused: that before/after measured nothing.
- Start a scripted or replayed scenario at its interesting state, not at its
  beginning: the chat simulator's `--start-at S` (seconds into the scenario) or
  `--seek-to-event SEQ --lead S` (S seconds before record SEQ) applies every
  earlier step at once, so the state there is exact, then plays the rest at its
  recorded pace (`webviews/src/agent-session/acpmux/sim/seek.ts`; the browser
  page's `window.__chatSim.seek(name, options)` draws that state for a recorder).
  Then cut the pair with `sbs` (above). Keep proof clips under about 15 s; a
  minute-long clip whose difference is in its last 10 s does not show it.
- Crop so sidebars with machine or account names are outside the frame;
  `redact --rect` is the fallback. `scan` reads no text and refuses nothing: the
  privacy check (`scripts/ci/pr_media_privacy.py check`, which `pr-media.py` runs
  on every upload) decides.
- Record what you measured: `--variable`, `--control`, `--runs`, `--viewport WxH`,
  `--split`, `--window-frames S:E` go into the sidecar; anything not given is null.
  Team members: the handbook page `ui-measurement-confounded.md` in cmuxterm-hq's
  `docs/handbook/` covers the measurement side.

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
bad default in the next nightly. Into `feat-cmux-next`, merge it yourself after
the review with a squash pinned to the reviewed head; `ready-to-land` is only a
fallback hand-off. The `risk:high` tier, a `HOLD:` line or hold label, and merge
freezes still hold.

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

