# Full app verification (fresh verifier), 2026-10-19

Status: done, 2026-10-20 02:40 UTC. **Overall: FAIL** (Chief unusable over the link on this rig, team creation broken, artifact previews refused, Feed scroll hitches; details below).

Lane: everything except the terminal, tab UX and transports (onboarding and
account, Home, Workspaces, Feed, Chief, agent chat, files and diffs, Settings,
Mac parity).

## Build under test

- Phone: `3e6a2b56eff` (the cmux INTERNAL 1.2.0 commit), Demo configuration,
  `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`, bundle `dev.cmux.cnx` 1.2.0 (1), dev
  Worker `cnx-ios-api-dev.debussy.workers.dev`. Built with Xcode 26.6 on
  mini-cmux7s (Xcode 26.3 on mini-2 fails at
  `CmuxTabsKit/UI/Toolbar.swift:391: ambiguous use of operator '-'`), then
  copied to mini-2. CnxFFI.xcframework from the rig cache, key
  `ccc2097337090383` (the sha1 of this commit's `cnx-ios/rust`,
  `cmux-wg`, `cmux-transport` trees).
- One headless simulator `cnx-fv-1` (iPhone 17 Pro, iOS 26.3, the only
  runtime on mini-2) on `mini-cmuxs-mac-mini-2`. Simulator.app is never
  opened by this run.
- Mac: fleet build `cnx-e2e-90375ce5` (job `b65d313ac0f91b52bbb59726`). It
  is the Mac half of this commit: `git diff 90375ce5e1 3e6a2b56eff` touches
  only `cnx-ios/CnxKit/Sources/CnxShell/RootView.swift` (phone),
  `cnx-ios/scripts/testflight-build.sh` and the TestFlight workflow, so the
  Mac app, cnx-hostd, daemon and acpmux sources are identical. An unmodified
  copy runs hidden (`open -g -j -n`) on mini-2; every setting goes in with
  `open --env` (`verify/parity/rmac.py`). Device id `1d1915d9…e14e`, shown
  on the phone as "cmux’s Mac mini (2) E14E".
- Account: the DEBUG dev credential (email step "42").
- Driver: `verify/fullverify/fv.py` on the mini (AXe HID taps, typed
  text); `fvr.sh` runs it from the laptop. Mac CLI only reads state.

Evidence (git-ignored): `verify/evidence/2026-10-19/full-verify-app/`
(`shots/*.png`, `video/*.mp4`), mirrored from `~/cnx-fv/evidence` on mini-2.

## Results

(First pass, 01:50 to 02:35 UTC. Shots `shots/NN-*.png`, videos `video/NN-*.mp4`.)

### 1. Onboarding and account (`video/01-onboarding.mp4`, `02-team-sidebar.mp4`)

| Check | Result | Evidence |
| --- | --- | --- |
| Fresh install: Welcome with Google, GitHub, email | Pass | `01-welcome.png` |
| Sign in (email step, dev credential) | Pass: "Choose a space" in about 4 s | `02-email-step.png`, `03-choose-space.png` |
| Choose a space > Personal, Connect your Mac (Mac online), Continue | Pass | `04-connect-mac.png`, `05-after-connect.png` |
| Sign up with a new email | Blocked: no inbox for a new address on this rig; only the shared sign-in screen was checked | — |
| Mac approval: phone shows "Approve this iPhone on cmux’s Mac mini (2) · Look for cmux on your Mac" | Pass (phone side) | `09-my-mac.png` |
| Mac approval: approving on the Mac | Not done in the Mac's UI: the rig app is hidden. Approved with the DEBUG pairing seed by the phone's link device id `ff8d711c…` (no name match), then the seed was emptied | `10-paired-list.png` |
| Approval persists (relaunch with the seed empty) | Pass: `paired-devices.json` holds the phone; list loads | — |
| Sign out (Settings > Sign out > confirm) | Pass: back to Welcome | `14-signout-confirm.png`, `15-signed-out.png` |
| Sign back in: same identity, no second approval | **Pass**: same device id `ff8d711c…` in every `link up`, seed empty, no approval banner, workspaces listed | `16-resignin-workspaces.png` |
| Sidebar: team list with Mac dots and "+N" | Pass ("4 of 56 Macs online") | `17-sidebar.png` |
| Team color and icon (long press > Change color and icon) | Pass: Purple + "Z" shows in the sidebar and Settings, persists across relaunch | `24`–`26`, `89-sidebar-after-relaunch.png`, `88-settings-after-relaunch.png` |
| Create team (+ > Create team) | **Fail (D1)** | `19`–`22` |
| Team switching | Blocked by D1 (only Personal exists for this account) | — |
| Invites (Invite to team, Join with invite link) | Blocked by D1 (Personal has no invite) | `18-add-team-menu.png` |
| Device removal (Settings > Devices > Edit > remove "cmux’s Mac mini (2) E14E" > Remove) | Pass: the row leaves the list; the Mac's hostd logs "this Mac was removed from the account's devices; stopping" (4002 removed) within 5 s | `94`–`97`, `video/10-device-removal.mp4` |

### 2. Home and Workspaces (`video/03-workspaces.mp4`)

| Check | Result | Evidence |
| --- | --- | --- |
| "Home" is not a workspace | Pass: the Mac lists `Home {"kind":"home"}`; the phone lists only real workspaces | `27-new-workspace.png` |
| New Workspace (tap) | Pass: created on the Mac in under 4 s ("New Workspace", folder ~). The phone stays on the list (it does not open it) | `27-new-workspace.png` |
| Rename | Pass on the Mac; but see D5 (autocorrect rewrote "Fvrenamed" to "Renamed") | — |
| Duplicate Workspace | Pass: a second "Renamed" on the Mac | `29-duplicated.png` |
| Close Workspace (with confirm "Its tabs close on …") | Pass: gone on the Mac | `30-close-confirm.png` |
| Search | Pass: "work" filters to workspace-1 | `31-ws-search.png` |
| Workspace groups: Move to New Group | Pass: `grp_9f0d…` "New Group" on the Mac (`workspace group list`) | `34-grouped.png` |
| Group menu (Rename, Color, Collapse, Ungroup, Delete) | Present | `35-group-header-menu.png` |
| Saved tab groups (Reopen / Delete Saved Tab Group) | Not run in this pass (tab lane overlap) | — |
| Live status line on a row ("Codex is working · …") | Pass | `36-feed.png` (taken while still on Workspaces) |
| Mac section header "Connect" | **Fail (D7)**: tapping the row does nothing; only Filter > the Mac connects | `07-connect-e14e.png`, `09-my-mac.png` |

### 3. Feed (`video/04-feed.mp4`)

| Check | Result | Evidence |
| --- | --- | --- |
| Codex (terminal, real model) finished event reaches the Feed | Pass after installing the cmux-tui agent hooks on the mini (`cmux agent hook install codex claude`; the mini had none, backups in `~/cnx-fv/*.backup.json`) | `38-feed-codex-finished.png` |
| Claude Code (terminal) events | **Blocked**: mini-2's `claude` (and `claude-real`) get "503 no accounts available" from the team subrouter | — |
| Permission request from a phone-started Codex chat shows as "Needs you" with the command | Pass, in 27 s from send | `51-feed-needs-you.png` |
| Inline Allow once from the Feed (Face ID match) reaches the agent | Pass: `codex_perm.txt` = "okay" on the Mac; card reads "Allowed: Allow" | `53-feed-after-allow.png` |
| Filters All / Needs you / Finished / Errors | Pass ("No matching events" when empty; Needs you count badge) | — |
| Tab badges (Feed, Workspaces) | Pass: "1" on both | `51-feed-needs-you.png` |
| Open routes to the right place | Pass: the Codex terminal of `agent-codex`; the chat for a chat event | `39-feed-open-route.png`, `54-codex-after-allow.png` |
| Notification taps | Blocked: Demo build in a simulator gets no APNs ("Notifications from your Macs need the TestFlight build") | `81-notifications.png` |
| Scroll performance (86 real events from the Mac, 12 finger flings, in-app frame log `CNX_FRAMELOG=1`) | **Fail (D10)**: 1479 frames, p50 16.7 ms, p95 16.7 ms, p99 49.2 ms, max 234.5 ms, 47 hitches, 152 dropped frames, 91.3 hitch ms/s (simulator on a mini, load about 5) | `feed-framelog.jsonl`, `video/09-feed-scroll.mp4`, `90-feed-load.png` |

### 4. Chief (`video/07-chief.mp4`)

| Check | Result | Evidence |
| --- | --- | --- |
| Open Chief | **Fail (D2)**: endless spinner, no error | `70`–`75` |
| Send a message | **Fail (D3)**: the composer clears and the message disappears, no bubble, no error | `73-chief-send.png` |
| Receive, attachments, quote bubbles, search | Blocked by D2 | — |

### 5. Agent chat (`video/05-agent-chat.mp4`)

| Check | Result | Evidence |
| --- | --- | --- |
| New Agent Chat With… sheet: harnesses with Ready / Unavailable + reason, model list | Pass | `41-agent-chooser.png`, `47-chooser-model.png` |
| Codex, default model | **Fail (D4)**: "Default (gpt-6.1-sol)" fails at once on this Mac's Codex account; the raw JSON error is shown | `44-codex-sent.png`, `45-composer-expanded.png` |
| Codex, GPT-6 Astra, Ask mode: streaming, tool call, permission card, Allow once (Face ID) | Pass: permission card in 27 s, file written, "PONG" | `48`, `49`, `55-codex-pong.png` |
| Stop, then a new prompt | Pass: "Stopped", then "RESUMED" | `57-after-stop.png`, `58-resumed.png` |
| Claude Code chat | **Fail/Blocked (D8)**: Start Chat with Claude Code does nothing (no tab, no message); Claude is also blocked on the mini (503) | `77-claude-start.png` |

### 6. Files and diffs (`video/06-files-diff.mp4`)

| Check | Result | Evidence |
| --- | --- | --- |
| Changes card on a real turn (2 files, +3 −1), file list, Mark as viewed | Pass | `61-edited.png`, `62-diff-viewer.png` |
| File diff (removed/added rows, Previous/Next file) | Pass with D6 (no line numbers) | `63-diff-readme.png` |
| Files and Artifacts list | Pass (README.md Edited, call.py Created · 3 lines) | `67-artifacts-sheet.png` |
| Preview a file the phone's own chat edited | **Fail (D9)**: "Can't open this file … isn't sharing any folders with this phone yet" | `68-artifact-preview.png` |

### 7. Settings (`video/08-settings.mp4`)

| Check | Result | Evidence |
| --- | --- | --- |
| Appearance Dark | Pass, persists across relaunch | `88-settings-after-relaunch.png` |
| Haptic feedback off | Pass, persists | — |
| Require Face ID | Pass: relaunch asks Face ID, a match opens the app; persists | `87-relaunch-faceid.png` |
| Notifications > Allow notifications | Pass: system prompt, then "On"; row reads "Chief only" after relaunch | `82`, `83` |
| Terminal font size 12 → 14 pt, Wrap code and diff lines | Pass, persist | `84-terminal-settings.png` |
| Composer: Follow-up while running | Menu opened but its items were not in the accessibility tree; not changed | `85-composer-settings.png` |
| Account page | Pass (sign-in methods, Delete Account present; not exercised) | `12-account.png` |

### 8. Parity (`verify/parity-mac.md`), items in this lane

| Mac action | Phone | Result |
| --- | --- | --- |
| New Workspace (⌘N) | New Workspace tap | Pass |
| Rename / Close / Duplicate Workspace | row menu | Pass (rename text autocorrected, D5) |
| Pin Workspace | row menu | Pass: "Pinned" section |
| Mark Workspace as Unread | row menu > Options | Pass on the phone row ("Done"); the Mac CLI shows no metadata to cross-check |
| Workspace groups | Group > Move Workspace to New Group | Pass (on the Mac) |
| New Agent Chat With… (harness, model) | + > New Agent Chat With… | Pass for Codex with an explicit model; D4 for the default model; D8 for Claude Code |
| Allow once / Deny | permission card (chat and Feed) | Pass (Allow once, Face ID) |
| Stop | composer Stop | Pass |
| Changes: last turn, Mark as viewed | Changes card, file diff | Pass (D6) |
| Files (folder split) | More > Files and Artifacts | List passes; preview fails (D9) |
| Chief conversation | Home > Chief | Fail (D2, D3) |
| Show Feed, filters | Feed tab | Pass |
| Clear All Notifications, Mute workspace, Reopen Saved Tab Group, Fork, Archive, Queue edits, Continue in…, Restart Shell | — | Not run in this pass (time; several are tab-lane items) |

## Defects (ranked)

| ID | Severity | Area | Defect | Steps to reproduce |
| --- | --- | --- | --- | --- |
| D2 | Critical (rig) / High (phone) | Chief | Chief never loads over the link from a DEV/tagged Mac: hostd dials `cmux-chief-<hash of ~/.cmux/chief/default>`, but a DEV build's Chief home is `~/.cmux/chief/<bundle id>` (`ChiefHome` rule 4) and the app never sets `CnxHostLaunch.chiefSession` (no setter in `Packages/macOS/CmuxNext/Sources`), so hostd refuses every `chief` channel ("cmux-tui session chief: No such file or directory"). Passing `CMUX_NEXT_CHIEF_ACCOUNT` at launch does not reach hostd. A NIGHTLY/Release Mac with the default account may not hit this; not verified. On the phone the Chief screen spins forever with no error or retry. | Pair with a tagged DEV Mac; Home > Chief. |
| D3 | High | Chief | A message sent while Chief is unavailable disappears: the composer clears, no bubble, no "not delivered", no error. | With D2, type "Hello Chief…" and tap Send (`73-chief-send.png`). |
| D1 | High | Teams | Create team fails silently: the request returns HTTP 200 and the success haptic fires, but the team never appears in the sidebar (also after relaunch), so team switching and invites cannot be reached. | Sidebar > + > Create team > a name > Create (`19`–`22`). |
| D9 | High | Files | Files and Artifacts lists files the phone's own Codex chat edited, but opening one says "cmux’s Mac mini (2) isn't sharing any folders with this phone yet … Settings › General › Chats › Chat Folders", although the chat was started in that workspace's folder from the phone. | Phone: New Agent Chat With… Codex in `agent-codex`, ask for an edit, More > Files and Artifacts > README.md (`68-artifact-preview.png`). |
| D4 | High | Agent chat | A phone-started Codex chat defaults to "Default (gpt-6.1-sol)", which this Mac's Codex account rejects; the turn fails with a raw JSON error toast (`{"type":"error","status":400,...}`) on top of the "Agent stopped" card. The composer of a running chat has no model menu to switch (only Add: Mention a File, Files, Photos, Camera); the user must start a new chat with a model. | New Agent Chat With… > Codex > Start Chat > send (`44`, `45`). |
| D10 | Medium | Feed | Scroll hitches with 86 events: 91 hitch ms/s, max frame 234 ms (simulator; repeat on a device). | Seed events, fling the Feed (`feed-framelog.jsonl`). |
| D8 | Medium | Agent chat | Start Chat with Claude Code does nothing: no tab, no toast, no error. (Claude is also unusable on mini-2, see Blocked.) | `agent-claude` > Tabs > + > New Agent Chat With… > Claude Code > Start Chat (`77-claude-start.png`). |
| D5 | Medium | Text entry | Name fields and the agent composer autocorrect: "fv team" became "Fav team", "Fvrenamed" became "Renamed", "calc.py" became "call.py" in a prompt (Codex then created `call.py`), "fvperm" became "perm". Code-oriented fields should turn autocorrection off. | Type those strings in Create team, Rename Workspace, the agent composer. |
| D7 | Medium | Workspaces | The Mac section header's "Connect" does nothing; the phone kept waiting on another Mac's approval ("Approve this iPhone on cmux’s Mac mini") until Filter > the Mac was used. With many Macs of the same name only the 4-character suffix tells them apart. | Fresh sign-in with several Macs; tap a header's Connect (`07-connect-e14e.png`). |
| D6 | Low | Diff | No line numbers in the file diff gutter; every row's accessibility label says "line 0". | Changes > README.md (`63-diff-readme.png`). |
| D11 | Low | Workspaces | While loading, the Mac section headers draw over the skeleton rows (text overlapped). | Fresh sign-in > Workspaces (`07-connect-e14e.png`). |
| D12 | Low | Feed | Codex "finished" events read only "Finished." (the Mac notification body is empty too); a permission row reads "Allowed: Allow". | `38`, `53`. |
| D13 | Low | Home | The Home row preview for a chat shows an older agent line ("I’ll update both files…") instead of the last reply. "You don't have a Cloud Chief yet / Create Cloud Chief" shows for a moment after launch and then goes away. | `69-home.png`, Home after relaunch. |
| D14 | Low | Accessibility | A new workspace row's label says "in 10 seconds" while the screen says "now"; the team emoji "🧪" renders as a "?" box on the iOS 26.3 simulator (may be the runtime's font). | `29-duplicated.png`, `03-choose-space.png`. |
| D15 | Low | Files | Files and Artifacts opened about 5–9 s after the menu tap once (a second open took 1 s). | `65`, `66`. |

## Blocked, and why

- **Claude Code on the Mac rig** (terminal and phone chats): mini-2's `claude`
  wrapper (and `claude-real`) answer "503 no accounts available" from the
  team subrouter. Codex works (API key). All Claude items are unverified.
- **Chief** send/receive, attachments, quote bubbles, search: D2 (no Chief over
  the link on a tagged Mac).
- **Team switching and invites**: D1 (no second team can be created; Personal
  has no invite).
- **Sign up** with a new email: no inbox on the rig.
- **Mac-side approval UI** (the Mac's Allow sheet): the rig app is hidden; the
  DEBUG pairing seed by device id approved the phone instead.
- **Notification taps**: the Demo build in a simulator gets no APNs
  (Settings says Mac notifications need the TestFlight build).
- Not run for time: saved tab groups, Clear All Notifications, Mute, Fork,
  Archive, Queue, Continue in…, Composer "Follow-up while running" change
  (its menu items were not in the accessibility tree).

## Rig changes made and undone

- `cmux agent hook install codex claude` on mini-2 (the mini had no cmux-tui
  hooks, so no agent event reached any Feed); `~/.codex/hooks.json` and
  `~/.claude/settings.json` were restored from backups at the end.
- The rig's `rmac.py` copy on the mini got `FV_NO_SR=1` (launch without the
  subrouter route) for the Claude attempt; it did not help (above).
- Cleanup: rig app quit and its leftover Chief daemons killed, simulator
  `cnx-fv-1` shut down and deleted, `~/cnx-fv` and the copied xcframework
  cache removed from mini-2, the temporary build tree removed from
  mini-cmux7s. The stale rig `cnx-e2e-604fc689` on mini-2 (another agent's,
  serving a phone `f4ad4f2f…` during this run) was left running.
