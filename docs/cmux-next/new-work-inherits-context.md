# New terminals and agent chats inherit your context

Tag: NEW-WORK-INHERITS-CONTEXT. Asked for by Lawrence (2026-10-22): every new terminal and every
new agent (ACP) chat starts in the same folder as the terminal or chat you used last, and a new
chat also starts on the same agent.

## The rule

The app keeps a list of the terminals and agent chats that had the keyboard, newest first
(`WorkContextTrail`, recorded when a window's focus settles on a tab's content). A new terminal,
split, workspace (Cmd-N), New Tab page or agent chat takes its folder from the first match:

1. The tab you are in, when it is a terminal or an agent chat.
2. The terminal or chat you focused last in the same workspace.
3. Only when that workspace has no terminal or chat of its own (a browser-only or empty
   workspace): the terminal or chat you focused last in the same window.
4. Nothing: the old fallbacks apply (the daemon's new-terminal resolver, then the home folder).

Why this order:

- It is what most terminals do (iTerm2, Ghostty, Terminal.app reuse the current session's
  folder), extended to the case they do not have: you are on a browser tab or a chat.
- A workspace usually is one project. Step 3 never brings another workspace's project into a
  workspace that has terminals of its own, even when nobody focused them yet (a restored launch);
  the daemon's resolver picks among those.
- Another window is never a source: a second window is often a separate task.
- Only this Mac's tabs are sources. A terminal or chat of another machine keeps its own folder
  rules, because its paths are that machine's.

An explicit folder (`--cwd`, a config command) always wins, and Ghostty's
`window-`, `tab-` and `split-inherit-working-directory = false` still start at home.

## Agent settings

A new agent chat starts on the harness of the agent chat you focused last, by the same rule but
with chats only (a terminal is never a source of agent settings). The chat page draws that harness
at once and starts the session on it with the first Send.

The model follows the existing last-pick memory for that harness (`lastPick.ts`: your last pick
in that folder, else anywhere). Effort and permission mode are not copied: acpmux accepts
`session/set_mode` and `session/set_config_option` only with the single-use ticket of a person's own
pick (`AgentPaneGestureIntent`), and copying a mode such as full access into a new chat without a
pick would bypass that guard. Copying them needs the app to issue those tickets for a person's own
New Chat action, as it does for a seeded prompt (`issueSeedTicket`); that is follow-up work.

## Where it lives

- `Packages/macOS/CmuxNext/Sources/CmuxNextApp/WorkContextTrail.swift`: the list and the rule
  (tests: `WorkContextTrailTests`).
- `AppServices+WorkContext.swift`: recording on focus settle, and the lookup of live tabs.
- `NewTerminalStart.inherited(besides:in:services:)`: the folder for every new terminal path
  (tab, split, Cmd-N, New Tab page, the docked chat's terminal).
- `PaneController.agentSeedFromSelectedTab()` and `inheritedHarness()`: a new chat's folder and
  harness.
- `webviews/src/agent-session/acpmux/App.tsx`: a seeded harness applies without a seeded prompt.
