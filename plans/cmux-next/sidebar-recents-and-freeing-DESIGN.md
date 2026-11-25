# Projects and Recents sidebar, and freeing idle workspaces (2026-11-05)

Ask (Lawrence, Nov 5): "i think we should have similar thing in sidebar as chatgpt app, make it an option,
basically u have projects/groups at the top, and show more, and you have recents as well, and we have good
heuristics of when a workspace's resources can be "freed" and restored. simple for acp + claude/codex tui, save
scrollback (bounded) for terminal processes with session restored + command to run to do same thing, where we have
storage optimizations, where it is configurable, and for older terminals, we trim more of their scrollback to save
on disk, we need to be wary of user's disk health tho so don't be excessive, make it configurable, like worst case
we just save the cli command that was last run, when it started, when it ended, think about what users would want"

Two parts: a sidebar layout (slice 1), and a third residency tier under workspace hibernation (slices 2 to 5).

## Part 1: Projects and Recents (slice 1)

`sidebar.groupBy` gets a third choice, `recents` ("Projects and Recents"; Settings > Appearance > Sidebar > Group
Projects By, `cmux settings`, cmux-next.json). Default stays `none`: the option is off by default.

On, the workspace list draws as the ChatGPT app's sidebar:

- **Projects**: one header over every computer's groups, in their manual order. The first 5 top-level groups list,
  then a "Show N more" row (opened: "Show fewer"). A list of 6 shows whole (a row that hides one saves nothing,
  as `sidebar.groupRowLimit`). The group that holds the active workspace always lists. Each open group lists its
  first 5 workspaces and "Show N more" (the existing row limit, 5 while this layout is on and the Debug tunable is 0).
- **Recents**: one header over every workspace in no group, from every computer, newest activity first
  (`SidebarWorkspace.lastActivity`; none last; ties keep the manual order). A newer activity moves the row, as a
  new message moves a ChatGPT chat to the top.
- Pinned, the document's sections, the Archive row and the Done fold work as before. A filter and the session tree
  list rows in place, as before. Group by Status wins over it. The list does not reorder by drag (as Group by Folder).

Files: `SidebarLayout+Recents.swift` (split and rows), `SidebarListHeader`, `ListHeaderRowView`,
`SidebarRowKey.listHeader`, `SidebarDoneFoldID.projects`. Tests: `SidebarRecentsLayoutTests`.

## Part 2: freeing idle workspaces (slices 2 to 5)

### What exists (measured by reading, Nov 5)

| Piece | Where | State |
| --- | --- | --- |
| Hibernation (app memory) | `CmuxNextHibernation`, workspace-hibernation-DESIGN.md | on, 60 min hidden and idle; processes keep running |
| Park a terminal, keep its tab | daemon `park-tabs` (`mux/terminal_reap.rs` `park_terminal_tabs`), `KeptStart::OnShow` | used only by the classic migration |
| Wake parked tabs on show | `DaemonService+ParkedTabs.wakeParkedTabs`, called by `WindowController` | works |
| Restart seeded with the previous screen | `terminal_respawn/manual.rs`, `launch.rs previous_screen` | exit snapshot, then output store, then journal checkpoint |
| Screen and scrollback on disk | daemon output store, `terminal.persistence.*` (snapshot mode: screen + 2,000 lines, 50 MiB total) | not in the schema, no Settings row |
| Agent TUI resume | `terminal_respawn/prefill.rs resume_command` (`claude --resume`, `codex resume`), `sessions.resumeAgents` | on |
| ACP chats | acpmux idle exit after 120 s, resume on the next prompt | already frees itself |
| Command start, end, exit, cwd | `shell_history.rs` `CommandTracker` (OSC 133 + OSC 7), `history.terminalCommands` | history store off by default |
| PTY reclaim | `mux/pty_reclaim.rs`: parks shells idle 30 min at a prompt when PTYs run low | on, only under PTY pressure |

So "free and restore" is mostly built: what is missing is a policy that parks idle terminals on purpose, a bounded
and aging scrollback for parked terminals, and the last-command record.

### Tiers

| Tier | When | What runs | What a show costs |
| --- | --- | --- | --- |
| Awake | shown, or hidden less than the hibernation idle time | everything | nothing |
| Hibernated | today's rule (60 min) | shells, programs, agents; no app views | cold mount, terminal replay |
| **Freed** (new) | hibernated and idle `workspaces.freeing.idleMinutes` (default **1440**, one day) | nothing of its terminals | a new shell in the same folder, the saved screen drawn above it |

### Which terminal tabs free (defaults)

A tab frees only when every fact below holds; any unknown fact keeps it running.

- A shell at an empty prompt: OSC 133 A seen, no command between C and D, nothing typed on the prompt line, no
  OSC 7501 program status, no client attached. A terminal without shell integration never frees (we cannot tell
  vim from a prompt).
- A Claude Code or Codex TUI whose agent is idle (no turn, no permission or question waiting) and whose session id
  is recorded (`relaunch_store` agent_json): it frees and resumes with `claude --resume` / `codex resume` (the
  existing prefill rules: runs at once only when `sessions.resumeAgents` is on and no approval flag is off).
  `workspaces.freeing.agents` (default **true**).
- Never: pinned, Keep Awake, a running command, an agent working or waiting on the person, an ssh or remote
  terminal, a Cloud machine's terminal.
- Running commands (a dev server, `tail -f`): `workspaces.freeing.runningCommands` = `never` (default) or
  `relaunch` (ends it; on show the command is typed at the new prompt without Return). Default never: ending a
  program the person started is not ours to do silently.

### What is kept on disk for a freed terminal

One record per terminal (the existing `terminal_relaunch` row plus a small `last_command` field): cwd, shell, last
command line (1 KiB cap), its start, end and exit code. Always kept while the tab exists (about 300 bytes).

Plus the screen and scrollback snapshot, trimmed as it ages (`terminal.persistence.parkedTiers`):

| Freed for | Scrollback kept (default) |
| --- | --- |
| under 1 day | 2,000 lines (the snapshot mode's default) |
| 1 to 7 days | 500 lines |
| 7 to 30 days | 100 lines (about the screen) |
| over 30 days | none: the record only (worst case the ask names) |

- Budget: `terminal.persistence.parkedMaxTotalBytes` (default **256 MiB**). Over it, the oldest snapshots step down a tier
  first, then lose their scrollback.
- Disk health: under `terminal.persistence.minFreeDiskBytes` (default **5 GiB**) or 5% free, a freed terminal keeps the
  record only, and no trim rewrites a file.
- SSD writes: a freed terminal writes its snapshot once when it frees (it makes no output after). A trim rewrites
  a file only when it changes tier: at most three rewrites in a terminal's life, done in the daemon's idle pass
  (one deadline, no polling), gzip as today.

### Restore

Showing a freed workspace wakes its parked tabs (existing `wakeParkedTabs`): each starts a new shell in its cwd,
draws the saved screen above a dim marker line, "Restored · last: `npm test` · exit 0 · 14:02 to 14:05". Palette
and tab menu: "Run Last Command Again" (types it without Return). Agent tabs resume their session. A record-only
terminal shows the marker line alone.

### Settings (cmux-next.json, Settings > General > Hibernation)

| Key | Default |
| --- | --- |
| `workspaces.freeing.enabled` | false (first release; on after dogfood, see below) |
| `workspaces.freeing.idleMinutes` | 1440 (one day) |
| `workspaces.freeing.agents` | true |
| `workspaces.freeing.runningCommands` | `never` |
| `terminal.persistence.parkedTiers` | the table above |
| `terminal.persistence.parkedMaxTotalBytes` | 256 MiB |
| `terminal.persistence.minFreeDiskBytes` | 5 GiB |

Off by default at first: freeing ends shell processes, which is user-visible high-tier behavior (risk tiers say a
default-off setting first). Flip it on once a week of dogfood shows no lost state.

### Slices

1. Projects and Recents sidebar (this change).
2. Freeing policy (shells): `WorkspaceFreeingPlanner` (pure) and the coordinator's freeing pass after each
   hibernation pass; the App host reads this Mac's daemon store (prompt, command, output, OSC 7501, agent record,
   remote) and parks through `park-tabs`; `workspaces.freeing.enabled` / `idleMinutes` rows. Agent TUIs stay
   running in this slice (an agent record keeps a terminal); they free in slice 4 with their resume (done).
   Tests: `WorkspaceFreeingTests` (eligibility table, settings, coordinator with a fake host).
3. Daemon: parked snapshots trim by tier, budget, free-space guard (`output_store/parked_trim.rs`), run with the
   store's prune and once a day from the writer; only a terminal whose shell ended (its tab stays) trims. Byte keys
   match the other `terminal.persistence.*Bytes` keys. Rust tests with a fixed clock and a given free-disk state.
4. Last-command record, the restored marker line, Run Last Command Again, `runningCommands: relaunch`. The record
   exists: the daemon's command history (`terminal-command-history-v1`, `mux/command_history.rs`) stores each
   finished OSC 133 command per terminal with its start, end and exit, but only while the history is on (off by
   default, and its module promises no screen text is read until a client turns it on). So slice 4 (4a, done) adds
   `shell_history::Recording::LastCommand`: while `workspaces.freeing.enabled` is on, each terminal's tracker keeps
   its newest finished command in memory only (never the history store). `park-tabs` writes it into the kept tab's
   row (`kept_tabs.last_command_json`, one row, about 100 bytes plus the 1 KiB-capped line; none for an incognito
   terminal), and the respawn marker reads it: "session restored · last: `npm test` · exit 1" (en, ja in the
   daemon catalog). 4b, done: the restored shell's prompt gets that command typed without Return (one line only,
   on a marked, empty prompt with the shell in the foreground; a person's own resume command and an agent resume
   win), so the person runs it again with Return (`Prefilled::LastCommand` in the respawn log). Also done (4b):
   "Run Last Command Again" (palette, terminal menu Tools ▸; `terminal-last-command-v1` reads a live shell's
   newest finished command, typed as a paste without Return only while the shell itself is in front);
   `workspaces.freeing.runningCommands: relaunch` (the park keeps the running command line, which the freed shell
   offers again; `never`, the default, keeps every terminal of a workspace that runs a command); and
   `workspaces.freeing.agents` (default on): an agent TUI that is idle, has a harness session id and asks the
   person nothing frees, and the respawn's agent prefill resumes it (without an agent record the shell offers the
   agent's command line instead). Tests: `WorkspaceFreeingTests`, `a_parked_running_command_is_kept_as_its_last_command`,
   `a_live_shell_reports_its_last_command`, `TerminalLastCommandRequestTests`.
5. Hover card "Freed 2d ago · restores on open", `debug.surfaces` counts, docs.
