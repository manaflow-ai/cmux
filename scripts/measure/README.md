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
| bundle | `bundle-size.sh` (DMG on a fleet Mac), an .app tree, or `--compare-zip URL` | Bundle size by component, against other apps. |
| launch | `launch-ready.sh` | Dock launch: bounce end, first window, main, first frame, every launch mark. |
| launch-premain | `launch-premain.sh` (also launch's mode=premain) | Time to main after a 60 s full run vs a short launch, and what it pays: pageins, residency, the code checkers' CPU, per arm. |
| post-update | `update-click-ab.sh` (default), `relaunch-shift.sh` (mode=shift), `nightly-fresh-launch.sh` (mode=fresh-copy) | First launch after an update and its hitches. |
| screen-share | `screen-stream-eval.sh` (default), `screen-share-vs.py` (mode=vs, once on base) | Screen share kbps, fps under motion, input-to-frame latency. |
| newtab | `instant-new-surfaces.sh` (default, mode=launch-pairs), `held-new-tab.sh` (mode=held) | New Tab first paint and settled-interactive time. |
| footprint | read-only probes (`ps`, rusage, `vmmap`) of a running app; `perf-bench.sh` cmux-budget on the fleet | Footprint per process kind. |
| xbench | `perf-bench.sh` (`scripts/perf-bench/xbench.py`); `--import` reads `results.json` and `scripts/perf-bench/baseline/*.json` | Against other browsers, and the resource budget rows. |
| idle | `perf-10x-idle.sh` | Idle CPU, wakeups and footprint per process kind. |
| tui-idle | `tui-idle-ram.sh` (`tui-idle-ram.py`, `dhat-top.py`) on Linux CI | The idle cmux-tui daemon's anonymous PSS, PSS, threads, binary sections and (dhat=1) Rust heap at commits. |
| mcp-fanout | `mcp-fanout.sh` (`mcp-fanout.py`) on a fleet Mac, any published app (`app=`) | MCP tool-server processes, RSS, idle CPU per kind at N open chats; first cmux tool call latency. |
| transcript-replay | `webviews/scripts/agent-pane/transcript-replay.bench.ts` on Linux CI (headless Chrome, synthetic daemon) | Agent chat transcript: visible-row shifts per replay phase (stream, page up, fold, composer) and first paint at 500 and 50k rows. |


## Launch and update

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `launch-ready.sh` | Time from Dock launch to a usable window, measured from outside the app. | CMUX-629, CMUX-631 | 2026-11-15 | active |
| `launch-ready.swift` | Swift probe that launches one app copy like the Dock and records every mark. | CMUX-629 | 2026-11-15 | active |
| `launch-premain.sh` | What makes a launch reach `main` 600 to 1170 ms late: arms after a 60 s run, page cache, purge, another app, sampled (launch bench mode=premain). | CMUX-629 | 2026-11-17 | active |
| `launch-premain.swift` | Probe for launch-premain.sh: open or exec one launch, pageins, CPU and the executable's residency at `main`. | CMUX-629 | 2026-11-17 | active |
| `launch-capture-probe.sh` | Launch image sources with no Screen Recording grant: TCC rows and prompts, the window composite and Chromium page image against the screen, ms and main-thread stall per source. | ask-b2b0f899c1 | 2026-11-17 | active |
| `launch-capture-probe.py` | Python driver for launch-capture-probe.sh. | ask-b2b0f899c1 | 2026-11-17 | active |
| `launch-ready-profile.py` | Main-thread Time Profiler summary of one launch-ready launch. | - | 2026-11-15 | active |
| `fresh-home-launch.sh` | Fresh-home launch of any commit's app on a fleet Mac. | - | 2026-11-14 | active |
| `nightly-fresh-launch.sh` | Where a published nightly's fresh-home launch spends its time. | CMUX-571 | 2026-11-15 | active |
| `nightly-fresh-launch.py` | Python driver for nightly-fresh-launch.sh. | CMUX-571 | 2026-11-15 | active |
| `relaunch-restore.sh` | Quit to usable time after Quit and Keep Sessions, on a published build. | hq#7149 L5 | 2026-11-05 | active |
| `relaunch-shift.sh` | Layout shift when the app relaunches after an update. | - | 2026-11-04 | active |
| `first-load-after-restart.sh` | A chat's first load after a restart, frame by frame, at commits (shift and blank frames, settle time). | - | 2026-11-16 | active |
| `update-click-ab.sh` | Real Sparkle update, Restart to Update clicked soon after staging, base vs head. | CMUX-571 | 2026-11-15 | active |
| `update-click-ab.py` | Summarizes update-click-ab.sh runs into medians. | CMUX-571 | 2026-11-15 | active |
| `update-e2e.sh` | End to end auto-update of a real nightly (correctness, not a timing). | R114 | 2026-10-04 | stale |
| `stable-next-smoke.sh` | Fresh-home launch smoke of the NEXT Stable build on a console worker. | - | 2026-10-30 | active |
| `daemon-registry-start.sh` | Start time of the cmux-tui daemon on a large registry. | - | 2026-11-13 | active |
| `daemon-registry-start.py` | Python driver for daemon-registry-start.sh. | - | 2026-11-13 | active |

## Input and latency

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `instant-new-surfaces.sh` | Key to visible frame for Cmd-N, Cmd-T, Cmd-D, Cmd-Shift-D. | - | 2026-10-27 | active |
| `new-terminal-100x.sh` | New terminal, split and workspace latency through the cmux-tui daemon. | - | 2026-11-07 | active |
| `held-new-tab.sh` | Held Cmd-T with Cmd-W now and then, in a session of many workspaces. | - | 2026-11-15 | active |
| `held-new-tab.py` | Python driver for held-new-tab.sh. | - | 2026-11-16 | active |
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
| `shell-integration.sh` | Shell integration costs nothing per prompt (fork guard plus bench). | perf-lead row 20 | 2026-11-01 | active |
| `menu-tracking-main-queue.sh` | Main-queue wait while a host context menu tracks. | - | 2026-11-11 | active |
| `menu-tracking-main-queue.swift` | Swift probe for menu-tracking-main-queue.sh. | - | 2026-10-30 | active |
| `devtools-calls.sh` | Main-thread time of large Chromium DevTools calls. | cmux-ad decision 5 | 2026-11-14 | active |
| `action-signposts.sh` | Action perform, commit and gate signposts, light and STRESS. | perf-lead row 23 | 2026-10-27 | active |
| `sidebar-stress.sh` | Sidebar scroll, switch, theme switch during a scroll and custom sidebar sections (install, save to render) at 20 and 500 workspaces. | - | 2026-11-17 | active |
| `main-thread-large-session.sh` | Main thread under the LARGE session (60 workspaces x 6 tabs). | MTS-0 | 2026-11-10 | active |

## Rendering and frames

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `pane-perf.sh` | Pane layout motion (split, close, zoom, drag) at 2, 8 and 30 terminals. | panes-perf | 2026-10-27 | active |
| `pane-zoom.sh` | Cmd-Shift-Enter zoom and unzoom frames in 1x2, 2x2, 2x4 layouts. | pane-zoom | 2026-10-27 | active |
| `split-spring.sh` | Rapid Cmd-D and Cmd-Shift-D frames, plus the perf cron budgets suite. | - | 2026-11-08 | active |
| `perf-10x-drag.sh` | Pane and divider drags at 120 Hz, plus daemon cost per drag value. | perf-10x | 2026-10-22 | active |
| `perf-10x-drag-daemon.py` | Daemon-side cost of one drag value. | perf-10x | 2026-11-13 | active |
| `pane-motion-films.sh` | One movie per pane act, for a person to look at (judges nothing). | - | 2026-11-15 | active |
| `pane-motion-films.py` | Python driver for pane-motion-films.sh. | - | 2026-11-15 | active |
| `pane-overflow-fade.sh` | Native presentation-layer measurement of the pane overflow fade. | - | 2026-10-28 | active |
| `pane-overflow-bundle-setup.py` | Keeps historical bundle installs from deleting tracked placeholder docs. | - | 2026-10-26 | active |
| `fullscreen-transition.sh` | Full screen enter and leave: lag, layout passes, resizes. | fullscreen-lag | 2026-10-27 | active |
| `edit-repaint.sh` | Edit to repaint for cmux-next.json edits and extension saves. | - | 2026-11-13 | active |
| `replay-build-bench.sh` | terminal VT replay build time, one text layout against two. | - | 2026-11-01 | active |
| `pane-main-profile.sh` | One Instruments profile of the pane's 20 MB prompt bench. | - | 2026-10-05 | stale |
| `pane-native-transport.sh` | Agent pane native transport against the page-world WebSocket. | - | 2026-11-07 | active |
| `mac-screen-120fps.sh` | Mac Screen stream at 120 fps through hardware H.264. | - | 2026-11-07 | active |

## Memory, idle and power

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `idle-cpu.sh` | Idle CPU and wakeups of the app, acpmux and cmux-tui after N minutes. | - | 2026-11-04 | active |
| `mcp-fanout.sh` | MCP tool-server processes, RSS and idle CPU per kind at N open chats (Claude, Codex) on any build (`app=`). | nightly-mcp-fanout | 2026-11-17 | active |
| `mcp-fanout.py` | Python driver for mcp-fanout.sh. | nightly-mcp-fanout | 2026-11-17 | active |
| `perf-10x-idle.sh` | Idle CPU, wakeups and RSS at 1, 10 and 50 workspaces. | perf-10x | 2026-11-14 | active |
| `perf-idle-ab.sh` | Interleaved base vs head idle A/B in one step. | - | 2026-11-14 | active |
| `perf-idle-power.sh` | Idle power and wakeups in the scenarios of a browser comparison. | msg 2654 | 2026-11-15 | active |
| `perf-bench.sh` | xbench: cmux NEXT against other browsers (power, scroll, video, tab switch, launch). | msg 2654 | 2026-11-15 | active |
| `perf-lab.sh` | Measures a prebuilt bench app of one commit on one lab host. | p12 | 2026-10-31 | active |
| `perf-lab-build.sh` | Builds another commit's bench app with this checkout's harness. | p12 | 2026-10-31 | active |
| `tab-hibernation.sh` | Tab hibernation keep rule on 48 Chromium tabs. | msg 9103 | 2026-11-03 | active |
| `renderer-sharing.sh` | Chromium renderer sharing across 100 same-site tabs. | - | 2026-10-27 | active |
| `cef-pump-wakes.sh` | Main-thread wakes from the Chromium message pump with busy hidden terminals. | STATUS 9946 | 2026-11-04 | active |
| `holder-dogfood.sh` | Terminal holder vs hosts: process and memory A/B. | perf lead | 2026-10-27 | active |
| `unshown-ptys.sh` | PTYs held by workspaces nobody has shown. | a913 | 2026-11-07 | active |
| `tui-scale-ab.sh` | cmux-tui daemon at scale on macOS, two commits interleaved. | - | 2026-11-07 | active |
| `orphan-process-scan.sh` | Read-only scan for orphaned cmux-tui and acpmux processes. | STATUS 1370 | 2026-10-31 | active |
| `dhat-top.py` | Top allocation sites at a dhat profile's peak. | - | 2026-11-15 | active |
| `infinite-items.py` | Time-compressed run of N workspaces, tabs and chats against the daemons. | CMUX-571 | 2026-11-15 | active |
| `infinite-items-linux.sh` | Infinite items on Linux, daemons plus headless chat pages. | CMUX-571 | 2026-11-15 | active |
| `infinite-items-profile.sh` | dhat heap profile of the daemons per item. | CMUX-571 | 2026-11-15 | active |
| `tui-idle-ram.sh` | Idle cmux-tui daemon memory on Linux at commits (bench tui-idle). | CMUX-571 | 2026-11-16 | active |
| `tui-idle-ram.py` | One idle headless daemon: smaps, threads, mappings, children. | CMUX-571 | 2026-11-16 | active |
| `chat-disk-growth.py` | One live chat's history bytes per simulated hour. | - | 2026-11-15 | active |
| `chat-disk-growth-linux.sh` | Linux entry for chat-disk-growth.py at 100,000 rows. | - | 2026-11-15 | active |
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
| `chief-import.sh` | One Chief import of a 2,020-message corpus on a quiet Mac. | - | 2026-10-10 | stale |
| `chief-prompt-bubble.sh` | Proof that a 140 KB Chief subagent prompt draws as the first bubble. | u4256 | 2026-10-27 | active |
| `team-eval.sh` | One run of the coordinator-mode eval: one task, one arm. | - | 2026-11-07 | active |
| `cu-bench` | Computer-use latency per tool call and per small task, per engine. | - | 2026-11-13 | active |
| `cu-driver-bench.sh` | Computer-use driver bench v2 in a macOS 26 VM (VM bring-up stage). | HQ#7146 G3a | 2026-11-08 | active |
| `cu-driver-eval` | Computer-use driver eval: every input route and driver build on test apps. | HQ#7146 G3a/G3b | 2026-11-13 | active |
| `cu-driver-eval.sh` | Fleet entry for cu-driver-eval (input-ab suite). | HQ#7146 G3a | 2026-11-08 | active |
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

## Build and dev loop

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
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
| `rift-eval.sh` | APFS clone workspaces vs git worktree for an agent's first green build. | - | 2026-11-11 | active |
| `nightly-cas-identity.sh` | Byte proof: a build with a reused compilation cache equals a clean build. | - | 2026-10-20 | active |
| `import-set-xcode.sh` | Import-set check stub cost with Xcode incremental builds. | - | 2026-10-18 | active |

## Size

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
| `app-ffi-size.sh` | Size the app FFI Rust library adds per LTO mode. | #42471 | 2026-11-13 | active |
| `cli-size.sh` | CLI size per compiler optimization mode. | CMUX-570 | 2026-11-14 | active |
| `panic-abort-size.sh` | Size saved by panic=abort on the shipped Rust helpers. | CMUX-570 | 2026-11-15 | active |
| `macos-floor.sh` | How much CmuxNext code needs a newer macOS than a given floor. | - | 2026-11-07 | active |
| `macho-filter-parity.sh` | Thin-bundle Mach-O filter: old file scan vs new list, with timings. | - | 2026-10-20 | active |

## CI and infrastructure

| name | what it measures | ticket / owner | last touched | status |
|---|---|---|---|---|
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
