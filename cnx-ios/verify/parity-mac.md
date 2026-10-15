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
| New Agent Chat (⌘I) | acpmux `session/new` (harness from the last pick, else acpmux `defaultHarness`), daemon `new-conversation-tab` | + > **New Agent Chat** | works (this branch) | One model-agnostic entry: the Mac's acpmux `defaultHarness` when a phone may start it, else the first that may (Claude). Was one "New Claude Chat" per harness. The Mac's last-pick memory (`newTab.lastPicks`, Mac UserDefaults) does not reach the phone; the phone uses acpmux's default. |
| Harness and model picker (chip: "Harness", "Model"; "Unavailable" + reason) | `session/new` then `session/set_model` | + > **New Agent Chat With…** (sheet "New Agent Chat": Harness, Model, Start Chat) | works (this branch) | Unavailable agents keep the Mac's reason. Codex and opencode: "Not available from here: this agent has no mode that asks before each change" (the Mac's own remote wording, acpmux `REFUSED_FAMILIES`). |
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
| Duplicate Tab | `new-tab` / browser duplicate | page and card menu **Duplicate Tab** | partial (this branch) | Terminal: a new terminal in the tab's pane (hostd's folder choice). Browser: the same http(s) page. Agent chat: none; use Continue in…. |
| Move Tab Left / Right, drag | `move-tab` | drag in the grid | partial (this branch) | Within the tab's pane (insertion index as the daemon reads it); a drag onto another pane's tab says to move it on the Mac. Unit-tested, not driven live. |
| Move Tab to Pane / New Workspace / another workspace | `move-tab-to-split`, `move-tab-to-new-workspace`, `move-tab-to-workspace` | — | missing | Allowlisted; no phone UI yet (the phone shows a workspace's tabs as one list, no panes). |
| Pin / Unpin Tab | `set-tab-pinned` | — | missing | Allowlisted; no UI. |
| Split Right / Down, New Column / Row, Zoom Pane | `split`, `new-pane-right`, `new-row`, `zoom-pane` | — | not applicable | The phone shows one tab at a time; panes are a Mac layout. |
| Reopen Last Closed Tab (⇧⌘T) | resource `closed.reopen` | — | not from a phone (yet) | The resource API is not on the phone's lane. |
| Restart Shell Here | `restart-tab` | — | not from a phone | Respawns a program; the remote relay rules need live verification on the Mac first (CLAUDE.md "Remote CLI relay"). |
| Tab groups (create, rename, close, save, reopen) | `*-tab-group*` | — | missing | Allowlisted; no UI. |

## Workspaces

| Mac action | Mac sends | Phone | State | Notes |
| --- | --- | --- | --- | --- |
| Rename Workspace… (⇧⌘R) | `rename-workspace` | row swipe / menu Rename | works | |
| Close Workspace (⇧⌘W) | `close-workspace` | row swipe / menu Close Workspace | works | |
| Close Other Workspaces / Close Workspaces Below / Above | `close-workspace` × n | row menu > **Close** > the Mac's three titles | works (parity2) | Over the Mac's sidebar order of that Mac's workspaces (pinned first). The Mac closes at once; the phone asks first ("Close 3 workspaces?", naming them), since a long press is easy to misplace. The Mac has no "Close All Workspaces". |
| Move Workspace Up / Down | `set-personal-workspace {index}` (personal order), else `move-workspace {index}` | row menu > **Move** > **Move Workspace Up / Down** | works (parity2) | The same index the Mac's `movePersonalWorkspace` computes. No drag: a long press opens the row menu, and the list is not a reorderable List. |
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
| Restart Shell, Reset Terminal, Keep Running After Close | — | not from a phone | Program lifetime stays the Mac's (`restart-tab`, `set-terminal-keep` not allowlisted). |

## Browser

| Mac action | Phone | State | Notes |
| --- | --- | --- | --- |
| Address bar, Back (⌘[), Forward (⌘]), Reload (⌘R) | TabsKit address bar and toolbar | works on a streaming Mac | `browser-navigate` (http/https only), `browser-back`, `browser-forward`, `browser-reload`. |
| Open Link in New Tab | — | missing | The streamed page sends no link targets to the phone. |
| Hard Reload, Open in Default Browser, Incognito | — | not applicable | |

## Agent chat

| Mac action (wording) | Phone | State | Notes |
| --- | --- | --- | --- |
| Stop | page menu Stop Agent, composer stop | works | `session/cancel`. |
| Retry / Send this prompt again | Retry on a failed turn | works | |
| Switch Model… (⌃⌘M), Mode | composer model and mode menus | works for phone-started chats | A Mac-started Claude session keeps its model and mode from a phone (acpmux D13). |
| Continue in… (handoff) | page menu Continue in… | works | `_acpmux/handoff_*`. |
| Allow Once / Allow for This Chat / Deny | permission cards | works | Allow needs the phone's Face ID signature (pairing). |
| Queue: Edit / Remove / Send now | queue remove | partial | |
| Fork Conversation, Archive Chat, Checkpoints, Commit, Push | Checkpoints shown as unavailable | missing | The link carries no checkpoints; fork and archive have no phone UI. |
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
4. The streamed browser tab's address control reads "Address, about:blank" to
   VoiceOver after navigation, while it shows the page's host.
5. Forward once did nothing on the first tap right after Back (the next tap
   worked).

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
