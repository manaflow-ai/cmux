# cmux-next Mac build for the cnx-ios overnight work

Run this Mac build: `~/cnx-ios-builds/20261015-1e5ee66013-mac-prod/cmux NEXT iOS Test.app` (1e5ee6601315)

Branch `feat-cnx-ios-macnext` integrates every Mac-side fix for the cmux-next
iOS work. It is for dogfood builds only; it never merges anywhere. Each build
goes to `~/cnx-ios-builds/<date>-<sha10>-mac-prod/cmux NEXT iOS Test.app`
(bundle id `dev.cmuxterm.app.next.iostest`, the same identity as the earlier
side-by-side builds, so it replaces them). Quit the older "cmux NEXT iOS Test"
before opening a new one.

## What each merge brought

| Step | Commit | Brought in |
| --- | --- | --- |
| Base | `feat-cnx-ios-machost-d5` e1edf234 | machost lineage, supervisor restart fix 3df9ff77, round-4 daemon fixes (D4 attach wait), PR #20809 review fixes (one replay per reattach, 30 s grow-hold for dropped phones) |
| Merge | `codex-daemon-hooks-next-machost` 711ded36 | PR #20770: plain `codex` reaches notifications and the Feed (agent shim stays first on PATH, Codex daemon refuses inherited routes, hooks.state as one inline table), macOS duplicate-event fix. Clean merge. |
| Merge | `feat-cnx-ios-mactry-rbfix` c01e1c2c | everything of the earlier user build not in d5: approvals (in-app pairing sheet, identity key, pairing seed, browser-stream-v1 flag), Chief avatar (#20531), rbhost (Release builds embed and sign the remote browser host; ensure/publish scripts with the controller fallback), rbfix host pin 2765fa17 (CEF `--use-mock-keychain`). Clean merge (90 commits). |
| Merge | `feat-cnx-ios-rbfix` a1f01f2e | SECURITY.md note: the browser host never reads the login Keychain. |
| Merge | `feat-cnx-ios` 3d2a8581 | the phone side's `cnx-ios/rust` (WireGuard RTP media lane, relay path labels, roam announcements), so the bundled cnx-hostd matches the phone build. Outside `cnx-ios/` it only adds iOS-only CmuxTabsKit files. `cnx-ios/rust` now equals feat-cnx-ios except `cnx-hostd/src/chief_policy.rs`, which keeps the Chief avatar fields (`chief.engine.set {avatar}`, `chief-profile-changed`). |
| Commit | b20242a0 | a Release cmux-next app always bundles cnx-hostd built from its own source (below). |
| Merge | `feat-cnx-ios-agentcwd` e0f1c3bf (via feat-cnx-ios-parity) | the phone may start agent chats in the folders of the person's workspace tabs: acpmux `_acpmux/workspace_roots_set`, the Mac sends its tab folders on the person connection while iPhone connections are on. SECURITY.md conflict resolved by keeping both sections. Trust-policy item for #13742; the user approved it for dogfood (2026-10-14 night). Parity commit 7582c2aa (drop a duplicate test) is not needed here: this tree has one copy of that test. |
| Merge (round 2) | `feat-cnx-ios` 30e51dff | acpmux replies over 16 KiB that the link splits into chunks join again (phone side); `cnx-ios/rust` stays equal to feat-cnx-ios except the Chief avatar fields. iOS-only outside `cnx-ios/`. Clean. |
| Merge (round 2) | `feat-cnx-ios-parity` 52e2b628 | Mac side: `CnxApproverSync.rootsClearPending`, so acpmux gets an empty workspace-folder list once after iPhone connections turn off, even with no approvers left; plus the parity tab actions on the phone and the agentcwd decision text (cc91107b). SECURITY.md conflict resolved to the parity text for the agentcwd and parity sections, keeping this branch's pairing-seed and Feed sections. No unit test exists for CnxApproverSync (it needs a person-proven acpmux socket); the logic was reviewed: turning connections off makes the folder stream yield `[]`, `updateWorkspaceRoots([])` sets the pending flag, a proven connection sends `[]` at once, otherwise `needed` stays true until a connection is proven and `send()` delivers it. The Release build compiles it. |
| Merge (round 3) | `feat-cnx-ios` aa685b82 | parity round 2, Mac side (61bdd4de, 35a1c8a3, 102cf50b, 3f475855, 93d588f7, 1585ab34, a432d416, ea83f361): a phone-started Codex chat starts in Codex's asking mode; cnx-hostd refuses phone prompts to sessions whose current mode does not ask; the remote sandbox opens only Claude's real endpoint (proxy agents work); restart-tab; the phone's sidebar order and unpin checked against the Mac's own; notification.clear; the Mac's last-picked agent as the phone's default. Clean merge. `cnx-ios/rust` equals feat-cnx-ios except the Chief avatar fields (cnx-hostd key `e5697f409291ea8f`). |

Checked and not needed in round 2: `feat-cnx-ios-termqa` has no daemon or Mac commits since 9063df14; PR #20809's head (c53859d8) adds only a merge of feat-cmux-next after 9db5f180, whose fixes are already here through machost-d5.

Not merged: PRs #20757, #20770 and #20809 stay open against their bases.

## cnx-hostd is always in a Release app

Before: the "Bundle cnx-hostd" phase skipped a Release build silently when
`CMUX_NEXT_CNX_HOSTD_BIN` was unset, and Linux-pool fleet builds shipped no
cnx-hostd (fleet side fixed in cmuxterm-hq #2091). Now (b20242a0):

- `scripts/cmux-next/bundle-cnx-hostd.sh` fails a Release build that has no
  cnx-hostd, or whose `.ref` names another source key than this checkout
  (`build-cnx-hostd.sh --print-key`). `CMUX_NEXT_CNX_HOSTD_OPTIONAL=1` is the one
  explicit opt-out (set only on the dev-daily Release compile, which never built it).
- `scripts/reload.sh` stops a Release build before the compile when no cnx-hostd
  can be built on that machine.
- `release.yml` builds cnx-hostd for the app bundle, as nightly-next does.
- Test: `scripts/cmux-next/tests/bundle-cnx-hostd-release.test.sh` (in cmux-next.yml).

## Builds

| When (UTC) | SHA | Fleet job | Path | Result |
| --- | --- | --- | --- | --- |
| 2026-10-15 08:20 | 1e5ee660 | prod cbf2ed30 (aws-m4pro-3), rig cnx-e2e-1e5ee660 16077cda (linux pool) | `~/cnx-ios-builds/20261015-1e5ee66013-mac-prod/cmux NEXT iOS Test.app` | all checks pass (below) |
| 2026-10-15 05:20 | 9063df14 | prod cbd41d5d (aws-m4pro-3), rig cnx-e2e-9063df14 79c6e58c (linux pool) | `~/cnx-ios-builds/20261015-9063df1493-mac-prod/cmux NEXT iOS Test.app` | bundle checks pass; live checks below |

## Verification of 9063df14

Bundle (headless, on this Mac and a copy on mini-cmux10s-mac-mini):

- `codesign --verify --deep --strict`: pass.
- `Resources/bin/cnx-hostd`: universal (arm64, x86_64), `.version` key `538d774e0f4acec6`, which is
  `build-cnx-hostd.sh --print-key` of 9063df14; the binary carries `browser-stream-v1`.
- Embedded `Helpers/cmux-remote-browser-host.app` rendered https://example.com with
  `rb-host-http-frames.sh` (first frame 553 ms) on mini-cmux10s, from a copy of the app.
- `Resources/bin/cmux-tui` (the daemon) is built from 9063df14 (`cmux-tui.version`), with the
  departed-phone grid hold (`terminal-grid-hold`, D4/D5 attach) and the Codex agent shims kept
  first on PATH (`_cmux_tui_agent_shims_first`).

Live rig (mini-cmux10s-mac-mini, tag cnx-e2e-9063df14, iOS Demo build of this tree in one
headless iOS 26.5 simulator; the rig app is an unmodified copy of the fleet build, settings
via `open --env`; no Keychain prompt, no SecurityAgent):

| Check | Result |
| --- | --- |
| Journey to a terminal (fresh install, sign-in, space, Mac discovered, workspace list, open workspace) | pass (run2, 05:49 UTC); link WebRTC direct |
| Browser tab streams (https://example.com in the seed workspace, opened from the phone's tab grid) | pass by evidence: the phone shows the page (screenshot `verify/rig-phone-browser-example-com.png` in the build folder, overlay `3 fps · track · latency 209 ms`), hostd logs `browser: video on the link's media lane`. The step's OCR needle was stale (example.com changed its copy); fixed in the rig, rerun below. |
| cnx-hostd kill, WebRTC (3 SIGKILLs, 20 s apart) | pass: link up 1.86, 1.96, 1.57 s after the kill (supervisor restart ~1.0 s, then ~0.7 s to link up); the phone's terminal input reached the Mac after each |
| Transport WebRTC to WireGuard and back | pass: WireGuard Connected in 7.9 s, back in 7.7 s, terminal input on both |
| Transport WireGuard (stays on), run4c | pass: Connected in 7.8 s |
| Browser tab streams over WireGuard, run4c | pass: the page is on the phone 4.9 s after opening the tab from the grid (includes starting the browser host) |
| cnx-hostd kill over WireGuard (3 SIGKILLs) | pass: link up 1.81, 2.26, 1.88 s after the kill (median 1.88), WireGuard via relay; terminal input reached the Mac after each |
| Plain `codex` in a terminal produces a Feed item (real model call) | pass, on a laptop rig (hidden app, `open -g -j` + `open --env`, headless simulator, the laptop's codex 0.162.1 login; the minis have no working Codex login): finished turn in the Feed 16.1 s after the prompt; the approval showed as Needs input after 74.5 s; Answer in Terminal opened the tab. Command: `codex --sandbox read-only --ask-for-approval on-request` (no `--no-daemon`). |

Both rigs were quit and their simulators deleted; no Keychain prompt or SecurityAgent on either
Mac. Evidence: mini-cmux10s `~/cnx-macnext/evidence/run{2,3,4c}/`, laptop
`~/cnx-ios-builds/20261015-9063df1493-e2e/evidence-codex/`.

Notes:
- Same-host rig: on mini-cmux10s the simulator and the rig Mac share one machine; WebRTC picked
  a direct path, WireGuard a relay path. The phone side used the real link either way.
- The default transport in the iOS Demo config is still WebRTC.
- Not folded: parity commit cc91107b (SECURITY.md and 13742-recommendation.md text for the
  agentcwd decision; the code is already here through feat-cnx-ios-agentcwd).

## Verification of 1e5ee660 (round 2)

Bundle: `codesign --verify --deep --strict` pass; cnx-hostd universal, key `538d774e0f4acec6` =
this commit's `--print-key` (`cnx-ios/rust` unchanged since 9063df14, so the fleet reused the
key-addressed binary; its `.version` names commit 9063df14); `browser-stream-v1` present; the
embedded browser host rendered https://example.com (first frame 740 ms, from a copy on
mini-cmux10s); the daemon still has the grid hold and the Codex shim fix; the app binary
carries `workspace_roots_set`.

| Check (rig cnx-e2e-1e5ee660) | Result |
| --- | --- |
| Journey to a terminal, WebRTC (mini-cmux10s, r2a) | pass, 6 steps |
| Browser tab streams, WebRTC | pass: page on the phone 5.0 s after opening the tab |
| cnx-hostd kill, WebRTC | pass: link up 1.70, 1.83, 1.87 s (WebRTC direct); terminal input after each |
| WireGuard on (r2b) | pass: Connected in 8.4 s |
| Browser tab streams, WireGuard | pass: 5.7 s |
| cnx-hostd kill, WireGuard | pass: link up 1.47, 2.03, 2.11 s (median 2.03, WireGuard relay) |
| Plain `codex` produces a Feed item (laptop rig, same conditions as round 1) | pass for the Feed item: "Codex · Finished." arrived (screenshot `verify/codex-feed-item.png` in the build folder). The step's second half (an approval as Needs input) did not finish: Codex (GPT-6-Astra, max effort) was still "Working" 2 min 30 s after the file-write prompt, so no approval was asked within the 150 s limit. Not rerun, to keep the Codex run to one turn plus one approval. |
| `rootsClearPending` live | not observed: the app's `app.iphone.approvers` log lines are not readable over ssh on the mini, and acpmux keeps the list in memory only. Turning iPhone connections off in the rig's settings file stopped cnx-hostd as expected. |

No Keychain prompt or SecurityAgent on either Mac; both rigs quit, their daemons stopped and
their simulators deleted.
