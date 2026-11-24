# Measurement harnesses

Measurements now go through `scripts/bench/cmux-bench`: one entry point, one row schema (`cmux-bench/v1`), one ledger (the `bench-ledger` branch of cmuxterm-hq).

- `cmux-bench list` shows the registered benches.
- `cmux-bench NAME [--build nightly|DEV|SHA] [--host fleet|local-readonly|anywhere] [--json]` runs one.
- `cmux-bench compare A B` compares two builds, for example `cmux-bench compare launch@nightly~1 launch@nightly`.

Rule: a new measurement lands as a registered bench in `scripts/bench/benches/`, or extends one. It is never a one-off script. Perf PRs cite `cmux-bench compare` output.

Details: [scripts/bench/README.md](../bench/README.md).

This file indexes every entry in `scripts/measure/`. Registered benches wrap some of these scripts; the rest are listed below by area. Status is by last commit date as of 2026-11-16: `active` is touched in the last 30 days, `stale` is not.

## Registered benches

| bench | wraps (script) | what |
|---|---|---|
| published-idle | `published-idle-power.sh` (pinned prepared PID, then `--import`) | Process CPU energy, wakeups and footprint including descendants; rejects incomplete windows. |
| bundle | `bundle-size.sh` (DMG on a fleet Mac), an .app tree, or `--compare-zip URL` | Bundle size by component, against other apps. |
| launch | `launch-ready.sh` | Dock launch: bounce end, first window, main, first frame, every launch mark. |
| launch-background | `background-ready.sh` | Show from the background (Cmd-H, windows closed to a menu bar app, quit) against a cold relaunch, and each state's idle cost. |
| launch-premain | `launch-premain.sh` (also launch's mode=premain) | Time to main after a 60 s full run vs a short launch, and what it pays: pageins, residency, the code checkers' CPU, per arm. |
| launch-matrix | `launch-matrix.sh` (`launch-matrix.swift`, `launch-matrix-summary.py`) | Any .app's launch on one harness: first visible frame, first accepted input, the whole process tree's resources, per scenario (warm, cold-quit, evicted, first-install, update, large-session), the reboot pair and idle growth. |
| post-update | `update-click-ab.sh` (default), `relaunch-shift.sh` (mode=shift), `nightly-fresh-launch.sh` (mode=fresh-copy), `go-back-duress.sh` (mode=go-back) | First launch after an update and its hitches. |
| screen-share | `screen-stream-eval.sh` (default), `screen-share-vs.py` (mode=vs, once on base), `screen-share-vs-pair.sh` (screen-share-vs.py as one job on the shared Mac, the viewer over LAN ssh; for a lane VM with no route to the pair) | Screen share kbps, fps under motion, input-to-frame latency. |
| newtab | `instant-new-surfaces.sh` (default, mode=launch-pairs), `held-new-tab.sh` (mode=held) | New Tab first paint and settled-interactive time. |
| footprint | read-only probes (`ps`, rusage, `vmmap`) of a running app; `perf-bench.sh` cmux-budget on the fleet | Footprint per process kind. |
| xbench | `perf-bench.sh` (`scripts/perf-bench/xbench.py`); `--import` reads `results.json` and `scripts/perf-bench/baseline/*.json` | Against other browsers, and the resource budget rows. |
| rivals | `rivals.sh` (`scripts/perf-bench/rivals.py`) on a fleet Mac, the newest nightly-next DMG | Against Claude, Codex, T3 Code, Rex, Slack, Chrome, Edge, Helium and Safari: first launch of a new install, launch after purge (close to a restart) and warm relaunch to window, CPU and peak RAM per launch, idle RAM ceiling, growth per minute, CPU and wakeups. |
| idle | `perf-10x-idle.sh` | Idle CPU, wakeups and footprint per process kind. |
| idle-compare | `idle-energy-compare.sh` (`idle-energy-compare.py`) on a fleet display Mac | cmux NEXT vs Claude Code desktop vs Terminal.app idle: fresh signed-out profiles, a calibration window, then at least 3 interleaved rounds of equal windows per app; CPU energy mW, CPU % and wakeups/s with baseline counters read first (hq#19931). |
| tui-idle | `tui-idle-ram.sh` (`tui-idle-ram.py`, `dhat-top.py`) on Linux CI | The idle cmux-tui daemon's anonymous PSS, PSS, threads, binary sections and (dhat=1) Rust heap at commits. |
| ci-vm-idle | `ci-vm-idle.py` from a local capture | GCP CI VM running time, idle time and list-price cost for persistent and JIT runner pools. The wrapper records VM-hours as seconds and USD as integer cents for stable scalar rows. |
| chat-size | `chat-size-sweep.sh` on the Linux fleet | Real daemon open, pages at three depths, first token, prompt index and RSS at 1 MB, 100 MB, 1 GB and 4 GB, with ratios and a Markdown table. |
| agent-turn | `cargo bench -p acpmux --bench turn_overhead` (`benches/turn_overhead.rs`) on Linux CI | One agent turn through a real acpmux daemon with a stand-in model that answers at once: send, harness, store, deliver, render, turn, shown (median and p95 over 100 turns). |
| cloud-turn | `cargo bench -p acpmux --features hub-carrier --bench turn_overhead -- --route local`, then `--route relay` (`benches/turn_overhead.rs`, `turn_overhead/relay.rs`) on Linux CI | The agent-turn turns with the chat crossing a real relay on loopback (the Cloud carrier's relay, its client and the Noise link), beside the local route from the same binary: the same stages plus relay_in, relay_out and a pane attach (connect, handshake, first frame). |
| daemon-latency | `tui-idle-ram.sh runs=0 latency=1` (`cmux-tui/scripts/bench-daemon-latency.py`, acpmux `start_under_load_bench`) on Linux CI | bin/cmux hot paths at commits in alternating rounds: daemon requests, the CLI end to end, acpmux send to first token (cold and warm). One run per commit, so `compare` matches the sides. |
| acpmux-watch-bytes | acpmux `hub/stream_tell_tests.rs` (cargo, Linux CI) | Bytes one acpmux watcher is sent while 20 chats stream and the list is read 60 times. |
| typing | `webviews/bench/composer-typing.bench.ts` (load modes L0-L3, Chromium and WebKit) on Linux CI | Composer keydown-to-paint p95/p99 and key integrity under idle, stream, ten streaming documents and a 100k-row stream. |
| mcp-fanout | `mcp-fanout.sh` (`mcp-fanout.py`) on a fleet Mac, any published app (`app=`) | MCP tool-server processes, RSS, idle CPU per kind at N open chats; first cmux tool call latency. |
| transcript-shifts | `webviews/scripts/agent-pane/transcript-shifts.bench.ts` on Linux CI (headless Chrome, synthetic daemon) | Agent chat transcript: visible-row shifts per replay phase (stream, page up, fold, composer) and first paint at 500 and 50k rows. |
| ext-reload | `ext-reload-nightly.sh` (`ext-reload-nightly.py`, `edit-repaint.py` in read-back mode) on a fleet Mac, any published app (`dmg=`) | Extension hot reload on a NIGHTLY: save to the watcher's reload, and save to shown in the window per case, with no rebuild asked. |
| workspace-factory | `workspace-factory.sh` (`workspace-factory/`, the `wsfactory` Rust factory) on a fleet Mac | A per-job throwaway workspace (APFS clone of a read-only seed) against today's cold and warm-slot step workspaces: start, build, cache hit, disk left behind. |
| stress | `split-spring.sh --suite=stress` (`scripts/cmux-next/stress-bench.py`, `stress_load.py`; the cli angle runs `scripts/stress-cli-socket-api.py`) on the exclusive bench worker | The app under extreme stress, one angle per launch (cpu/thread starvation, many streaming mock chats with long transcripts, many workspaces with output floods, CLI/socket flood, memory past RAM into swap): frame p50/p95, dropped frames, input latency, daemon RTT, app CPU, footprint, hangs, baseline and stress window each. |
| dev-loop | `dev-loop-ceiling.sh` (`dev-loop/<loop>.sh`, `dev-loop/bound.py`) on a fleet Mac | Edit to running for web swap, daemon restart, Swift inject and the startup loop, each over its simulated stage-floor bound; worst ratio (goal dev-loop-ceiling). |
| coord-sim | `coord-sim-linux.sh` (crate `cmux-tui/crates/coord-sim`) on Linux CI; also the perf cron's coord-sim part | Several synthetic coordinator chats at once into a release acpmux: event delivery p50/p95/p99, lost and duplicated events, attach and first paint under load, history paging, prompt ack and echo, daemon RSS and its slope, memory and CPU per chat. |
| projection-way-back | `a_bench_of_bring_back` (`cmux-tui/crates/cmux-tui/tests/link_project_back.rs`) on Linux CI | Bring Back of a projected folder against today's pull (`seed pull --or-copy`) at N files and 50 edits, over a 50 ms RTT link; the plan step and the pure plan's cost. |
| chief-latency | `chief-latency.sh` (`Native/OptChat/optchat-chief/measure/chief_driver.py --scenario latency`, `chief_latency.py`) on a fleet Mac, real model through SR2 | A scratch Chief built at two refs, alternating rounds of 15 typical asks (trivial, memory, tool, long reply, one and two subagents, a view rebuild): input tokens of each turn's first request and of every request, first token (warm, cold), turn p50/p90, cold share, refused sends, and a before/after markdown table for a PR body. |


## Dev loop

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `dev-loop-ceiling.sh` | Runs each `dev-loop/<loop>.sh` on one Mac, then `dev-loop/bound.py` (dev-loop bench). | goal dev-loop-ceiling | 2026-11-21 | active |
| `dev-loop/bound.py` | Each loop's p50 over the Monte Carlo critical path of its stage floors; writes report.json. | goal dev-loop-ceiling | 2026-11-21 | active |

## Launch and update

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `launch-ready.sh` | Time from Dock launch to a usable window, measured from outside the app. | CMUX-629, CMUX-631 | 2026-11-15 | active |
| `launch-ready.swift` | Swift probe that launches one app copy like the Dock and records every mark. | CMUX-629 | 2026-11-15 | active |
| `launch-premain.sh` | What makes a launch reach `main` 600 to 1170 ms late: arms after a 60 s run, page cache, purge, another app, sampled (launch bench mode=premain). | CMUX-629 | 2026-11-17 | active |
| `launch-premain.swift` | Probe for launch-premain.sh: open or exec one launch, pageins, CPU and the executable's residency at `main`. | CMUX-629 | 2026-11-17 | active |
| `launch-reboot.sh` | The first launch after a reboot, with and without a post-login pre-read of the app's binaries (row F, background-ready-copy): one phase per step, before (shutdown -r) and after (noread, read, residency). | row F | 2026-11-18 | active |
| `launch-matrix.sh` | One launch harness for any .app (cold-start tables against Claude, Codex, T3 Code, Edge, Chrome, Safari, Slack, Helium): scenarios, reboot phases, growth (launch-matrix bench). | ask-37d682a340 | 2026-11-22 | active |
| `launch-matrix.swift` | Probe for launch-matrix.sh: open, window, first non-blank frame and first accepted key through CuaDriver, tree resources, growth, no-root page cache eviction. | ask-37d682a340 | 2026-11-22 | active |
| `launch-matrix-summary.py` | launch-matrix.sh's LM-TABLE lines and report.json. | ask-37d682a340 | 2026-11-22 | active |
| `launch-capture-probe.sh` | Launch image sources with no Screen Recording grant: TCC rows and prompts, the window composite and Chromium page image against the screen, ms and main-thread stall per source. | ask-b2b0f899c1 | 2026-11-17 | active |
| `launch-capture-probe.py` | Python driver for launch-capture-probe.sh. | ask-b2b0f899c1 | 2026-11-17 | active |
| `background-ready.sh` | Open request to window on screen from the background (hide, close, quit) against a cold relaunch; idle CPU, wakeups, energy, memory, files and sleep assertions per state. | ask-b2b0f899c1 | 2026-11-17 | active |
| `background-ready.swift` | Driver for background-ready.sh: one arm per process, holding the marks FIFO across shows. | ask-b2b0f899c1 | 2026-11-17 | active |
| `background-ready-idle.py` | Idle cost of a running or quit copy (procs.py) and its stop by pid, for background-ready.sh. | ask-b2b0f899c1 | 2026-11-17 | active |
| `launch-ready-profile.py` | Main-thread Time Profiler summary of one launch-ready launch. | - | 2026-11-15 | active |
| `fresh-home-launch.sh` | Fresh-home launch of any commit's app on a fleet Mac. | - | 2026-11-14 | active |
| `helper-fresh-grant.sh` | On a SIP-off fleet Mac: a Screen Recording and Accessibility grant made while cmux runs reaches Computer Use with no restart of cmux or its daemon (TCC rows written, status and screenshot timed), Computer Use in TextEdit, and the helper's share host streaming to a bench viewer. `ref=SHA` builds any commit. | cmux#49813 | 2026-11-22 | active |
| `helper-fresh-grant.py` | Python driver for helper-fresh-grant.sh. | cmux#49813 | 2026-11-22 | active |
| `nightly-fresh-launch.sh` | Where a published nightly's fresh-home launch spends its time. | CMUX-571 | 2026-11-15 | active |
| `nightly-fresh-launch.py` | Python driver for nightly-fresh-launch.sh. | CMUX-571 | 2026-11-15 | active |
| `relaunch-restore.sh` | Quit to usable time after Quit and Keep Sessions, on a published build; `base=SHA head=SHA` runs two builds as interleaved pairs with the load (`relaunch-restore-pairs.py`). | hq#7149 L5 | 2026-11-05 | active |
| `relaunch-shift.sh` | Layout shift when the app relaunches after an update. | - | 2026-11-04 | active |
| `first-load-after-restart.sh` | A chat's first load after a restart, frame by frame, at commits (shift and blank frames, settle time). | - | 2026-11-16 | active |
| `host-line-shift-duress.sh` | The agent pane's chat rows and composer moving when the link drops and comes back, during a long streaming chat, optionally on a loaded machine, at commits. | - | 2026-11-23 | active |
| `update-click-ab.sh` | Real Sparkle update, Restart to Update clicked soon after staging, base vs head. | CMUX-571 | 2026-11-15 | active |
| `update-click-ab.py` | Summarizes update-click-ab.sh runs into medians. | CMUX-571 | 2026-11-15 | active |
| `go-back-duress.sh` | Go back to the previous build (updates.rollback) right after an update, with live agent turns and terminals, on a quiet and a loaded Mac: click to the kept build's first window. | #41013, ask-c013f6fec6 | 2026-11-23 | active |
| `update-idle-e2e.sh` | Update When Idle end to end: a staged update installs by itself only after the running turn ended, the draft was cleared and the idle time passed; agent host counts and pids before and after; base as the control (`update-harness/idle_e2e.py`). | update-when-idle | 2026-11-19 | active |
| `update-e2e.sh` | End to end auto-update of a real nightly (correctness, not a timing). | R114 | 2026-10-04 | stale |
| `stable-next-smoke.sh` | Fresh-home launch smoke of the NEXT Stable build on a console worker. | - | 2026-10-30 | active |
| `daemon-registry-start.sh` | Start time of the cmux-tui daemon on a large registry. | - | 2026-11-13 | active |
| `daemon-registry-start.py` | Python driver for daemon-registry-start.sh. | - | 2026-11-13 | active |
| `daemon-stop-swap.sh` | The cmux-tui daemon's stop under load at two commits: stops with a thread that did not end, stop and next start times. | PL-daemon | 2026-11-18 | active |

## Input and latency

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `instant-new-surfaces.sh` | Key to visible frame for Cmd-N, Cmd-T, Cmd-D, Cmd-Shift-D. With `--bench=cmd-n-paint --screen`: one Cmd-T and one Cmd-N from the screen's own frames, alone and 100 ms after another key, in a session of many workspaces (the frame of the tab or row, of the page's first content and of the last change; a report with the kept pictures, no judgement). | - | 2026-11-18 | active |
| `new-terminal-100x.sh` | New terminal, split and workspace latency through the cmux-tui daemon. | - | 2026-11-07 | active |
| `held-new-tab.sh` | Held Cmd-T with Cmd-W now and then, in a session of many workspaces. | - | 2026-11-15 | active |
| `held-new-tab.py` | Python driver for held-new-tab.sh. | - | 2026-11-16 | active |
| `recent-pages.py` | Recent pages with site icons for a bench session (`held-new-tab.py --recent-sites N --recent-pages M`): loopback sites with one 64 x 64 icon each, the visits through one Chromium tab of the app, and the read of the app's own list of recent pages. Not a step's script: held-new-tab.py loads it. | - | 2026-11-18 | active |
| `new-tab-letters.py` | The letter cases of the held New Tab measure (`held-new-tab.py --letter-cases N`): a letter typed directly after a New Tab key, as key sequences of the app in a page's window, in 7 forms; each form's word from the key hold's log, the first new tab's field and the counts of the app's park for typed text at the tool's last call before its own acts on that tab, the focus of its pane and its select (a text in the park there is no pass: the select gives the tab the keyboard, and the app types the text then). With a text in the park a case first makes no act but a read of the park each 0.1 s, to the first read with no text or to 4 s after its last key (the park keeps a text for 2 s of the app's own clock and the app drops it at a read then, so the 4 s are only for a text that stays on its way into its page), and waits again in the same way for a text that is there at the last read before the 4 s: an app that types the text by itself in that time can pass; for each case where the letter is (`letter_is`), as one word of 12, the first that is true in this order: `typed only after the select`, `new tab's field`, `second new tab's field`, `tab before`, `refused by the field`, `dropped after the bound`, `page gone`, `parked` (from the fields of the case's tabs and the counts of the app's park for typed text), then `not run`, `dropped by the hold`, `a place not read`, `nowhere read`. `nowhere read` is said only for a case that ran, with no dropped key and an answer of each place; a place that gave no answer is in the case's `places_not_read`, and a form's line counts such cases, the cases with a text in the park at that last read and at the first read, and has the most seconds to an empty park of the cases that waited. A case with no counts of the park at such a read, with a count below 0, or with a text in the park before its keys is `not_run`. A case's record also has the count of the park at the first read with the seconds to the read from which the park had no text and to the last read (`park_wait`), the count of the open New Tab key holds, and, from the app's input journal (read before the last read of the park), the counts of the pages' readiness notes, the count of the page entries of each id and the first new tab's engine word (`webkit`, `chromium`, 2 words for a Chromium page's window, or `other` for a word that the tool does not know), and the same counts and engine word of ONE more read of the journal after the tool's select, directly after the read of the window and before the reads of the places (`journal_after_select`, `engine_after_select`: of the entries after the journal's last number at the last read before the select, to that read; a read only, which changes no verdict; the reads of the places select other tabs, and the app can then give the first new tab's view to another tab). An entry that the app writes after this read is not in the counts: between the select and this read the tool makes only the wait for the pane to show the tab, a pause of 0.4 s, 1 or more reads of the field (5 s of them with an empty field) and the read of the window, and by a read of the app's code these entries can come later than that: a give of the page focus, an entry with the word `chromium-key` or `chromium-unchosen-key` (a callback of the page's window) and a readiness note (a callback of the page); so an undercount in `journal_after_select` is possible (not proved how often), and it changes no verdict and no count of late cases, which do not use the journal. The journal names a cmux page in Chromium by the page's own random id and not by the tab's id: the tool takes that id from ONE read of the window's word (`debug.focus`) after its select and the verdict's read of the field, only when the window's focus model names the first new tab, counts the entries before and after the select by it, and keeps no id in a record. `shown_page_has_chromium_focus` says if it had such an id (None: no read); `keyboard.after_select.chromium_page_focus` True with it False says that the window's focus model named another tab or none. The id names a page view, not a tab (the app can give the view of a New Tab tab that nobody used to the next one): the counts and the engine words are of the view that the first new tab has after the tool's select, and `page_is_the_windows_page_before_the_keys` says if that id is the one that the window had before the keys (None: no id, or no read then; the tool keeps that id in memory only); with True they are of ONE view that an older tab had before the keys, so they do not say what the first new tab had at the time of the letter, and False does not say that no other tab had the view (the window has the id of the page with the page focus only). By a read of the app's code, True is the normal value in three-key, two-key and reselect (the first new tab takes the view of the shown tab that nobody used) and False in from-chat and close-move. The tool has no fact that proves that the view after the select is the one of the time of the letter: a run gives no engine sentence on a late letter. An opening's `idle` True says that the open took no spare page and that the tab's content was shown in the key's own turn; it says nothing of a take after the key. With no id and no entry of the tab's id, the counts of the first new tab and the 2 engine words are the word `not readable for a cmux page in Chromium`, and not 0 and None (the word is said for a page in a WebKit view too: the run's `page_engine` says the engine, the view's class alone does not); None is said with an id and no entry of it, or with no read of the journal. `first_new_tab.chromium_given` (the gives with the word `chromium`) of 1 or more says that the app gave that page the page focus; the last engine word alone does not say it, and a count of 0 with `shown_page_has_chromium_focus` True is a real state (the app can record the page with no give). `keyboard` has the class of the window's first responder, and yes or no for a Chromium page that the window records as the one with the page focus, before the keys, after them and after the select. Not proved by a run: that the window's id is the journal's id (by a read of the app's source it is). Not a step's script: held-new-tab.py loads it. | - | 2026-11-22 | active |
| `build-flags.py` | The form of a tagged reload's build, from the reload's own log: its `bench configuration` line, the optimization settings, the count of Swift compile lines with each -O level (held-new-tab.sh and pane-motion-films.sh call it). | - | 2026-11-17 | active |
| `burst-bench.sh` | Bursts of Cmd-W, Cmd-D and Cmd-Shift-D: per-press input to next commit. | PL-burst | 2026-10-27 | active |
| `palette-open.sh` | Command palette open time, per stage, from several page types. | - | 2026-10-27 | active |
| `omnibar-click.sh` | Omnibar mouse-down to the frame that shows focus. | - | 2026-10-27 | active |
| `hover-preload.sh` | Pointer sweep over sidebar rows: hover preload wakes and cost. | - | 2026-11-07 | active |
| `chat-open.sh` | Sidebar click to first content for a chat. | - | 2026-11-03 | active |
| `right-pane-open.sh` | Click to first content for every right-side open of a chat. | - | 2026-11-07 | active |
| `fork-open.sh` | Fork Conversation to a usable fork, for every Fork To destination. | - | 2026-11-07 | active |
| `close-flash.sh` | Close Window and close-key commit time in an active app. | - | 2026-11-01 | active |
| `nightly-ws-switch.sh` | Workspace switch, typing and hangs on published nightly DMGs. | - | 2026-11-02 | active |
| `tab-switch.sh` | Frame-judged tab switch harness (long chat, new and close tab). | - | 2026-11-15 | active |
| `tab-switch-frames` | Swift frame recorder used by tab-switch.sh. | - | 2026-11-15 | active |
| `settings-section-switch.sh` | Settings section switch latency in headless WebKit and Chromium. | - | 2026-11-11 | active |
| `perf-10x-lifecycle.sh` | Tab, pane, split and workspace create and close latency. | perf-10x | 2026-11-07 | active |
| `perf-10x-daemon.sh` | Request latency of a headless cmux-tui (raw, 10 clients, CLI). | perf-10x | 2026-10-18 | active |
| `perf-10x-settings.sh` | Settings page render cost over the mock provider in bun and jsdom. | perf-10x | 2026-11-11 | active |
| `terminal-cmd-click.sh` | Cmd-click in a terminal: no main-thread stall over 50 ms (live check). | cx-7xss | 2026-10-24 | active |
| `terminal-throughput.sh` | 200 MB burst through a NEXT terminal and through a standalone terminal. | CMUX-571 | 2026-11-13 | active |
| `terminal-throughput-quick.sh` | The same burst on any Mac in about a minute: an installed NEXT (a side copy of the NIGHTLY) and an installed Ghostty, no build or slot. | CMUX-571 | 2026-11-23 | active |
| `shell-integration.sh` | Shell integration costs nothing per prompt (fork guard plus bench). | perf-lead row 20 | 2026-11-01 | active |
| `menu-tracking-main-queue.sh` | Main-queue wait while a host context menu tracks. | - | 2026-11-11 | active |
| `menu-tracking-main-queue.swift` | Swift probe for menu-tracking-main-queue.sh. | - | 2026-10-30 | active |
| `devtools-calls.sh` | Main-thread time of large Chromium DevTools calls. | cmux-ad decision 5 | 2026-11-14 | active |
| `action-signposts.sh` | Action perform, commit and gate signposts, light and STRESS. | perf-lead row 23 | 2026-10-27 | active |
| `sidebar-stress.sh` | Sidebar scroll, switch, theme switch during a scroll and custom sidebar sections (install, save to render) at 20 and 500 workspaces. | - | 2026-11-17 | active |
| `main-thread-large-session.sh` | Main thread under the LARGE session (60 workspaces x 6 tabs). | MTS-0 | 2026-11-10 | active |
| `mobile-bench-mac-capture.sh` | Reference clips for the mobile bench: an iPhone app the App Store offers on the Mac, recorded at 120 fps (ScreenCaptureKit, every frame's own time) on a 120 Hz virtual display through the bench's flows, one `clip.mp4` + `meta.json` per flow (driver `scripts/mobile-bench/mac/`). | Leo 2026-11-19, mobile reference bench | 2026-11-19 | active |

## Rendering and frames

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `pane-perf.sh` | Pane layout motion (split, close, zoom, drag) at 2, 8 and 30 terminals. | panes-perf | 2026-10-27 | active |
| `pane-zoom.sh` | Cmd-Shift-Enter zoom and unzoom frames in 1x2, 2x2, 2x4 layouts. | pane-zoom | 2026-10-27 | active |
| `split-spring.sh` | Rapid Cmd-D and Cmd-Shift-D frames, plus the perf cron budgets suite. | - | 2026-11-08 | active |
| `diff-page-frames.sh` | A large diff tab at two commits: code view open, Plain English first paint, rAF scroll frame times, a clip (`diff-page-frames.py`). | cmux#46299 | 2026-11-20 | active |
| `perf-10x-drag.sh` | Pane and divider drags at 120 Hz, plus daemon cost per drag value. | perf-10x | 2026-10-22 | active |
| `perf-10x-drag-daemon.py` | Daemon-side cost of one drag value. | perf-10x | 2026-11-13 | active |
| `pane-motion-films.sh` | One movie per pane act, for a person to look at (judges nothing). | - | 2026-11-15 | active |
| `pane-motion-films.py` | Python driver for pane-motion-films.sh. | - | 2026-11-15 | active |
| `window-resize-feel.sh` | Films of a window corner drag (and a pane divider drag) over chat transcripts, one fresh launch per CEF resize-sync arm (`--arms=NAME:LIVE_MS:DRAG_MS:FRAME_SHARE,...`), with frame intervals and CEF fence/commit deltas; for a person or a frame analysis (judges nothing). | Leo 2026-11-22, #50940 | 2026-11-22 | active |
| `window-resize-feel.py` | Python driver for window-resize-feel.sh. | Leo 2026-11-22, #50940 | 2026-11-22 | active |
| `pane-overflow-fade.sh` | Native presentation-layer measurement of the pane overflow fade. | - | 2026-10-28 | active |
| `pane-overflow-bundle-setup.py` | Keeps historical bundle installs from deleting tracked placeholder docs. | - | 2026-10-26 | active |
| `fullscreen-transition.sh` | Full screen enter and leave: lag, layout passes, resizes. | fullscreen-lag | 2026-10-27 | active |
| `edit-repaint.sh` | Edit to repaint for cmux-next.json edits and customize saves (section, rows, pane, and a section card's `.glass` level), a palette command and a key binding. | - | 2026-11-23 | active |
| `replay-build-bench.sh` | terminal VT replay build time, one text layout against two. | - | 2026-11-01 | active |
| `pane-main-profile.sh` | One Instruments profile of the pane's 20 MB prompt bench. | - | 2026-10-05 | stale |
| `pane-native-transport.sh` | Agent pane native transport against the page-world WebSocket. | - | 2026-11-07 | active |
| `mac-screen-120fps.sh` | Mac Screen stream at 120 fps through hardware H.264. | - | 2026-11-07 | active |

## Memory, idle and power

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `idle-cpu.sh` | Idle CPU and wakeups of the app, acpmux and cmux-tui after N minutes. | - | 2026-11-04 | active |
| `interactive-lateness.sh` | One JSON line over N seconds: 10 ms timer lateness (p50/p95/p99/max, share over 5 and 16 ms), CPU busy %, memory pressure, swap and swap-out growth, thermal, HID idle, load, CPUs and perf levels (RFD 0072 piece 1; macOS and Linux). | RFD 0072 | 2026-11-24 | active |
| `ci-vm-idle.py` | Running VM-hours, idle VM-hours and list-price USD for persistent and JIT GCP CI pools from a local capture (`cmux-bench ci-vm-idle --arg input=PATH`). | GCP CI capacity | 2026-11-23 | active |
| `mcp-fanout.sh` | MCP tool-server processes, RSS and idle CPU per kind at N open chats (Claude, Codex) on any build (`app=`). | nightly-mcp-fanout | 2026-11-17 | active |
| `mcp-fanout.py` | Python driver for mcp-fanout.sh. | nightly-mcp-fanout | 2026-11-17 | active |
| `perf-10x-idle.sh` | Idle CPU, wakeups and RSS at 1, 10 and 50 workspaces; with `axes=`, the marginal idle cost (CPU, footprint, wakeups, disk bytes per hour, GPU utilization) of one more chat or terminal, hidden or visible, per process. | perf-10x, CMUX-672 | 2026-11-19 | active |
| `perf-idle-ab.sh` | Interleaved base vs head idle A/B in one step. | - | 2026-11-14 | active |
| `perf-idle-power.sh` | Idle power and wakeups in the scenarios of a browser comparison. | msg 2654 | 2026-11-15 | active |
| `perf-bench.sh` | xbench: cmux NEXT against other browsers (power, scroll, video, tab switch, launch). | msg 2654 | 2026-11-15 | active |
| `perf-lab.sh` | Measures a prebuilt bench app of one commit on one lab host. | p12 | 2026-10-31 | active |
| `perf-lab-build.sh` | Builds another commit's bench app with this checkout's harness. | p12 | 2026-10-31 | active |
| `tab-hibernation.sh` | Tab hibernation keep rule on 48 Chromium tabs. | msg 9103 | 2026-11-03 | active |
| `infinite-tabs.sh` | The app with 500 browser tabs, 200 workspaces and 100 agent chats hibernated, over the empty app: RSS, CPU, wakeups, switch times. | cmuxterm-hq goals/infinite-tabs-flat.md | 2026-11-22 | active |
| `renderer-sharing.sh` | Chromium renderer sharing across 100 same-site tabs. | - | 2026-10-27 | active |
| `cef-pump-wakes.sh` | Main-thread wakes from the Chromium message pump with busy hidden terminals. | STATUS 9946 | 2026-11-04 | active |
| `holder-dogfood.sh` | Terminal holder vs hosts: process and memory A/B. | perf lead | 2026-10-27 | active |
| `unshown-ptys.sh` | PTYs held by workspaces nobody has shown. | a913 | 2026-11-07 | active |
| `tui-scale-ab.sh` | cmux-tui daemon at scale on macOS, two commits interleaved. | - | 2026-11-07 | active |
| `orphan-process-scan.sh` | Read-only scan for orphaned cmux-tui and acpmux processes. | STATUS 1370 | 2026-10-31 | active |
| `dhat-top.py` | Top allocation sites at a dhat profile's peak. | - | 2026-11-15 | active |
| `infinite-items.py` | Time-compressed run of N workspaces, tabs and chats against the daemons. | CMUX-571 | 2026-11-15 | active |
| `infinite-items-linux.sh` | Infinite items on Linux, daemons plus headless chat pages. | CMUX-571 | 2026-11-15 | active |
| `perf-cron-linux.sh` | One perf cron Linux part on a Linux pool worker, for the build controller. | - | 2026-11-21 | active |
| `infinite-items-profile.sh` | dhat heap profile of the daemons per item. | CMUX-571 | 2026-11-15 | active |
| `tui-idle-ram.sh` | Idle cmux-tui daemon memory on Linux at commits (bench tui-idle); with latency=1 its hot-path latency (bench daemon-latency). | CMUX-571 | 2026-11-16 | active |
| `tui-idle-ram.py` | One idle headless daemon: smaps, threads, mappings, children. | CMUX-571 | 2026-11-16 | active |
| `chat-disk-growth.py` | One live chat's history bytes per simulated hour. | - | 2026-11-15 | active |
| `chat-disk-growth-linux.sh` | Linux entry for chat-disk-growth.py at 100,000 rows. | - | 2026-11-15 | active |
| `daemon-restart-linux.sh` | Daemon restart to a non-empty chat attach (god_daemon.rs small and god homes), median of up to 3 runs; the perf cron's daemon-restart part. | - | 2026-11-18 | active |
| `coord-sim-linux.sh` | Several synthetic coordinator chats at once against a release acpmux on Linux (bench coord-sim). | coord-sim | 2026-11-19 | active |
| `journal-writes.py` | Bytes the acpmux journal writes per hour and write amplification. | hq#11322 | 2026-11-15 | active |
| `qos-load-bench.sh` | Effect of agent load on foreground work, with and without the QoS tier. | cmux#27587 | 2026-10-29 | active |
| `qos-load-bench` | C probes (probe.c, spin.c) for qos-load-bench.sh. | cmux#27587 | 2026-10-29 | active |

## Network and screen

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `screen-stream-eval.sh` | Every screen stream through the same fixed scenarios on one Mac. | HQ#7146 G0 | 2026-11-15 | active |
| `screen-stream-eval` | Harness, scenarios and target interface for the screen stream eval. | HQ#7146 | 2026-11-16 | active |
| `codec-bench.sh` | Screen-share codec encode and decode ms per frame on Apple silicon. | - | 2026-11-14 | active |
| `codec-study.sh` | Still-image codec study on cmux screens (size, speed, OCR error). | - | 2026-11-08 | active |
| `codec-study` | Corpus and Swift helpers for codec-study.sh. | - | 2026-11-08 | active |
| `remote-agent-path.sh` | What an agent on another machine feels through cmux Remote. | - | 2026-11-15 | active |
| `relay-path-probe.sh` | Every path the iPhone link can take to a Mac (WireGuard direct, TURN/UDP, TURN/TLS 443, WebRTC direct and relay): setup p50/p95, link RTT p50/p95/p99 and loss, hub colo, ICE and TURN allocation times, as JSON and a table (`cmux-mobile-path-probe`). | Leo ask-6242128727, relay-path-latency | 2026-11-21 | active |
| `cloud-machine-directory.py` | Before and after CLI directory benchmark with a guest-program provider. | - | 2026-11-12 | active |
| `cloud-machine-read.py` | Two built binaries through the same fake-provider file-read route. | - | 2026-11-12 | active |

## Agents and chat

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `agent-engine.sh` | Agent chat engine spike: open time, memory, flings, typing per engine. | - | 2026-10-27 | active |
| `chat-typing-ab.sh` | Agent chat typing A/B, base vs head, in one step. | - | 2026-11-14 | active |
| `acpmux-overhead.sh` | acpmux against each harness run raw (Claude Code, Codex and others). | #2758 | 2026-10-29 | active |
| `agent-loop.sh` | Agent loop on a published NEXT nightly: scripted UI change applied live. | hq#7149 L8 | 2026-11-05 | active |
| `agent-loop.py` | Python driver for agent-loop.sh. | hq#7149 L8 | 2026-11-05 | active |
| `chief-build-cache.sh` | Chief build cache timing before and after. | #28481 | 2026-10-30 | active |
| `chief-latency.sh` | Chief latency before/after: a scratch Chief at two refs on one Mac, the 15-ask `latency` scenario with a real model (chief-latency bench; how to run: `Native/OptChat/optchat-chief/measure/README-latency.md`). | Chief latency lane | 2026-11-23 | active |
| `chief-import.sh` | One Chief import of a 2,020-message corpus on a quiet Mac. | - | 2026-10-10 | stale |
| `chief-prompt-bubble.sh` | Proof that a 140 KB Chief subagent prompt draws as the first bubble. | u4256 | 2026-10-27 | active |
| `team-eval.sh` | One run of the coordinator-mode eval: one task, one arm. | - | 2026-11-07 | active |
| `cu-bench` | Computer-use latency per tool call and per small task, per engine. | - | 2026-11-13 | active |
| `cu-driver-bench.sh` | Computer-use driver bench v2 in a macOS 26 VM (VM bring-up stage). | HQ#7146 G3a | 2026-11-08 | active |
| `cu-driver-eval` | Computer-use driver eval: every input route and driver build on test apps. | HQ#7146 G3a/G3b | 2026-11-13 | active |
| `cu-driver-eval.sh` | Fleet entry for cu-driver-eval (input-ab suite). | HQ#7146 G3a | 2026-11-08 | active |
| `cmux-cua-patch-tests.sh` | The legacy Computer Use helper's Rust unit tests (cmux-cua-core, cmux-cua-platform-macos) with cmux's patches from any ref applied, on a fleet Mac. | ask-3cf710da4e | 2026-11-18 | active |
| `cua-takeover.sh` | False takeovers and latency of the computer-use takeover detector. | - | 2026-11-04 | active |

## Browser and CEF

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `browser-fuzz.sh` | Seeded fuzz of URLs, navigation and tab storms (correctness). | fuzz row k | 2026-11-14 | active |
| `browser-use-perf.sh` | cmux browser host REPL against other browser-automation tools, no model. | - | 2026-11-03 | active |
| `cef-tab.sh` | New Chromium tab: input to visible and to page pixels. | PL-cef-tab | 2026-10-27 | active |
| `cef-embedder.sh` | CEF fork embedder tests against an unreleased fork build. | PL-cef-fork | 2026-11-12 | active |
| `cef-helpers.sh` | Chromium helper check: renderer and GPU helpers start, no V8 OOM. | - | 2026-11-05 | active |
| `cef-pak-render.sh` | Pages still render after the CEF paks are trimmed. | - | 2026-11-12 | active |
| `chromium-host-bench.sh` | Chromium host input hop time (hop_us). | cef-host-input | 2026-11-03 | active |
| `cef-app-size.sh` | Installed-size proof for CEF binary with V8 snapshots. | CMUX-570 | 2026-11-14 | active |
| `cef-snapshot-resources.py` | Pairs a CEF binary with its generated V8 snapshots. | CMUX-570 | 2026-11-14 | active |
| `clear-cache-look.sh` | Clear Browsing Data's cache option on a real Chromium engine: a service worker's Cache Storage before and after (correctness). | - | 2026-11-17 | active |
| `floating-pane-look.sh` | Pictures of a floating pane with the Debug Settings knob `Background opacity` at 1 and below 1: a terminal pane and a page pane, with a background picture and without (a look for a person; judges nothing). | - | 2026-11-18 | active |
| `floating-pane-look-daemon.sh` | The daemon calls of floating-pane-look.sh against a `cmux-tui` daemon alone, with no app and no display (a check of the look's driver before its display step). | - | 2026-11-18 | active |

## Build and dev loop

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `projection-macos.sh` | One agent checkout's FSEvents (events, unique paths), seconds, first `git status`, disk: git worktree, APFS clone (wt today), recycled checkout, projected (cmux-projection over NFSv3 from localhost); JOBS at once; fseventsd RSS (`projection-macos/fsevents-count.swift`). | projectionfs harder (2026-11-23) | 2026-11-23 | active |
| `rust-dev-loop.sh` | Edit to runnable time of the Rust dev build, per build variant. | #42280 | 2026-11-12 | active |
| `rust-dev-loop.py` | Python driver for rust-dev-loop.sh. | #42280 | 2026-11-12 | active |
| `blaze-home.sh` | Sourced helper: short link for the blaze home so its socket path fits. | - | 2026-11-06 | active |
| `rust-live-swap.sh` | cmux live --rust: save to swapped daemon, shells kept. | - | 2026-11-05 | active |
| `rust-test-bench.sh` | One cmux-tui Rust test run alone on an idle Mac. | - | 2026-11-01 | active |
| `rust-test-at-commits.sh` | One Rust test at a change's parent and at the change. | CMUX-571 | 2026-11-14 | active |
| `swift-test-bench.sh` | One swift-test benchmark run alone. | - | 2026-10-29 | active |
| `bench-at-commits.sh` | One webviews bench against the pane source of other commits. | CMUX-571 | 2026-11-14 | active |
| `structural-rebuild.sh` | Swift change that cannot be injected: time to a relaunched app. | - | 2026-11-10 | active |
| `structural-rebuild.py` | Python driver for structural-rebuild.sh. | - | 2026-11-10 | active |
| `live-code-app.sh` | Live code in the app end to end (patch, bad patch, rollback). | - | 2026-11-10 | active |
| `live-code-app.py` | Python driver for live-code-app.sh. | - | 2026-11-10 | active |
| `live-code-cost.sh` | Cost of a live code build against a regular build. | - | 2026-11-05 | active |
| `live-code-cost.py` | Report half of live-code-cost.sh. | - | 2026-11-05 | active |
| `live-code-shell.sh` | Live code in the view shell, judged by rendered width. | - | 2026-11-04 | active |
| `live-mode-swift.sh` | Swift live mode end to end on a tagged build. | - | 2026-11-10 | active |
| `live-mode-swift.py` | Python driver for live-mode-swift.sh. | - | 2026-11-12 | active |
| `hot-apply-nightly.sh` | hot-apply.py proven on a published nightly (apply then roll back). | - | 2026-11-14 | active |
| `hot-apply-nightly.py` | App half of hot-apply-nightly.sh. | - | 2026-11-14 | active |
| `hot-apply-dry-run.sh` | hot-apply fetch side timed cold and warm, any host. | - | 2026-11-14 | active |
| `try-pr-live-code.sh` | try-pr.sh --live-code end to end on a fleet Mac. | - | 2026-11-10 | active |
| `try-pr-live-share.py` | Share of recent NEXT PRs that try-pr.sh puts in with no app build. | - | 2026-11-07 | active |
| `try-pr-side-instance.sh` | try-pr.sh to a side instance, timed to loading the PR's page. | - | 2026-11-04 | active |
| `ext-hot-reload.sh` | Extension hot reload read-back test from DEV and Release builds. | - | 2026-11-14 | active |
| `ext-reload-nightly.sh` | Extension hot reload on a published NIGHTLY: the activity example saved under a watching ext dev and read back with no rebuild asked (the watcher's reload, the daemon's loaded copy, open views), and edit-repaint.py in read-back mode. | - | 2026-11-19 | active |
| `ext-reload-nightly.py` | App half of ext-reload-nightly.sh. | - | 2026-11-19 | active |
| `look-keys-readback.sh` | Look keys read back on a published NIGHTLY side instance (`build=VERSION` or `dmg=URL`): each case of a cases file (`look-keys-readback/cases.json`: theme file keys, chat stylesheet tokens) applied live, every theme key read through `settings.get`, window and desktop shots before and after, and a color probe for what no socket method reads. | goals/look-keys-land | 2026-11-24 | active |
| `look-keys-readback.py` | App half of look-keys-readback.sh (`prepare`, `run`). | goals/look-keys-land | 2026-11-24 | active |
| `ext-rows-nightly.sh` | Extension rows closed in code read back on a published NIGHTLY side instance, CLI and daemon ops only: web panes, background activation, link openers, the New Tab page, `ext new` for every kind, composer commands and mentions, chat-widget routing. | - | 2026-11-19 | active |
| `ext-rows-nightly.py` | App half of ext-rows-nightly.sh: one function per row. | - | 2026-11-19 | active |
| `meet-browser.sh` | What a video-call page needs, on a published NIGHTLY side instance (Chromium, WebKit) against Google Chrome on the same Mac: getUserMedia with and without fake-device switches, getDisplayMedia, Picture-in-Picture, notifications, a loopback 720p WebRTC call with CPU, meet.google.com load cold and warm, hidden-tab timer drift. | - | 2026-11-22 | active |
| `meet-browser.py` | Driver half of meet-browser.sh: the local test page, cmux over its control socket, Chrome over DevTools. | - | 2026-11-22 | active |
| `rift-eval.sh` | APFS clone workspaces vs git worktree for an agent's first green build. | - | 2026-11-11 | active |
| `cloud-partial-hydrate.sh` | A Cloud checkout's time to first read with the rest downloading in the background (hot files, wants, kill and resume) against the whole checkout. | - | 2026-11-24 | active |
| `nightly-cas-identity.sh` | Byte proof: a build with a reused compilation cache equals a clean build. | - | 2026-10-20 | active |
| `import-set-xcode.sh` | Import-set check stub cost with Xcode incremental builds. | - | 2026-10-18 | active |

## Size

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `app-ffi-size.sh` | Size the app FFI Rust library adds per LTO mode. | #42471 | 2026-11-13 | active |
| `cli-size.sh` | CLI size per compiler optimization mode; `toolchain BASE [HEAD]` builds two commits and HEAD with acpmux + cmux-tui-core at opt-level s and z, with speed. | CMUX-570 | 2026-11-18 | active |
| `cli-size-speed.py` | Bytes plus interleaved CLI and headless-daemon p50 for the builds `cli-size.sh toolchain` makes. | CMUX-570 | 2026-11-18 | active |
| `panic-abort-size.sh` | Size saved by panic=abort on the shipped Rust helpers. | CMUX-570 | 2026-11-15 | active |
| `macos-floor.sh` | How much CmuxNext code needs a newer macOS than a given floor. | - | 2026-11-07 | active |
| `macho-filter-parity.sh` | Thin-bundle Mach-O filter: old file scan vs new list, with timings. | - | 2026-10-20 | active |

## CI and infrastructure

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `workspace-factory.sh` | Throwaway per-job workspace from a read-only seed vs today's step workspaces, one real SwiftPM prebuild (bench workspace-factory). | hq RFD 0005 | 2026-11-17 | active |
| `workspace-factory` | `wsfactory`, the std-only Rust factory the script builds: seed publish/verify, create, destroy, reconcile. | hq RFD 0005 | 2026-11-17 | active |
| `quiet-host.sh` | Runs one measurement on a quiet host and records other CPU use. | - | 2026-10-31 | active |
| `require-chromium.sh` | Sourced by an entry that builds its app: the build requires the Chromium engine unless `--allow-no-chromium`. Measures nothing. | - | 2026-11-16 | active |
| `bench-ab` | Interleaved A/B driver for fleet benches with A/A self-test and intervals. | - | 2026-11-06 | active |
| `crash-gate.sh` | Fleet run of the "crash ends the app" gate. | - | 2026-10-30 | active |
| `blocking-checks.sh` | Checks the main-thread blocking detector's build configurations. | - | 2026-10-24 | active |
| `blocking-probe.sh` | Finds main-thread blocking with the probe over every catalog action. | - | 2026-11-12 | active |
| `blocking-probe` | probe.c, injected into the app by blocking-probe.sh. | - | 2026-10-24 | active |
| `blocking-probe-report.py` | Ranks the main-thread blocking the probe recorded. | - | 2026-10-24 | active |
| `ios-sim-density.sh` | iOS simulators per fleet Mac: N clones of one booted base running the same UI suites at once, jobs per hour, failures, memory per simulator, CPU, swap, pressure. | Leo 2026-11-16, simulator density | 2026-11-17 | active |
| `ios-sim-density.py` | Python driver for ios-sim-density.sh. | Leo 2026-11-16 | 2026-11-17 | active |
| `gui-user-per-job.sh` | One macOS account per GUI job: whether a pool account with no login of its own gets WindowServer, capture and AX input, TCC routes, cost per account, setup and teardown times. Pool stages need root (fleet-sudo). | Leo 2026-11-17, GUI CI partitioning | 2026-11-17 | active |
| `gui-user-isolation.sh` | Isolation test for the GUI user pool: N jobs at once, each as its own pool account, plus a simulator in its own device set; fails if any job sees another job's defaults, keychain, clicks or pixels, or a job touches the general pasteboard. | Leo 2026-11-17, GUI CI partitioning | 2026-11-17 | active |
| `tui-kit-selftest.sh` | Self-test of the journeys TUI load kit on a Mac. | - | 2026-11-11 | active |
| `tests` | Shell and Python tests for the harnesses in this directory (28 files). | - | 2026-11-15 | active |
| `export-action-catalog-dump.sh` | Regenerates action-catalog.json from the Swift catalog (generator). | CMUX-383 | 2026-11-14 | active |
| `export-action-surfaces.sh` | Regenerates action surfaces, docs and links (generator). | - | 2026-11-03 | active |
| `export-settings-artifacts.sh` | Regenerates settings artifacts with the CI-pinned Xcode (generator). | cx-aha.12 | 2026-10-12 | stale |

## Misc

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `api-compat-bench.sh` | api-compat change-rule chains: upgrade, downgrade, broadcast to 1,000 peers. | msg 2785 | 2026-10-19 | active |
| `files-finder-bench.sh` | Finder vs the Files pane: folder open and name search at 10k and 100k files. | - | 2026-10-20 | active |
| `files-finder-bench` | Swift main for files-finder-bench.sh. | - | 2026-10-20 | active |
| `classic-upgrade.sh` | Opt-in classic upgrade timings, apart from PR correctness checks. | - | 2026-10-29 | active |
| `hotkey-history.sh` | Runs one CmuxNext action-catalog regression test (not a measurement). | - | 2026-11-10 | active |
| `projection.sh` | Projection window of a published build: shows a change within 5 s. | hq#7149 L10 | 2026-11-05 | active |
| `closed-kit-raw-values.sh` | Hand-set values that type-check in the first closed webviews directory (15 probes, `open` or `closed`), and `tsc -p tsconfig.closed.json` cold and incremental. The follow rate is `bun run gallery:perturb` in webviews. | RFD 0040 | 2026-11-23 | active |

No script is marked `duplicate of`: the A/B wrappers (`*-ab.sh`) and the `.py` drivers reuse their base script on purpose, and no other pair clearly measures the same thing the same way.

## Retire candidates

Retired in the cmux-bench PR: `fresh-home-launch-ab.sh` (same measurement as `nightly-fresh-launch.sh dmg=build base=`, on Release builds: `cmux-bench post-update --arg mode=fresh-copy --build SHA --arg base=SHA`) and `baseline-ram.sh` (per-kind footprint at launch is the cmux-budget rows: `cmux-bench footprint --host fleet`). The rest below are candidates; check each before removing.

- `cu-driver-bench.sh`: its commit (#38523) made `cu-bench` the one latency bench for every computer-use engine; this is the older VM bring-up stage.
- `import-set-xcode.sh`: a one-time behavior test of a fleet slot check from 2026-10-18; not a recurring measurement.
- `api-compat-bench.sh`: a one-time parity check against a number from another team (msg 2785); no registered bench uses it.
- `macho-filter-parity.sh`: compares an old scan with its replacement once; the old path is gone.
- `rift-eval.sh`: a one-time evaluation of another tool (plans/cmux-next/rift-eval.md); ends when the plan is decided.
- `team-eval.sh`: a one-time coordinator-mode eval run, not a repeatable measurement.
- `pane-main-profile.sh`: a one-off Instruments profile from 2026-10-05 for the agent pane prompt bench.
- `pane-overflow-fade.sh` and `pane-overflow-bundle-setup.py`: the native fade proof was rejected (see the #25374 commit); stale since late October.
- `nightly-cas-identity.sh`: a one-time byte proof for the warm nightly worker.
- `hotkey-history.sh`: runs an action-catalog regression test, not a measurement; belongs with the tests.
- `export-action-catalog-dump.sh`, `export-action-surfaces.sh`, `export-settings-artifacts.sh`: generators, not measurements; they fit better in a generators directory.
- `update-e2e.sh`, `crash-gate.sh`, `stable-next-smoke.sh`, `terminal-cmd-click.sh`: correctness checks that run on the fleet, not measurements.
