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
| New Workspace in a folder / Open Folder… (⌘O) / New Workspace Like This | `create-workspace` + `create-terminal {cwd}` | New Workspace (hold) > **Recent Directories** | partial (this branch) | The folders of the Mac's workspaces and the ones used on this phone. The new terminal types `cd '<folder>' && clear`, since the phone sends no `cwd`. No free folder picker: a phone browses no Mac folders. |
| New Browser Workspace (⌥⌘N) | `new-frontend-browser-tab` | New Workspace (hold) > **New Browser Workspace** | works | |
| New Agent Chat over Home (a workspace whose only tab is the chat) | `create-workspace`, `new-conversation-tab` | — | missing | Two steps on the phone: New Workspace in a folder, then New Agent Chat. |

## Tabs

| Mac action | Mac sends | Phone | State | Notes |
| --- | --- | --- | --- | --- |
| Close Tab (⌘W) | `close-surface` | grid ×, page menu Close Tab | works | Asks first when a program runs. |
| Rename Tab… (⌘R) | `rename-surface` | page and card menu **Rename Tab…** | works (this branch) | Rolls back on refusal. |
| Duplicate Tab | `new-tab` / browser duplicate | page and card menu **Duplicate Tab** | partial (this branch) | Terminal: a new terminal in the tab's pane (hostd's folder choice). Browser: the same http(s) page. Agent chat: none; use Continue in…. |
| Move Tab Left / Right, drag | `move-tab` | drag in the grid | works (this branch) | To the place of the tab it lands on, across panes too. |
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
| Close Other / Above / Below / All | `close-workspace` × n | — | missing | |
| Move Workspace Up / Down, drag | `move-workspace` | — | missing | The phone list is ordered by activity. |
| Pin, Color, Icon, Description, Clear Name | `set-workspace-metadata` | — | missing | Allowlisted. |
| Mark as Read / Unread | `ack-tab-notifications` | open marks read | partial | |
| Duplicate Workspace | composed app-side | — | missing | |
| Workspace groups | `*-workspace-group*` | — | missing | Allowlisted; no UI. |
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
| Trust this folder ("Trust / Don't trust") | — | not from a phone | acpmux refuses `acp.trust.set` from a remote connection; answer on the Mac. |

## Chief and the Feed

| Mac action | Phone | State | Notes |
| --- | --- | --- | --- |
| Chief conversation, questions | Home > Chief | works | Answers need the phone's signature. |
| Stop the Chief, Chief settings | Chief settings | works | `chief.stop`, `chief.engine.*`. |
| New Chief…, Archive Chief, Memory Inspector | — | missing | |
| Show Feed, Jump to Latest Unread, Mark read | Feed tab, swipe | works | |
| Clear All Notifications, Mute workspace | — | missing | Resource op `notification.clear` is not on the lane. |

## Verification

See "Live run" below for what ran against the real link.
