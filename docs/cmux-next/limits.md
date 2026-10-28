# cmux-next limits: scale and abuse

What breaks first at large sizes and with bad input, and at what limit. From pro audit 14
(2026-10-28), read from the code at perf/chrome-parity 4a27193f7ac; nothing in this table was
measured on a Mac yet (see "Not measured"). Each row names the constant, so a change to it must
change this page.

"Refused" means cmux says no and keeps running. "Dropped" means the data is lost with no message.

## Terminal input

| Case | First limit | What happens | Where |
| --- | --- | --- | --- |
| Paste or scripted input, one terminal | 1 MiB per `send` line (after the fix in `cp/audit-14-oversize-input`; before it, one line per paste) | Sent as consecutive lines, in order | `TerminalAttachment.maxInputBytesPerSend` |
| Request line to the daemon | 16 MiB (`MAX_JSON_LINE_BYTES`) | Before the fix: a paste of 12 MiB or more (base64 is 4/3) ended the connection, every terminal view on it reattached and the paste was lost. After: the request fails alone (`request_too_large`) | cmux-tui-core `server.rs:330`; `LineTransport.maxRequestLineBytes` |
| Paste larger than the app's socket queue | 64 MiB queued (`FrameWriter.defaultLimit`): about a 46 MiB paste on an idle connection | Before the fix: the connection stopped sending forever while output still came in. After: the paste is refused whole (logged), the connection stays | `FrameWriter.swift:60`, `TerminalAttachment.enqueueInput` |
| 100 MB paste | the 64 MiB queue above | Refused whole. Flow control (the input lane waits for the queue to drain) is open work | same |
| Input to a program that reads nothing | 16 MiB + 64 KiB for keys (`QUEUE_LIMIT_BYTES`) | More input is refused; keys still go in behind a full paste | cmux-tui-core `pty_write.rs:166-169` |
| App input lane overflow (the IO stops draining) | 16 MiB or 32,768 records | Later records dropped and counted | `TerminalInputLane.overflowByteLimit` |
| Typing while `yes` runs | output parsed in 64 KiB chunks; keys use their own lane | Keys are not starved | cmux-tui-core `surface/local_output.rs`, `pty_write.rs` |

## Terminal output

| Case | First limit | What happens | Where |
| --- | --- | --- | --- |
| Scrollback per terminal | 10 MB default (`SCROLLBACK_BYTES_PER_TERMINAL`); `scrollback-limit-bytes` has no upper clamp | 1 GB is accepted; total scrollback RAM is still capped by `scrollback_total` (64 MiB to 1 GiB from installed RAM), (how the total is enforced across terminals was not traced) | cmux-memory `budget.rs:16,38` |
| Copy scrollback as text | daemon control queue 32 MiB per connection, 128 MiB total | A larger reply fails (`outbound byte budget overflowed`); the whole history is formatted under the terminal lock first, so output of that terminal waits | cmux-tui-core `server/cmd_terminal_io.rs:517` |
| History after a respawn (full persistence) | newest 64 MiB raw output, rebuilt into a 10 MB scrollback | Older history is not restored, also with a 1 GB setting | cmux-tui-core `output_store/segments.rs:254-256` |
| One stored output frame | 64 MiB raw (`MAX_FRAME_RAW_BYTES`) | A larger frame is written but not read back: that frame and the later frames of the file are lost on rebuild | `output_store/segments.rs:44,193` |
| A view that falls behind | 256 items or 16 MiB per view | The view reattaches and resyncs | cmux-tui-core `surface/attach_tap.rs` |
| OSC title, cwd (OSC 7), link (OSC 8), clipboard (OSC 52) | 2,048 bytes (Ghostty `osc.zig` `MAX_BUF`); titles cut to 256 characters | Longer sequences are ignored; invalid UTF-8 becomes U+FFFD | ghostty-next `src/terminal/osc.zig:359`, cmux-tui-core `terminal_title.rs` |
| Notifications (OSC 9/777/99) | 4,096-byte body | Longer bodies are dropped | cmux-tui-core `terminal_metadata.rs:18` |
| Kitty graphics (APC) | 65 MiB per sequence; 10 MB images per terminal | Larger images are dropped with a log line | ghostty-next `src/terminal/apc.zig:405`, cmux-memory `budget.rs:42` |
| Binary output (`cat /dev/urandom`) | none found | No crash path from terminal bytes into Swift strings or integer conversions was found | `GhosttyActionDecoder.swift` |
| One 1 MB line with no newline | none in the terminal path | The terminal wraps it; line-based readers that see terminal text (agent detection, feed text) cut at 4,000 characters | cmux-tui-core `agent_hooks.rs:115-130` |

## Workspaces, tabs, windows, agents

| Case | First limit | What happens | Where |
| --- | --- | --- | --- |
| Terminals open at once | macOS `kern.tty.ptmx_max` (511 by default) PTYs for the whole Mac | `openpty` fails and the daemon refuses the new terminal with the OS error (what the app shows was not traced) | cmux-holder-v3 `pty.rs:52` |
| Holder output memory | 1 MiB ring per terminal (512 KiB below 16 GB RAM) | About 511 MiB at the PTY limit | cmux-memory `budget.rs:18` |
| Open files in the daemon | soft limit raised to min(hard, 65,536) | Not reached before the PTY limit | cmux-pty `open_files.rs:25` |
| Event subscribers | 4,096 pending events per subscriber; coalesced surface output takes one slot per surface | A subscriber that falls behind is closed and resyncs | cmux-tui-core `event_bus.rs:19,620,650` |
| 1,000 workspaces / 10,000 tabs: `list-workspaces` | no cap; the tree is built as JSON while the daemon's state lock is held | Every daemon change waits for the build (O(tabs)); not measured | cmux-tui-core `server.rs:2655`, `mux.rs:989` |
| Launch snapshot | 8 MiB file | A larger snapshot is skipped: the launch shows "connecting" until the daemon answers | `LaunchSnapshot.maximumBytes` |
| Agent message (acpmux) | 15 MiB per message; the app's agent line reader 16 MiB | A larger message fails alone; a larger line drops the agent connection | acpmux `rpc.rs:67`, `AcpmuxCheckedLine.swift:20` |
| Windows on several displays | one display link per screen (VSyncHub), not per window | 20 windows on 3 displays use 3 links | `CmuxNextWakeups/VSyncHub.swift` |

## Not measured

No row was measured on a Mac in this audit. To measure on the fleet: the stress sessions in
`scripts/cmux-next/perf-stress-session.py`, the sidebar stress bench and `scripts/measure/tui-scale-ab.sh`.
Missing measurements: the `list-workspaces` time at 1,000 workspaces and 10,000 tabs, a 1 GB
scrollback copy, 50 streaming agents, and 20 windows on 3 physical displays (the fleet has only
virtual displays).
