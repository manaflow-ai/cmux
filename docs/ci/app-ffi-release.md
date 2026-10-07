# App FFI release: publishing by hand

`.github/workflows/app-ffi-release.yml` builds `CCmuxAppFFI.xcframework` on every
FFI source push to `feat-cmux-next` and tries to publish it as the prerelease
`cmux-app-ffi-<full sha>`. The publish job fails loud with "Publish by hand"
when it cannot create the release:

- workflow files changed since the last FFI tag (GitHub refuses a
  `GITHUB_TOKEN` tag over workflow-file changes, run 37272232472, HTTP 403);
- the create returns an error such as HTTP 403;
- the job finishes without a release (run 37556534995).

The hand publish is the accepted path (coordinator decision 2026-10-07; revisit
an App token if this happens more than about twice a week). The CI lead runs it,
never a rebuild. Every check below is required; if one fails, stop and report.

FFI tags `cmux-app-ffi-*` are protected by two repository rulesets that the
coordinator applies:

- 24624526 "cmux-app-ffi tags: admin create only" (creation; admins bypass).
- 24624527 "cmux-app-ffi tags: immutable" (update and deletion; no bypass).

The workflow's `GITHUB_TOKEN` therefore cannot create these tags, and the hand
publish by an admin is the path. A wrong release cannot be fixed by replacing
it, so verify before `gh release create`. Emergency exit only: an admin deletes
ruleset 24624527 (the rollback lines are in the coordinator's window log), then
restores it.

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
   newest `origin/feat-cmux-next`, set the `CCmuxAppFFI` binaryTarget `url`
   and `checksum` in `Packages/macOS/CmuxNext/Package.swift`, commit, then

   ```bash
   if scripts/cmux-next/check-app-ffi-pin.sh --verify-release; then <safe-push>; fi
   git merge-base --is-ancestor <pin commit> origin/feat-cmux-next
   ```

   The `cmux-next` step "Check the app FFI pin" proves the pin in CI. When tip
   pushes cancel that job before the step runs, `--verify-release` on the tip
   is the accepted evidence.
