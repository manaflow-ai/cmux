# App FFI release: publishing by hand

`.github/workflows/app-ffi-release.yml` builds `CCmuxAppFFI.xcframework` on every
FFI source push to `feat-cmux-next` and publishes it as the prerelease
`cmux-app-ffi-<full sha>`. The publish job runs in the `ffi-release` environment
(deployment policy: branch `feat-cmux-next` only), which holds the FFI release App
credentials `CMUX_FFI_RELEASE_APP_ID` and `CMUX_FFI_RELEASE_APP_KEY` (App
`manaflow-cmux-ffi-release`, id 5246086, installed on this repository only and
used for nothing else). It mints a token for this repository only,
with contents:write, and workflows:write only when the tagged tree's
`.github/workflows` differs from the default branch tip, from the merge-base
with it, or from the last FFI tag. GitHub compares a new tag with the default
branch, not with the last FFI tag: runs 37551889292 and 38682698310 had the
last tag's workflow tree, minted contents:write only and got HTTP 403. Only the
release create uses that token.

## The pin, after a publish

The run's `repin` job first pins its release straight on `feat-cmux-next`
(`scripts/cmux-next/pin-app-ffi-on-base.sh`), the way the base autofix pins
GhosttyKit: one bot commit that changes only the pin, pushed with the base
autofix's App token (`manaflow-cmux-pr-autofix`, the bypass actor of the
branch's required check). It does so only when:

- the tip's FFI sources (`check-app-ffi-pin.sh --list-inputs`) are the
  release's, compared by content, so unrelated commits on top don't matter;
  or the tip moved past them, and the release is on the tip's history and
  newer than the current pin (the pin then follows one release behind);
- the tip's C headers keep every declaration of the current pin's
  (`scripts/cmux-next/app_ffi_additive.py`), so Swift that built against the
  old pin still builds;
- `check-app-ffi-pin.sh --verify-release` passes on the pinned tree.

Otherwise it falls back to the `app-ffi-repin` pull request, which the app
compile proves before it lands. Dry run until `CMUX_NEXT_BASE_AUTOFIX` is
`1`, like the base autofix.

A tip whose FFI sources moved past the release still gets that release
pinned. Until 2026-11-11 it was left to the newer push's own run, and when FFI
commits landed faster than a release builds (20 to 45 minutes) no release
ever had the tip's sources: the pin did not move from 23:42 to 03:37 UTC on
2026-11-10, with the release of a6741b51 published at 01:08 and never pinned.

## Catalog exports after a re-pin

`regenerate-action-exports.sh` runs `ActionSurfaceParityTests`, `ActionCatalogDumpTests`
and `LinkExportTests` together against one pinned app FFI. Its patch and every base-autofix
carrier include `action-surfaces.json`, `action-catalog.json`, `actions.md` and `links.json`.
The cached pack recipe changes when that set changes; a pack missing any member is refused.

The publication detector is the existing `cmux-action-catalog` `swift_parity` integration
suite. `base-autofix-push.sh` runs it on the final candidate immediately before each push,
including a candidate rebuilt after the base moves. Build scripts and tests run without
the publication token or injected Git authorization headers. Failure stops publication: neither an
old green result nor regenerated files alone prove the candidate consistent. A re-pin whose
`AWAITING_REPIN` or field/shortcut marker is stale needs that marker reconciled in a reviewed
change; automation never filters out the disagreement.

This closes the partial-export failure in base-autofix run `43540827406`: the surface report
acquired an action while the full catalog dump stayed old. Regression coverage executes the
real regeneration and push scripts with process-boundary fixtures, verifies that all changed
exports travel together, and checks that a failed parity command leaves the remote unchanged
(`regenerate-action-exports.test.sh`, `base-autofix-action-exports.test.sh`,
`base-autofix-push.test.sh`, `test_base_autofix_pushed_exports.py`).

Registering a missed export in `generated_outputs.py` is ownership repair when its literal
path already exists on the base. `generated_files_guard.py` checks that distinction;
new export paths and widened patterns still fail. Its regression tests cover both cases
(guard run `43580150976` misclassified the existing catalog dump as a new committed file).
The PR-size generated-output list must carry the same export set; `test_ci_pr_size.py`
checks every tracked registered output against it (run `43581204521` caught the missing dump).

## The pin check on the tip

An FFI commit's release can only be built from that pushed commit, so after
every FFI push the pin is behind the sources until the steps above finish. The
push run of `cmux-next` therefore runs "Check the app FFI pin" with
`--stale-grace 7200`: a pin that has been behind for less than two hours passes
with a note that names the commits, and one behind for longer fails. The two
hours count from the first commit that left the pin behind, not from the
newest. A red there now means that a release or its pin did not happen: look
at the `app FFI release` runs of the commits it lists. Pull requests and the
pre-push gate run the check without the flag, as before.

Before this, every pin went through the pull request, whose CI took over an
hour; an FFI change landing in that hour made the pin stale before it could
land, and base stayed red on "Check the app FFI pin" (cmux#39863 re-pinned
three times on 2026-11-10 and never landed).

FFI tags `cmux-app-ffi-*` are protected by two repository rulesets:

- 24624526 "cmux-app-ffi tags: admin create only" (creation; admins and the
  FFI release App bypass). `GITHUB_TOKEN` cannot create these tags (run 37272232472,
  HTTP 403).
- 24624527 "cmux-app-ffi tags: immutable" (update and deletion; no bypass, the
  App included).

The publish job fails loud with "Publish by hand" when it cannot create the
release:

- the App token cannot be minted (environment secrets missing or wrong);
- the create returns an error such as HTTP 403;
- the job finishes without a release (run 37556534995).

The hand publish below is then the path. The CI lead runs it, never a rebuild,
as an admin. Every check below is required; if one fails, stop and report. A
wrong release cannot be fixed by replacing it, so verify before
`gh release create`. Emergency exit only: an admin deletes ruleset 24624527
(the rollback lines are in the coordinator's window log), then restores it.

## A pull request that changes FFI inputs

A release is published only from a `feat-cmux-next` push: the `ffi-release`
environment allows only that branch, and the `cmux-app-ffi-*` tags cannot
change. So a pull request cannot pin a release of its own FFI sources, and
"Check the app FFI pin" is red on every pull request that changes an FFI input
(`scripts/cmux-next/check-app-ffi-pin.sh --list-inputs`). If this PR changes
FFI inputs: split it into a Rust-only step A and a Swift step B after the
re-pin.

A crate's `tests/`, `benches/` and `examples/` are not FFI inputs
(`--list-excluded`): Cargo never builds them into the library, so a test-only
change (a new test, a `cargo fmt` of one) needs no release and no re-pin. A
library file that names one of those folders (an `include_str!` of a test
vector, a build script) keeps it an input. `scripts/ci/app_ffi_pin.py`
(`NOT_BUILT`) is the one definition; the pin check, the pin on the base, the
release workflow's push paths, the router, `build_class.py` and
`base_red_excuse.py` read it.

1. **Step A: the Rust change only.** Make it additive, so that the Swift on
   `feat-cmux-next` keeps working with the new Rust. Do not change Swift,
   `Package.swift` or `app-ffi-pin.json`. The merge gate excuses the stale-pin
   red of such a PR (`scripts/ci/base_red_excuse.py`, the step-A rule). After
   the merge, `app-ffi-release.yml` publishes the release and the re-pin bot
   opens the re-pin pull request (branch `app-ffi-repin`). The merge queue
   merges the re-pin first. A function that step A adds to a header is not
   port drift (`scripts/cmux-next/ffi_caller_ratchet.py`) while the pinned
   release lacks it: the app cannot call it yet, so the check prints a note,
   not a finding. From the re-pin on, it needs its Swift caller, which is
   step B. A re-pin, the bot's or one by hand, is never refused by the
   check.
2. **Step B: the Swift change,** after the re-pin merges. Its FFI inputs then
   equal the pinned source, so the pin check passes.

If the Rust change cannot be additive (the old Swift breaks with it), tell
the coordinator before you split.

## Steps

Set the landed sha and the run. The run must be `app FFI release` on exactly
that sha, and the sha must be on `origin/feat-cmux-next`.

```bash
SHA=<full 40-char landed sha>
RUN=<app-ffi-release run id>
TAG=cmux-app-ffi-$SHA
git fetch origin feat-cmux-next
git merge-base --is-ancestor "$SHA" origin/feat-cmux-next
gh run view "$RUN" --repo manaflow-ai/cmux --json headSha,workflowName --jq '.headSha,.workflowName'
```

1. Download the artifact (no rebuild):

   ```bash
   gh run download "$RUN" --repo manaflow-ai/cmux --name CCmuxAppFFI.xcframework --dir "app-ffi-$SHA"
   cd "app-ffi-$SHA"
   ```

2. Check SHA256SUMS and SOURCE_SHA:

   ```bash
   shasum -a 256 -c SHA256SUMS
   test "$(cat SOURCE_SHA)" = "$SHA"
   ```

3. Compare the zip checksum with the run print (`checksum:` in the step
   "Assemble, check and checksum") and with the value the owning lane reports:

   ```bash
   cat CCmuxAppFFI.xcframework.zip.sha256
   gh run view "$RUN" --repo manaflow-ai/cmux --log | grep -E 'checksum: [0-9a-f]{64}'
   ```

4. Check that no tag or release with that name exists:

   ```bash
   ! gh release view "$TAG" --repo manaflow-ai/cmux
   ! gh api "repos/manaflow-ai/cmux/git/refs/tags/$TAG"
   ```

5. Create the prerelease, never latest:

   ```bash
   gh release create "$TAG" CCmuxAppFFI.xcframework.zip CCmuxAppFFI.xcframework.zip.sha256 SHA256SUMS SOURCE_SHA \
     --repo manaflow-ai/cmux --target "$SHA" --title "$TAG" \
     --notes "<source, ABI version, lanes included, why hand-published>" \
     --prerelease --latest=false
   gh api repos/manaflow-ai/cmux/releases/latest --jq .tag_name   # must not be an FFI tag
   ```

6. Download the asset anonymously and compare:

   ```bash
   curl -fsSL -o /tmp/ffi.zip "https://github.com/manaflow-ai/cmux/releases/download/$TAG/CCmuxAppFFI.xcframework.zip"
   shasum -a 256 /tmp/ffi.zip   # must equal the checksum from step 3
   ```

7. Pin move, by the lane that owns the window: in a fresh worktree from the
   newest `origin/feat-cmux-next`, run
   `scripts/cmux-next/repin-app-ffi.sh <source sha> <checksum>`, which writes
   `url` and `checksum` into `Packages/macOS/CmuxNext/app-ffi-pin.json` (the
   file Package.swift reads) and the same checksum into Package.swift's one
   `// app-ffi-pin-checksum:` line (SwiftPM caches the manifest by its text, so
   the manifest must change with the pin; never edit anything else there),
   commit, then

   ```bash
   if scripts/cmux-next/check-app-ffi-pin.sh --verify-release; then <safe-push>; fi
   git merge-base --is-ancestor <pin commit> origin/feat-cmux-next
   ```

   The `cmux-next` step "Check the app FFI pin" proves the pin in CI. When tip
   pushes cancel that job before the step runs, `--verify-release` on the tip
   is the accepted evidence.
