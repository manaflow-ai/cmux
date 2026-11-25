# Classic → cmux-next stable handoff: go-live runbook (NOT executed)

Status: dry run only (2026-11-17). Nothing here has been done to the production feed. Every step under
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
| `sparkle:version` (CFBundleVersion) > installed build. Classic 0.65.2.2 is build **113** | feat-cmux-next has `CURRENT_PROJECT_VERSION = 108`. **Blocker B1.** The RCs set 114, 115 and 116 in Info.plist on their test branches only. |
| No `sparkle:channel` on the item (classic allows no channels) | release.yml writes none. |
| `sparkle:minimumSystemVersion` ≤ the Mac's macOS | Both floors are 14.0. |
| Same bundle id, Developer ID team 7WLXT3NR37, notarized, stapled | Release config: `com.cmuxterm.app`, `cmux.app`, same team. |
| Apple silicon only | The app binary is universal, but `bin/cmux` and CEF are arm64 only (**B6b**), so the item requires arm64 (**B0b**) and Intel classic is not offered it. Intel not run on hardware (**B6**). |
| Per-arch feed files exist on the latest release | release.yml copies `appcast.xml` to `appcast-arm64.xml` and `appcast-x86_64.xml`. |

Classic ignores a `defaults write com.cmuxterm.app SUFeedURL …` override (its Sparkle delegate returns
the Info.plist URL), so the only feed classic users read is the one above. The test switch
(`scripts/cmux-next/classic-handoff-rc.sh`) therefore edits one install's Info.plist and signs that copy
ad hoc. An edit alone is not enough: with a broken Developer ID signature, Sparkle's installer refuses
the app's XPC connection and the update fails with SUSparkleErrorDomain 4005 ("An error occurred while
starting the installer"), seen in end-to-end run A. Go-live needs no switch: the production feed is the
one classic already reads.

## Dry run results (2026-11-17)

- RC: cmux-next `1.0.0` build `114`, release.yml dry run
  [44080991422](https://github.com/manaflow-ai/cmux/actions/runs/44080991422) on
  `rc/cmux-next-handoff-dry-7` (feat-cmux-next `43c5b903` plus the build-114 Info.plist literal).
  Developer ID `7WLXT3NR37`, notarized, stapled, Gatekeeper accepts it.
- Test feed: `https://github.com/manaflow-ai/cmux-next-handoff-test/releases/latest/download/appcast.xml`
  (a separate repository; no shipped build reads it, and classic's `UpdateFeedResolver` keeps it as is).
  Release [rc7-b114](https://github.com/manaflow-ai/cmux-next-handoff-test/releases/tag/rc7-b114) holds
  the DMG, the appcast and the recordings.
- End-to-end on cmux-lawrence-2 (macOS 27.0.1, arm64), through the in-app flow (sidebar "Update…" pill,
  "Install and Relaunch"):
  - Run A, classic 0.65.2.2, Info.plist edit only: download done, install failed (4005). Fixed in the switch.
  - Run B, classic 0.65.2.2: the 297 MB update downloaded and the app relaunched as 1.0.0 in 26 s (click 14:48:04 UTC, relaunch 14:48:30 UTC); cmux-next asked "Import your
    classic cmux workspaces? 4 workspaces and 1 browser tab"; Import gave the 4 workspaces (names, the
    color `#C0392B`, the split, the browser tab), the group `Frontend`, and the toast "Workspaces from
    classic cmux are open." Second launch: no duplicates. cmux-next then read the production feed and
    found nothing newer (`onNewerThanLatestVersion`, latest 0.65.2). `back` restored classic 0.65.2.2,
    which opened its own 4 workspaces. **The sidebar showed no workspace rows (B14).**
  - Run C, classic 0.64.25 (build 106): update installed; same workspaces, no second import prompt (run B's
    import is remembered), no duplicates.
  - Intel: no host reachable (B6).
- Production unchanged: hashes of `releases/latest/download/appcast{,-arm64,-x86_64}.xml` and
  `files.cmux.com/stable/appcast{,-arm64,-x86_64}.xml` are the same before and after (201aaa85…,
  3c9f03fc…, d41a0daf…); latest release still `v0.65.2.2`; cask still `0.64.25`.

### RC 8 (build 115, after B0b, B0c and B14)

- RC: release.yml dry run [44114944663](https://github.com/manaflow-ai/cmux/actions/runs/44114944663) on
  `rc/cmux-next-handoff-dry-8` (feat-cmux-next `26a09e12`, the same tree as the landed `3e27adbe`, plus the
  build-115 Info.plist literal). The DMG bundles `bin/optchat-chief`, `bin/cmux-mobile-host` and
  `Library/cmux Screen Sharing.app` (all universal, team `7WLXT3NR37`); `bin/cmux` is arm64 only and the
  appcast item carries `<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>`. Gatekeeper
  accepts it. Release [rc8-b115](https://github.com/manaflow-ai/cmux-next-handoff-test/releases/tag/rc8-b115)
  holds the DMG, the appcast, the screenshots and the recordings.
- Lab setup: `cmux-next.json` set to `showProjects: true` for the runs (B14), the cmux-next migration
  ledger, its daemon session and the two settings import keys moved aside; all restored afterwards.
- Run B, classic 0.65.2.2 (build 113): found build 115 on the test feed, installed and relaunched. The
  first attempt got no import prompt (see B16): the lab still had four terminal hosts from the RC 7 run,
  the new daemon showed them as "Recovered terminals", and cmux-next took the Mac as "in use before". After
  those hosts were stopped and the state moved aside again: "Import your classic cmux workspaces? 3
  workspaces and 1 browser tab", Import, toast "Workspaces from classic cmux are open.", **the sidebar
  lists all 3 workspaces** (B14 closed), `cmux workspace list` the same 3 plus Home. The stable app
  started its bundled Chief (`optchat-chief host` and `mcp` from `/Applications/cmux.app`). Second
  launch: still 3 rows, the ledger shows each workspace `done` once.
- Run C, classic 0.64.25 (build 106), fresh cmux-next state: found build 115; "Install Update and
  Relaunch" stopped at classic's own "Quit cmux? This will close all windows and workspaces." sheet (B17);
  after Quit, the update installed, the import prompt showed 3 workspaces and 1 browser tab, Import gave
  the same 3 sidebar rows, and the Chief started.
- Production unchanged after RC 8: the same six feed hashes, latest release `v0.65.2.2`, cask `0.64.25`.

### RC 9 (build 116, the B16 fix)

- RC: release.yml dry run [44151701525](https://github.com/manaflow-ai/cmux/actions/runs/44151701525) on
  `rc/cmux-next-handoff-dry-9` (feat-cmux-next `f06afba3` plus the build-116 Info.plist literal), release
  [rc9-b116](https://github.com/manaflow-ai/cmux-next-handoff-test/releases/tag/rc9-b116).
- Run B with leftover terminals: an RC 8 cmux-next made two terminal workspaces, its daemon was stopped
  so their hosts kept running, and its session and migration ledger were moved aside. Classic 0.65.2.2
  then updated to build 116. The new daemon recovered the hosts into "Recovered terminals", and cmux-next
  still asked "Import your classic cmux workspaces? 3 workspaces and 1 browser tab". After Import the
  sidebar lists Recovered terminals and the 3 classic workspaces; the ledger shows each `done` (no
  `baseline`). Screenshots `b9-1-prompt-with-recovered-terminals.png`, `b9-2-after-import.png` and the
  recording are on the release.
- Production unchanged after RC 9: the same six feed hashes, latest release `v0.65.2.2`, cask `0.64.25`.

## Go live (not taken)

Preconditions: every **Blocker** below closed; the RC passed the end-to-end test on a clean classic install
for the current classic release and one older release; one Intel classic run shows no update offered (B0b).

1. Land the build-number bump on feat-cmux-next: `CURRENT_PROJECT_VERSION` above both the newest classic
   build and every RC build handed out (the RCs used 114, 115 and 116, so ≥ 117). The exact change, in
   `cmux.xcodeproj/project.pbxproj` on feat-cmux-next: both `CURRENT_PROJECT_VERSION = 108;` lines (the
   Debug and Release configs of the cmux target) become `CURRENT_PROJECT_VERSION = 117;`
   (`./scripts/bump-version.sh 1.0.0` would write 109, too low: write the number by hand or run
   `bump-version.sh` after the edit). `Resources/Info.plist` reads `$(CURRENT_PROJECT_VERSION)`, so nothing
   else changes. The file is frozen (`FREEZE: cmux.xcodeproj/project.pbxproj token=none` in the
   coordinator's WINDOW, `~/fun/cmuxterm-hq/.cmux-scratch/nx-coordinator/WINDOW`; `prepush-gate.py`
   enforces it). Only Chief (the coordinator) grants a slot: it writes a token on that line, the commit
   carries `Freeze-Token: <token>`, and the line goes back to `none` after the push. Lawrence can order a
   slot directly (as on 2026-10-20).
2. Pin the final classic item (only if the cmux-next floor rises above 14.0):
   `skills/cmux-release/references/cmux-next-update-floor.md`.
3. Decide the release tag (`v1.0.0`) and changelog (`/release` flow on feat-cmux-next).
4. Add a phased rollout to the item (Sparkle `sparkle:phasedRolloutInterval`, seconds per group, 7 groups):
   `86400` ≈ 1/7 of automatic updaters per day over a week. Sparkle applies it only to background checks; a
   manual "Check for Updates" always offers the update. Set it with
   `gh variable set CMUX_STABLE_PHASED_ROLLOUT_INTERVAL -R manaflow-ai/cmux --body 86400` (**B9**).
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
| B0 | Blocker | `release.yml` had never built feat-cmux-next. Six dry runs found six breaks, each fixed on feat-cmux-next: no Zig (2361b768), Zig 0.16 instead of 0.17 for acpmux (f9f86e98), web bundles missing (8cd2edf8), arm64/x86_64 CEF versions differ (92de5acb), no Intel cmux-tui in the tree manifest (8005881e), classic `remote-daemon-status` query run on the Rust CLI (43c5b903). | Keep one dry run green per week until go-live. |
| B0b | Closed (Apple silicon only) | Only main and rc/** pushes build cmux-tui for Intel (cmux-next is arm64 only since 2026-11-12, and tree manifests are immutable), so a feat-cmux-next tag has no Intel `bin/cmux`. | Decision: cmux-next stable goes to Apple silicon only. release.yml now bundles the arm64 CLI for tags too and marks the appcast item `<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>` (`scripts/cmux-next/appcast-require-arm64.py`, test `tests/test_appcast_require_arm64.py`, run in the step). Sparkle 2.9+ (classic ships 2.9.5) skips that item on Intel, so Intel classic stays on classic 0.65.2.2. Risk: a classic build with Sparkle older than 2.9 ignores the element. To offer Intel later: build Intel cmux-tui on feat-cmux-next and Intel CEF (B6b), then drop the marker. |
| B0c | Closed | `release.yml` did not build or bundle the OptChat Chief (`bin/optchat-chief`), the iPhone host (`bin/cmux-mobile-host`) and the Screen Sharing helper, and the app started a bundled Chief only on DEV and NIGHTLY. | release.yml runs nightly's chief-build.sh, app-build-mobile-host.sh and app-bundle-chief-and-mobile-host.sh and checks all three are universal; `HomeBrainHost.bundledChiefAllowed` now also allows stable and RC (red/green suite `ChiefStableChannelTests`). Developer tools stay DEV and NIGHTLY only. This reverses c8ca87c2 ("Release and RC never bundle or start it"). |
| B6b | High | Intel CEF is pinned at cmux.48, arm64 at cmux.52. Since 92de5acb the build embeds arm64 CEF only, so an Intel Mac gets cmux-next with no Chromium browser. | Publish a cmux.52 x86_64 CEF before go-live. |
| B14 | Closed (lab config, not a product bug) | After the update the sidebar showed no workspace rows, although `cmux workspace list` returned all 5 workspaces. Root cause: the lab Mac's `~/.config/cmux/cmux-next.json` (written on 2026-11-16 by earlier nightly-next dogfood, before the runs) has `"sidebar": {"showProjects": false, "minimal": true}`, which hides the workspace list. No classic setting maps to it, and a fresh user gets `showProjects: true`. | Rerun with `showProjects: true` (see the RC 8 results). Possible polish: the import toast could say when Projects is hidden. |
| B16 | Fixed | cmux-next counted a "Recovered terminals" workspace (terminal hosts a previous cmux-next daemon left running) as a workspace of the person's own. On the first contact it then recorded a `baseline` ledger instead of asking, and the classic workspaces were marked `done` and never offered (RC 8 run B attempt 1, `b8-1-recovered-terminals-no-prompt.png`). | `needsFirstWorkspace` (`CmuxNextHomeEngine/FirstWorkspace.swift`) no longer counts the daemon's recovery workspace, first matched by the names cmux-tui gives it ("Recovered terminals", "復元されたターミナル"; red e8460bb9, fix f06afba3, suite `RecoveredTerminalsFirstUseTests`; re-proved in RC 9 run B with leftover terminals present). Now the daemon marks it: capability `workspace-recovered-v1`, field `recovered` on each workspace of the tree (true while every tab of the workspace is a recovered terminal host, read from the durable `recovered_terminal` launch spec; a tab the person adds makes it theirs). `needsFirstWorkspace` reads `WorkspaceModel.recovered` and uses the two names only when the daemon sends no field (an older daemon). Tests: cmux-tui `a_live_host_of_a_lost_registry_is_recovered_not_terminated`, suite `RecoveredWorkspaceMarkerTests`. No new RC: the change does not touch the update path. |
| B17 | Low | Classic 0.64.25 shows its "Quit cmux?" sheet when Sparkle relaunches it for the update; the install waits until the person clicks Quit. 0.65.2.2 does not ask. | Release note for older classic installs; nothing to change in cmux-next. |
| B15 | Medium | On cmux-next's first launch macOS 27 showed "Data Access Blocked: “cmux” tried to access your data from other apps". | Find the path (likely a classic-era container or another app's data during import) and avoid it or ask first. |
| B1 | Fix in review | feat-cmux-next `CURRENT_PROJECT_VERSION` is 108, classic stable is 113: classic would never take the update, and the tag push's monotonic guard (`enforce`) fails. | The release-channels PR bumps both lines to `117` in a commit of its own (`docs/cmux-next/release-channels.md`); it lands in a granted pbxproj slot or is dropped. The monotonic guard passes against 113. |
| B2 | Fixed | Socket access got looser: classic's Settings choice (UserDefaults `socketControlMode`) was ignored and next defaulted to `automation`. | Fixed in this change: `ControlService.classicStoredMode` falls back to classic's stored mode when `cmux-next.json` names none; `password` still fails closed to `off`. Suite `ControlServiceAccessModeTests` 3/3 on aws-m4pro-6. |
| B3 | High | Classic's packet-tunnel system extension (`com.cmuxterm.app.tunnel`) and its "cmux Cloud" VPN configuration are orphaned; cmux-next has no NetworkExtension code to remove them. | Ship a one-time cleanup in cmux-next, or a last classic build that deactivates it first. |
| B4 | High | Settings-window preferences are lost: only 4 link-routing keys and shortcuts import; theme, fonts, sidebar tint and about 170 other `@AppStorage` keys do not. No notice tells the user. | Import list or a toast naming what did not carry over. |
| B5 | High | Browser sign-ins are lost: classic WebKit `.default()` store and named profiles are not imported; cmux-next uses Chromium by default and its own WebKit store. The design doc claimed the opposite (corrected). | Cookie import from classic's WebKit store, or a first-run card. |
| B6 | High | No Intel Mac was reachable for the end-to-end run (cmux-aws-mac timed out). The DMG is universal; Intel launch is unproven. | One run on an Intel Mac before go-live. |
| B7 | Medium | `/usr/local/bin/cmux` silently becomes the cmux-tui CLI. Classic verbs (`send`, `new-workspace`, …) print a hint instead of working; scripts break. | Release note + verb shims for the top verbs. |
| B8 | Medium | Agent history (hook stores, agent journal) imports only through `scripts/cmux-next/classic-to-next.py`, not at first launch. | Fold into the launch migration or say so in the toast. |
| B9 | Fix in review | No phased rollout support in the stable appcast generator. | `scripts/cmux-next/appcast-phased-rollout.py`, run by release.yml when `vars.CMUX_STABLE_PHASED_ROLLOUT_INTERVAL` is set (test `tests/test_appcast_phased_rollout.py`). |
| B10 | Medium | Downgrade is one-way: work in cmux-next does not reach classic; signing out in one signs out both (shared keychain item). | Document; accepted. |
| B11 | Low | Homebrew cask is on 0.64.25, behind classic. | Fix the cask job before go-live. |
| B12 | Low | Shared UserDefaults domain: no full key-by-key type audit. Overlapping keys checked by name show no mismatch. | Audit before go-live. |
| B13 | Low | The design doc's staging step (`defaults write … SUFeedURL`) never worked on shipped classic. | Replaced by `classic-handoff-rc.sh` (this change). |
