# Reference desktop agent app, whole

Opt-in. This look is the whole Codex desktop app in one folder. It joins the codex-app recipe with the
four codex feature looks next to it (`../composer`, `../send-parity`, `../sidebar`, `../threads`), so
one install gives you the colors, type, sidebar, composer, keys, New Tab page and motion together.
It is built only from the public customization docs (`docs/cmux-next/extensions/`).

```sh
cmux setup install ./examples/looks/codex/profile --yes
cmux setup remove manaflow-ai/codex-profile   # everything you had comes back
```

## What is in it

- `cmux-setup.json`: the settings, with each pending key as a comment naming its pull request.
- `themes/codex-app.json`: the colors `appearance.themeFile: codex-app` loads (the codex-app recipe's), shipped in
  the pack so a fresh install finds it.
- `agent-pane/theme.css`: every composer icon button highlights as a circle (`--cv-composer-icon-radius`), and
  the reference app's own durations and curves on cmux's motion tokens (Motion, below).
- `keybindings.json`: the reference app's keys.
- `customize/`: one customize app, `local/customize`, with the Chats section, the thread hover card,
  the row decorations (from `../sidebar`) and the builder New Tab page (from `../send-parity`), each
  part in its own scope. The Chats section adds the reference app's Active work and Recents to
  `../sidebar`'s; the rest is those looks' `main.js` unchanged.

## Features

Each feature of the reference app, and how this look matches it or which gap is left.
Totals: 6 matched, 18 partial, 3 missing, out of 27.

| Feature | Status | In this look, or the gap |
| --- | --- | --- |
| Integrated terminal scoped to the checkout | matched | cmux is terminal-native: every workspace has terminals in its cwd. |
| Split and full tab views | matched | `tabs.hideLoneChatTab`. |
| Composer placeholder ("Ask for follow-up changes") | matched | `agentPane.composerPlaceholder`. |
| Slash commands in the composer | matched | cmux's agent composer offers the harness's slash commands; Codex's list itself is harness-defined. |
| Automations (scheduled tasks in project or worktree) | matched | cmux has automations (scheduled, catch-up, failure states); look surfaces them in the sidebar like Codex. |
| Search chats | matched | `tabs.toolbarButtons` carries `agentPane.searchChats`. |
| Keyboard shortcut set (new chat, diff, model switch, previous and next chat, rename, archive, pin, mark unread, copy link and path, reopen, shortcut search) | partial | keybindings.json binds 16 keys to the cmux commands that do the same; eight more are cmux's defaults already. Gap: the reference app's toggle terminal (Command-J), side chat, temporary chat and copy last code block have no cmux command. |
| Jump to next chat that needs attention | partial | Option-Command-A runs `jumpToUnread` (the latest unread). Gap: the reference app's walks every chat waiting on you in turn. |
| Deep links (codex:// to chats and Settings pages) | partial | cmux has its own cmux:// links; no codex:// scheme, and Settings sub-page links are not checked against Codex's. |
| Diff / review pane beside the thread | partial | `openDiffViewer` in the toolbar and on `ctrl+shift+g`, `diff.layout: unified`. Gap: opens as a tab, not docked. |
| Stage / revert per file or hunk, inline diff comments the agent addresses | partial | cmux's diff viewer has hunk actions and inline comments in code; not verified to send comments back to the chat the way Codex does. |
| Pull request review view (description, files, comments, checks) | partial | cmux has a PR widget look and browser; no Codex-style in-app PR review page. |
| File tree panel | partial | The look binds Cmd-Shift-E to agentPane.toggleFiles; Codex's own file tree is not confirmed in its docs, so parity is unverified. |
| Plan mode | partial | cmux has a plan-mode access chip (Normal / Plan) in the composer; Codex's current docs do not document a plan mode page, so only the presence is comparable. |
| Attachments: images and files in the composer, image output in chat | partial | `agentPane.attachmentView: strip`. |
| Status / progress: per-thread unread and running indicators, ages | partial | One-line rows, `sidebar.showTimestamps`, arc status mark, `notifications.attention.agentChats: ring`; the Chats section's Active work lists the chats working or waiting on you. |
| Model + reasoning effort picker | partial | `agentPane.display.modelPickerStyle: menu`: the chip opens a short model list with a check and an Effort submenu, as the reference does; More models opens the full picker. `ctrl+shift+m` opens the picker. |
| Permission chip (Default permissions) | partial | Codex shows 'Default permissions' left in the composer; cmux shows 'Normal' with a shield in the same slot. |
| Account / profile menu at the sidebar foot (invites, workspace switch) | partial | cmux has a profile menu on the sidebar-foot avatar (sidebar.profileMenu) with sign-in/out; it is cmux-account and browser-profile switching, not the reference app's workspace switching; Codex's current foot row is Settings. |
| Settings window with left nav (General, Appearance, Configuration, Personalization, MCP servers, Git, Environments, Worktrees, Archived threads) | partial | Gap: a look cannot reorder or rename Settings sections. |
| Appearance: theme import/copy, accent/background/foreground, UI and code font, contrast, UI font size | partial | cmux theme files cover colors and fonts and the look sets system-ui at 12 px; no contrast slider or Codex theme import. |
| Proportions: type size and transcript column width | matched | The nightly capture read cmux's type about 1.3x larger than the reference in the sidebar and transcript, and the reference column wider. `agentPane.display.font.size` 12 (was 15), `appearance.metrics.chromeFontSize` 11 (was 14) and `agentPane.display.width` 1200 (was 1000). Needs a recapture to confirm. |
| Skills and plugins | partial | Sidebar Skills row matches; cmux's App Store is the plugin surface rather than Codex's Plugins page. |
| Threads grouped by project with ages, pinned chats | partial | The Chats section (customize/): New chat, Active work, Pinned, Projects and Recents (chats with no folder), or one list, and a sort from the heading's `…`; `sidebar.groupBy: folder` with `sidebar.folderlessUngrouped`, so no No Folder header. cmux's top section (Home, drawn as Chief) is hidden and sections draw no header (`sidebar.sectionLook: lines`). Gap: no workspace switcher header. |
| Mobile control of desktop chats | partial | cmux has an iOS app and cloud machines; not the reference mobile app's flow. |
| Review command with prioritized findings | missing | No built-in review command that lists ranked findings; cmux relies on the harness or a skill. |
| Work location chip (Local / Worktree / Cloud) and branch chip under the composer | missing | cmux has workspaces, worktrees and cloud machines, but no location/branch chip row under the composer. |
| Local <-> worktree handoff of a chat | missing | No one-click move of a chat between the main checkout and a worktree. |

## Motion

The reference app's timings come from its shipped desktop build (26.1120.50957): its stylesheets'
duration and curve tokens and its motion module, read value by value. None is a guess. The look puts
them on cmux's motion tokens in `agent-pane/theme.css`; animations off or Reduce Motion still put
cmux's own values back.

| Motion | Reference (source) | In this look |
| --- | --- | --- |
| Hover and press on rows and chips | 75 ms, `ease` (row and button hover rules) | `--cmux-motion-quick: 75ms`; circular icon highlight |
| Model picker, menus and popovers open | 0.15 s on `cubic-bezier(0.23, 1, 0.32, 1)` (basic duration; motion module base) | `--cmux-motion-micro: 150ms`, `--cmux-ease-out` |
| A panel or card entering | 0.2 s (moderate duration) | `--cmux-motion-standard: 200ms` |
| A sheet, drawer, Settings open, the chat switch | 0.3 s (relaxed duration) | `--cmux-motion-large: 300ms` |
| A fold opening or closing | 0.24 s on `cubic-bezier(0.22, 1, 0.36, 1)` (disclosure rows) | `--cmux-motion-settle: 240ms`, `--cmux-ease-settle` |
| A selection that travels | the snappy `linear()` spring (20 stops) | `--cmux-ease-spring` |
| Working line shine | one band half the line wide, -100% to 250% in 2 s, `steps(48)` | `agentPane.display.thinking.shimmer: continuous`, `shimmerPeriod: 2000`, `shimmerBand: 0`. Gap: cmux's band eases, the reference steps |
| Streaming text reveal | each new word fades in over 0.7 s on `cubic-bezier(0.37, 0.55, 0.86, 0.88)`, no stagger, while live; 0.15 s with a 24 ms stagger (at most 0.8 s) otherwise | `--cmux-motion-stream: 600ms` (the look bound; 0.1 s short of the reference), `--cmux-ease-stream` on its curve |
| Send button morph (send, stop, voice) | 0.48 to 0.52 s keyframes, the stop square turning 90 degrees | Gap: cmux's send button swaps its icon |
| Sent prompt and the thread's rise | a 0.5 s spring, no bounce | left to `../send-parity` (the send placement is still being chosen) |
| Sidebar reorder on new activity | not found in the build (its list moves run in script) | cmux's sidebar motion at fast speed |

## Gaps

These are the places where the public API could not express the reference app:

- **One customize app per look.** A look's `customize/` is the one `local/customize` app, and
  `implements` holds each interface once. So `../threads`' Activity section (`cmux.section/1`) can't
  ship next to the Chats section. The Chats section draws Active work itself instead.
- **Sidebar.** Nightly 4572038238101 (hq `goals/customize-app-profiles.parity.json`, codex-app `sidebar`) drew
  Priority, Chief, a Chats header with Organize and a No Folder section where the reference app draws a workspace
  switcher header, Active work and Recents. The look now leaves the priority view off, hides cmux's top section
  `sec_top` (Home, drawn as Chief, and the App Store), draws sections with no header (`sidebar.sectionLook: lines`),
  ungroups chats with no folder (`sidebar.folderlessUngrouped`), and its Chats section heads New chat, Active work,
  Projects and Recents, with the sort and grouping in a `…` menu on the Projects heading. Left: no setting draws a
  workspace switcher header over the sidebar.
- **Settings nav and section rows.** `sidebar.nav` styles the sidebar only; no setting restyles the Settings window's
  nav or rows (the `settingsSections` look is not a key), so the Settings gap stays.
- **Motion left.** The send button's icon morph and the stepped shine have no token yet, and the
  streaming fade stops at the 600 ms look bound (Motion, above).
- **No "next chat that needs you" action** that walks every waiting chat; Option-Command-A jumps to the
  latest unread.
- **Model and effort as separate chips.** Effort is inside the model menu. `cmux.composer.chip/1` could draw an effort chip, but it would need its own customize app (see the first gap).
- **No location and branch chip row** under the composer (Local, Worktree, Cloud), and no handoff of
  a chat between the main checkout and a worktree.
- **No review command** that lists ranked findings.
- **Pending settings:** sidebar width limits, row radius, inset and padding, `sidebar.sortBy`,
  `sidebar.rowHoverAction`, `agentPane.display.sendPop` (cmux#50293) and `agentPane.sendPlacement`.
