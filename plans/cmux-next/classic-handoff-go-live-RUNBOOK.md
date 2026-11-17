# Classic → cmux-next stable handoff: go-live runbook (NOT executed)

Status: dry run only (2026-11-16). Nothing here has been done to the production feed. Every step under
"Go live" is written to be run later, by a person who decides to ship. Companion docs:
`plans/cmux-next/classic-migration-DESIGN.md` (what the migration does),
`docs/cmux-next/classic-handoff-test.md` (how to test the RC on your own Mac).

## How a classic install takes the update

Classic stable (0.65.x, bundle `com.cmuxterm.app`) checks
`https://github.com/manaflow-ai/cmux/releases/latest/download/appcast-<arch>.xml` every hour
(`UpdateFeedResolver` rewrites `appcast.xml` per architecture). It installs an item when all hold:

| Must be true | Today |
| --- | --- |
| Item is EdDSA-signed with classic's stable key (`SUPublicEDKey` avjcg…, secret `SPARKLE_PRIVATE_KEY`) | release.yml on feat-cmux-next signs with the same secret. Proven by the RC dry run. |
| `sparkle:version` (CFBundleVersion) > installed build. Classic 0.65.2.2 is build **113** | feat-cmux-next has `CURRENT_PROJECT_VERSION = 108`. **Blocker B1.** The RC set 114 in Info.plist on its test branch only. |
| No `sparkle:channel` on the item (classic allows no channels) | release.yml writes none. |
| `sparkle:minimumSystemVersion` ≤ the Mac's macOS | Both floors are 14.0. |
| Same bundle id, Developer ID team 7WLXT3NR37, notarized, stapled | Release config: `com.cmuxterm.app`, `cmux.app`, same team. |
| Universal DMG for Intel | release.yml builds `ARCHS="arm64 x86_64"`; Intel not run on hardware (**B6**). |
| Per-arch feed files exist on the latest release | release.yml copies `appcast.xml` to `appcast-arm64.xml` and `appcast-x86_64.xml`. |

Classic ignores a `defaults write com.cmuxterm.app SUFeedURL …` override (its Sparkle delegate returns
the Info.plist URL), so the only feed classic users read is the one above. The test switch
(`scripts/cmux-next/classic-handoff-rc.sh`) therefore edits one install's Info.plist instead.

## Go live (not taken)

Preconditions: every **Blocker** below closed; the RC passed the end-to-end test on a clean classic install
for the current classic release and one older release; one Intel run.

1. Land the build-number bump on feat-cmux-next: `CURRENT_PROJECT_VERSION` above both the newest classic
   build and every RC build handed out (RC1 used 114, so ≥ 115). `project.pbxproj` is frozen
   (`FREEZE: cmux.xcodeproj/project.pbxproj token=none`): ask the coordinator for a slot.
2. Pin the final classic item (only if the cmux-next floor rises above 14.0):
   `skills/cmux-release/references/cmux-next-update-floor.md`.
3. Decide the release tag (`v1.0.0`) and changelog (`/release` flow on feat-cmux-next).
4. Add a phased rollout to the item (Sparkle `sparkle:phasedRolloutInterval`, seconds per group, 7 groups):
   `86400` ≈ 1/7 of automatic updaters per day over a week. Sparkle applies it only to background checks; a
   manual "Check for Updates" always offers the update. `scripts/sparkle_generate_appcast.sh` has no
   option for it yet (**B9**).
5. Push the tag `v1.0.0` from feat-cmux-next. `release.yml` builds, signs, notarizes, uploads the DMG and
   appcasts to the GitHub release, publishes it as latest, then uploads `files.cmux.com/stable/appcast*.xml`.
   From this moment classic installs start updating.
6. Watch: Sentry release `1.0.0` crash-free sessions, the migration toast counters, GitHub issues with
   label `classic-migration`, download counts on the release assets.
7. Homebrew cask (`manaflow-ai/homebrew-cmux`, currently `0.64.25`, already behind classic): the release
   job updates it; check it moved, or leave it pinned to classic until the rollout is complete.

## Kill switch (stop more installs from updating)

Make `latest` point back at classic's release, so `releases/latest/download/appcast-*.xml` serves
classic's appcast again, and put classic's appcast back on R2:

```sh
gh release edit v0.65.2.2 --repo manaflow-ai/cmux --latest
for f in appcast.xml appcast-arm64.xml appcast-x86_64.xml; do
  gh release download v0.65.2.2 --repo manaflow-ai/cmux -p "$f" -D /tmp/killswitch --clobber
done
# then upload the three files to files.cmux.com/stable/ (release.yml's "Upload release appcast to R2" step)
```

Installs that already updated stay on cmux-next (Sparkle never offers a lower build). Classic installs that
already downloaded the update in the background install it at their next quit; there is no remote recall.

## Rollback (people already on cmux-next)

- Per person: `scripts/cmux-next/classic-handoff-rc.sh back` (downloads classic `v0.65.2.2`, verifies team
  and Gatekeeper, keeps the cmux-next bundle aside). Classic's own session file, `cmux.json` and defaults
  were never written by cmux-next, so classic opens where it was at the update. Work done in cmux-next
  does not go back to classic.
- Everyone: ship classic again with a build number above cmux-next's (for example classic `0.65.3` with
  CFBundleVersion 200) as a normal classic release. That moves every cmux-next stable install back to
  classic. Only with a decision; it is the same "downgrade" the migration's merge path handles.

## Blockers and risks (most severe first)

| # | Severity | Finding | Fix or owner |
| --- | --- | --- | --- |
| B1 | Blocker | feat-cmux-next `CURRENT_PROJECT_VERSION` is 108, classic stable is 113: classic would never take the update, and the tag push's monotonic guard (`enforce`) fails. | Bump ≥ 115 with a pbxproj freeze slot (step 1). |
| B2 | Fixed | Socket access got looser: classic's Settings choice (UserDefaults `socketControlMode`) was ignored and next defaulted to `automation`. | Fixed in this change: `ControlService.classicStoredMode` falls back to classic's stored mode when `cmux-next.json` names none; `password` still fails closed to `off`. Suite `ControlServiceAccessModeTests` 3/3 on aws-m4pro-6. |
| B3 | High | Classic's packet-tunnel system extension (`com.cmuxterm.app.tunnel`) and its "cmux Cloud" VPN configuration are orphaned; cmux-next has no NetworkExtension code to remove them. | Ship a one-time cleanup in cmux-next, or a last classic build that deactivates it first. |
| B4 | High | Settings-window preferences are lost: only 4 link-routing keys and shortcuts import; theme, fonts, sidebar tint and about 170 other `@AppStorage` keys do not. No notice tells the user. | Import list or a toast naming what did not carry over. |
| B5 | High | Browser sign-ins are lost: classic WebKit `.default()` store and named profiles are not imported; cmux-next uses Chromium by default and its own WebKit store. The design doc claimed the opposite (corrected). | Cookie import from classic's WebKit store, or a first-run card. |
| B6 | High | No Intel Mac was reachable for the end-to-end run (cmux-aws-mac timed out). The DMG is universal; Intel launch is unproven. | One run on an Intel Mac before go-live. |
| B7 | Medium | `/usr/local/bin/cmux` silently becomes the cmux-tui CLI. Classic verbs (`send`, `new-workspace`, …) print a hint instead of working; scripts break. | Release note + verb shims for the top verbs. |
| B8 | Medium | Agent history (hook stores, agent journal) imports only through `scripts/cmux-next/classic-to-next.py`, not at first launch. | Fold into the launch migration or say so in the toast. |
| B9 | Medium | No phased rollout support in the stable appcast generator. | Add `--phased-rollout-interval` to `sparkle_generate_appcast.sh`. |
| B10 | Medium | Downgrade is one-way: work in cmux-next does not reach classic; signing out in one signs out both (shared keychain item). | Document; accepted. |
| B11 | Low | Homebrew cask is on 0.64.25, behind classic. | Fix the cask job before go-live. |
| B12 | Low | Shared UserDefaults domain: no full key-by-key type audit. Overlapping keys checked by name show no mismatch. | Audit before go-live. |
| B13 | Low | The design doc's staging step (`defaults write … SUFeedURL`) never worked on shipped classic. | Replaced by `classic-handoff-rc.sh` (this change). |
