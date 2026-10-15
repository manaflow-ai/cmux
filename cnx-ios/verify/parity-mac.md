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
| New Agent Chat over Home (a workspace whose only tab is the chat) | `create-workspace`, `new-conversation-tab` | New Workspace (hold) > **New Agent Chat** > a folder (parity2) | works (parity2, live: `agent_chat_workspace` pass) | acpmux `session/new` in that folder first (a folder not trusted yet leaves no empty workspace), then `create-workspace` and `new-conversation-tab {workspace}` (the daemon makes its first pane). The Mac's default agent. Folders: the Mac's workspace folders (Recent Directories) only, since acpmux's remote guard starts a phone's chat only there; any other folder says to open a workspace there first (New Workspace › Open Folder…). No new allowlist entry. |

## Tabs

| Mac action | Mac sends | Phone | State | Notes |
| --- | --- | --- | --- | --- |
| Close Tab (⌘W) | `close-surface` | grid ×, page menu Close Tab | works | Asks first when a program runs. |
| Rename Tab… (⌘R) | `rename-surface` | page and card menu **Rename Tab…** | works (this branch) | Rolls back on refusal. |
| Duplicate Tab | `new-tab` / browser duplicate / a second tab of the chat | page and card menu **Duplicate Tab** | works (parity2 tabs) | Terminal: a new terminal in the tab's pane (hostd's folder choice). Browser: the same http(s) page. Agent chat: a second tab of the same chat (`new-conversation-tab` with the tab's session), as the Mac's `duplicateAgentTab`; never a copy of the conversation (that is Fork). |
| Move Tab Left / Right, drag | `move-tab` | drag in the grid | works (parity2 tabs; live) | Within the tab's pane (insertion index as the daemon reads it); a drag onto another pane's tab says to move it on the Mac. A real long press and drag is proven by an XCUITest (`CnxAppUITests/TabReorderUITests`: first card to the third slot, iOS 26.5 simulator, mock data); `pq_tabs.reorder` runs it against the rig Mac. |
| Move Tab to Workspace… / Move Tab to New Workspace | `move-tab-to-workspace {surface, workspace}`, `move-tab-to-new-workspace {surface, name}` | page menu **Move Tab to Workspace…** (a picker of this Mac's other workspaces), **Move Tab to New Workspace** | works (parity2 tabs; live) | The Mac's More rows, so on the phone they are in the page menu (the card menu has no room). The new workspace is named by the Mac's rule (`NewWorkspaceName`: a last tab keeps its workspace's name; else the tab's name, page title or host, terminal title unless a bare shell, then its folder). The tab keeps its terminal, page or chat; the phone stays in the source workspace (the Mac's own view is its own) and says "Moved <tab> to <workspace>."; leaving it when that was the last tab. A tab in Home has no Move Tab to New Workspace ("Home's tabs stay in Home."), as on the Mac. |
| Move Tab to New Split / Column, Move Tab to Pane Left / Right / Above / Below, Previous / Next Pane | `move-tab-to-split`, `move-tab-to-column`, `move-tab` across panes | — | not applicable (decision) | The phone shows a workspace's tabs as one list and has no panes to aim at; a pane move would change the Mac's layout with nothing on the phone to show it. Left off the phone on purpose; the commands stay allowlisted for a future pane view. |
| Pin Tab / Unpin Tab | `set-tab-pinned` | page and card menu **Pin Tab** / **Unpin Tab** | works (parity2 tabs; live) | Here at once, rolled back on refusal. A pinned tab's card icon is a pin; the Mac sorts pinned tabs first in their pane. |
| Split Right / Down, New Column / Row, Zoom Pane | `split`, `new-pane-right`, `new-row`, `zoom-pane` | — | not applicable | The phone shows one tab at a time; panes are a Mac layout. |
| Reopen Last Closed Tab (⇧⌘T) | resource `closed.reopen` | — | not from a phone (yet) | The resource API is not on the phone's lane. |
| Restart Shell Here | `restart-tab` | dead terminal: overlay "The shell ended." + **Restart Shell Here**, page menu row | works (round 2) | Allowlisted with the surface only (no command, folder, env or alias), after live verification on the rig Mac that the new shell runs on the Mac under the same tab (SECURITY.md "Restart Shell"). The phone now lists a dead terminal the Mac keeps (it hid every dead tab). |
| New Tab Group, Add Tab to Group…, Remove Tab from Group | `create-tab-group {surfaces, color}`, `add-tabs-to-tab-group`, `remove-tabs-from-tab-group` | page and card menu, the Mac's group rows | works (parity2 tabs; live) | New Tab Group takes the Mac's next color (`GroupColor.automatic`, never blue or grey) and no name. A pinned tab offers no group rows ("Pinned tabs cannot be grouped." on the Mac). A member's card carries the group's chip (name, else "<Color> group"). |
| The group's chip menu: Rename Tab Group…, Pin Group / Unpin Group, Ungroup Tabs, Close Tab Group | `update-tab-group {name}`, `save-tab-group`, `unsave-tab-group`, `ungroup-tab-group`, `close-tab-group` | a member's menu > **Tab Group: <name>…** (the group's actions) | works (parity2 tabs; live) | The phone has no group chip to hold, so a member's row opens the same actions. Close Tab Group waits for the Mac, then removes every member. Collapse / Expand, color and icon, Move Tab Group … and New Tab in Group: not on the phone (the phone has no strip to collapse or arrange; a new tab in a group starts a terminal by another path). |
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
| Set Icon… / Remove Icon | `set-workspace-metadata {icon}` | row menu > **Appearance** > **Set Icon…** (16 SF Symbols both apps draw, or **Emoji…** for one emoji), **Remove Icon** | works (parity2, live: `icon_clear_name` pass) | The Mac's picker has every SF Symbol and uploaded images; the phone offers a short list and emoji. The row shows the icon before the name. |
| Clear Workspace Name | `set-workspace-metadata {title: null}` | row menu > **Options** > **Clear Workspace Name** (only when a display name is set) | works (parity2, live: same flow) | The workspace's own name shows again. |
| Edit Workspace Description… | — | — | not on the Mac either | The Mac reports it needs a daemon capability (`workspace-description-v1`) the daemon does not have. |
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
| Queue: Edit queued prompt / Send now / Move up / Move down / Remove queued prompt | hold a queued prompt (the agent pane's wording) | partial (parity2: unit-tested; not shown live) | acpmux `_acpmux/queue_edit {op: update | send_now | move}`, `_acpmux/queue_remove`; the phone follows `queue_updated` and `queue_order`. hostd lets `_acpmux/queue_edit` through only when the session's current mode asks before each change. Resume (after an error) is not on the phone. Live on the rig (2026-10-15), a prompt sent while Claude was writing a long reply was taken into the running turn and answered at once, never queued, so the queue row and its menu never appeared; Edit / Send now are verified by unit tests only. |
| Fork (chat menu "Fork"; palette Fork Conversation to New Tab) | page menu **Fork** | works (parity2 tabs; live) | acpmux `session/fork` (the whole chat), then `new-conversation-tab` of the copy in the chat's pane; the copy comes to the front, as the Mac opens a fork in a tab of its own. A Claude chat the Mac started is refused for a remote connection (acpmux D13, `remote_guard.rs`); the phone shows acpmux's own reason: "This chat runs with <Mac>'s Claude permissions. Start a new chat from this device to control it remotely." Fork from an earlier turn (Fork from here) is not on the phone. |
| Archive (chat menu "Archive", Archive Chat ⌃⌘A) | page menu **Archive** | works (parity2 tabs; live) | acpmux `_acpmux/archive {archived: true}`, then `close-surface`, as the Mac's pane asks its app to close the tab. Unarchive is on the Mac (its archived list). |
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
| `icon_clear_name` (rig `cnx-p2-d1a70bd6`): Appearance › Set Icon… hammer, Remove Icon, Options › Clear Workspace Name | Pass: `icon` hammer then cleared on the Mac, the row showed the icon; the display name cleared and the own name came back |
| `agent_chat_workspace`: New Workspace › New Agent Chat › p2ws-proj | Pass: a new workspace on the Mac whose only tab is the chat (`conversation`), in 2.1 s |
| `queue_edit`: a second prompt while a turn runs, then Edit queued prompt and Send now | Not shown: the second prompt was taken into the running turn (answered at once), so nothing queued; the flow could not reach the queue menu. An earlier attempt hit "API Error: Output blocked by content filtering policy" on a long numbered list |

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

Live run (2026-10-15, rig Mac `cnx-p2-1585ab34` on mini-cmux11s, the Debug app of this
branch in one headless simulator `cnx-p2-tabs`): `verify/parity/pq_tabs.py`, each flow
checked on the Mac's own daemon tree (its socket) and recorded in `~/cnx-ios-e2e/p2tabs-raw/`.

| Flow | Result | Video |
| --- | --- | --- |
| Pin Tab, Unpin Tab (card menu) | Pass: pinned on the Mac in 0.2 s and first in its pane; unpinned in 0.2 s | `pin.mp4` |
| Move Tab to Workspace… (page menu, picker) | Pass: the tab in the other workspace 0.1 s after the pick | `move-to-workspace.mp4` |
| Move Tab to New Workspace | Pass: a new Mac workspace named `p2tabs-t2` (the tab's name) holds it | `move-to-new-workspace.mp4` |
| New Tab Group, Add Tab to Group… | Pass: both tabs in one Mac group (red), each step 0.1 s | `tab-groups.mp4` |
| Rename Tab Group…, Pin Group, Ungroup Tabs | Pass: renamed in 0.8 s (the alert capitalizes the first letter, as iOS text fields do), saved, ungrouped | `tab-groups-2.mp4` |
| Drag to reorder (XCUITest long press and drag) | Pass: Mac pane order [95, 98, 100] -> [98, 100, 95] | `reorder.mp4` |
| Browser: address, Back, Forward right after Back | Pass: the address reads "Address, iana.org" (never about:blank); Back then Forward 0.5 s later lands with one tap. The daemon's tab record of a streamed tab keeps about:blank (the page's address comes from the Mac's browser host) | `browser-forward.mp4` |
| New Agent Chat, then Fork, Duplicate Tab, Archive (page menu) | Pass: a real turn ("PONG"); Fork made a chat tab with its own session in 0.8 s and its transcript; Duplicate Tab a third tab on the same session; Archive closed a tab on the Mac | `chat-fork-duplicate-archive.mp4` |

Not driven live: the D13 refusal of a fork of a Mac-started Claude chat (unit-tested,
its text is acpmux's). Home: a tab in the Mac's Home workspace (daemon `kind: "home"`) has no Move Tab to New
Workspace on the phone, and a request is refused with "Home's tabs stay in Home." (the Mac's
`TabPromotion`); Move Tab to Workspace… stays, as on the Mac. Unit-tested
(`homeTabsStayInHome`), not driven live.

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
| Codex again on the final build (`cnx-p2-d1a70bd6`, with hostd's current-mode check on every prompt) | Pass: open 4.6 s, "PONG" 13.2 s | `codex-final.mp4` |
| `claude-sr` (sr claude proxy) | Pass (was "agent process closed"): open 4.5 s, "PONG" 3.9 s | `sr-agent.mp4` |
| `claude` (user settings route to the subrouter) | Pass: "PONG" 1.9 s | `claude-agent.mp4` |
| Restart Shell Here (rig `cnx-p2-1585ab34`; the rig killed the tab's terminal host until the Mac stopped respawning it, as "Terminal stopped: its host kept failing") | Pass: the phone showed "The shell ended." with Restart Shell Here; one tap, the Mac listed the tab live in 0.1 s with a new shell (pid 55406 -> 55788), whose parent is the rig app's own `cmux-tui __terminal-host` on the Mac; the page reattached and `echo restarted-$((6*7))` printed `restarted-42` | `restart-shell.mp4` |
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


### Remaining gaps after round 2 (and why)

- **opencode** from a phone: refused. opencode starts every agent from allow-all and
  merges the user's own rules last, so acpmux cannot prove it asks before each change.
- **`cmux` harness** (cmux model router): the phone path works through the sandbox now;
  the test account's team is not entitled to the hosted router (403), and the
  mini-cmux11s rig's local router did not answer. Needs an entitled account to see a reply.
- **Folder trust from the phone**: left on the Mac by decision; the phone gives the steps.
- **Duplicate Workspace**: the Mac composes it from its tabs' programs and folders; a phone
  may not choose either.
- **Workspace groups** (personal order): more resource ops on the lane; not reviewed yet.
- **Reopen Saved Tab Group**: recreates terminals; same live check as Restart Shell needed.
- **Open Link in New Tab, Checkpoints, Commit, Push, New Chief…, Memory Inspector, Reset
  Terminal, Keep Running After Close**: not on the link (or Mac-only by design).
- **The Mac's last pick** reaching the phone: unit-tested on both sides; not driven live
  (a hidden rig app has no person to pick on its New Tab page).
- **A Mac-started Codex chat in Agent mode** is refused for phone prompts by cnx-hostd
  (unit-tested); not driven live.

## Round 3 sweep (2026-10-15, branch `feat-cnx-ios-p3sweep`)

Code-level comparison of the phone with the cmux-next Mac app beyond workspaces and
tabs, with the fixes made on this branch. Every row is **code-checked; live pending**:
the orchestrator drives the steps below and finalizes the state. Mac sources: the agent
pane (`webviews/src/agent-session/acpmux`, strings from `generated/strings.json`), the
Chief settings and Home in `Packages/macOS/CmuxNext`, acpmux and the relay in `cmux-tui`.

Commits: phone `5ccaa08c` (failure copy, retries), `0e81e2ce` (permissions),
`b1aa7008` (diffs, artifacts), `e9e4bb97` (teams, devices), `c4403fc3` (read timeout);
Mac-side `f3ff65e0` (relay). Tests: CnxKit `swift test` on mini-cmux11s (TurnFailureCopyTests,
TurnFailureLiveTests, PermissionRound3Tests, Round3DiffArtifactTests, plus AgentChatTests,
DiffLayoutTests, DiffViewedStoreTests, FeedPendingTests, ChatFeedRoundOneTests, ParityTests,
FeedRefreshTests, FeedReadMarksTests, AcpmuxParityTests: 120 pass); iOS compile of the
CnxShell scheme (generic iOS Simulator, Xcode 27) succeeded; Rust `cmux-coderouter`
test, fmt and clippy on rbx.

### 1. Files and artifacts

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| "Files" (`header.files`): a folder split of the workspace | title menu or More > **Files and Artifacts** (chips All / Files / Folders / Images / Videos / Documents / Code / Links; Grid / List) | partial (different design) | The Mac has no list of what a session touched; the phone builds one from the transcript (edits, reads, tool input and output, attachments, links) and reads bytes over the link's `file` service (24 MB cap). Folders say "Folder listings aren't available…". No "Search files". code-checked; live pending |
| "Document preview" (HTML, SVG, Markdown from a reply; "Preview" / "Code", versions, "Save") | Preview / Source toggle, More: Copy Path, Copy Contents, Share | partial | No versions or Save on the phone; a document that only came in a reply (not a file) is not offered. Fixed: SVG previews as markup (was "Not an image"). code-checked; live pending |
| "Image too large to show" | "This file is larger than 24 MB, too large to preview on the phone." | works | code-checked; live pending |
| (no Mac equivalent) a read that stalls | "Can't open this file" with Try Again | works (fixed) | A read with no bytes for 20 s now gives up ("<Mac> stopped sending this file…"); it used to spin forever if the Mac slept mid-read. code-checked; live pending |

### 2. Diff viewer

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| "Changes: Last turn" (the transcript's tool diffs, one per edit, pending edits skipped) | **Changes · This turn** card, **Agent Edits** ("Edits in this chat") | works (fixed) | Same source of truth for this scope: acpmux tool-call diffs. Fixed: a file edited twice compared the first snippet's old text with the last one's new text (a wrong diff), numbered lines from 1, and Agent Edits kept only the last turn's version of a file; each snippet edit is now its own hunk without line numbers, a written-then-edited file shows as written, and edits waiting on a permission or refused are left out. code-checked; live pending |
| "Uncommitted / Staged / Unstaged / Committed / Branch" (`git.diff`, `git.status`, `git.checkpoint.diff` through cmux-git) | — | missing | The phone makes no `git.*` calls: shell-made edits and edits older than the loaded history are not on the phone. Needs a read-only git diff on the phone's lane (hostd allowlist, a #13742 decision). |
| "Changed files", "File tree", "Filter files…" | flat list, "N files changed", "N of M viewed" | partial | No tree or filter. |
| "Mark {path} as viewed" | **Mark as viewed** / **Viewed** | works | code-checked; live pending |
| "Switch to split diff" / "Switch to unified diff", "Word wrap" | **Diff options**: Unified / Split, Wrap, Hide Whitespace | works (fixed) | Word-level marks on both (`intraline.ts`, `WordDiff.mark`). Fixed: Hide Whitespace after Expand could index past the end. code-checked; live pending |
| "New" / "Deleted" badges, renames, "Binary file not shown", untracked skipped | A / M badges | partial | ACP diffs carry no delete, rename or binary; those come with git scopes. |
| "Stage", "Unstage", "Create PR", "Undo", "Open in editor" | Copy Path, Copy Line, Copy with Line Number | not from a phone | Read-only on the phone. |

### 3. Chief

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| Chief conversation | Home > Chief | works | code-checked; live pending |
| Chief Settings "Harness" / "Model" / "Effort" (`chief.engine.set`) | Chief settings **Harness**, **Model**, **Effort** | works | Same params; on hostd's list and forwarded by the daemon. code-checked; live pending |
| "Stop the Chief" (`chief.stop`) | **Stop Chief** (while Chief is typing) | works | Wording differs a little. code-checked; live pending |
| "Recent replies, answered by:" | **Recent Turns** | works | Wording differs. |
| "Name" | **Name** | works | code-checked; live pending |
| "Avatar" | (hidden) | not from a phone | The phone shows its editor only when `chief.engine.get` reports `avatarSupported`, which no daemon sends, and hostd refuses `avatar`. Left hidden. |
| Answer a Chief question (`conversation-op question.answer`) | **Answer** > sheet > **Send Answer** (Face ID) | works | Signed `cnx-chief-answer-v1` approval, checked and stripped by hostd. Failures say why ("Not sent: Face ID was cancelled.", "Chief no longer needs this answer.", "Couldn't confirm. Chief may have it." + Check). code-checked; live pending |
| Skip a Chief question | — | missing | The phone has no decline for a Chief question. |
| "Open traces", "Show memory", New Chief…, Archive Chief | text: "Chief's memory and traces open on the Mac." | not from a phone | |

### 4. Feed: questions and permissions

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| "Allow once" | Feed **Allow once** (Face ID), chat bar **Allow once** | works (fixed wording) | Signed `approverDecision` after Face ID. Was "Allow" / acpmux's option name. code-checked; live pending |
| "Allow for this chat" | — | not from a phone (fixed) | acpmux refuses every lasting grant from a paired device (`remote.lasting_grant_refused`). The phone offered "Always" / "Allow for this session", which cost a Face ID and then failed; it now offers only Allow once and Deny. Answering it from the phone is a #13742 decision. |
| "Deny" | **Deny**, full swipe | works | Unsigned, at once. code-checked; live pending |
| Question "Submit" / "Skip" | QuestionCard **Answer**; **Decline** after an error | partial | Same `permissionId` from the Feed and the chat. Wording differs; the answer shows before Face ID (rolled back on failure). |
| Answered on the Mac first | card closes "Already answered on your Mac" | works (fixed) | Was: the card reopened with "no pending permission perm_…". With two open asks, one answered on the Mac still shows live until tapped (the session's change notice carries no permission id). |
| "Answered by {name} on {device}" | "Answered" | partial | No attribution on the phone. |

### 5. Settings

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| Settings > Mobile > "Phones" > "Remove" (drops links, forgets the pairing) | Settings > **Devices** > Phones row: swipe **Remove** / **Remove iPhone** | partial | The phone removes it from the account's devices only; each Mac keeps allowing it (paired list, Face ID approvers) until removed there. Fixed: the alert now says so. Revoking from the phone needs a Mac-side change (the hub telling hostd a phone was removed) and a #13742 decision. code-checked; live pending |
| Mac removed from the account | Macs row **Remove Mac** | works | hostd stops (4002); the phone forgets the pin. code-checked; live pending |
| (revoke this phone) | **Remove This iPhone from My Macs** | partial | Unpairs only on the Mac linked now; errors are ignored. |
| Settings > Mobile "Status" | Settings > **Transport** | works | Phone-only setting. |
| Notification kinds | Settings > **Notifications**: Questions and permissions, Finished tasks, Errors | works | Match the push kinds. |

### 6. Team switching

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| Team Picker (⌥⇧⌘T), "Choose a Team" | hamburger **Teams** > a team row | works (fixed) | Macs, link, presence, workspaces and Chief reload. Fixed: the Feed kept the old team's items (an old ask answered went to the new team's Mac); it now empties on a team change and refills from the new team's Macs. A switch by tap or by following a Mac closes an open workspace and a chat opened from the Feed. code-checked; live pending |
| — | Teams row menu: Change color and icon, Invite to team, Copy team name; **Add team** | works | |

### 7. The `cmux` harness and the model service's 403

From code: Claude Code does not retry a 403, so its result is `is_error` with
"API Error: 403 {"error":{"code":"auth.forbidden","message":"this team cannot use the
model router on this deployment yet",…}}". acpmux's claude bridge turns that into a
failed prompt, the hub records `turn_error` and `turn_result {status: failed, errorText}`
and `lastTurn.errorText`. So the turn ends; it does not hang. What did hang: when the
local relay has no upstream or its sign-in expired, it answered 503, which Claude Code
retries up to 10 times (about 2.5 minutes of "Working", the round 1 observation).

| Mac (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| Failed turn note: "The provider refused cmux’s credentials (403)." + Details, Copy error | **Agent stopped**: "cmux's model service isn't available for this team yet." + **Details** (the agent's text), Retry | works (fixed) | Was the raw "API Error: 403 {json}". The phone ports the Mac's `failureCopy` kinds and sentences, plus the model service's own cases (not connected, sign-in expired, didn't answer). Mac-side gap: the Mac's sentence for this case blames credentials; the same case belongs in `failureCopy.ts`. code-checked; live pending |
| Feed | failed item with the same sentence | works (fixed) | Was the chat's previous reply (the preview) or "The turn failed.". |
| (no Mac display) Claude Code's `api_retry` | running turn reads "Retrying (2 of 10, error 503)" | works (new) | From acpmux's raw `claude.system.api_retry` record. |
| Relay with no upstream / expired sign-in | turn ends at once with "cmux's model service isn't connected on the Mac…" | works (fixed, Mac-side `f3ff65e0`) | The relay's own 503s now carry `x-should-retry: false`, and the hosted service's `x-should-retry` is forwarded. Relies on Claude Code honoring the header (the Anthropic SDK's behavior). |

### Live steps for the orchestrator (simulator, real link, rig Mac)

Taps by accessibility label or identifier. Mac checks through the rig's daemon socket
and its acpmux socket (`pq_ws.acp`).

1. **cmux harness 403** (the test account reproduces it): workspace > + > **New Agent
   Chat With…** > Harness **cmux** > **Start Chat**; send "PONG". Expect within seconds:
   the card **Agent stopped** with "cmux's model service isn't available for this team
   yet.", **Details** expanding to "API Error: 403 …", and **Retry**; no "Working" left.
   Mac: `_acpmux/sessions` shows the session with `lastTurn.status` `failed` and
   `errorText` containing `403`. Feed tab: the newest item reads the same sentence.
   If the rig's relay has no upstream, expect "cmux's model service isn't connected on
   the Mac…" at once (not minutes; needs a rig built with `f3ff65e0`).
2. **Permissions**: in a Claude chat, ask "run `echo p3 > p3.txt`". Chat bar shows
   exactly **Allow once** and **Deny** (no "Allow for this session"). Tap **Allow once**,
   Face ID (simulator match); Mac: `p3.txt` exists. Repeat with the chat closed: Feed card
   shows **Allow once** and **Deny** only. Then ask again and answer on the Mac
   (`_acpmux/permission_respond` on the rig socket, `allow_once`), then tap **Allow once**
   on the phone: the card closes "Already answered on your Mac" with no error.
3. **Agent Edits**: ask Claude to create `p3-notes.txt` with three lines, then in the next
   prompt to change line 2, then in a third to change line 3 of it and another file.
   Title menu > **Agent Edits**: `p3-notes.txt` shows the written file with both edits
   applied (A badge, numbered 1-3); a file that existed before shows each edit as its
   own hunk separated by "⋯", no line numbers. **Diff options** > Hide Whitespace on a
   file after tapping an **Expand N hidden lines** row: no crash.
4. **Files and Artifacts**: ask Claude to write `p3.svg` (a circle). Title menu >
   **Files and Artifacts** > the SVG: it draws (was "Not an image"). Open a large text
   file and the PNG: previews load; **Preview**/**Source** toggle (`artifact.sourceToggle`).
5. **Chief**: Home > Chief; send a message; settings (`chief.settings`): change
   `chief.settings.model`, then `chief.settings.stop` while Chief types. Mac:
   `chief.engine.get` shows the model. A Chief question: `chief.question.bar` > answer >
   `chief.question.send` (Face ID); Mac: the question answered.
6. **Team switch**: with a Feed item from team A, hamburger **Teams** > team B row. The
   Feed is empty until team B's Macs fill it; an open workspace screen closed. Switch
   back: team A's last turns return.
7. **Devices**: Settings > `settings.devices` > a second phone row > swipe **Remove**:
   the alert says the Macs still allow it until removed in Settings → Mobile on each Mac.
   Mac: the phone is still in its Phones list (expected; the gap above).
