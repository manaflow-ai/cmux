# cmux NEXT at the speed of sound: the physical floor for CPU, memory, disk and overhead

Status: reference (2026-10-21). Owner of the numbers: the `cmux-budget` bench
(`scripts/perf-bench/budget.py`, `budgets.json`, `budgets-heavy.json`).

The user's ask (msgs 9689, 9692, 9701): every part of cmux 100x more efficient in active CPU, idle
CPU, memory and disk, judged from first principles: how little CPU, memory, disk and overhead can
an app of this kind need, even with very many workspaces.

This doc is the reference that other perf work cites (hover cards, Cmd-Tab activation, space and
workspace switch, chat switch, CEF, hibernation, spinners, idle CPU). A PR that changes cost says
which row of section 3 it moves, and by how much, with the bench row as proof.

## 1. The rule

**Cost follows what the user sees and what changes, never what exists.**

- Idle (nothing on screen changes, no input, no output): 0 CPU, 0 wakeups, 0 disk writes, 0 IPC
  messages, in every process cmux owns. Not "low": zero. Anything that wakes does so because an
  event arrived (input, PTY output, a network reply, a deadline the user asked for).
- Active: work per event is O(what changed on screen), never O(workspaces), O(tabs), O(chats) or
  O(rows in a list). One compositor commit per change, at most one per display frame.
- Memory: O(visible) hot state plus a small fixed record per object that exists. A hidden thing
  keeps its identity and the bytes to rebuild it; everything rebuildable is dropped or on disk.
- Disk: bytes written are proportional to new information (output the user may scroll back to,
  messages, settings the user changed). Never a periodic save of unchanged state.
- Overhead: a process boundary only where it buys isolation or survival (the daemon outlives the
  app; Chromium needs its own sandboxed processes). Each event crosses the fewest hops, wakes the
  fewest threads, notifies one observer (the view that shows the change) and allocates nothing in
  steady state.

## 2. Assumptions for the arithmetic

- Mac: Apple M-series, 12 cores, 16 GB, one 3024x1964 Retina display at 120 Hz (ProMotion).
- A cell (terminal character slot): 4 B codepoint + 2 B style index + 2 B flags = 8 B. A visible
  terminal pane: 200 x 60 = 12,000 cells = 96 KB per screen grid.
- Scrollback: 10,000 lines, average 60 printable bytes per line (real shell output), so 600 KB raw,
  about 120 KB with zstd (5:1 on text). A cell grid for scrollback (200 B/line at 1 B/cell + a
  style run table) is 2 MB raw; nobody needs it as cells until it scrolls into view.
- Glyph atlas: one per font size and scale, shared by every terminal: 2048 x 2048 R8 (4 MB) plus a
  color emoji atlas grown on demand (start at 1 MB).
- Window surface: 3024 x 1964 x 4 B = 23.8 MB. The compositor double-buffers: 47.5 MB for the window
  that is up. A hidden or minimized window needs none of it (its IOSurfaces can be purged).
- Workspace record (identity, name, folder, color, layout tree with pane and tab ids, unread state):
  under 2 KB. Tab record (kind, id, title, URL or command, scroll position): under 1 KB.
- Chat message index entry (offset, length, role, time): 32 B. A visible chat shows about 40
  messages, laid out text about 5 KB each: 200 KB.
- A keystroke echo: about 10 bytes of PTY output, one row dirty.

## 3. The floor, per component

"Floor" is the minimum a correct design needs on this Mac; "today" is the measured number on the
fleet (section 5) where one exists. Idle means no input, no output, no animation, 60 s window.

### 3.1 Idle

| Component | Floor idle CPU | Floor wakeups/s | Floor disk writes | Why the floor is what it is |
|---|---|---|---|---|
| App main thread | 0.00 % | 0 | 0 B/s | Nothing changed, so nothing to compute or draw. A cursor blink is a Core Animation opacity animation in the render server (0 app wakeups). Relative times ("2m ago") step at most once a minute, only for visible rows: 0.017/s. |
| App other threads | 0.00 % | 0 | 0 | No polling, no heartbeat to a local daemon (a socket hang-up is the liveness signal). |
| cmux-tui daemon | 0.00 % | 0 | 0 | Blocked in kevent on PTY and socket fds. A quiet PTY wakes nothing. |
| PTY hosts | 0.00 % | 0 | 0 | Ideally no per-terminal process at all (section 3.4); if one exists, it sleeps in a blocking read. |
| acpmux | 0.00 % | 0 | 0 | Blocked on the agents' pipes; an idle agent writes nothing. |
| Chromium / CEF, no visible page | 0.00 % | 0 | 0 | Hidden pages are discarded (section 3.3). With no live page, the engine's processes need not exist. |
| Chromium / CEF, visible static page | ~0.05 % | ~2 | 0 | Chromium's own delayed tasks on a static page (Safari's whole-browser number with 20 tabs is 0.12 % and 4.8/s on the same Mac). |
| Home chat | 0.00 % | 0 | 0 | A static transcript. A "thinking" indicator is a render-server animation (0 app wakeups). |
| Sidebar | 0.00 % | 0 | 0 | Draws only on a model change for a visible row. |
| Update checker | ~0 | 1 per 24 h | 0 | One HTTPS request a day (or a push), not a timer loop. |
| Chief host / Cloud link | ~0 | 0 (push) | 0 | A long-lived connection with server keepalive; the client sleeps between frames. TCP keepalive is in the kernel. |
| **Whole tree** | **0.00 %** | **0** | **0 B/s** | With a visible static Chromium page: ~0.05 % and ~2/s, all inside Chromium. |

### 3.2 Active

Costs on the app's side; the kernel and WindowServer add their own share, which is also O(changed
pixels).

| Action | Floor work per event | Floor at a human rate | Hops (floor) |
|---|---|---|---|
| Keystroke with echo | parse ~10 B (~1 us), one dirty row re-encoded (~20 us), one commit; ~0.1 ms CPU | 10 keys/s: 1 ms/s = 0.1 % of one core | key -> app -> PTY write (1 IPC hop to the daemon that owns the PTY, or 0 with a shared ring); output back the same way; 1 frame |
| Heavy output (`cat` of 100 MB) | VT parse at >= 1 GB/s; draw at most once per frame, only dirty rows | 100 MB/s: ~10 % of one core for parsing; drawing capped at 120 fps x dirty rows | one read per 64 KB, no per-line message |
| Scroll a terminal, 120 fps | reuse rendered rows, draw the newly exposed rows only: ~0.05 ms per frame | 120 x 0.05 ms = 6 ms/s = 0.6 % | 0 IPC (scrollback is in the app's hot window, or one paged read per 1,000 lines) |
| Scroll a chat transcript | page in ~40 laid-out messages, offset layers | < 1 % | 0 IPC; one disk read per page of messages not yet in memory |
| Switch workspace / space | hide one layer subtree, show a built one; draw each visible pane once if it changed while hidden | < 2 ms, one frame, independent of 10 / 150 / 1000 workspaces | 0 IPC (the model is in the app); no daemon round trip |
| Switch tab in a pane | same as above for one pane | < 1 ms | 0 |
| Move focus to another pane (click, Focus Pane Left/Right, Next Pane) | the old pane drops its ring and dim, the new pane takes them and the keyboard; nothing else re-runs (perf gate `pane_focus`: 2 pane chrome updates per move) | < 0.5 ms main thread, one frame, O(1) in panes and workspaces | 0 IPC on the path; the window record save that follows is off the frame |
| Cmd-Tab back to cmux | key-window state changes: title bar, focus ring, cursor; nothing else | < 1 ms, O(1) in workspace and tab count | 0 |
| Hover card | one small layer built on hover, from data already in the model | < 1 ms | 0 |
| Agent streaming a reply into a visible chat | append text, lay out the new line(s) only, one commit per frame at most | ~1 % while streaming | one message per chunk from acpmux to the app |
| Agent streaming into a hidden chat | write to the transcript (the agent does), bump an unread counter | ~0 | the counter update only; no layout |

### 3.3 Memory (physical footprint)

| Component | Floor | Notes |
|---|---|---|
| App, fixed | 25-40 MB | Dirty heap of an AppKit app with its model (frameworks' clean code pages are shared and not in the footprint). |
| Window surfaces | 47.5 MB per visible window, 0 hidden | Double-buffered IOSurfaces for a full Retina window, mostly charged to WindowServer. |
| Glyph atlases | 5 MB, shared | One set per font size and scale. |
| Visible terminal | 96 KB grid + hot scrollback window (~2,000 lines laid out = 400 KB) | ~0.5 MB |
| Hidden terminal | ~1 KB record + the screen grid (96 KB) | Its scrollback is in the daemon (compressed, ~120 KB) or on disk; the app holds none. |
| Terminal in the daemon | 96 KB grid + ~120 KB compressed scrollback | ~0.2 MB per terminal |
| Workspace not shown | < 2 KB | Record only; no views, no layers, no web views. |
| Sidebar | O(visible rows): ~40 rows x 10 KB = 0.4 MB | Same for 10 or 1,000 workspaces. |
| Visible chat | ~0.2 MB laid out + the index (32 B x messages) | A 10,000-message chat: 0.5 MB of index. |
| Hidden chat | < 1 KB | Id, scroll anchor, unread count. Transcript on disk. |
| acpmux | ~5 MB + ~50 KB per live session | Agents themselves (Claude Code, Codex) are the user's processes, outside the budget. |
| Chromium engine (browser + GPU + network processes) | ~120 MB while any Chromium page is visible or was used in the last few minutes; 0 otherwise | Chrome's own floor on this Mac is about this. |
| Visible Chromium page | ~30-40 MB per renderer | Chromium's floor for a simple page. |
| Hidden Chromium tab | ~50 KB | Discarded: URL, scroll position, a JPEG thumbnail. Reload on show (or keep the last N, user setting). |
| WebKit page (cmux's own pages, Markdown, settings) | 0 when hidden; ~15 MB visible | A page that is not shown has no WebContent process. |
| cmux's own UI pages (Home chat, settings) | 0 extra processes | Native views, or one shared renderer, never one renderer per page. |

Totals (floor, one visible window, one visible terminal, no visible web page, Chromium unused for
10 minutes):

| Scenario | App | Daemon + acpmux | Chromium | WebKit | Floor total |
|---|---|---|---|---|---|
| 10 workspaces, 20 terminals, 10 chats | 80 MB | 10 MB | 0 | 0 | **~90 MB** |
| 150 workspaces, 300 terminals, 100 chats, 100 browser tabs | 85 MB | 70 MB | 5 MB (thumbnails) | 0 | **~160 MB** |
| 1,000 workspaces, 2,000 terminals, 1,000 chats, 1,000 tabs | 95 MB | 420 MB | 50 MB | 0 | **~565 MB**; or ~150 MB with cold terminals' scrollback paged to disk |

With one visible Chromium page add ~160 MB (engine + renderer).

### 3.4 Processes, threads and hops

| Overhead | Floor | Why |
|---|---|---|
| Processes cmux owns, no browser | 2: the app and one daemon (PTYs + ACP sessions, outlives the app) | Shells and agents are the user's. No per-terminal host, no shell wrapper, no helper that polls. |
| Processes with Chromium in use | +3 (browser, GPU, network) + 1 per visible site | Chromium's sandbox model. Its storage service can share the browser process. |
| Threads, app | ~6 (main, render encoder, 2-4 GCD workers on demand) | Threads that exist but sleep cost memory (512 KB stack each), not CPU. |
| Threads, daemon | 2-3 (event loop, writer, one for blocking file I/O) | One kqueue serves every PTY. |
| IPC hops per keystroke | 2 (app -> daemon, daemon -> app) or 0 with a shared-memory ring | The PTY must live in the surviving daemon. |
| Observers notified per event | 1 (the view that shows it) | A model change for a hidden workspace notifies nothing that draws. |
| Allocations per keystroke, steady state | 0 | Preallocated parse and vertex buffers. |

### 3.5 Disk

| Item | Floor | Notes |
|---|---|---|
| App bundle without Chromium | ~30 MB | Terminal, UI, daemon. |
| Chromium framework | ~250-400 MB, downloaded on first use | A user who never browses never pays it. |
| Session state | 2 KB x workspaces: 2 MB at 1,000 | Written as deltas on change. |
| Scrollback | ~120 KB compressed per terminal | 1,000 terminals: 120 MB. |
| Transcripts | 0 extra bytes | The agent writes its own transcript; cmux keeps a 32 B/message index at most. |
| Writes at idle | 0 B/s | |
| Writes when active | O(new information): compressed output, appended messages, one delta per user change | |

## 4. What the gate measures

`cmux-budget` (scripts/perf-bench/README.md) measures each row on a fleet Mac with an isolated HOME.
Two scenarios:

- `budgets.json` (standard): Home idle, then one workspace with 5 hidden terminals and 6 hidden tabs
  of each engine, idle with the window in view and with the app hidden.
- `budgets-heavy.json` (heavy): 150 workspaces, 20 hidden terminals, 20 hidden Chromium tabs.

Rows: CPU %, wakeups/s, footprint (whole tree, per hidden terminal, per hidden tab, per workspace),
disk writes KB/s, Mach messages/s, syscalls/s, context switches/s, process and thread counts, and a
`/usr/bin/sample` call tree of the hidden app's main thread so a Release build's wakeups get a
named owner. Every row starts advisory and becomes enforced once the base holds it. Limits step
toward the floor of section 3; the floor stays the target.

## 5. Floor against today

Measured on cmux20 (Apple M6, 12 cores, 16 GB, macOS 27.0), Release build, isolated HOME:
fleet step e44e5f2fc0a2cca452b71dee at feat-cmux-next e8af890de1 (2026-10-21, standard scenario),
and the 2026-10-20 xbench baseline (`baseline/apple-m6-macos27.json`, nightly 3944134600801) for the
20-terminal row. The heavy-scenario numbers are in section 7 once the fleet run lands.

| Row | Floor | Today | Gap |
|---|---|---|---|
| Idle CPU, whole tree, Home after launch | 0.00 % | 3.81 % (Home's 3 Chromium renderers 2.02 %, main 1.63 %) | >> 100x |
| Idle wakeups, whole tree, Home | 0/s | 51.9/s (main 42.6/s) | >> 100x |
| Idle CPU, 20 idle terminals, window in view (Oct 20) | 0.00 % | 7.30 % | >> 100x |
| Idle CPU, tabs hidden, window in view | 0.00 % | 0.33 % | >> 100x |
| Idle wakeups, tabs hidden, window in view | 0/s | 35.2/s (main 27.2/s) | >> 100x |
| Idle wakeups, app hidden | 0/s | 115/s (main 107/s: more than with the window in view) | >> 100x |
| Memory, Home idle | ~70 MB (app 40 + window 30) | 794 MB | 11x |
| Memory, whole tree, 5 terminals + 12 hidden tabs | ~95 MB | 1,470 MB | 15x |
| Memory, app main process | 40 MB + window | 366 MB | 7x |
| Memory, cmux-tui (2 processes) at Home | ~5 MB | 109 MB | 22x |
| Memory per hidden terminal | ~0.1 MB in the app, 0.2 MB in the daemon | 7.8 MB (2.1-2.5 MB terminal-host process + 2.4 MB shell + app) | 30-70x |
| Memory, first hidden Chromium tab | 0.05 MB (engine can stop) | 196 MB | 4,000x |
| Memory per further hidden Chromium tab | 0.05 MB | 52 MB | 1,000x |
| Memory per further hidden WebKit tab | 0.05 MB | 26 MB | 500x |
| Processes cmux owns, 5 terminals, no visible page | 2 | ~35 own (+ 13 Chromium/WebKit helpers) | 17x |
| Chromium renderers with no browser tab open (Home) | 0 | 3 (185 MB) | n/a |

## 6. Ranked gaps and the root cause of each

Largest first. Each fix lands with a failing bench row or test first.

1. **Hidden web pages keep their engines.** A hidden Chromium tab costs 52 MB and a hidden WebKit
   tab 26 MB, against a floor of a 50 KB record. Root cause: hiding freezes a page but keeps its
   renderer. Fix: discard on hide past a short grace (hibernation, a456), keep URL + scroll +
   thumbnail; restore on show. Shutting the engine down when no Chromium page is live removes the
   196 MB first-tab cost too. Rows: `budget-memory-per-*-tab`, `budget-memory-first-chromium-tab`.
2. **cmux's own pages run in Chromium renderers.** Home starts 3 Chromium renderers (185 MB, 2 %
   CPU, 83 mW) before the user opens any browser tab. Root cause: `browser.defaultEngine` routes
   cmux's React pages through CEF (ChromiumPageHost). Fix: Home chat native (a488's SwiftUI/AppKit
   track) or one shared WebKit page process; never one renderer per cmux page. Row:
   `budget-idle-cpu-home`, `budget-memory-home`.
3. **The main thread wakes 27-107 times a second at idle, more when the app is hidden.** Floor 0.
   Root cause unknown in a Release build (debug.wakeups is Debug-only); the bench now records a
   main-thread sample of the hidden app so the owner gets named, then a red row and the fix
   (idle-wakeups.md primitives: no repeating timers, FrameScheduler stops when nothing moves).
   Rows: `budget-idle-wakeups`, `budget-idle-wakeups-app-hidden`.
4. **20 idle terminals cost 7.3 % CPU** (1 terminal: 0.09 %). Floor 0. Work grows with terminal
   count while nothing changes: O(all), not O(visible). Measured again in the heavy scenario.
5. **One process per terminal.** Each terminal adds a `cmux-tui __terminal-host` process (2-2.5 MB)
   and threads; with 300 terminals that is 300 processes and ~700 MB. Floor: the daemon holds every
   PTY in one kqueue. Row: `budget-processes`, `budget-memory-per-terminal`.
6. **The app's own footprint is 7x the floor** (366 MB with hidden tabs, 188 MB at Home). Needs a
   heap breakdown (memory-inspector-native-DESIGN.md) before a fix.
7. **Helper processes nobody uses at idle**: two `sh` wrappers, a perl MediaRemoteAdapter,
   two cmux-agent-screen-detection, open/save panel and QuickLook XPC services started at launch.
   Each should start on first use.

## 7. Measured with the overhead rows (2026-10-22)

cmux20 (Apple M6, macOS 27.0), Release build, one round, isolated HOME. Standard: fleet step
338ba2ea5665dc7e439ba255 at feat-cmux-next 7eeba1d596c (5 terminals, 6 hidden tabs of each
engine). Heavy: step c347f45ee8d6f0328e7dda54 at the same commit (150 workspaces, 20 terminals,
20 hidden Chromium tabs). "Floor" is section 3's.

| Row | Floor | Standard | Heavy (150 ws) | Gap (heavy / floor) |
|---|---|---|---|---|
| Idle CPU, Home after launch | 0 % | 3.40 % (renderers 1.78 %, main 1.37 %) | 3.29 % | >> 100x |
| Idle disk writes, Home | 0 KB/s | 358 KB/s (all in the app process) | – | >> 100x |
| Idle syscalls, Home | 0 /s | 1,400 /s (app) | – | >> 100x |
| Idle CPU, tabs hidden, window in view | 0 % | 1.82 % | 0.82 % | >> 100x |
| Idle wakeups, tabs hidden | 0 /s | 188 /s (app 94, each hidden WebKit tab 11) | 69 /s (app 36) | >> 100x |
| Idle Mach messages, tabs hidden | 0 /s | 541 /s (app 209, WebKit GPU 198) | 154 /s | >> 100x |
| Idle syscalls, tabs hidden | 0 /s | 1,502 /s | 437 /s | >> 100x |
| Idle disk writes, tabs hidden | 0 KB/s | 0.0 KB/s | 0.07 KB/s | ok |
| Memory, Home | ~70 MB | 793 MB | 802 MB | 11x |
| Memory, whole tree | 160 MB (150 ws) | 1,462 MB | 3,538 MB | 22x |
| Memory per further workspace (1 terminal) | 0.002 MB app + 0.2 MB daemon | – | 8.2 MB | 40x |
| Memory per hidden Chromium tab | 0.05 MB | 55 MB | 56 MB | 1,100x |
| Memory per hidden WebKit tab | 0.05 MB | 29 MB | – | 600x |
| Processes | 2 (+3 with Chromium) | 52 | 392 (172 terminal hosts, 171 shells, 25 renderers) | 78x |
| Threads | ~10 | 677 | 3,300 (daemon 797, app 91) | 330x |
| App process footprint | 40 MB + window | 361 MB | 844 MB | 10x |
| cmux-tui daemon footprint | ~35 MB at 172 terminals | 56 MB | 284 MB | 8x |

New ranked gaps from these rows (added to section 6):

8. **The app writes 358 KB/s to disk and makes 1,400 syscalls/s while idle on Home.** Floor 0.
   The bench now lists the files written during the window (`home idle wrote:` lines) to name it.
9. **Hidden WebKit tabs wake 11 times a second each** with 21 Mach messages/s each, and the WebKit
   GPU process exchanges 198 messages/s with them: a hidden WebKit page still runs a timer or
   rAF loop. Hidden Chromium tabs freeze after 30 s (0.2 wakeups/s); WebKit tabs have no freeze.
10. **The daemon holds ~4.6 threads per terminal** (797 threads at ~172 terminals). The bench now
    logs its thread names to find which loop is per terminal.
11. **Each workspace costs 8.2 MB**: a terminal host process (2.3 MB) and a shell (2.3 MB) per
    terminal, ~1.5 MB in the daemon and ~3 MB in the app (a Ghostty surface per hidden terminal).

## 8. Who works on which row

| Row / area | Owner |
|---|---|
| Perf gate, budgets | a436 |
| Idle CPU and wakeups | a323, a154 |
| Profiling | a421 |
| CEF per-frame cost | a462 |
| Hidden-tab hibernation | a456 |
| Spinners and animation frames | a465, a477 |
| Chat switch | a470 |
| Space and workspace switch | a489, a492 |
| Cmd-Tab activation | a503 |
| Pane focus moves | a515 |
| Hover card | a505 |
| SwiftUI removal (Home chat native) | a488 |
