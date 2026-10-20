# Terminal titles (OSC 0/1/2) name tabs and workspaces

Status: landed on `feat-cmux-next` (2026-10-19). Asked by Lawrence: "claude osc
titles (or osc titles in general) aren't working (for renaming tabs/workspace)".

## What was wrong

Traced end to end on NIGHTLY 4803cf8 with `printf '\e]2;hello\a'`, Claude Code,
Codex and a spinner script:

| Layer | Finding |
| --- | --- |
| Program | **Claude Code sets no title at all**: `~/.claude/settings.json` has `env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` (set for classic's hook-based naming). A settings `env` beats the process env, so cmux cannot turn it back on. With it cleared, Claude sends `✳ Claude Code`, then the task name (`Two-line Rust poem`). **Codex sets none either**: `~/.codex/config.toml` has `terminal_title = []`. |
| Daemon parser | OSC 0/2 work: `title-changed` reaches every subscriber, the tree's tab `title` is right. **CSI 22/23 t (title push/pop) are no-ops** in libghostty-vt, so a program that pushes, retitles and pops (vim, less, many TUIs) leaves its own title behind. **OSC 1** (icon name) is dropped. No sanitizing (control and bidi characters reach the UI; libghostty-vt cuts at 1024 bytes). The same title rewritten (a spinner's rest frame, a prompt redraw) is announced again. |
| App store | `TabModel.setTitle` keeps the raw title. A spinner title (`⠂ Task`, `⠐ Task`) changes the tab's text, and so the strip and sidebar row, on every frame. |
| Workspace | `WorkspaceAutoName` follows the front tab's title only when `workspaces.autoName` is on and the workspace has a daemon default name (`workspace-N`). Nearly all of the user's workspaces are user-named, so they do not follow a title; that is by design. |

Classic cmux "works" because its Claude hook (`cmuxterm-hq/.claude/hooks/user-prompt-submit.sh`)
renames the workspace and tab through the CLI from the first prompt; terminal titles
are off there too.

## Model

1. **The title belongs to the terminal**, set by the program in it: OSC 0 and 2
   set it; OSC 1 (the icon name) sets it only while no OSC 0/2 has. `CSI 22;{0,2,}t`
   pushes the title (at most 10), `CSI 23;{0,2,}t` pops it; `;1` (icon only) is ignored.
   The daemon's output path (`cmux-tui-core/src/terminal_title.rs`, run by
   `prompt_mode_reset::write_output`) rewrites a pop and an early OSC 1 into the `OSC 2`
   that applies them, so the terminal, every hosted mirror and every attach client
   parse the same bytes.
2. **The daemon stores it** (`PtySurface.title`, the terminal-host snapshot), sanitized
   (`terminal_title::sanitize`: no C0/C1 controls, no bidi embeddings, overrides,
   isolates or marks, no zero-width spaces or BOM; tab/newline read as a space; trimmed;
   at most 256 characters; a zero-width joiner stays). It survives an app restart, a
   daemon reattach and a host reconnect because it lives in the daemon and the host.
3. **One event per change.** Each parser announces a title only when the sanitized text
   differs from the one it last stored, and a resize replay announces nothing. The event
   bus already coalesces `title-changed` per surface (last value wins), so a burst
   reaches a slow client as one event.
4. **Precedence** (highest first, sticky): a user rename (strip, palette, sidebar) and an
   agent or CLI rename (`cmux tab rename`, Chief) both store the tab's `name` with its
   `name_source`; then the program's live title; then the fallback (the cwd's folder,
   from OSC 7). An OSC title never overwrites a name. Clearing the name (empty name,
   Clear Tab Name, `cmux tab clear-name`) shows the live title again.
5. **Status glyphs are status.** `TerminalTitle(raw:)` (CmuxNextDaemon) moves leading
   spinner and state glyphs off the text: Braille frames and turning circles mean
   working, `✳ ● ⏺ ·` idle, `✓ ✔ ✅` done, `✗ ✘ ❌` failed. `TabModel.titleText` and
   `titleActivity` are assigned only when they change, so a spinner frame invalidates no
   view of `displayTitle`. A working glyph shows as the tab's working indicator when no
   other state (loading, OSC 9;4, OSC 7501) claims it. Browser titles keep their glyphs.
6. **When the program exits** the shell's integration sets its own title at the next
   prompt (seen live: `lawrence@host:~`); a shell that sets none keeps the last title
   until a program sets another. The fallback shows only for a terminal never titled.
7. **Workspace title**: the user's or CLI's name or title, else (with
   `workspaces.autoName` on, the default) the words of its **front tab**: the selected tab
   of the workspace's focused pane, or the last focused work tab when a browser page
   fronts it (`SidebarMapping.workTab`). A named workspace is never renamed
   (`WorkspaceAutoName.isUserNamed`).

## Tests

- Rust unit (`terminal_title::tests`): push/pop with every parameter form, an
  icon-only push, an empty stack, a sequence split across chunks, OSC 1 before and after
  OSC 2, the 10-deep stack, sanitize, no copy for plain output.
- Rust end to end (`tests/pty.rs`
  `a_spinner_titled_agent_retitles_the_terminal_once_per_change`): a fake Claude prints
  spinner titles, a duplicate frame, a bidi override and a push/pop; the stored title
  follows, the pop restores, no title is announced twice in a row.
- Swift (`TerminalTitleTests`, `TerminalTitleTabItemTests`, `WorkspaceAutoNameTests`):
  glyph parsing, no invalidation on a spinner frame, name precedence and clearing, the
  strip's title and working mark, the workspace label.

## Not done

- The fallback names the folder, not the foreground process (`vim — notes`); the daemon
  knows the process (`process` in the tree) but no tab reads it yet.
- No live-app check: the NIGHTLY on this Mac predates the change.
- Turning Claude's and Codex's titles on is a user setting (see the table above).
