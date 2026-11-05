# Workspace hover card: history, layouts, settings (u3320)

Lawrence, 2026-10-19:

> On hover over workspaces right now, we see some timings but I want to see the history of
> prompts that were sent, as well as when they were sent and when Codex completed. I want to know
> when Claude started waiting for my input, stuff like that. Any ideas or more designs for how we
> can make the hover card thing better? We also need to make it more customizable. We need to have
> a scrollable support area as well. Right now if I scroll, it just completely goes into the card.
> If I open a card, move my mouse over, and start scrolling, the card just disappears.

Gallery of the five designs: [gallery.html](gallery.html) (open it in a browser; light and dark).

## 1. The scroll bug

The card is a click-through child window (`HoverCardPanel.ignoresMouseEvents = true`): hit tests
look through it, so the hover machine sees the row under it. A wheel event over the card went to the
window under it (the sidebar scrolled) and the coordinator's dismissal monitor hid the card on every
`.scrollWheel`.

Fix (`HoverCardCoordinator.handleMonitoredEvent`): a wheel event whose pointer is on the shown card
belongs to the card. The coordinator hands it to the card (`HoverCardPanel.scrollCard`), which
scrolls its innermost scroll view under the pointer, and swallows it (the monitor returns nil), so
the sidebar never moves and the card stays. A wheel event off the card still ends it, as before.
The panel keeps ignoring the mouse: nothing about hover hit testing or a94's motion changes.

Tests: `WorkspaceHoverCardScrollTests` (red first: 6f365c08921).

## 2. Where the history comes from

| Moment | Terminal agents (Claude Code, Codex via hooks) | Agent chats (acpmux) |
| --- | --- | --- |
| Prompt sent (text, time) | `agent-changed` working with a new `last_prompt` / hook report (`AgentRoster.startsPromptedTurn`) | summary `turn.prompt`, `turn.startedAt` |
| Started (no prompt known) | non-hook reporter's start of work | working with no prompt |
| Waiting for your input | state `blocked` (permission, question) | indicator `input` |
| Finished | `working`/`blocked` to `idle`/`done` | `working`/`input` to done or none |
| Failed | (none) | indicator `failed` / `lost` |

Recording:

- `AgentTimeline` (CmuxNextDaemon): one agent's moments, oldest first, at most 64 events and 240
  characters of text each, memory only. Exact repeats (a resync re-seeding the same status) add
  nothing. An answer to a wait (blocked to working with the same prompt) is no new prompt.
- `AgentRoster.timelines`: one per terminal, at most 512 terminals (the quietest dropped first).
  It is fed by the same `apply`/`seed` path as Jump to Last Prompt, so it follows resyncs.
- `AgentTurnStateStore.Session.timeline`: one per chat, from `apply`. The watch closing
  (`clearLive`) notes nothing.
- `WorkspaceTimelineReader` (CmuxNextBridge) merges a workspace's tabs, newest first, when a card
  opens. Nothing is read per frame and no row redraws for a new moment (the timelines are not
  observed).
- The newest wait, while the workspace still waits, takes the row's reason
  (`SidebarWorkspaceDetail.needsInput`: the blocked program's words or the notification).

Not covered yet: the daemon keeps no history across an app restart (the roster is memory only), and
a remote machine's terminal agents report only what its daemon pushes while connected.

## 3. Five designs

All share the title row (name, kind icon, age) and the status row with its live elapsed time.

1. **Stats and History** (`timeline`, the default). Title, status, a stats line ("Prompts: 4 ·
   Worked 12m"), the facts (agent, task, folder, branch, PR, ports, machine, status entries), then
   "History": a scrollable list, newest first, at most 220 pt tall. Each line: clock time, an icon,
   the prompt (two lines) or what happened ("Codex finished", "Claude Code is waiting for your
   input: Allow Bash?"). Best default: it answers "what did I ask, when, and what is it doing now"
   without losing the facts the card already had.
2. **Compact** (`compact`). The facts card with the last three moments under it, no stats, no
   scrolling. For people who want the card small.
3. **Full History** (`log`). Only the title, status, stats and the history, 340 pt wide and up to
   360 pt tall, prompts up to three lines. For long-running agent workspaces.
4. **Details Only** (`classic`). The card before this change.
5. **Minimal** (`minimal`). Title, status and the last prompt.

Rejected: a per-agent column layout (two agents in one workspace interleave better by time), and
relative times on each line ("4m ago" ticks every second and makes the list jitter; the stats line
and the status row carry the running times).

## 4. Settings

One schema source (`schemas/settings/source/hover-cards.json`) feeds the Settings window rows,
cmux.json, the palette's settings rows (Cmd+Shift+P, the `,` scope) and `cmux settings set`:

| Key | Default | |
| --- | --- | --- |
| `sidebar.hoverCards.layout` | `timeline` | `timeline`, `compact`, `log`, `classic`, `minimal` |
| `sidebar.hoverCards.sections.timings` | `true` | running times and the stats line |
| `sidebar.hoverCards.sections.prompts` | `true` | prompts and starts in the history |
| `sidebar.hoverCards.sections.waiting` | `true` | waits, finishes, failures in the history |
| `sidebar.hoverCards.sections.git` | `true` | branch and pull request |
| `sidebar.hoverCards.sections.ports` | `true` | listening ports |
| `sidebar.hoverCards.maxRows` | `20` | 1 to 100 history lines |
| `sidebar.hoverCards.delay` | `1300` | (existing) ms before a card opens (Chrome's, 2026-10-28) |

Example:

```json
{ "sidebar": { "hoverCards": { "layout": "log", "maxRows": 40, "sections": { "git": false } } } }
```

```sh
cmux settings set sidebar.hoverCards.layout compact
cmux settings set sidebar.hoverCards.sections.ports false
```
