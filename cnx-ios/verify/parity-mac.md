# Phone parity with the cmux-next Mac app

Branch `feat-cnx-ios-parity`, 2026-10-14. The person's report: "I can't create
browser tabs or GUI sessions on iOS. GUI sessions should open model-agnostic,
not with New Claude Chat. I should be able to do everything I do on cmux-next
Mac on my phone."

The Mac's actions come from its action catalogs (`Packages/macOS/CmuxNext/Sources/CmuxNextActions/Catalog/*`,
`origin/feat-cmux-next` c6416c53) and the agent pane strings
(`webviews/src/agent-session/acpmux/generated/strings.json`).

States: **works** (on the phone and verified), **partial** (on the phone with
a stated limit), **missing** (not on the phone yet), **not from a phone**
(kept off the phone on purpose, with the reason).

## Creation (priority 1)

| Mac action (wording) | Mac sends | Phone | State | Notes |
| --- | --- | --- | --- | --- |
| New Agent Chat (⌘I) | acpmux `session/new` (harness from the last pick, else acpmux `defaultHarness`), daemon `new-conversation-tab` | + > **New Agent Chat** | works (round 2) | One model-agnostic entry. Round 2: it starts where the Mac's would: the Mac's last pick in the workspace folder, then its last pick anywhere, then the agent it picked last, then acpmux's `defaultHarness` (a pick the phone can't start is skipped). The Mac app hands its `newTab.lastPicks` to acpmux over its person connection (`_acpmux/new_chat_picks_set`, memory only) and `_acpmux/harnesses` shows them (`lastPicks`). Unit-tested on both sides; not driven live (the rig app is hidden, so nobody picks on its New Tab page). |
| Harness and model picker (chip: "Harness", "Model"; "Unavailable" + reason) | `session/new` then `session/set_model` | + > **New Agent Chat With…** (sheet "New Agent Chat": Harness, Model, Start Chat) | works (round 2) | acpmux now says per agent what a phone may start (`remote: {startable, modes}` or the reason). **Codex** (the `codex app-server` bridge, the Mac's `codex` profile) is startable: a phone-started Codex chat begins in the bridge's **Ask** mode (approval policy `untrusted`: Codex asks before every command that is not a known-safe read and before every file change), with acpmux policy `ask`, so each approval reaches the phone and Allow needs Face ID. The codex-acp adapter and **opencode** stay "Not available from here: this agent has no mode that asks before each change" (opencode starts every agent from allow-all and merges the user's rules last). A Mac without the `remote` row keeps Codex refused. |
| Agent chat in a workspace folder | `session/new {cwd}` (the pane's folder) | same | works (this branch) | Needed `feat-cnx-ios-agentcwd` (acpmux `_acpmux/workspace_roots_set`), merged here. A workspace still at home gets "Agent chats start in a project folder…". A folder Claude has never been trusted in waits on the Mac's trust question (see Gaps). |
| New Terminal Tab (⌃`) | `new-tab {cwd}` | + > **New Terminal** | works | hostd picks the pane's folder (`with_pane_folder`); the phone never sends `cwd`. |
| New Browser Tab (⇧⌘L) | `new-frontend-browser-tab` | + > **New Browser Tab** | works on a Mac that streams (`browser-stream-v1`) | An older Mac now keeps the entry; a tap says "Update cmux on <Mac> to open browser tabs from your phone." (was: silently missing). |
| New Workspace (⌘N) | `create-workspace`, `create-terminal {cwd}` | **New Workspace** (tap) | works | Mac default folder (home). |
| New Workspace in a folder / Open Folder… (⌘O) / New Workspace Like This | `create-workspace` + `create-terminal {cwd}` | New Workspace (hold) > **Recent Directories**, **Open Folder…** (parity2) | partial | Recent Directories: the folders of the Mac's workspaces and the ones used on this phone. Open Folder… takes a typed full path (`/…`, `~`, `~/…`); a relative path is refused with "Type the folder's full path on <Mac>, starting with / or ~/.". The new terminal types `cd '<folder>' && clear`, since the phone sends no `cwd`; a folder with a control or format character, a backslash or `!` is never typed ("Open it in cmux on <Mac>"). A folder that does not exist shows the shell's own `cd` error in the new terminal. Not possible from a phone: browsing the Mac's folders (no file picker over the link). |
| New Browser Workspace (⌥⌘N) | `new-frontend-browser-tab` | New Workspace (hold) > **New Browser Workspace** | works | |
| New Agent Chat over Home (a workspace whose only tab is the chat) | `create-workspace`, `new-conversation-tab` | — | missing | Two steps on the phone: New Workspace in a folder, then New Agent Chat. |

## Tabs

| Mac action | Mac sends | Phone | State | Notes |
| --- | --- | --- | --- | --- |
| Close Tab (⌘W) | `close-surface` | grid ×, page menu Close Tab | works | Asks first when a program runs. |
| Rename Tab… (⌘R) | `rename-surface` | page and card menu **Rename Tab…** | works (this branch) | Rolls back on refusal. |
| Duplicate Tab | `new-tab` / browser duplicate / a second tab of the chat | page and card menu **Duplicate Tab** | works (parity2 tabs) | Terminal: a new terminal in the tab's pane (hostd's folder choice). Browser: the same http(s) page. Agent chat: a second tab of the same chat (`new-conversation-tab` with the tab's session), as the Mac's `duplicateAgentTab`; never a copy of the conversation (that is Fork). |
| Move Tab Left / Right, drag | `move-tab` | drag in the grid | works (parity2 tabs; live run pending) | Within the tab's pane (insertion index as the daemon reads it); a drag onto another pane's tab says to move it on the Mac. A real long press and drag is proven by an XCUITest (`CnxAppUITests/TabReorderUITests`: first card to the third slot, iOS 26.5 simulator, mock data); `pq_tabs.reorder` runs it against the rig Mac. |
| Move Tab to Workspace… / Move Tab to New Workspace | `move-tab-to-workspace {surface, workspace}`, `move-tab-to-new-workspace {surface, name}` | page menu **Move Tab to Workspace…** (a picker of this Mac's other workspaces), **Move Tab to New Workspace** | works (parity2 tabs; live run pending) | The Mac's More rows, so on the phone they are in the page menu (the card menu has no room). The new workspace is named by the Mac's rule (`NewWorkspaceName`: a last tab keeps its workspace's name; else the tab's name, page title or host, terminal title unless a bare shell, then its folder). The tab keeps its terminal, page or chat; the phone stays in the source workspace (the Mac's own view is its own) and says "Moved <tab> to <workspace>."; leaving it when that was the last tab. |
| Move Tab to New Split / Column, Move Tab to Pane Left / Right / Above / Below, Previous / Next Pane | `move-tab-to-split`, `move-tab-to-column`, `move-tab` across panes | — | not applicable (decision) | The phone shows a workspace's tabs as one list and has no panes to aim at; a pane move would change the Mac's layout with nothing on the phone to show it. Left off the phone on purpose; the commands stay allowlisted for a future pane view. |
| Pin Tab / Unpin Tab | `set-tab-pinned` | page and card menu **Pin Tab** / **Unpin Tab** | works (parity2 tabs; live run pending) | Here at once, rolled back on refusal. A pinned tab's card icon is a pin; the Mac sorts pinned tabs first in their pane. |
| Split Right / Down, New Column / Row, Zoom Pane | `split`, `new-pane-right`, `new-row`, `zoom-pane` | — | not applicable | The phone shows one tab at a time; panes are a Mac layout. |
| Reopen Last Closed Tab (⇧⌘T) | resource `closed.reopen` | — | not from a phone (yet) | The resource API is not on the phone's lane. |
| Restart Shell Here | `restart-tab` | dead terminal: overlay "The shell ended." + **Restart Shell Here**, page menu row | works (round 2) | Allowlisted with the surface only (no command, folder, env or alias), after live verification on the rig Mac that the new shell runs on the Mac under the same tab (SECURITY.md "Restart Shell"). The phone now lists a dead terminal the Mac keeps (it hid every dead tab). |
| New Tab Group, Add Tab to Group…, Remove Tab from Group | `create-tab-group {surfaces, color}`, `add-tabs-to-tab-group`, `remove-tabs-from-tab-group` | page and card menu, the Mac's group rows | works (parity2 tabs; live run pending) | New Tab Group takes the Mac's next color (`GroupColor.automatic`, never blue or grey) and no name. A pinned tab offers no group rows ("Pinned tabs cannot be grouped." on the Mac). A member's card carries the group's chip (name, else "<Color> group"). |
| The group's chip menu: Rename Tab Group…, Pin Group / Unpin Group, Ungroup Tabs, Close Tab Group | `update-tab-group {name}`, `save-tab-group`, `unsave-tab-group`, `ungroup-tab-group`, `close-tab-group` | a member's menu > **Tab Group: <name>…** (the group's actions) | works (parity2 tabs; live run pending) | The phone has no group chip to hold, so a member's row opens the same actions. Close Tab Group waits for the Mac, then removes every member. Collapse / Expand, color and icon, Move Tab Group … and New Tab in Group: not on the phone (the phone has no strip to collapse or arrange; a new tab in a group starts a terminal by another path). |
| Reopen Saved Tab Group…, Delete Saved Tab Group… | `reopen-saved-tab-group`, `delete-saved-tab-group` | — | not from a phone (yet) | Reopening recreates terminals from the saved record (a respawn path); the remote rules need live verification of it on the Mac first (orchestrator decision 2026-10-15). Pin Group on the phone saves the group; it is reopened on the Mac. |

## Workspaces

| Mac action | Mac sends | Phone | State | Notes |
| --- | --- | --- | --- | --- |
| Rename Workspace… (⇧⌘R) | `rename-workspace` | row swipe / menu Rename | works | |
| Close Workspace (⇧⌘W) | `close-workspace` | row swipe / menu Close Workspace | works | |
| Close Other Workspaces / Close Workspaces Below / Above | `close-workspace` × n | row menu > **Close** > the Mac's three titles | works (parity2) | Over the Mac's sidebar order of that Mac's workspaces (pinned first). The Mac closes at once; the phone asks first ("Close 3 workspaces?", naming them), since a long press is easy to misplace. The Mac has no "Close All Workspaces". |
| Move Workspace Up / Down | `set-personal-workspace {index}` (personal order), else `move-workspace {index}` | row menu > **Move** > **Move Workspace Up / Down** | works (parity2) for unpinned workspaces | The same index the Mac's `movePersonalWorkspace` computes. Pinned workspaces have no Move on the phone: the Mac orders its pinned tiles with a layout `item.move`, which is not on the phone's lane. No drag: a long press opens the row menu, and the list is not a reorderable List. |
| Pin Workspace / Unpin Workspace | layout tile in `sec_pinned` (`sidebar_layout.update`), legacy `set-workspace-metadata {pinned}` | row menu > **Pin Workspace / Unpin Workspace** | works (parity2) | Pin sends the legacy flag, which the Mac turns into its pinned tile (`migrateLegacyPins`); Unpin removes the tile (`item.remove`). The phone reads the tiles (`sidebar_layout.get`). |
| Set Workspace Color… / Reset Workspace Color | `set-workspace-metadata {color}` | row menu > **Appearance** > the Mac's nine colors (Grey…Orange), **Reset Workspace Color** | works (parity2) | The row shows the color as a bar in its gutter (idle rows). |
| Icon, Description, Clear Name | `set-workspace-metadata` | — | missing | Not in this round. |
| Mark Workspace as Read / Unread | `ack-tab-notifications` on unread tabs + `set-workspace-metadata {marked_unread}` | row menu > **Options** > **Mark Workspace as Read / Unread**; opening marks read | works (parity2) | |
| Duplicate Workspace | composed app-side (new workspace, then each tab) | — | missing | The Mac composes it in the app (its tabs' programs and folders); a phone would have to start programs in folders it may not choose (`cwd`). Use New Workspace in the same folder. |
| Workspace groups | personal groups (`set-personal-workspace {group}`, `workspace_group.*`) | — | missing | On a Mac with personal order, groups are personal resource ops not on the phone's lane; the phone shows grouped workspaces in the Mac's order, without the group headers. |
| Move to Window / New Window, Show in Finder, Copy Path | app-local | Copy Directory (terminal page) | not applicable | Mac windows and Finder. |

## Terminal

| Mac action | Phone | State | Notes |
| --- | --- | --- | --- |
| Type, paste, keys, Ctrl-C | composer, direct typing, key bar, paste | works | |
| Run a command | type it | works | The phone never starts a program by argv (`run` refused). |
| Clear Screen (⇧⌘K) | page menu Clear | works | `clear-history`. |
| Find, Copy | Files and Links, selection | partial | |
| Restart Shell Here | overlay and page menu on a dead terminal | works (round 2) | See Tabs. |
| Reset Terminal, Keep Running After Close | — | not from a phone | Program lifetime stays the Mac's (`set-terminal-keep` not allowlisted). |

## Browser

| Mac action | Phone | State | Notes |
| --- | --- | --- | --- |
| Address bar, Back (⌘[), Forward (⌘]), Reload (⌘R) | TabsKit address bar and toolbar | works on a streaming Mac | `browser-navigate` (http/https only), `browser-back`, `browser-forward`, `browser-reload`. Forward right after Back is one tap (finding 5, fixed in parity2 tabs). The address reads the page's host, and a new tab's about:blank reads "Search or enter website" (finding 4). |
| Open Link in New Tab | — | missing | The streamed page sends no link targets to the phone. |
| Hard Reload, Open in Default Browser, Incognito | — | not applicable | |

## Agent chat

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| Stop | page menu Stop Agent, composer stop | works | `session/cancel`. |
| Retry / Send this prompt again | Retry on a failed turn | works | |
| Switch Model… (⌃⌘M), Mode | composer model and mode menus | works for phone-started chats | A Mac-started Claude session keeps its model and mode from a phone (acpmux D13). Round 2: the mode menus list only modes that ask (Claude's Default and Plan, Codex's Ask) plus the current one, and cnx-hostd refuses any other mode a phone sends (`acpmux_policy.rs`), because acpmux lets an authenticated remote connection pick any Codex bridge mode. |
| Continue in… (handoff) | page menu Continue in… | works | `_acpmux/handoff_*`. |
| Allow Once / Allow for This Chat / Deny | permission cards | works | Allow needs the phone's Face ID signature (pairing). |
| Queue: Edit / Remove / Send now | queue remove | partial | |
| Fork (chat menu "Fork"; palette Fork Conversation to New Tab) | page menu **Fork** | works (parity2 tabs; live run pending) | acpmux `session/fork` (the whole chat), then `new-conversation-tab` of the copy in the chat's pane; the copy comes to the front, as the Mac opens a fork in a tab of its own. A Claude chat the Mac started is refused for a remote connection (acpmux D13, `remote_guard.rs`); the phone shows acpmux's own reason: "This chat runs with <Mac>'s Claude permissions. Start a new chat from this device to control it remotely." Fork from an earlier turn (Fork from here) is not on the phone. |
| Archive (chat menu "Archive", Archive Chat ⌃⌘A) | page menu **Archive** | works (parity2 tabs; live run pending) | acpmux `_acpmux/archive {archived: true}`, then `close-surface`, as the Mac's pane asks its app to close the tab. Unarchive is on the Mac (its archived list). |
| Checkpoints, Commit, Push | Checkpoints shown as unavailable | missing | The link carries no checkpoints. |
| Trust this folder ("Trust / Don't trust") | the toast says how, step by step; `claude` in the terminal works | partial | acpmux refuses `acp.trust.set` from a remote connection (finding 2). The phone now says: "Claude hasn't been trusted in <folder> yet. Either: 1. On the Mac, open this workspace in cmux and choose Trust when it asks. Or 2. Here, open this workspace's terminal, type claude, press Return, choose "Yes, I trust this folder", then type /exit. Then start the chat again." Whether a Face ID answer from the phone may count is the person's decision (#13742). |

## Chief and the Feed

| Mac action | Phone | State | Notes |
| --- | --- | --- | --- |
| Chief conversation, questions | Home > Chief | works | Answers need the phone's signature. |
| Stop the Chief, Chief settings | Chief settings | works | `chief.stop`, `chief.engine.*`. |
| New Chief…, Archive Chief, Memory Inspector | — | missing | |
| Show Feed, Jump to Latest Unread, Mark read | Feed tab, swipe | works | |
| Clear All Notifications | Feed > Filter menu > **Clear All Notifications** | works (parity2) | `notification.clear` on the Mac's current session (new on the lane, see SECURITY.md); the Feed's terminal events go with it. No confirmation, as on the Mac. |
| Mute workspace | Feed > Filter > Workspaces toggles | partial | The phone's mute is the phone's own (the Mac's mute is not on the lane). |

## Workspace list order (parity2 decision)

The phone's Workspaces list follows the Mac's sidebar: **Needs You** first (the
phone's own attention section; those rows are also in the Mac's list), then
**Pinned** in the Mac's tile order, then the rest titled **Workspaces** in the
Mac's order: the person's personal order (`list-personal`) on a Mac that has
one, else the daemon's workspace order. Rows of a Mac whose order the phone
does not know yet (cached, mock) keep the old newest-activity order under
**Recent**. Move Up / Down moves within the row's section on its Mac.

## Live run, workspace lane (parity2, 2026-10-15)

Rig Mac `cnx-p2-26459378` on mini-cmux11s, the phone in one headless simulator
(`cnx-p2-ws`), driver `verify/parity/pq_ws.py`; the Mac side read from its own
daemon (list-workspaces, list-personal, sidebar_layout.get, list-notifications).
Videos: `~/cnx-ios-e2e/p2ws-raw/ws-<flow>.mp4` (not committed).

| Flow | Result |
| --- | --- |
| `pin_color_order`: Pin, Set Workspace Color… Green, Reset, Unpin, Move Up, Move Down | Pass: pinned tile on the Mac, color `green` then cleared, unpinned; Move Up changed the Mac's personal order `[c, b, a]` to `[b, c, a]` and the phone list matched; Move Down restored it |
| `mark_unread`: Options › Mark Workspace as Unread, then as Read | Pass: `marked_unread` true, then false |
| `bulk_close`: Close › Close Workspaces Below (after "Close 2 workspaces?") | Pass: exactly the two named workspaces closed, the chosen one stayed |
| `open_folder`: New Workspace › Open Folder… `~/cnx-ios-e2e/p2ws-folder` | Pass: the workspace on the Mac in 0.7 s, its terminal in that folder |
| `feed_clear_all`: Feed › Filter › Clear All Notifications | Pass: the Mac's notification ledger empty |
| `trust_steps`: New Agent Chat in a folder Claude was never trusted in | Pass: the step-by-step message in 1.6 s |

## Live run (2026-10-14/15)

- **Mac:** a real tagged cmux-next build of this branch (`cnx-e2e-dc79f937`, fleet job
  `632570e0c07656235e782c58`, with `feat-cnx-ios` 3d2a8581: the browser host fix and
  the media lane) on `mini-cmux11s-mac-mini`, hidden, launched with `open --env`
  only (no bundle edit, `verify/parity/rmac.py`). Agents reach Claude through the
  team subrouter server (real model calls).
- **Phone:** this branch's Demo build in one headless simulator (`cnx-parity-1`)
  on the laptop, over the real link (TeamHub signaling, WebRTC direct). Taps and
  typing are HID events (`axe`); driver `verify/parity/pq.py`.
- **Videos:** `~/cnx-ios-e2e/parity-raw/*.mp4` (not committed).

| Flow | Result | Video |
| --- | --- | --- |
| New Agent Chat (Mac default `claude`, Opus 5.5) in a workspace folder | Pass after fixes: chat open in 3-12 s, "PONG" in 42 s; Mac lists the session (`claude`, `claude-opus-5-5`, policy `ask`, the workspace folder) | `agent-default.mp4` |
| New Agent Chat With… (sheet: Harness, Model; Codex rows "Unavailable" with the Mac's reason) | Pass: loads in 0.8 s; Claude Code + Claude Haiku 5.5: open 3.1 s, "PONG" 3.6 s; Mac session `claude-haiku-5-5` | `agent-chooser.mp4`, `agent-chooser-model.mp4` |
| Another harness: `cmux` (open-source model through the cmux model router) | Opens (session `cmux`, `qwen/qwen3.7-flash`), then Working with no reply for 2.5 min: see finding 3 | `agent-chooser.mp4` |
| New Browser Tab, address bar, navigate, Back, Forward, Reload | Pass: example.com and iana.org render; Back, Forward (second tap; see finding 5), Reload | `browser.mp4`, `browser-forward.mp4`, `browser-reload.mp4` |
| New Terminal | Pass: opens in the workspace folder in 5 s; `echo parity-$((6*7))` prints `parity-42` | `terminal.mp4` |
| New Workspace > Recent Directories > proj | Pass: `proj` on the Mac in 1 s, terminal at `proj %` (cd + clear) | `workspace-folder.mp4` |
| New Workspace (tap), then New Agent Chat in it | Pass at the time (the tap then reused the last folder; after review a tap opens at the Mac's default folder, as on the Mac) | `workspace-home-agent.mp4` |
| Rename Tab… (card menu) | Pass on the Mac (`rename-surface`); the field then started with the old name and the typed text landed mid-name, so it now starts empty | `tab-edits.mp4` |
| Duplicate Tab | Pass: Mac tabs 12 -> 13, the copy opens | `tab-edits.mp4` |
| Drag to reorder | Unit-tested only: the simulated drag opened the card menu, then left the workspace | — |
| A new folder's trust question | Refused by acpmux (`trust.pending`) until answered; answered from the phone by running `claude` in the workspace's terminal and choosing "Yes, I trust this folder" | `trust-from-phone-terminal.mp4` |

### Findings

1. **Fixed: acpmux replies over 16 KiB never reached the phone.** cnx-link writes
   in 16 KiB chunks since the input lane (e1eb3562), and
   `AcpmuxConnection.MessageJoiner` dropped any chunk under 256 KiB that did not
   parse, so `_acpmux/models` (23 KB) never answered and New Agent Chat sat on
   "Opening…". Transcripts and event pages over 16 KiB were lost the same way.
   Fixed with a red/green test (`sixteenKiBChunksJoin`), also on `feat-cnx-ios`.
   The catalog reads now give up after 15 s.
2. **A new folder's trust question needs the Mac (or the terminal).** acpmux
   refuses `acp.trust.set` from a remote connection, so a phone cannot answer
   "Trust / Don't trust". The phone now says so ("Trust proj on <Mac> first:
   answer its trust question in cmux on the Mac, or run claude in this
   workspace's terminal and accept it."). Answering it on the phone with the
   phone's Face ID signature is a trust decision for #13742.
3. **Harnesses whose API is behind a loopback proxy hang when a phone starts
   them.** acpmux runs a phone-started Claude in its remote-chain Seatbelt
   profile, which shuts loopback except Claude's own `ANTHROPIC_BASE_URL` port.
   The `cmux` harness (the cmux model router through the local relay) and
   `claude-sr` (`sr claude proxy`) reach their APIs another way: `cmux` worked
   and never answered; `claude-sr` closed ("agent process closed"); `claude`
   through a loopback `ANTHROPIC_BASE_URL` failed with "Unable to connect to API
   (EPERM)". Owner: acpmux remote sandbox (`hub/remote_sandbox.rs`).
4. Fixed (parity2 tabs): the streamed browser tab's address control read "Address,
   about:blank" to VoiceOver after navigation. The Mac's browser reports the old page
   (a new tab's about:blank) while a navigation loads, and that report replaced the
   address the person typed. The model now keeps the asked-for address until the page
   reports another one or stops loading, and an about:blank tab reads "Search or enter
   website". Unit tests `theAddressIsTheOneAskedForWhileItLoads`, `aBlankBrowserTabHasNoAddress`.
5. Fixed (parity2 tabs): Forward once did nothing on the first tap right after Back.
   The browser reports the old history (no forward entry) until Back commits, so the
   button was disabled, or the Mac ignored the step. Back now offers Forward at once,
   and a step tapped before the previous one commits is sent when it does (bounded at
   2 s). Unit tests `forwardRightAfterBackNeedsOneTap`, `aCachedStepCommitsOnTheNewAddress`.

### Review (correctness-first subagent, 2026-10-15)

Fixed on this branch (52e2b628 and after): the typed `cd` refused folders with
line-editing characters (DEL, ^U, ESC, a backslash, `!`) after an injection
finding; `move-tab` sent the target's index (off by one forward, and could move a
tab into another pane); `session/new` and `set_model` had no timeout; the
folder refusal blamed an old Mac; the joiner re-parsed large messages on every
chunk; a renamed Codex profile showed as startable; a plain New Workspace tap
typed `cd` to the last folder; the Mac kept the folder list after iPhone
connections turned off when no approvers were paired. Those fixes have unit
tests and were not driven live again.

## Parity round 2: tabs lane (2026-10-15)

Branch `feat-cnx-ios-p2tabs`. No daemon allowlist change: every command used was already
allowed (`move-tab-to-workspace`, `move-tab-to-new-workspace`, `set-tab-pinned`, the
`*-tab-group*` commands, `new-conversation-tab`, `close-surface`). acpmux's Fork and
Archive go over the phone's acpmux lane as a remote (Web) connection: `session/fork`
passes `remote_guard.rs` (folder and policy checks, D13 refusal for a Mac-started
Claude chat) and `_acpmux/archive` sets one tag.

Phone menus, following the Mac's tab menu (`ContextMenuEssentials`): the card menu has the
top rows (Rename Tab…, Pin Tab / Unpin Tab, Duplicate Tab) and the group rows; TabsKit adds
Close Tab and Close Other Tabs. The page menu adds the Mac's More rows that make sense on a
phone (Move Tab to Workspace…, Move Tab to New Workspace), and on an agent chat the chat
menu's Fork and Archive.

Live flows: `verify/parity/pq_tabs.py` (`pin`, `move-to-workspace`, `move-to-new-workspace`,
`tab-groups`, `tab-groups-2`, `reorder`, `browser-forward`, `chat-fork-duplicate-archive`),
each checked on the Mac's daemon tree and recorded. Status: ready; not yet run against the
rig Mac.

## Round 2 (2026-10-15, branch `feat-cnx-ios-parity2`)

Rig: real cmux-next builds of this branch (`cnx-p2-bfdcd53e`, then `cnx-p2-26459378`),
hidden, settings by `open --env` only. Agents through the team subrouter on
mini-cmux11s (`~/cnx-ios-e2e/p2`); Codex on a hidden rig app on the laptop
(`~/cnx-ios-e2e/p2l`), with the laptop's own Codex login used in place (quit after).
Phone: this branch's Demo build in one headless simulator, real link. Videos:
`~/cnx-ios-e2e/p2main-raw/` (orchestrator), `p2ws-raw/`, `p2tabs-raw/` (lanes).

| Flow | Result | Video |
| --- | --- | --- |
| Codex: New Agent Chat With… > Codex > Start Chat, "PONG" | Pass: open 4.7 s, reply 9.7 s; Mac session `codex`, mode `ask`, policy `ask`, model gpt-6.1-sol | `codex-agent.mp4` |
| Codex tool approval: "echo hi > p2-approval.txt" | Pass: Codex asked first ("Codex wants to run a command"), Allow + Face ID (simulator match) on the phone, the file appeared on the Mac | `codex-approval.mp4` |
| `claude-sr` (sr claude proxy) | Pass (was "agent process closed"): open 4.5 s, "PONG" 3.9 s | `sr-agent.mp4` |
| `claude` (user settings route to the subrouter) | Pass: "PONG" 1.9 s | `claude-agent.mp4` |
| `cmux` (local relay to the cmux model router) | The request now reaches the relay from the sandbox (was: Working, no reply). The hosted router answered 403 "this team cannot use the model router on this deployment yet" for the test account: an account entitlement, not the phone path. On mini-cmux11s the rig's local router did not answer its admin socket (a Mac-side router problem; a Mac-local session failed the same way). | `cmux-agent.mp4` |

Findings fixed in round 2:

1. **Codex refused from a phone.** acpmux already bridged Codex through `codex
   app-server` and let an authenticated remote connection use any of its modes,
   but a remote session stayed in the bridge's default `agent` (no asking) and the
   phone refused the family by name. Now: a phone-started Codex chat starts in
   `ask`, the catalog says so, and hostd keeps the phone to asking modes.
2. **Agents behind a local model proxy never answered.** Claude Code applies its
   user settings `env` over its process env, so the route the sandbox opened
   (the profile's) was not the one Claude used (the user's settings pointed at the
   subrouter, a port the sandbox kept shut: EPERM or a silent hang). The sandbox
   now opens exactly the endpoint Claude will use, pins it in the inline
   settings, and skips the user settings source when the profile names its own
   route (whose key the user settings would replace). `sr claude proxy` cannot
   listen in the sandbox, so a remote chain runs Claude straight to the
   subrouter server, as acpmux already does when that launcher cannot run.
   Tests: unit (Linux) and `remote_sandbox` on macOS (the chain reaches its
   loopback proxy port and no other loopback port).

