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
- `agent-pane/theme.css`: every composer icon button highlights as a circle (`--cv-composer-icon-radius`).
- `keybindings.json`: the reference app's keys.
- `customize/`: one customize app, `local/customize`, with the Chats section, the thread hover card,
  the row decorations (from `../sidebar`) and the builder New Tab page (from `../send-parity`). Each
  part is that look's `main.js` unchanged, in its own scope.

## Features

Each feature of the reference app, and how this look matches it or which gap is left.
Totals: 5 matched, 18 partial, 3 missing, out of 26.

| Feature | Status | In this look, or the gap |
| --- | --- | --- |
| Integrated terminal scoped to the checkout | matched | cmux is terminal-native: every workspace has terminals in its cwd. |
| Split and full tab views | matched | `tabs.hideLoneChatTab`. |
| Slash commands in the composer | matched | cmux's agent composer offers the harness's slash commands; Codex's list itself is harness-defined. |
| Automations (scheduled tasks in project or worktree) | matched | cmux has automations (scheduled, catch-up, failure states); look surfaces them in the sidebar like Codex. |
| Search chats | matched | `tabs.toolbarButtons` carries `agentPane.searchChats`. |
| Keyboard shortcut set (new chat, diff, model switch, sidebar tab cycling, shortcut search) | partial | keybindings.json binds all seven keys. |
| Jump to next chat that needs attention | partial | Gap: no public action names "next chat that needs you", so no key is bound. |
| Deep links (codex:// to chats and Settings pages) | partial | cmux has its own cmux:// links; no codex:// scheme, and Settings sub-page links are not checked against Codex's. |
| Diff / review pane beside the thread | partial | `openDiffViewer` in the toolbar and on `ctrl+shift+g`, `diff.layout: unified`. Gap: opens as a tab, not docked. |
| Stage / revert per file or hunk, inline diff comments the agent addresses | partial | cmux's diff viewer has hunk actions and inline comments in code; not verified to send comments back to the chat the way Codex does. |
| Pull request review view (description, files, comments, checks) | partial | cmux has a PR widget look and browser; no Codex-style in-app PR review page. |
| File tree panel | partial | The look binds Cmd-Shift-E to agentPane.toggleFiles; Codex's own file tree is not confirmed in its docs, so parity is unverified. |
| Plan mode | partial | cmux has a plan-mode access chip (Normal / Plan) in the composer; Codex's current docs do not document a plan mode page, so only the presence is comparable. |
| Attachments: images and files in the composer, image output in chat | partial | `agentPane.attachmentView: strip`. |
| Status / progress: per-thread unread and running indicators, ages | partial | One-line rows, `sidebar.showTimestamps`, arc status mark, `notifications.attention.agentChats: ring`, priority view. |
| Model + reasoning effort picker | partial | Gap: effort is inside the model menu; no setting splits it into its own chip. `ctrl+shift+m` opens the picker. |
| Permission chip (Default permissions) | partial | Codex shows 'Default permissions' left in the composer; cmux shows 'Normal' with a shield in the same slot. |
| Account / profile menu at the sidebar foot (invites, workspace switch) | partial | cmux has a profile menu on the sidebar-foot avatar (sidebar.profileMenu) with sign-in/out; it is cmux-account and browser-profile switching, not the reference app's workspace switching; Codex's current foot row is Settings. |
| Settings window with left nav (General, Appearance, Configuration, Personalization, MCP servers, Git, Environments, Worktrees, Archived threads) | partial | Gap: a look cannot reorder or rename Settings sections. |
| Appearance: theme import/copy, accent/background/foreground, UI and code font, contrast, UI font size | partial | cmux theme files cover colors and fonts and the look sets system-ui at 15 px; no contrast slider or Codex theme import. |
| Skills and plugins | partial | Sidebar Skills row matches; cmux's App Store is the plugin surface rather than Codex's Plugins page. |
| Threads grouped by project with ages, pinned chats | partial | The Chats section (customize/): New chat, Pinned, by project or one list, a sort; `sidebar.groupBy: folder`. |
| Mobile control of desktop chats | partial | cmux has an iOS app and cloud machines; not the reference mobile app's flow. |
| Review command with prioritized findings | missing | No built-in review command that lists ranked findings; cmux relies on the harness or a skill. |
| Work location chip (Local / Worktree / Cloud) and branch chip under the composer | missing | cmux has workspaces, worktrees and cloud machines, but no location/branch chip row under the composer. |
| Local <-> worktree handoff of a chat | missing | No one-click move of a chat between the main checkout and a worktree. |

## Motion

The reference app moves little and fast. There is no public recording of it, so none of its timings
can be measured, and this look does not invent any. It keeps cmux's `ui.animationSpeed: fast`, pane
animations and every `ui.animations.*` group on. A sent prompt already lands in one frame.

| Motion | Reference | In this look |
| --- | --- | --- |
| Model picker open and close | unmeasured | cmux's overlay motion at fast speed |
| Account menu open and close | unmeasured | cmux's overlay motion at fast speed |
| Settings open | unmeasured | cmux's page motion at fast speed |
| Streaming text reveal | unmeasured | gap: no `agentPane.display.streaming` setting |
| Hover and press on rows and chips | unmeasured | cmux's feedback motion; circular icon highlight from theme.css |
| Sidebar reorder on new activity | unmeasured | cmux's sidebar motion at fast speed |

## Gaps

These are the places where the public API could not express the reference app:

- **One customize app per look.** A look's `customize/` is the one `local/customize` app, and
  `implements` holds each interface once. So `../threads`' Activity section (`cmux.section/1`) can't
  ship next to the Chats section. This look keeps Chats and turns on cmux's own priority view instead.
- **Sidebar sections the look cannot name.** Nightly 4572038238101 (hq `goals/customize-app-profiles.parity.json`,
  codex-app `sidebar`) still draws Priority, Chief, a Chats header with Organize and a No Folder section where the
  reference app draws a workspace switcher header, Active work and Recents. `sidebar.sections.hidden` and
  `sidebar.sections.order` (docs/cmux-next/sidebar-customization.md) take section ids, but no document lists the ids
  of those four sections, so this look sets none rather than guess; the ids need reading from a live sidebar
  document (`cmux-layout-reducer` `sidebar_section_customization.rs` takes `id` or `keys`). Renaming a section
  (Priority to Active work) has no setting.
- **Settings nav and section rows.** `sidebar.nav` styles the sidebar only; no setting restyles the Settings window's
  nav or rows (the `settingsSections` look is not a key), so the Settings gap stays.
- **No motion timings.** A look can switch animations on or off and pick a speed. It cannot set a
  duration or an easing for any one transition.
- **No "next chat that needs you" action** to bind a key to.
- **Model and effort as separate chips.** Effort is inside the model menu. `cmux.composer.chip/1` could draw an effort chip, but it would need its own customize app (see the first gap).
- **No location and branch chip row** under the composer (Local, Worktree, Cloud), and no handoff of
  a chat between the main checkout and a worktree.
- **No review command** that lists ranked findings.
- **Pending settings:** sidebar width limits, row radius, inset and padding, `sidebar.sortBy`,
  `sidebar.rowHoverAction`, `agentPane.display.sendPop` (cmux#50293) and `agentPane.sendPlacement`.
