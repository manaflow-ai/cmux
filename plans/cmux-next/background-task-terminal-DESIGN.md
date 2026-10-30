# Background task terminal

User (2026-10-20): "For the web UI for background tasks, I want to be able to click on it and
see a terminal that shows everything that ran in it, like the full stdin/stdout/stderr. Think
of what I would want to see and make it happen."

## What the person wants to see

A background task is a command an agent left running: a dev server, a watcher, a long test
run. When you click it you want to answer, in this order:

1. **What ran, where:** the exact command line and its folder.
2. **Is it still running:** its state, and since when (start time, elapsed).
3. **Everything it printed:** all of it from the first byte, not the last 64 KiB, in the
   order it was printed, with its colors (ANSI) kept.
4. **Live:** new output appears as it is printed while it runs.
5. **How it ended:** finished, failed, stopped (by you, the agent, a time limit), or lost
   (its harness exited), with the exit code when the harness reports one, and the duration.
6. **Act on it:** stop it from the view; search and copy its output.
7. **Never lag:** megabytes of output stream without freezing the chat.

## Decision: a real terminal tab, not a web widget

The view is a read-only terminal tab in the column right of the chat (the column a chat
opens its diff and preview in), running `acpmux process show --follow`. A real terminal
gives ANSI colors, Cmd-F search, selection and copy, scrollback and fast rendering of large
output for free, and it is what "a terminal that shows everything" means. A web widget would
re-implement each of those, worse.

It opens from every place a background task shows in the chat:

- the transcript note of its end ("Background task failed: npm test"): a click opens the note
  in place (the whole command, the end of its output from `_acpmux/process/tail`, the exit code
  when known, the harness's summary), and its **Open in terminal** button is the only thing
  that opens the terminal (Leo 2026-10-21: a click on the row must never replace the window);
- the chat summary's and the Inspector's Background tasks lists (running ones included), where
  a click on a row opens it.

## The view (`acpmux process show`)

```
$ npm run dev
  folder   ~/code/uploader
  started  Oct 20 14:03:11 · Claude Code · background
  log      ~/.claude/…/tasks/b7x.output
──────────────────────────────────────────────
<every byte of output, colors kept>
──────────────────────────────────────────────
● Running for 3m 12s   k stop   q close
```

and at the end, for example `✓ Completed after 3m 12s`, `✗ Failed (exit 1) after 4s`,
`■ Stopped by you after 3m 12s`, `? Lost: its agent exited`.

- **Header:** command (bold), folder, local start time, harness and origin (background or
  moved to the background), and the output file, so `less` or an editor can open it too.
- **Output:** read with `_acpmux/process/tail` from byte 0 in 1 MiB pages, written raw, so
  escape sequences and colors reach the terminal as the command printed them.
- **Live tail:** while it runs, the view asks for new bytes every 200 ms, backing off to 1 s
  while nothing new comes. (`process/watch` is not built in the daemon yet; when it is, the
  view switches to its notifications.)
- **Keys** (the tab is read-only, nothing reaches the process): `k` asks "Stop this
  process? y/N" and then calls `_acpmux/process/kill`; `q` or Ctrl-C closes the view (the
  process keeps running). After the end the footer stays until `q`, so the output can still
  be searched and copied.
- **Tab title:** the command, so the strip says what the tab shows.

## What is not possible yet, and why

- **stdout vs stderr:** Claude Code writes one output file per background shell, with both
  streams already merged in order. The order is right, but which line came from stderr is
  lost before acpmux sees it. Marking stderr needs Claude Code to keep the streams apart.
- **stdin:** background shells take no input (Claude Code has none; Codex's `write_stdin`
  is out of scope in `cmux-tui/crates/acpmux/docs/background-processes.md`). The command line
  is shown as the prompt line.
- **Exit code:** Claude Code reports only completed / failed / stopped; Codex reports the
  code, and the footer shows it when there is one.
- **Codex output:** `process/tail` is Claude Code only for now; for a Codex process the
  view shows the header, says the output is not shared yet, and still follows it to its
  end.
- **Another machine's chat:** process methods are local only (the daemon refuses remote
  WebSocket and peer connections), so the click works for chats on this Mac.

## Wiring

- **Page** (`webviews/src/agent-session/acpmux`): `processTerminal.ts` posts
  `chat.processTerminal {toolCallId}`; `BackgroundTaskNote`'s Open in terminal and the
  summary's and Inspector's background task rows call it.
- **Pane host** (`CmuxNextAgentPane`): `AgentPaneRequest.processTerminal(toolCall:)`; the
  model answers it through `AgentPaneHeaderHooks.openProcess(session, toolCall)`.
  `AgentPaneProcessViewer` builds the viewer's argv, title and environment
  (`ACPMUX_SOCKET` of the chat's daemon only, never a secret).
- **App** (`CmuxNextApp`): starts that argv with `create-terminal` (`new-tab` takes no argv
  and ran a bare shell instead) and places the tab in the column right of the chat
  (`AgentBesidePlacement`, as Changes and Preview open).
- **CLI** (`acpmux process list | show | kill`): `show` finds the process by id, or by the
  chat's session and the tool call that started it (also a subagent's).

## Tests (failing first)

- Rust (`cli/process.rs`): finding a process by tool call (subagent included), header and
  footer text for each state, replay of every byte across pages, follow until the end, a
  kill after `k` then `y`, and the Codex notice.
- Web (`agent-pane-background-tasks.test.ts`, `BackgroundMark.test.tsx`): clicking the end
  note opens it in place and posts nothing; its Open in terminal and the summary row post
  `chat.processTerminal` with the tool call id.
- Swift (`AgentPaneProcessViewerTests`): the request decodes, and the viewer's argv and
  environment.

## Later

- The running row in the transcript itself (the design's "Tail / Stop" row), when
  `process/watch` lands.
- Foreground commands ("Ran 5 commands"): their output is already in the transcript; the
  same view could replay one from the session log.
