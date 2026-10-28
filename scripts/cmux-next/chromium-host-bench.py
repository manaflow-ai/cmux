#!/usr/bin/env python3
"""Chromium in process vs Chromium in its own host app (prototype; plans/cmux-next/cef-helper-app-DESIGN.md).

Launches one tagged Debug cmux-next app with `browserHost.helper` and `browserResize.layerHostingEveryPage` (the
bench-only feature `cefLayerHostingEveryPage`'s local override: every page window hosts from fork API 26, without the
Track A calls the shipping feature `cefLayerHosting` needs) on, and measures the same probe page twice. Chromium tabs
stay in cmux (`browserHost.tabs` off) except with `--modes profiles`, `--modes tcc`, `--modes agentcdp` and
`--kill-host`, which need them in the host: profiles, tcc and agentcdp run in a launch without the in-process rows
(inproc, --baseline, --stress), and
--kill-host runs instead of the modes; an in-process row of a launch whose tabs run in the host says not_run (its
numbers would be the host's):

  inproc   a normal Chromium tab (`openBrowser.chromium`): the browser process is the cmux app, its pump runs on
           cmux's main thread, the page's pixels are layer hosted (fork API >= 26) and its input goes to the page
           window (debug.mouse/debug.key `target: page`)
  helper   `debug.chromium_host open`: the browser process is `<App>.app/Contents/MacOS/<App> Chromium Host`, the page's pixels are the
           host's CAContext in a CALayerHost over the same pane, and cmux forwards its input over the wire

Per mode:
  key      N key presses (debug.key, timestamped at send) into a focused text field. The page records, per key,
           performance.now() - event.timeStamp at its next requestAnimationFrame (`key_to_raf_ms`: the frame the
           change is drawn in, as Chromium schedules it). In helper mode Chromium stamps the key when the host
           dispatches it, so the hop cmux -> host UI thread is measured separately (`hop_us`, the host's
           event-time-to-dispatch percentiles) and `key_to_raf_ms + hop` is the comparable total.
  click    the same for N clicks (debug.mouse).
  pacing   the page's requestAnimationFrame intervals during a 3 s CSS animation (`raf_ms`: p50/p95/max,
           `long_frames`: intervals over 1.5 refresh periods), with the display refresh rate.
  ping     helper only: N round trips cmux -> host UI thread -> cmux over the wire (`ping_us`).
  kill     helper only: SIGKILL to the host. Pass when the cmux app's pid is unchanged and answers, a new host
           starts by itself (restart policy) and loads the saved page, and the in-process tab still answers.
  pixels   helper only: the share of screen samples in the probe's background color (a `screencapture` of the main
           display) before the host page opens (only the in-process page shows it) and after it shows, and again
           after the kill's restart. Pass when the host page adds at least 2 % of the screen: its pixels really
           composite through the CALayerHost (the host's page window is never ordered in, and its alpha 0 must not
           stop the hosted context from drawing).
  lifetime helper only, after every other row (it kills cmux): `debug.chromium_host close` ends and reaps the host
           within the quit limit and does not restart it; a host stopped with SIGSTOP (its UI thread never reads
           `quit`) and then closed is SIGKILLed at the quit limit (15 s); SIGKILL to cmux itself ends the host
           within the quit limit (it reads EOF on the wire).
  pump     the baseline the move removes: the share of cmux's main thread spent inside Chromium's pump passes
           (CefDoMessageLoopWork and every CEF callback it runs, `debug.cef` pump.work_ms over wall time) and the
           app's wakes (`wakes`, debug.wakeups: kernel wakeups and CPU of the app process, the wakeup ledger, and
           its CEFMessagePump part), `pump_share` idle (page shown, nothing happens) and while the page scrolls (one
           wheel event per frame). inproc: light and, with --stress, in the STRESS session (perf-stress-session.py,
           its Chromium pages selected). helper: light, the host page idles and scrolls while the in-process tab
           stays open, idle, in the other pane (cmux's pump still runs for it and the spare page).
           Key callbacks Chromium makes from cmux's own event dispatch are not in it (they run outside a pass).
  input    helper: typing and the caret, one blur and one focus when cmux's focus moves out and back, copy and
           paste through cmux's Edit menu, and Chromium's native UI from the host (context menu, <select>, alert,
           file picker; each in a fresh host) with the frontmost pid and the host's activation counters; IME and
           drag are listed as not forwarded, find as run by --find.
  ime      helper, with --ime: the host's TEXT_INPUT_STATE pushes per keystroke into the focused field against the
           fork's text input changes (ime_row; pass: <= 1 push per key). Then password_row (task p01-process-230):
           a click into the probe's password field turns cmux's secure event input on (debug.chromium_host
           password_input, and the system's secure input pid is cmux's where ioreg shows it), a click back into the
           text field turns it off.
  identity helper: the host is a second executable of cmux.app (cmux's bundle id): its LaunchServices type
           (UIElement: no Dock icon, menu bar or Cmd-Tab entry), the frontmost app after the input rows and after
           `open -b <bundle id>` and during 10 clicks with a key each (never the host; the host's own activation and
           key-window counters stay 0), the host's on-screen windows (CGWindowList; pass: 0, its page windows are
           detached and never ordered in, task p01-process-053), the keys of cmux's defaults domain that changed
           while the host ran less those cmux changed alone before it (pass: none), and a Quit AppleEvent to the
           bundle id (cmux quits, not the host; last row).
  geometry helper: the window moves, then grows, 1 point per display frame; the host's geometry counters
           (kOpGeometryStats through `debug.chromium_host.measure {op: geometry}`) give the page placements per
           display frame (pass: <= 1, none unplaced; geometry_row, task p01-process-053).
  failure  helper: when the host page never shows, the host's Chromium log tail and its crash reports.
  route    (`--modes route`, task p01-process-042) host mode's input ring with ack pacing (feature
           chromiumHostInputRing, a host-mode Chromium tab whose page view takes its input): the
           `debug.chromium_host` `input_route` counters while the probe tab gets
           scroll_pacing  a trackpad gesture (began, 60 changed, ended) then its momentum (began, 30 changed,
                          ended), one tick per 4 ms: pass when the page's pacer never had more than 1 wheel in
                          flight, the first wheel tick of the gesture left cmux within 0.5 ms of its event
                          (`first_wheel_send_us` p50/p95/max) and the page scrolled during the momentum ticks.
           key            --count keys into the focused field: pass when the field got every key, none was left
                          unwritten, and no move or wheel was in flight more than once (keys never wait).
           A build whose tabs are not in host mode (no input route) fails the mode with the reason.
  baseline (--baseline, task p01-process-005; plans/cmux-next/chrome-parity/p01-process.md) adds the numbers the
           process-model program is measured against, and prints them as perf-lead.md section 5 rows
           (chromium_host_baseline.py, `baseline-rows.md` in --out):
           stall    requirement 9a of cef-helper-app-DESIGN.md: a 50 ms main-thread stall every 100 ms
                    (`debug.stall`, from a second socket connection) while the page animates; the page's rAF
                    intervals and long frames, per mode (pass: 0 long frames).
           tabs10   idle wakes with 10 in-process Chromium tabs (the probe and 9 more), after --idle-settle-seconds
                    (hidden pages freeze after 30 s), per process kind (app, helpers, daemon), in three scenarios:
                    app visible, workspace hidden (a new workspace selected) and app hidden (NSApp.hide);
                    the 9 are closed after.
           census   process-model-census.py (task p01-process-004) on this running app (`--tag` and `--socket`,
                    never `--app`, which launches and then ends a second instance of the tag): light after the
                    light-session rows (its workspace is not in them), then one census of the session as it is
                    and the heavy one with that as its `--baseline`. The per-role memory split per added hidden
                    terminal is each role's private growth plus the shared mappings' growth counted once
                    (chromium_host_baseline.memory_split).
           with --stress: idle wakes in the same three scenarios, and key and click to paint and the stall in
           both modes, in the STRESS session too (the probe opened in its measured pane).
  cursor   `--modes cursor` (task 045 of plans/cmux-next/chrome-parity/p01-process.md): a Chromium tab of the app's
           backend over a page of four bands, text (an input), link, col-resize and a CSS image cursor; the pointer
           moves over each (`debug.mouse` page `move`, its reply kept per band; a move that errs fails its band) and
           `debug.cef`'s `page_cursor` (the page view's cursor in host mode) must name it. In process the page window
           shows Chromium's own cursor, and until the host input route (p01-process-042) a host-mode page view has no
           pointer route to the host: the row says not_measurable with the reason instead of passing.
  mouse    `--modes mouse` (task 054 of plans/cmux-next/chrome-parity/p01-process.md), host mode: a page with a
           `title=` band and a pad that records every mousedown, mouseup, click, auxclick and ctrl-wheel (a pinch, as
           Blink hands it to the page) with its button, and visualViewport.scale.
           tooltip  the pointer moves onto the band once and stays: `debug.cef`'s `page_tooltip` must name the band's
                    title and `tooltip_shown` (the app's tooltip on screen) must show it while the pointer stays
                    inside the page view (Chrome's -setToolTipAtMousePoint: shows it with no exit and enter).
           back, forward  `debug.mouse` page clicks with AppKit buttons 3 and 4: the page must see no left button
                    (button 0) event; until the host sends kBack and kForward (p01-process-054b) it sees none.
           middle   a middle click: the page's events of button 1 (auxclick), reported.
           pinch, smart_magnify  `debug.mouse` page `pinch` (scale 1.5) and `smart_magnify`: the frames the page view
                    sent, and whether the page saw them (scale changed or a ctrl-wheel); `not_dispatched` with the
                    reason while the host drops kGesture (p01-process-054b), never a pass.
           In process, or before the host input route (p01-process-042), the row says not_measurable.
  dragin   `--modes dragin` (task 050), on an input host (real HID events) with feature chromiumHostDragIn on: a
           Chromium tab of the app's backend over a drop zone and an <input type=file>; a real drag session from
           another app (pointer-probe.swift drag-file, as from Finder) drops one file on each. Pass: the zone's drop
           event and the input's change event have the file's name and size, the source saw the drop taken, and
           `debug.cef`'s `page_drag` counts one more DragTarget drop and at least one DRAG_OPERATION answer (the
           page view, not the DevTools relay, took it). In process, or with a fork API below 31 (p01-process-178,
           where the relay takes the drops), the row says not_measurable with the reason instead of passing.
  agentcdp `--modes agentcdp` (task p01-process-233), feature chromiumHostAgentRelay on: an agent session of the app's
           browser host sends --agent-rate CDP messages a second to a hidden Chromium tab in the Chromium Host for
           --agent-seconds while the bench types into the terminal in front of it; the app's main-thread tasks per
           `browser-host.cdp*` owner (pass: 0 per message) and terminal key-to-frame (pass: p99 <= 16.7 ms)
           (chromium_host_agent_cdp.py; run the bench under trace.py's wrap mode for the turns' timeline). With
           --kill-app, last (it kills cmux): SIGKILL to cmux with the agent's tab open, cmux launched again, and the
           agent drives the same page (performance.timeOrigin unchanged; needs browserHost.survivesAppCrash, task 150).
  display  `--modes display` (task 221): a Chromium tab of the app's backend in the Chromium Host follows the cmux
           window's display: rAF/s against the display's refresh rate and devicePixelRatio against its scale, then,
           with a second display (cmux20-bench has an external one), frames until both are the new display's after
           the window moves there and back, counted from the move (pass: rate within 2 frames, scale within 1, the
           1x to 2x move reported as `scale_up`) (chromium_host_display.py).
  tcc      opt-in (`--modes tcc`; it runs before helper and closes its tab after), with `browserHost.tabs` on like
           profiles: a page in a Chromium tab of cmux's host mode (debug.cef backend "host", else a mode error) asks for
           camera, mic, location, Local Network, Screen Recording and Bluetooth, its site permissions answered with
           browser.prompt.allow, and each row passes when macOS charges the host's request to cmux, not to the host or a
           helper; the keychain row passes when hosts make and read "Chromium Safe Storage", and read the item cmux's
           in-process engine made, with no prompt (chromium_host_tcc.py has the evidence and the rules). It launches
           cmux as its own responsible process (BenchApp own_responsibility) and, when the item is not another app's (or
           with --keychain-reset), first a seed launch with Chromium in process, both with Chromium's real keychain
           (CMUX_NEXT_BENCH_REAL_KEYCHAIN=1).
  profiles `--modes profiles` (task 080), with `browserHost.tabs` on (every Chromium tab in the supervisor's
           host): two browser profiles made with the app's CLI, a Chromium tab of each; pass when the backend is the
           host, both load, the supervisor's one host (`debug.cef` host_supervisor) serves both and their localStorage
           is apart (chromium_host_profiles.py).

  swipe    `--modes swipe` (task 234), on an input host (real HID events): a two-finger trackpad swipe
           (pointer-probe.swift swipe, through NSApp's event dispatch like a hand's) over a Chromium tab of the app's
           backend. flat: a page that does not scroll sideways, opened twice (?1 then ?2); a swipe that drags the
           content right must go Back to ?1. wide: a page whose sideways scroller is scrolled to its middle; the same
           swipe must scroll it and stay on ?2. Per gesture, `debug.cef` `swipe` gives the page probes (each a script
           run in the page: a control request in host mode) and the WHEEL_ACKs it decided from. Pass: back on flat,
           no navigation on wide, and on a host that acks wheels (`host_acks_wheels`) 0 probes per gesture. A swipe no
           gesture of reaches (`gestures` unchanged: the page view takes no scrolls before the host input route,
           p01-process-042) says not_measurable.
  pinch    `--modes pinch` (task 234), on an input host: a real trackpad pinch (pointer-probe.swift magnify, zoom in)
           over a Chromium tab of the app's backend. Pass: the page's visual viewport scale grows (Chrome's pinch
           zoom), the page stays put, and the pinch starts no swipe gesture (`debug.cef` `swipe`). The page counts
           the ctrl+wheel events Chrome makes of a pinch, so a pinch that reached Chromium but did not zoom fails
           apart from one that never arrived. In host mode a pinch that never reaches the page (the page view's
           magnify route is p01-process-042's input route with p01-process-054's PinchEvent) says not_measurable.

--native-ui [ROWS] runs instead the native UI rows (chromium_host_native_ui.py), all or the comma-separated ROWS: a
<select> as a cmux menu while the host is never frontmost (p01-process-060, feature chromiumHostPopupMenus), the page
menu (CONTEXT_MENU and context_menu_done) and a page's download (DOWNLOAD_* and download_continue) in host mode
(p01-process-069), the hosted widget rows (p01-process-066): date, datalist, popup window, DevTools docked and in a window, an extension
popup and a side panel, each shown by cmux from the host's layer context (`debug.cef` `host_widgets`), with feature
chromiumHostWidgets on and two test extensions, then the autofill and password rows (chromium_host_suggestions.py,
p01-process-061): the field's suggestions in cmux's list (`debug.cef` `host_suggestions`) with feature
chromiumHostSuggestions on, then the page dialog rows (chromium_host_native_ui_dialogs.py, p01-process-064): file
picker, certificate error, beforeunload and renderer hang, each answered by cmux while the host is never frontmost
and shows no window, with feature chromiumHostFileDialogs on, the permission rows (p01-process-062, feature
chromiumPermissionPromptsFromData): camera, microphone, location and notifications on a page served from 127.0.0.1.
Each is asked in cmux's prompt bar and answered Block through `debug.browser.prompts`, the page hears the refusal,
and the app's child processes show no window, then the chooser rows (chromium_host_native_ui_choosers.py,
p01-process-228): color, device chooser, screen share, external protocol, Web Share (skipped until p01-process-228c), video
and document picture-in-picture, with feature chromiumHostChoosers on, then the fullscreen and lock rows
(chromium_host_native_ui_locks.py, p01-process-229): HTML fullscreen, pointer lock and keyboard lock held by cmux
(`debug.cef` `host_locks`) and each ended by Escape, with feature chromiumHostLocks on. The page rows share one probe
tab; each row gets a `host_windows` block from the host's lines in the app log written while it ran
(chromium_host_windows.py, p01-process-068): the Chromium widgets the fork blocked (BLOCKED_WIDGET, by Views class and
by the cmux UI whose kind of request it was) and the host windows its backstop took off screen (UNEXPECTED_WINDOW). A
row fails with any unexpected window, or a blocked widget with no logged dismissal (refused or close-failed: it still
shows, whatever its owner); `host_windows` in the report is the same count over the whole run.
--list-failing then prints one `FAILING native_ui.<row>: <reason>` line per failing row (`FAILING none` when none).

--renderer-hang runs instead the renderer hang row (chromium_host_renderer_hang.py, p01-process-072) with feature
chromiumHangFollowsVisibility on: a `while(true){}` page's Page unresponsive prompt shows in that tab only, after
kHungRendererDelay (15 s), never as the host's banner; hidden behind another tab it goes and stays away past the
delay; shown again it comes back a full delay after the show; Exit page ends that renderer.

--kill-host runs instead the host kill rows (chromium_host_kill.py, p01-process-082): one `--signals` signal per row
(default KILL; TRAP,SEGV,ABRT,KILL for the done check) to the supervisor's Chromium Host under a Chromium tab
(`browserHost.tabs` on): cmux runs on, the tab shows the crash page with Reload (`crash_page_ms` from the signal),
`debug.crashes` lists the host's end in `chromium_host` with that signal, its fork API and its log's last lines (at
least one, none with a URL; the row's `crash_record`, chromium_host_crash_records.py, p01-process-085), and Reload
brings the page back under a new host.

--kill-host --restore runs instead the restore row (chromium_host_restore.py, p01-process-083) in a launch of its own,
with feature chromiumHostRestoreTabs on (the kill rows expect the crash page and Reload, which a restore replaces): it
opens 20 Chromium tabs in 3 windows, each with two history entries, SIGKILLs the Chromium Host, and checks every tab
back at its address with both entries on one new host: each window's shown tab within 2 s (`shown_ms`), each hidden
one when it is focused (`hidden_ms`).

--find runs instead the find rows (chromium_host_find.py, p01-process-048): Cmd-F, a typed query, Cmd-G, Cmd-Shift-G
and Escape through cmux's find pill on a Chromium page in the host (`debug.cef` backend `host`), the pill's match
count and active match (the oracle's overlays.findBar) and the page scrolled to the active match.

--helper-kill runs instead the helper-kill rows (chromium_host_helper_kill.py, p01-process-225): on a Chromium page in
the host, the tab's renderer pids are the host's children, and a SIGKILL to the host's network service, GPU process
and the tab's renderer each makes one `debug.crashes` record with its pid, type and signal (the host's HELPER_EXIT).

--hang MS runs instead the busy banner row (chromium_host_hang.py, p01-process-084): with chromiumHostHangBanner on,
the host stopped MS ms with a key waiting shows "Chromium is busy" at 2000 +/- 100 ms (`debug.cef` host_hang), no
busy deadline is armed with no input waiting, and the banner goes when the host runs again.

A Debug or bench build (reload.sh --config bench: debug.chromium_host, its measure call and the tunables file
answer there for a development bundle, p12-perf-process-221), never Release: the numbers compare the two paths,
they are not shipping latencies. `build` in the report is the bundle's config.
Not a gate: exit 1 only when a mode could not run (no host app, refused fork API, launch failure).

Percentiles (n/p50/p95/p99/max) are scripts/perf-lab/perf_stats.py's (linear interpolation) over the raw values:
the page reports each event's delta, never its own summary. Every series is also one cmux-perf-result/v1 file in
--out through BenchApp.record (browser_engine_bench_report.py): `chromium_host.<session>.<mode>.<metric>` in story
chromium-host (key and click to paint and to the next animation frame, frame intervals, long frames, pump share);
the report lists them under `results_v1`. hop_us and ping_us stay in the report only: debug.chromium_host.measure
answers percentiles, not samples, so the story claims no hot path (cef-host-input) until it returns the samples.

On a fleet GUI host:
  python3 scripts/cmux-next/chromium-host-bench.py --app "<cmux DEV tag.app>" --out DIR [--count 60]
"""
import argparse, base64, json, os, pathlib, signal, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp, LaunchError, RecordError, build_config, build_sha, tag_of  # noqa: E402
import browser_engine_bench_report as results  # noqa: E402
import chromium_host_agent_cdp  # noqa: E402
import chromium_host_baseline  # noqa: E402
import chromium_host_crash_records  # noqa: E402
import chromium_host_display  # noqa: E402
import chromium_host_find  # noqa: E402
import chromium_host_helper_kill  # noqa: E402
import chromium_host_hang  # noqa: E402
import chromium_host_kill  # noqa: E402
import chromium_host_native_ui  # noqa: E402
import chromium_host_native_ui_choosers  # noqa: E402
import chromium_host_native_ui_dialogs  # noqa: E402
import chromium_host_native_ui_locks  # noqa: E402
import chromium_host_profiles  # noqa: E402
import chromium_host_renderer_hang  # noqa: E402
import chromium_host_restore  # noqa: E402
import chromium_host_windows  # noqa: E402

# Every --native-ui row, in the order they run.
NATIVE_UI_ROWS = (chromium_host_native_ui.ROWS + chromium_host_native_ui_dialogs.ROWS
                  + chromium_host_native_ui_choosers.ROWS + chromium_host_native_ui_locks.ROWS)


def parse(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--count", type=int, default=60,
                        help="keys and clicks per mode; above about 60 the helper's title passes TITLE_LIMIT")
    parser.add_argument("--modes", default="inproc,helper")
    parser.add_argument("--json", help="also write the result here (a fleet measure entry's report.json)")
    parser.add_argument("--stress", action="store_true", help="also measure the pump share in the STRESS session")
    parser.add_argument("--pump-seconds", type=float, default=10.0)
    parser.add_argument("--keychain-service", default="Chromium Safe Storage",
                        help="the tcc mode's OSCrypt keychain item")
    parser.add_argument("--keychain-reset", action="store_true",
                        help="tcc: delete an existing --keychain-service item first (it may be another Chromium app's)")
    parser.add_argument("--host-switches", default="", help="more Chromium switches for the host, comma-separated (diagnosis)")
    parser.add_argument("--ime", action="store_true", help="helper: TEXT_INPUT_STATE pushes per keystroke (ime_row)")
    parser.add_argument("--native-ui", nargs="?", const="", default=None, metavar="ROWS",
                        help="only the native UI rows (chromium_host_native_ui.py): all, or the comma-separated ROWS "
                             f"({', '.join(NATIVE_UI_ROWS)})")
    parser.add_argument("--list-failing", action="store_true",
                        help="with --native-ui: print one FAILING line per failing row at the end")
    parser.add_argument("--find", action="store_true", help="only the find rows (chromium_host_find.py)")
    parser.add_argument("--agent-rate", type=int, default=chromium_host_agent_cdp.RATE,
                        help="agentcdp: CDP messages a second (commands and replies)")
    parser.add_argument("--agent-seconds", type=float, default=chromium_host_agent_cdp.SECONDS,
                        help="agentcdp: how long the burst runs")
    parser.add_argument("--kill-app", action="store_true",
                        help="agentcdp: last, SIGKILL cmux with the agent's tab open and launch it again (it ends cmux)")
    parser.add_argument("--helper-kill", action="store_true",
                        help="only the helper-kill rows (chromium_host_helper_kill.py): GPU, renderer, utility")
    parser.add_argument("--renderer-hang", action="store_true",
                        help="only the renderer hang row (chromium_host_renderer_hang.py, about 90 s)")
    parser.add_argument("--hang", type=int, metavar="MS",
                        help="only the busy banner row (chromium_host_hang.py, p01-process-084): the host stopped MS ms")
    parser.add_argument("--kill-host", action="store_true",
                        help="only the host kill rows (chromium_host_kill.py) with their crash records "
                             "(chromium_host_crash_records.py)")
    parser.add_argument("--signals", default="KILL",
                        help=f"--kill-host: the signals, one row each ({','.join(chromium_host_kill.SIGNALS)})")
    parser.add_argument("--restore", action="store_true",
                        help="--kill-host: the restore row (chromium_host_restore.py, p01-process-083) instead of the "
                             "signal rows, with feature chromiumHostRestoreTabs on")
    parser.add_argument("--baseline", action="store_true", help="task p01-process-005: stall 9a, 10-tab idle wakes, census, rows")
    parser.add_argument("--idle-settle-seconds", type=float, default=35.0, help="wait before the 10-tab idle sample")
    parser.add_argument("--tag", help="the lab runner's tag of --app (checked against the bundle's name)")
    parser.add_argument("--session", choices=["light"], default="light",
                        help="result-v1 session of the run (--stress adds the stress session's pump share)")
    parser.add_argument("--story", default=results.CHROMIUM_HOST_STORY, help="result-v1 story")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    args = parser.parse_args(argv)
    if args.kill_app and "agentcdp" not in args.modes.split(","):
        parser.error("--kill-app needs --modes agentcdp (it kills cmux with the agent's tab open)")
    if sum([args.native_ui is not None, args.find, args.helper_kill, args.kill_host, args.renderer_hang,
            args.hang is not None]) > 1:
        parser.error("--native-ui, --find, --helper-kill, --kill-host, --renderer-hang and --hang each run instead of "
                     "the modes: pick one")
    if args.hang is not None and args.hang < chromium_host_hang.BUSY_AFTER_MS + chromium_host_hang.TOLERANCE_MS:
        parser.error(f"--hang must hold the host past the banner's {chromium_host_hang.BUSY_AFTER_MS} ms")
    if args.list_failing and args.native_ui is None:
        parser.error("--list-failing lists the --native-ui rows: pass --native-ui")
    if args.restore and not args.kill_host:
        parser.error("--restore is a --kill-host row: add --kill-host")
    host_tab_modes = [mode for mode in HOST_TAB_MODES if mode in args.modes.split(",")]
    if host_tab_modes and ("inproc" in args.modes.split(",") or args.baseline or args.stress):
        parser.error(f"--modes {','.join(host_tab_modes)} runs every Chromium tab in the host: run it in a launch of "
                     "its own, without inproc, --baseline or --stress (they measure in-process tabs)")
    try:
        args.signals = chromium_host_kill.signal_numbers(args.signals)
    except ValueError as error:
        parser.error(str(error))
    if args.native_ui is not None:
        try:
            args.native_ui = chromium_host_native_ui.rows_named(
                args.native_ui, NATIVE_UI_ROWS)
        except ValueError as error:
            parser.error(str(error))
    if args.tag is not None and tag_of(f"cmux DEV {args.tag}.app") != tag_of(args.app):
        parser.error(f"--tag {args.tag!r} is not the tag of --app {args.app!r}")
    return args


opts = None  # parse()'s options, set by __main__

PAGE = """<!doctype html><meta charset=utf-8><title>host probe</title>
<style>html,body{margin:0;height:100%;background:#204080;color:#fff;font:16px system-ui}
#t{position:fixed;left:10%;top:20%;width:60%;font-size:20px}#b{position:fixed;left:10%;top:40%;width:30%;height:80px}
#box{position:fixed;left:0;top:70%;width:60px;height:60px;background:#f0c000}
.go{animation:slide 0.5s linear infinite alternate}@keyframes slide{to{transform:translateX(600px)}}</style>
<input id=t><button id=b>click</button><div id=box></div>
<input id=pw type=password style="position:fixed;left:45%;top:40%;width:20%">
<select id=s style="position:fixed;left:10%;top:55%;width:20%;height:30px"><option>one<option>two<option>three</select>
<button id=al style="position:fixed;left:45%;top:55%;width:15%;height:40px" onclick="S.dialogs++; alert('probe')">alert</button>
<input id=f type=file style="position:fixed;left:65%;top:55%;width:20%">
<script>
const S = {key: [], click: [], raf: [], key_paint: [], click_paint: [], focus: 0, blur: 0, dialogs: 0, menus: 0};
addEventListener('focus', () => { S.focus++; report(); });
addEventListener('blur', () => { S.blur++; report(); });
addEventListener('contextmenu', () => { S.menus++; report(); });
document.addEventListener('selectionchange', () => report());
// The wall time (ms since 1970, the system clock the bench reads with time.time()) of the animation frame that
// shows each change: the bench subtracts its own send time, so both ends share one clock in both modes. A
// forwarded event's timeStamp cannot be used: the host's CEF windowed Send*Event gives the event no time, and
// Chromium clamps its timeStamp to the page's time origin (the in-page delta then read the page's age, 13 s).
const wall = () => performance.timeOrigin + performance.now();
function sample(list, paint, e) {
  const at = performance.now();
  // The frame that shows the change: the next animation frame after the event.
  requestAnimationFrame(() => { list.push(performance.now() - at); paint.push(+wall().toFixed(3)); report(); });
}
// `p` starts the pacing run, `r` drops its intervals once the bench read them: both keep the title short (below).
addEventListener('keydown', e => {
  if (e.key === 'p') { window.__pace(3000); return; }
  if (e.key === 'r') { e.preventDefault(); S.raf = []; report(); return; }
  document.getElementById('t').style.outline = '2px solid #' + (S.key.length % 9) + 'f0'; sample(S.key, S.key_paint, e);
}, true);
// Only clicks on the button are samples: the click that focuses the field is not one of the bench's measured clicks.
addEventListener('mousedown', e => { if (e.target.id !== 'b') return; e.target.textContent = 'click ' + S.click.length; sample(S.click, S.click_paint, e); }, true);
// Raw deltas only: the bench takes every percentile from perf_stats. The helper reads this title through the host
// (CEF OnTitleChange), and Blink cuts a title at mojom::kMaxTitleChars (4096, Document::DispatchDidReceiveTitle in
// third_party/blink/renderer/core/dom/document.cc): __pace drops the key and click lists the bench already read,
// and `r` the intervals, so the title stays below it (TITLE_LIMIT).
const raw = list => list.map(v => +v.toFixed(2));
function report() { document.title = 'probe ' + JSON.stringify({key_raw: raw(S.key), click_raw: raw(S.click), raf_raw: raw(S.raf), key_paint: S.key_paint, click_paint: S.click_paint, focus: S.focus, blur: S.blur, has_focus: document.hasFocus(), active: (document.activeElement || {}).id || null, field: document.getElementById('t').value.length, caret: document.getElementById('t').selectionStart, dialogs: S.dialogs, menus: S.menus}); }
window.__pace = function(ms) {
  S.key = []; S.click = []; S.key_paint = []; S.click_paint = []; S.raf = []; const box = document.getElementById('box'); box.classList.add('go');
  let last = null; const end = performance.now() + ms;
  function tick(t) { if (last !== null) S.raf.push(t - last); last = t; if (t < end) requestAnimationFrame(tick); else { box.classList.remove('go'); report(); } }
  requestAnimationFrame(tick);
};
window.__reset = function() { S.key = []; S.click = []; S.raf = []; S.key_paint = []; S.click_paint = []; report(); };
report();
</script>"""

# Blink's mojom::kMaxTitleChars: a longer document.title reaches the browser cut, and the probe's JSON with it.
TITLE_LIMIT = 4096


def cursor_png():
    """A 16 x 16 opaque red PNG (stdlib only): the probe's CSS image cursor."""
    import zlib
    rows = b"".join(b"\x00" + b"\xff\x00\x00\xff" * 16 for _ in range(16))
    chunk = lambda kind, data: struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    header = struct.pack(">IIBBBBB", 16, 16, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


# The cursor row's page: four bands, each a cursor the page view must show (expected CSS names in CURSOR_BANDS).
CURSOR_BANDS = {"text": "text", "link": "pointer", "resize": "col-resize", "custom": "custom"}
CURSOR_PAGE = """<!doctype html><meta charset=utf-8><title>cursor probe</title>
<style>html,body{margin:0;height:100%;font:16px system-ui}div,a,input{position:fixed;left:0;width:100%;height:25%;
margin:0;border:0;padding:0;display:block;box-sizing:border-box}</style>
<input id=text style="top:0" value="text">
<a id=link href="#link" style="top:25%;background:#cde">link</a>
<div id=resize style="top:50%;cursor:col-resize;background:#dec">resize</div>
<div id=custom style="top:75%;cursor:url(data:image/png;base64,PNG) 4 4,auto;background:#ecd">custom</div>""".replace(
    "PNG", base64.b64encode(cursor_png()).decode())

# The drag-in probe (task 050): a drop zone that takes the drop (preventDefault in dragover) and a file input,
# whose default drop sets its files. window.dragLog records what each saw.
DRAG_PAGE = """<!doctype html><meta charset=utf-8><title>drag probe</title>
<style>html,body{margin:0;height:100%;font:16px system-ui}#zone,#file{position:fixed;top:10%;width:40%;height:50%;
box-sizing:border-box;margin:0}#zone{left:5%;background:#2a6}#file{left:55%;background:#ddd}</style>
<div id=zone>drop zone</div><input id=file type=file>
<script>
const log = window.dragLog = {zone: [], dropped: null, file: null};
const zone = document.getElementById('zone');
for (const type of ['dragenter', 'dragover', 'dragleave', 'drop']) zone.addEventListener(type, event => {
  event.preventDefault();
  if (!log.zone.includes(type)) log.zone.push(type);
  if (type === 'drop') log.dropped = [...event.dataTransfer.files].map(f => [f.name, f.size]);
});
document.getElementById('file').addEventListener('change', event => { log.file = [...event.target.files].map(f => [f.name, f.size]); });
</script>"""
DRAG_FILE_TEXT = "cmux drag-in probe\n" * 64

# The swipe probe: `?flat` does not scroll sideways (taller than the pane: it scrolls only down); `?wide` is a
# sideways scroller filling the page. The title names the variant and the step (?flat-1, ?flat-2), so a Back shows.
SWIPE_PAGE = """<!doctype html><meta charset=utf-8><title>swipe probe</title>
<style>html,body{margin:0;background:#204080;color:#fff;font:16px system-ui}#tall{height:300vh}
#wide{position:fixed;inset:0;overflow-x:auto;overflow-y:hidden}#wide div{width:400vw;height:100%;
background:linear-gradient(90deg,#204080,#f0c000)}</style>
<div id=tall></div>
<script>
const [variant, step] = location.search.slice(1).split('-');
document.title = 'swipe ' + variant + ' ' + step;
if (variant === 'wide') {
  document.getElementById('tall').remove();
  const wide = document.createElement('div');
  wide.id = 'wide';
  wide.appendChild(document.createElement('div'));
  document.body.appendChild(wide);
  wide.scrollLeft = wide.scrollWidth / 2 - innerWidth / 2;
}
window.__scrollLeft = () => (document.getElementById('wide') || document.scrollingElement).scrollLeft;
</script>"""

# The pinch probe: a page the pinch zooms. Chrome turns a trackpad pinch into ctrl+wheel events for the page first
# (a script may take them) and, untaken, into a pinch of the visual viewport; the page counts the ctrl+wheels so a
# pinch that reached Chromium but did not zoom shows apart from one that never arrived.
PINCH_PAGE = """<!doctype html><meta charset=utf-8><title>pinch probe</title>
<style>html,body{margin:0;background:#204080;color:#fff;font:16px system-ui}
#grid{height:100vh;background:repeating-linear-gradient(45deg,#204080 0 20px,#f0c000 20px 40px)}</style>
<div id=grid></div>
<script>
window.__pinch = {ctrlWheels: 0};
addEventListener('wheel', event => { if (event.ctrlKey) window.__pinch.ctrlWheels += 1; }, {passive: true});
window.__zoom = () => ({scale: visualViewport.scale, dpr: devicePixelRatio, ctrlWheels: window.__pinch.ctrlWheels});
</script>"""
# ChromiumHostDragDestination.forkAPI: the fork whose DragTarget calls reach a detached page (task 172).
DRAG_TARGET_FORK_API = 31


# The mouse row's page (task 054): a title= band over a pad that records the page's mouse events and pinches.
MOUSE_TOOLTIP = "probe tooltip"
MOUSE_PAGE = """<!doctype html><meta charset=utf-8><title>mouse probe</title>
<style>html,body{margin:0;height:100%;font:16px system-ui}div{position:fixed;left:0;width:100%;height:50%}</style>
<div id=tip style="top:0;background:#cde" title="TIP">tooltip</div>
<div id=pad style="top:50%;background:#ecd">buttons and gestures</div>
<script>
window.__mouse = [];
for (const type of ["mousedown", "mouseup", "click", "auxclick", "contextmenu"])
  addEventListener(type, e => { __mouse.push({type, button: e.button, buttons: e.buttons}); }, true);
addEventListener("wheel", e => { if (e.ctrlKey) __mouse.push({type: "pinch-wheel", dy: e.deltaY}); }, {capture: true, passive: true});
</script>""".replace("TIP", MOUSE_TOOLTIP)

TUNABLES = {"version": 1, "values": {"browserHost.helper": True, "browserResize.layerHostingEveryPage": True}}


# The modes whose rows need every Chromium tab in the host: profiles (task 080) and tcc (task 089: the host's own
# privacy requests and keychain reads come only from a host-backed tab) and agentcdp (the
# Chromium Host relays the agent's CDP only for a tab it runs).
HOST_TAB_MODES = ("profiles", "tcc", "agentcdp")


def launch_tunables(modes, kill_host=False):
    """TUNABLES for a run of `modes`: Chromium tabs move to the host (`browserHost.tabs`, feature chromiumHostTabs)
    only for the HOST_TAB_MODES rows and the `--kill-host` rows (they end the host their tabs run in, and the restore
    row brings them back on the next one), so every other row's Chromium tab stays in process."""
    values = dict(TUNABLES["values"], **{"browserHost.tabs": any(mode in modes for mode in HOST_TAB_MODES) or kill_host})
    return {**TUNABLES, "values": values}


def tabs_in_host(rpc):
    """Why this launch's Chromium tabs cannot be measured as in-process tabs (they run in the Chromium Host,
    `debug.cef` backend `host`), or None when they run in cmux."""
    backend = (rpc("debug.cef") or {}).get("backend")
    return f"the Chromium backend is {backend!r}: Chromium tabs run in the Chromium Host" if backend == "host" else None
RESULT = {"build": "Debug", "modes": {}, "notes": []}


def main_display_hz():
    """The main display's refresh rate (CoreGraphics), or None."""
    import ctypes
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    cg.CGMainDisplayID.restype = ctypes.c_uint32
    cg.CGDisplayCopyDisplayMode.restype = ctypes.c_void_p
    cg.CGDisplayCopyDisplayMode.argtypes = [ctypes.c_uint32]
    cg.CGDisplayModeGetRefreshRate.restype = ctypes.c_double
    cg.CGDisplayModeGetRefreshRate.argtypes = [ctypes.c_void_p]
    mode = cg.CGDisplayCopyDisplayMode(cg.CGMainDisplayID())
    return round(cg.CGDisplayModeGetRefreshRate(mode), 2) if mode else None


def child_windows_on_screen(root):
    """The on-screen windows with alpha > 0 of every process below `root` (the Chromium Host, its helpers, the
    in-process helpers), each with its pid; None when a process's windows cannot be read."""
    pids, frontier = [], [root]
    while frontier:
        parent = frontier.pop()
        try:
            listed = subprocess.run(["/usr/bin/pgrep", "-P", str(parent)], capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.TimeoutExpired):
            return None
        children = [int(pid) for pid in listed.split() if pid.isdigit()]
        pids += children
        frontier += children
    found = []
    for pid in pids:
        windows = on_screen_windows(pid)
        if windows is None:
            return None
        found += [{**window, "pid": pid} for window in windows if (window.get("alpha") or 0) > 0]
    return found


def on_screen_windows(pid):
    """The on-screen windows `pid` owns (CGWindowListCopyWindowInfo with kCGWindowListOptionOnScreenOnly), each
    {"layer", "alpha", "bounds" [x, y, w, h]}, or None when CoreGraphics cannot be read."""
    import ctypes
    try:
        cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    except OSError:
        return None
    ptr, index = ctypes.c_void_p, ctypes.c_long
    cg.CGWindowListCopyWindowInfo.restype, cg.CGWindowListCopyWindowInfo.argtypes = ptr, [ctypes.c_uint32, ctypes.c_uint32]
    cg.CGRectMakeWithDictionaryRepresentation.restype = ctypes.c_bool
    cg.CGRectMakeWithDictionaryRepresentation.argtypes = [ptr, ptr]
    cf.CFArrayGetCount.restype, cf.CFArrayGetCount.argtypes = index, [ptr]
    cf.CFArrayGetValueAtIndex.restype, cf.CFArrayGetValueAtIndex.argtypes = ptr, [ptr, index]
    cf.CFDictionaryGetValue.restype, cf.CFDictionaryGetValue.argtypes = ptr, [ptr, ptr]
    cf.CFNumberGetValue.restype, cf.CFNumberGetValue.argtypes = ctypes.c_bool, [ptr, index, ptr]
    cf.CFRelease.argtypes = [ptr]
    key = {name: ptr.in_dll(cg, name).value for name in ("kCGWindowOwnerPID", "kCGWindowLayer", "kCGWindowAlpha",
                                                         "kCGWindowBounds")}
    sint32, double = 3, 13  # kCFNumberSInt32Type, kCFNumberDoubleType

    def number(entry, name, kind, ctype):
        value, out = cf.CFDictionaryGetValue(entry, key[name]), ctype()
        return out.value if value and cf.CFNumberGetValue(value, kind, ctypes.byref(out)) else None

    windows = cg.CGWindowListCopyWindowInfo(1, 0)  # kCGWindowListOptionOnScreenOnly, kCGNullWindowID
    if not windows:
        return None
    found = []
    try:
        for i in range(cf.CFArrayGetCount(windows)):
            entry = cf.CFArrayGetValueAtIndex(windows, i)
            if number(entry, "kCGWindowOwnerPID", sint32, ctypes.c_int32) != pid:
                continue
            rect = (ctypes.c_double * 4)()  # CGRect: origin x, y, size width, height
            bounds = cf.CFDictionaryGetValue(entry, key["kCGWindowBounds"])
            placed = bool(bounds) and cg.CGRectMakeWithDictionaryRepresentation(bounds, rect)
            found.append({"layer": number(entry, "kCGWindowLayer", sint32, ctypes.c_int32),
                          "alpha": number(entry, "kCGWindowAlpha", double, ctypes.c_double),
                          "bounds": [round(v, 1) for v in rect] if placed else None})
    finally:
        cf.CFRelease(windows)
    return found


# ChromiumHostFrame.quitLimit: how long a host may take to end after `quit` or EOF before it is SIGKILLed / ends itself.
QUIT_LIMIT_S = 15.0
# The probe's background (#204080), with room for the display's color conversion.
PROBE_RGB, PROBE_TOLERANCE = (0x20, 0x40, 0x80), 24


def probe_color_share():
    """The share of main-display samples in the probe's background color, or None when the screen cannot be read
    (no Screen Recording permission, no display). A BMP capture, read without an imaging library."""
    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, "screen.bmp")
        try:
            done = subprocess.run(["/usr/sbin/screencapture", "-x", "-m", "-t", "bmp", path], capture_output=True, timeout=15)
        except subprocess.TimeoutExpired:
            return None
        if done.returncode != 0 or not os.path.exists(path):
            return None
        data = open(path, "rb").read()
    if data[:2] != b"BM" or len(data) < 54:
        return None
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bpp, compression = struct.unpack_from("<HI", data, 28)
    if bpp not in (24, 32) or compression not in (0, 3) or width <= 0 or height == 0:
        return None
    step = bpp // 8
    stride = (width * step + 3) & ~3
    rows = abs(height)
    hits = total = 0
    for y in range(0, rows, 4):
        base = offset + y * stride
        for x in range(0, width, 4):
            i = base + x * step
            if i + 3 > len(data):
                break
            b, g, r = data[i], data[i + 1], data[i + 2]  # BI_RGB and the BGRA bitfields screencapture writes
            total += 1
            if all(abs(c - w) <= PROBE_TOLERANCE for c, w in zip((r, g, b), PROBE_RGB)):
                hits += 1
    return round(hits / total, 4) if total else None


BENCH_START = time.time()
APP_LOG = {}
DEFAULTS = {}


def app_log_lines(needles, limit=40):
    """The app log's distinct lines that hold one of `needles` (the first `limit`, process ids and times
    dropped for the dedupe, each up to 2,000 characters: a dlopen error names its reason at the end), or None."""
    import re
    try:
        lines = open(APP_LOG["path"], errors="replace").read().splitlines()
    except (KeyError, OSError):
        return None
    seen, out = set(), []
    for line in lines:
        if not any(n in line for n in needles):
            continue
        key = re.sub(r"^\[[0-9:/.]+\]|\[\d+:\d+\]|\d{4}-\d\d-\d\d [\d:.]+", "", line)
        if key in seen:
            continue
        seen.add(key)
        out.append(line[:2000])
    return out[:limit]


def log_tail(path, lines=40):
    """The last lines of the host's Chromium log (warnings and fatal messages), or None."""
    try:
        return open(path, errors="replace").read().splitlines()[-lines:] if path else None
    except OSError:
        return None


def host_crash_reports():
    """Crash reports of a Chromium host written since this bench started: file, exception, abort message and the
    crashed thread's top frames (image + offset; the framework is stripped, symbolicate with its dSYM)."""
    found = []
    for folder in ("/Library/Logs/DiagnosticReports", os.path.expanduser("~/Library/Logs/DiagnosticReports")):
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for name in sorted(names):
            path = os.path.join(folder, name)
            if "Chromium Host" not in name or os.path.getmtime(path) < BENCH_START:
                continue
            entry = {"file": path}
            try:
                body = json.loads(open(path).read().split("\n", 1)[1])
                images = body.get("usedImages") or []
                thread = (body.get("threads") or [{}])[body.get("faultingThread", 0)]
                entry.update(exception=body.get("exception"), asi=body.get("asi"), thread=thread.get("name"),
                             frames=[f"{(images[f['imageIndex']] or {}).get('name')}+{f.get('imageOffset')} {f.get('symbol') or ''}".strip()
                                     for f in (thread.get("frames") or [])[:24]])
            except (OSError, ValueError, IndexError, KeyError) as error:
                entry["unreadable"] = str(error)
            found.append(entry)
    return found


def app_bundle_id():
    import plistlib
    with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
        return plistlib.load(f).get("CFBundleIdentifier")


def ls_types():
    """LaunchServices' view of every app: {pid: application type} (`lsappinfo list`: Foreground has a Dock icon and
    a menu bar, UIElement and BackgroundOnly do not)."""
    import re
    try:
        done = subprocess.run(["/usr/bin/lsappinfo", "list"], capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        return {}
    types = {}
    for block in re.split(r"\n(?=\s*\d+\) )", done.stdout):
        pid = re.search(r"\bpid = (\d+)", block)
        kind = re.search(r'\btype="([^"]+)"', block)
        if pid:
            types[int(pid.group(1))] = kind.group(1) if kind else None
    return types


def front_pid():
    """The pid of LaunchServices' frontmost app, or None."""
    import re
    try:
        asn = subprocess.run(["/usr/bin/lsappinfo", "front"], capture_output=True, text=True, timeout=10).stdout.strip()
        if not asn:
            return None
        info = subprocess.run(["/usr/bin/lsappinfo", "info", "-only", "pid", asn], capture_output=True, text=True, timeout=10).stdout
    except subprocess.TimeoutExpired:
        return None
    found = re.search(r"(\d+)", info.split("=", 1)[-1])
    return int(found.group(1)) if found else None


def chromium_host_pid():
    """The pid of the running Chromium Host (`<Product> Chromium Host` in the app's Contents/MacOS), or None."""
    return next(iter(chromium_host_pids()), None)


def supervisor_host_pid(rpc):
    """The pid of the supervisor's running Chromium Host (`debug.cef` host_supervisor, the host that serves the tabs),
    else the first running host of the app (chromium_host_pid), or None."""
    supervisor = (rpc("debug.cef") or {}).get("host_supervisor")
    pid = supervisor.get("pid") if isinstance(supervisor, dict) else None
    return int(pid) if isinstance(pid, (int, float)) and not isinstance(pid, bool) else chromium_host_pid()


def chromium_host_pids():
    """The pids of every running Chromium Host of the app (`<Product> Chromium Host` in its Contents/MacOS)."""
    macos = os.path.join(os.path.abspath(opts.app), "Contents", "MacOS") + "/"
    try:
        listing = subprocess.run(["/bin/ps", "-axo", "pid=,command="], capture_output=True, text=True, timeout=10).stdout
    except subprocess.TimeoutExpired:
        return []
    pids = []
    for line in listing.splitlines():
        pid, _, command = line.strip().partition(" ")
        if command.startswith(macos) and command[len(macos):].split(" --", 1)[0].endswith(" Chromium Host"):
            pids.append(int(pid))
    return pids


def bundled_cli(*args, timeout=90):
    """(exit code, JSON reply) of the app's bundled `cmux --json` on its own session (no socket flag)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    cli = os.path.join(os.path.abspath(opts.app), "Contents", "Resources", "bin", "cmux")
    try:
        run = subprocess.run([cli, "--json", *args], capture_output=True, text=True, timeout=timeout, env=env,
                             stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as error:
        return 1, {"error": str(error)}
    try:
        return run.returncode, json.loads(run.stdout or "{}")
    except ValueError:
        return run.returncode, {"error": run.stdout.strip()[:400]}


def process_rows():
    """Every process as (pid, ppid, command) (`ps`), or [] when ps does not answer."""
    try:
        listing = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True, timeout=10).stdout
    except subprocess.TimeoutExpired:
        return []
    rows = []
    for line in listing.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def defaults_snapshot(domain):
    """cmux's defaults domain as {key: value repr} (`defaults export`), or None."""
    import plistlib
    try:
        done = subprocess.run(["/usr/bin/defaults", "export", domain, "-"], capture_output=True, timeout=20)
    except subprocess.TimeoutExpired:
        return None
    if done.returncode != 0:
        return None
    try:
        return {k: repr(v)[:200] for k, v in plistlib.loads(done.stdout).items()}
    except Exception:  # noqa: BLE001 - an unreadable export is reported as None
        return None


def defaults_diff(before, after):
    if before is None or after is None:
        return None
    return {"added": sorted(set(after) - set(before)), "removed": sorted(set(before) - set(after)),
            "changed": sorted(k for k in set(before) & set(after) if before[k] != after[k])}


def pid_gone(pid):
    """True once `pid` no longer exists; a zombie (ended, not reaped) still counts as there."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def page_eval_reply(rpc, script, tab=None):
    """(value, tab) of `browser.page.eval` in `tab`, or in the focused page without one."""
    reply = rpc("browser.page.eval", {"script": script, **({"tab": tab} if tab else {})}, timeout=20)
    if not isinstance(reply, dict) or "error" in reply:
        return None, None
    return reply.get("value"), reply.get("tab")


def page_eval(rpc, script, tab):
    return page_eval_reply(rpc, script, tab)[0]


def wait(check, seconds, step=0.1):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def settle_host_feature(app, seconds=15):
    """The launch's features snapshot once it shows TUNABLES' host toggle: features.list reports `browserHost.helper`
    as feature cefHelperHost, source local, but the tunables file loads after the launch's first read. Reads it
    again until cefHelperHost is on or `seconds` pass, so the results record the arm they measured."""
    def on():
        snapshot = app.read_features()
        if snapshot is not None:
            app.features = snapshot
        return ((snapshot or ({}, None, None))[0].get("cefHelperHost") or {}).get("state") == "on"
    if not wait(on, seconds, step=0.5):
        RESULT["notes"].append("features.list never reported cefHelperHost on: the results record the app's answer")


# {mode: {metric: per-event values, None for a lost event}}: drive()'s raw series for result-v1
# (browser_engine_bench_report.chromium_host_series).
SAMPLES = {}


def paint_deltas(sent, painted):
    """Each sent event's send-to-paint ms, matched in order; None for each event past the last paint (lost)."""
    painted = painted or []
    n = min(len(sent), len(painted))
    return [p - s for s, p in zip(sent[:n], painted[:n])] + [None] * (len(sent) - n)


def paired(sent, painted):
    """Send-to-paint percentiles (ms) of events matched in order; None when the page reported none. Only as many as
    painted; a count below len(sent) means events were lost and the pairs may be shifted (the row says so)."""
    if not painted:
        return None
    out = results.percentiles(paint_deltas(sent, painted))
    out["sent"] = len(sent)
    return out


def padded(values, expected):
    """`values` with a None for each of the `expected` events that gave none (a missed run in result-v1)."""
    values = list(values or [])
    return values + [None] * max(0, expected - len(values))


def main():
    os.makedirs(opts.out, exist_ok=True)
    tunables = os.path.join(opts.out, "debug-tunables.json")
    json.dump(launch_tunables(opts.modes.split(","), kill_host=opts.kill_host), open(tunables, "w"))
    probe = os.path.join(opts.out, "probe.html")
    open(probe, "w").write(PAGE)
    url = pathlib.Path(probe).as_uri()
    env = {"CMUX_NEXT_DEBUG_TUNABLES_FILE": tunables}
    if opts.native_ui:
        native = os.path.join(opts.out, "native-ui.html")
        open(native, "w").write(chromium_host_native_ui.PAGE)
        url = pathlib.Path(native).as_uri()
        env.update(chromium_host_native_ui.launch_env(chromium_host_native_ui.write_extensions(opts.out)))
        permission_url = chromium_host_native_ui.serve_permission_page()
        env["CMUX_ENABLE_FEATURES"] = ",".join(filter(None, [env.get("CMUX_ENABLE_FEATURES"), chromium_host_native_ui_dialogs.FEATURES,
                                                             chromium_host_native_ui_choosers.FEATURES,
                                                             chromium_host_native_ui_locks.FEATURES]))
        env.update(chromium_host_native_ui_choosers.ENV)
        chooser_page = os.path.join(opts.out, "native-ui-choosers.html")
        open(chooser_page, "w").write(chromium_host_native_ui_choosers.PAGE)
    if opts.hang is not None:
        hang_page = os.path.join(opts.out, "hang.html")
        open(hang_page, "w").write(chromium_host_hang.PAGE)
        url = pathlib.Path(hang_page).as_uri()
        env["CMUX_ENABLE_FEATURES"] = ",".join(filter(None, [env.get("CMUX_ENABLE_FEATURES"), chromium_host_hang.FEATURES]))
    if opts.kill_host:
        kill_page = os.path.join(opts.out, "kill-host.html")
        open(kill_page, "w").write(chromium_host_kill.PAGE)
        url = pathlib.Path(kill_page).as_uri()
    if opts.find:
        find_page = os.path.join(opts.out, "find.html")
        open(find_page, "w").write(chromium_host_find.PAGE)
        url = pathlib.Path(find_page).as_uri()
    if "agentcdp" in opts.modes.split(","):
        env["CMUX_ENABLE_FEATURES"] = ",".join(filter(None, [env.get("CMUX_ENABLE_FEATURES"), "chromiumHostAgentRelay"]))
        env["CMUX_NEXT_TYPING_PROBE"] = os.path.join(opts.out, "typing.csv")
    if opts.renderer_hang:
        env["CMUX_ENABLE_FEATURES"] = ",".join(filter(None, [env.get("CMUX_ENABLE_FEATURES"), chromium_host_renderer_hang.FEATURES]))
    if opts.kill_host and opts.restore:
        env["CMUX_ENABLE_FEATURES"] = ",".join(filter(None, [env.get("CMUX_ENABLE_FEATURES"), chromium_host_restore.FEATURES]))
    if "dragin" in opts.modes.split(","):
        env["CMUX_ENABLE_FEATURES"] = ",".join(filter(None, [env.get("CMUX_ENABLE_FEATURES"), "chromiumHostDragIn"]))
    if opts.host_switches:
        env["CMUX_NEXT_CHROMIUM_HOST_SWITCHES"] = opts.host_switches
        RESULT["host_switches"] = opts.host_switches
    tcc_keychain = tcc_seed = None
    if "tcc" in opts.modes.split(","):
        import chromium_host_tcc
        tcc_keychain = chromium_host_tcc.keychain_plan(opts.keychain_service, opts.keychain_reset)
        if tcc_keychain["real_keychain"]:
            env["CMUX_NEXT_BENCH_REAL_KEYCHAIN"] = "1"
        # Before the measured launch: cmux's in-process engine makes the item the host then reads (the upgrade case).
        tcc_seed = seed_tcc_keychain(tcc_keychain)
    # tccd charges a privacy request to its process's responsible process: for the tcc rows that must be cmux, as
    # when a person opens it, not this script's ssh or runner.
    app = BenchApp(opts.app, out=opts.out, env=env, build_config=opts.build_config, perf_session=opts.session,
                   own_responsibility=tcc_keychain is not None)
    APP_LOG["path"] = app.log_path
    try:
        RESULT["build"] = build_config(app.app, app.binary, opts.build_config)
    except RecordError as error:
        RESULT["build"] = None
        RESULT["notes"].append(str(error))
    ok = True
    try:
        app.launch()
        settle_host_feature(app)
        rpc = app.rpc
        RESULT["refresh_hz"] = main_display_hz()
        RESULT["host"] = host_block()
        cef = rpc("debug.cef") or {}
        RESULT["cef"] = {"fork_api": (cef.get("windows") or {}).get("fork_api"), "unavailable": cef.get("unavailable"),
                         "fallback": cef.get("fallback")}
        DEFAULTS["launch"] = defaults_snapshot(app_bundle_id())
        modes = ([] if opts.native_ui or opts.find or opts.helper_kill or opts.kill_host or opts.renderer_hang
                 or opts.hang is not None
                 else opts.modes.split(","))
        if opts.native_ui:
            RESULT["modes"]["native_ui"], ok = native_ui_rows(
                rpc, url, pathlib.Path(chooser_page).as_uri(), app.process.pid if app.process else None,
                permission_url=permission_url,
                child_windows=(lambda: child_windows_on_screen(app.process.pid)) if app.process else None)
        if opts.find:
            RESULT["modes"]["find"], ok = chromium_host_find.run(rpc, wait, lambda script: page_eval(rpc, script, None), url)
        if opts.helper_kill:
            RESULT["modes"]["helper_kill"], ok = chromium_host_helper_kill.run(
                rpc, wait, process_rows, chromium_host_pid, os.kill, url)
        if opts.renderer_hang:
            RESULT["modes"]["renderer_hang"], ok = chromium_host_renderer_hang.run(
                rpc, wait, lambda script: page_eval(rpc, script, None), opts.out, chromium_host_pid, front_pid, on_screen_windows)
        if opts.hang is not None:
            RESULT["modes"]["hang"], ok = chromium_host_hang.run(
                rpc, wait, lambda script: page_eval(rpc, script, None), url, chromium_host_pid,
                lambda pid: os.kill(pid, signal.SIGSTOP), lambda pid: os.kill(pid, signal.SIGCONT), opts.hang)
        if opts.kill_host:
            if opts.restore:
                RESULT["modes"]["kill_host"] = {}
                RESULT["modes"]["kill_host"]["restore"], ok = chromium_host_restore.run(
                    rpc, wait, lambda script, tab: page_eval(rpc, script, tab), lambda script: page_eval_reply(rpc, script),
                    url, chromium_host_pids, lambda pid: os.kill(pid, signal.SIGKILL), time.monotonic, time.sleep)
            else:
                RESULT["modes"]["kill_host"], ok = chromium_host_kill.run(
                    rpc, wait, url, opts.signals, lambda: supervisor_host_pid(rpc), app.process.pid if app.process else None,
                    lambda pid: pid is not None and not pid_gone(pid),
                    record=lambda host, number: chromium_host_crash_records.row(rpc, wait, host, number))
        inproc_tab = None
        if "inproc" in modes:
            inproc_tab = run_inproc(rpc, url)
            ok = ok and inproc_tab is not None
        if "tcc" in modes:
            ok = run_tcc(rpc, app.process.pid if app.process else None, tcc_keychain, tcc_seed) and ok
        if "helper" in modes:
            ok = run_helper(rpc, url, inproc_tab) and ok
        if "route" in modes:
            ok = run_route(rpc, url) and ok
        if opts.baseline and inproc_tab:
            # After the helper rows: the 9 extra tabs would otherwise be in its pump share.
            RESULT.setdefault("sessions", {}).setdefault("light", {})["tabs10"] = tabs10_wakes(rpc, url)
        if opts.baseline:
            # After every light-session row: the census's light workspace is not in their numbers.
            RESULT["baseline"] = {"census_light": census(app, "light", session="light")}
        if "cursor" in modes:
            cursor_probe = os.path.join(opts.out, "cursor.html")
            open(cursor_probe, "w").write(CURSOR_PAGE)
            ok = run_cursor(rpc, pathlib.Path(cursor_probe).as_uri()) and ok
        if "swipe" in modes:
            swipe_probe = os.path.join(opts.out, "swipe.html")
            open(swipe_probe, "w").write(SWIPE_PAGE)
            ok = run_swipe(rpc, pathlib.Path(swipe_probe).as_uri()) and ok
        if "pinch" in modes:
            pinch_probe = os.path.join(opts.out, "pinch.html")
            open(pinch_probe, "w").write(PINCH_PAGE)
            ok = run_pinch(rpc, pathlib.Path(pinch_probe).as_uri()) and ok
        if "dragin" in modes:
            drag_probe = os.path.join(opts.out, "drag.html")
            open(drag_probe, "w").write(DRAG_PAGE)
            ok = run_dragin(rpc, pathlib.Path(drag_probe).as_uri()) and ok
        if "mouse" in modes:
            mouse_probe = os.path.join(opts.out, "mouse.html")
            open(mouse_probe, "w").write(MOUSE_PAGE)
            ok = run_mouse(rpc, pathlib.Path(mouse_probe).as_uri()) and ok
        if "display" in modes:
            display_probe = os.path.join(opts.out, "display.html")
            open(display_probe, "w").write(chromium_host_display.PAGE)
            RESULT["modes"]["display"], ran = chromium_host_display.run(
                rpc, wait, lambda script: page_eval(rpc, script, None), pathlib.Path(display_probe).as_uri(), time.sleep)
            ok = ran and ok
        agent_url = None
        if "agentcdp" in modes:
            agent_probe = os.path.join(opts.out, "agent-cdp.html")
            open(agent_probe, "w").write(chromium_host_agent_cdp.PAGE)
            agent_url = pathlib.Path(agent_probe).as_uri()
            RESULT["modes"]["agentcdp"], ran = chromium_host_agent_cdp.run(
                rpc, wait, lambda script: page_eval(rpc, script, None), agent_url, lambda script, timeout:
                AgentRun(app, script, timeout), lambda seconds: type_terminal(rpc, seconds), typed_key_ms,
                rate=opts.agent_rate, seconds=opts.agent_seconds)
            ok = ran and ok
        if "profiles" in modes:
            RESULT["modes"]["profiles"], ran = chromium_host_profiles.run(
                rpc, wait, lambda script, tab: page_eval(rpc, script, tab), url, bundled_cli, chromium_host_pids,
                str(int(time.time())))
            ok = ran and ok
        if opts.stress:
            run_stress_pump(rpc, url, "helper" in modes)
        if opts.baseline:
            # Last before the lifetime rows (they end cmux): the heavy session stays. The split is the growth over
            # a census of the session just before it, so the tabs and the STRESS session opened since launch are
            # not in it; that census is the heavy one's --baseline (its per hidden terminal over all roles).
            before_heavy = census(app, "before-heavy")
            RESULT["baseline"]["census_heavy"] = census(app, "heavy", session="heavy", baseline=before_heavy.get("path"))
            RESULT["baseline"]["memory_split"] = chromium_host_baseline.memory_split(
                before_heavy, RESULT["baseline"]["census_heavy"])
        if "helper" in modes and RESULT["modes"].get("helper", {}).get("kill"):
            ok = run_lifetime(app, url) and ok
        if opts.kill_app and agent_url:
            # Last: it kills cmux.
            row, ran = chromium_host_agent_cdp.kill_app(
                app.process.pid if app.process else None, chromium_host_pid(), lambda: app.launch(validate_host=False),
                lambda script, timeout: AgentRun(app, script, timeout), agent_url, lambda pid: not pid_gone(pid),
                time.sleep)
            RESULT["modes"]["agentcdp"]["kill_app"] = row
            ok = ran and ok
    except LaunchError as error:
        RESULT["error"] = error.reason
        ok = False
    finally:
        try:
            if opts.baseline:
                RESULT["baseline_rows"] = chromium_host_baseline.rows(RESULT, time.strftime("%Y-%m-%d", time.gmtime()))
                with open(os.path.join(opts.out, "baseline-rows.md"), "w") as out:
                    out.write("\n".join(RESULT["baseline_rows"]) + "\n")
            if app.features is not None and SAMPLES:  # a launch that answered features.list and measured a mode
                RESULT["results_v1"] = results.record_all(app, results.chromium_host_series(
                    SAMPLES, RESULT["modes"], session=opts.session, story=opts.story))
        finally:
            try:
                for path in filter(None, [os.path.join(opts.out, "chromium-host-bench.json"), opts.json]):
                    with open(path, "w") as out:
                        json.dump(RESULT, out, indent=2)
                print("CHROMIUM-HOST-BENCH " + json.dumps(RESULT), flush=True)
                if opts.list_failing:
                    print_failing(RESULT)
            finally:
                app.stop()
    return 0 if ok else 1


class AgentRun:
    """One `cmux-browser-host eval` of the agentcdp session against `app`'s own browser host (bench_renderer_sharing's
    CLI helpers), started now; `result()` waits for it: (exit code, stdout, stderr)."""

    def __init__(self, app, script, timeout):
        import bench_renderer_sharing as sharing
        self.timeout, self.process, self.error = timeout, None, None
        bundle = os.path.realpath(opts.app)
        socket = wait(lambda: sharing.host_socket(sharing.bm.process_table(), bundle), 60, 0.5)
        if socket is None:
            self.error = f"no browser host of {bundle} runs"
            return
        cli = os.path.join(bundle, "Contents/Resources/bin/cmux-browser-host")
        self.process = subprocess.Popen(
            [cli, "eval", "--session", chromium_host_agent_cdp.SESSION, "--engine", "cef", script, "--socket", socket],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=sharing.host_cli_env(socket, app.socket))

    def result(self):
        if self.process is None:
            return 1, "", self.error
        try:
            out, err = self.process.communicate(timeout=self.timeout)
        except subprocess.TimeoutExpired:
            self.process.kill()
            out, err = self.process.communicate()
            return 124, out, (err or "") + " (timed out)"
        return self.process.returncode, out, err


def type_terminal(rpc, seconds):
    """Keys into the focused terminal, one every KEY_INTERVAL_S for `seconds` (the typing probe records each)."""
    keys = "abcdefghijklmnopqrstuvwxyz"
    end, index = time.monotonic() + seconds, 0
    while time.monotonic() < end:
        sent = time.monotonic()
        rpc("debug.key", {"key": keys[index % len(keys)], "timestamp": time.clock_gettime(time.CLOCK_UPTIME_RAW)},
            timeout=10)
        index += 1
        rest = chromium_host_agent_cdp.KEY_INTERVAL_S - (time.monotonic() - sent)
        if rest > 0:
            time.sleep(rest)  # one key in flight at a time
    time.sleep(0.5)  # the last echo lands


def typed_key_ms():
    """The typing probe's key-to-frame values (`contents_ms` of complete rows), oldest first."""
    import csv
    try:
        with open(os.path.join(opts.out, "typing.csv")) as handle:
            rows = list(csv.DictReader(handle))
    except OSError:
        return []
    return [float(row["contents_ms"]) for row in rows if row.get("complete") == "1" and row.get("contents_ms")]


def native_ui_rows(rpc, url, chooser_url, app_pid, permission_url=None, child_windows=None):
    """The --native-ui rows (task p01-process-068): the page rows in one probe tab, then the dialog rows, then the
    chooser rows on their probe page at `chooser_url`, then the lock rows; `permission_url` and `child_windows` are
    chromium_host_native_ui.run's `permission_url` and `host_windows`; each row gets
    chromium_host_windows' block of the app log lines written while it ran (a log cursor taken right after it), and
    RESULT["host_windows"] is the block of the whole run (lines a row's last dismissal wrote after it ended are counted
    there). Each block also holds the host's visible windows the window server lists at its end (host_on_screen): a
    host window its backstop never saw fails the row all the same. Returns (rows, ok)."""
    every_line = []
    cursor = chromium_host_windows.LogCursor(APP_LOG.get("path"))
    evaluate = lambda script: page_eval(rpc, script, None)  # noqa: E731

    def on_row(_name, row):
        lines = cursor.take()
        every_line.extend(lines)
        return chromium_host_windows.checked(row, lines, host_on_screen())

    rows = {}
    page_rows = [row for row in opts.native_ui if row in chromium_host_native_ui.ROWS]
    if page_rows:
        rows.update(chromium_host_native_ui.run(rpc, wait, evaluate, url, rows_to_run=page_rows, front=front_pid,
                                                app_pid=app_pid, right_click=page_right_click(rpc),
                                                permission_url=permission_url, host_windows=child_windows,
                                                on_row=on_row)[0])
    dialog_rows = [row for row in opts.native_ui if row in chromium_host_native_ui_dialogs.ROWS]
    if dialog_rows:
        rows.update(chromium_host_native_ui_dialogs.run(rpc, wait, evaluate, opts.out, chromium_host_pid, front_pid,
                                                        on_screen_windows, rows_to_run=dialog_rows, on_row=on_row)[0])
    chooser_rows = [row for row in opts.native_ui if row in chromium_host_native_ui_choosers.ROWS]
    if chooser_rows:
        rows.update(chromium_host_native_ui_choosers.run(rpc, wait, evaluate, chooser_url, chromium_host_pid, front_pid,
                                                         on_screen_windows, rows_to_run=chooser_rows,
                                                         on_row=on_row)[0])
    lock_rows = [row for row in opts.native_ui if row in chromium_host_native_ui_locks.ROWS]
    if lock_rows:
        clear = lambda: chromium_host_native_ui_dialogs.host_ui_clear(chromium_host_pid, front_pid, on_screen_windows)  # noqa: E731
        rows.update(chromium_host_native_ui_locks.run(rpc, wait, evaluate, opts.out, clear, rows_to_run=lock_rows,
                                                      on_row=on_row)[0])
    every_line += cursor.take()
    RESULT["host_windows"] = chromium_host_windows.count(every_line, host_on_screen())
    # A skipped row (another task's, chromium_host_native_ui_choosers.skipped) counts neither way.
    ok = bool(rows) and RESULT["host_windows"]["ok"] and all(row.get("ok") for row in rows.values()
                                                             if "skipped" not in row)
    return rows, ok


def host_on_screen():
    """The running Chromium Host's on-screen windows with alpha above 0 (none when no host runs), or None when the
    window list cannot be read."""
    pid = chromium_host_pid()
    return [] if pid is None else chromium_host_windows.visible(on_screen_windows(pid))


def print_failing(result):
    """--list-failing: one line per failing --native-ui row, and the whole run's host window check."""
    failing = chromium_host_windows.failing(result["modes"].get("native_ui") or {})
    whole = result.get("host_windows") or {}
    if whole and not whole.get("ok"):
        failing.append(("host_windows", chromium_host_windows.summary(whole)))
    if result.get("error"):
        failing.append(("launch", result["error"]))
    for name, reason in failing:
        print(f"FAILING native_ui.{name}: {reason}", flush=True)
    if not failing:
        print("FAILING none", flush=True)


def probe_stats(title):
    if not title or not title.startswith("probe "):
        return None
    try:
        return json.loads(title[len("probe "):])
    except ValueError:
        return None


def drive(rpc, mode, title_of, key_target, mouse_target, click_point, record=True):
    """Keys, clicks and pacing for one mode; title_of() reads the page's summary title. `record` keeps the raw
    series in SAMPLES (the run's own session); the --baseline STRESS rows pass False."""
    row = {}
    # Focus the text field with one click first.
    rpc("debug.mouse", {**mouse_target, **click_point("t")})
    time.sleep(0.3)  # test harness: focus lands
    key_sent = []
    for i in range(opts.count):
        key_sent.append(time.time() * 1000)
        reply = rpc("debug.key", {**key_target, "key": "a", "timestamp": time.clock_gettime(time.CLOCK_UPTIME_RAW)})
        if i == 0:
            row["first_key_reply"] = reply
        time.sleep(1 / 30)  # test harness: one key per two frames, so samples do not share a frame
    stats = wait(lambda: len((probe_stats(title_of()) or {}).get("key_raw") or []) >= opts.count and probe_stats(title_of()), 10)
    stats = stats or probe_stats(title_of()) or {}
    # key_to_raf_ms: from the page's handler to the frame (in-page clock). key_to_paint_ms: from cmux's send to that
    # frame, one wall clock at both ends; matched in order (n says how many keys arrived).
    samples = SAMPLES.setdefault(mode, {}) if record else {}
    samples["key_to_raf"] = padded(stats.get("key_raw"), opts.count)
    samples["key_to_paint"] = paint_deltas(key_sent, stats.get("key_paint"))
    row["key_to_raf_ms"] = results.percentiles(stats.get("key_raw") or [])
    row["key_to_paint_ms"] = paired(key_sent, stats.get("key_paint"))
    click_sent = []
    for i in range(opts.count):
        click_sent.append(time.time() * 1000)
        rpc("debug.mouse", {**mouse_target, **click_point("b")})
        time.sleep(1 / 30)  # test harness: as above
    stats = wait(lambda: len((probe_stats(title_of()) or {}).get("click_raw") or []) >= opts.count and probe_stats(title_of()), 10)
    stats = stats or probe_stats(title_of()) or {}
    # The page samples only clicks on the button, so the focus click above is not in its lists: they start with
    # this loop's first click.
    clicks = (stats.get("click_raw") or [])[:len(click_sent)]
    click_paint = (stats.get("click_paint") or [])[:len(click_sent)]
    samples["click_to_raf"] = padded(clicks, opts.count)
    samples["click_to_paint"] = paint_deltas(click_sent, click_paint)
    row["click_to_raf_ms"] = results.percentiles(clicks)
    row["click_to_paint_ms"] = paired(click_sent, click_paint)
    row.update(pace(rpc, key_target, title_of, samples=samples))
    if opts.baseline:
        row["stall"] = stall_row(rpc, key_target, title_of)
    return row


def pace(rpc, key_target, title_of, during=None, samples=None):
    """The key `p` starts a 3 s animation in the page; the page records its frame intervals. `during()` runs
    while it animates and returns what it did; `samples` (drive()'s result-v1 series) gets the intervals."""
    rpc("debug.key", {**key_target, "key": "p"})
    did = during() if during else None
    if not during:
        time.sleep(3.6)  # test harness: the page animates for 3 s
    raw = (probe_stats(title_of()) or {}).get("raf_raw") or []
    rpc("debug.key", {**key_target, "key": "r"})  # read: the page drops the intervals from its title
    if samples is not None:
        samples["raf_interval"] = raw
    row = {"raf_ms": results.percentiles(raw)}
    if raw and RESULT.get("refresh_hz"):
        period = 1000 / RESULT["refresh_hz"]
        row["long_frames"] = sum(1 for v in raw if v > 1.5 * period)
    if did is not None:
        row["during"] = did
    return row


# cef-helper-app-DESIGN.md requirement 9a: a 50 ms main-thread stall every 100 ms; the page still animates at
# the display's refresh with 0 long frames.
STALL_MS, STALL_EVERY_S = 50, 0.1


def stall_row(rpc, key_target, title_of):
    """Pacing while cmux's main thread stalls on the 9a schedule (`debug.stall`, one socket connection each)."""
    def stalls():
        sent, end = 0, time.monotonic() + 3.6
        while time.monotonic() < end:
            at = time.monotonic()
            reply = rpc("debug.stall", {"ms": STALL_MS}, timeout=5)
            if isinstance(reply, dict) and reply.get("stalled_ms"):
                sent += 1
            time.sleep(max(0.0, STALL_EVERY_S - (time.monotonic() - at)))  # test harness: the 9a schedule
        return sent
    row = pace(rpc, key_target, title_of, during=stalls)
    row.update({"stall_ms": STALL_MS, "every_ms": int(STALL_EVERY_S * 1000), "stalls": row.pop("during"),
                "refresh_hz": RESULT.get("refresh_hz")})
    row["pass"] = row["stalls"] > 0 and row.get("long_frames") == 0
    return row


def open_inproc_probe(rpc, url, name):
    """Opens the probe as `url?probe=<name>` in a focused in-process Chromium tab, and binds every eval to that tab:
    the first focused page that answers with this probe's query is it (an older probe tab never does).
    Returns (page eval, click_point, tab id), or (None, the error, None)."""
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": f"{url}?probe={name}"}, "focus": True,
                                "origin": "script"}, timeout=120)
    ready = (f"document.readyState === 'complete' && document.title.startsWith('probe ') "
             f"&& location.search === '?probe={name}'")
    found = wait(lambda: (lambda value, tab: tab if value is True and tab else None)(*page_eval_reply(rpc, ready)), 60, 0.5)
    if not found:
        return None, f"the probe never loaded: {json.dumps(opened)[:200]}", None
    page = lambda script: page_eval(rpc, script, found)
    page("window.__reset()")

    def click_point(element):
        rect = page(f"(() => {{ const r = document.getElementById('{element}').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; }})()")
        return {"x": rect[0], "y": rect[1]} if rect else {}
    return page, click_point, found


def run_inproc(rpc, url):
    """The in-process rows; returns the probe's tab id, or None."""
    not_in_process = tabs_in_host(rpc)
    if not_in_process:
        RESULT["modes"]["inproc"] = {"not_run": not_in_process}
        return None
    page, click_point, tab = open_inproc_probe(rpc, url, "light")
    if not page:
        RESULT["modes"]["inproc"] = {"error": click_point}
        return None
    hosted = ((rpc("debug.cef") or {}).get("tracker") or {}).get("hosted_pages", 0)
    row = drive(rpc, "inproc", lambda: page("document.title"), {"target": "page"}, {"target": "page"}, click_point)
    row["hosted_pages"] = hosted
    row["pump_share"] = {"light": pump_share(rpc, page)}
    RESULT["modes"]["inproc"] = row
    return tab


FIRST_WHEEL_LIMIT_US = 500  # The first wheel tick of a gesture leaves cmux in < 0.5 ms


def route_report(rpc):
    """`debug.chromium_host` `input_route` (host mode's input ring, p01-process-042); None without one."""
    return (rpc("debug.chromium_host") or {}).get("input_route")


def route_page(report):
    """The route's page whose pacer moved most: the probe's (the bench shows one hosted page)."""
    pages = (report or {}).get("pages") or []
    return max(pages, key=lambda page: page.get("sent") or 0) if pages else {}


def run_route(rpc, url):
    """The `route` rows (p01-process-042): scroll pacing with momentum and keys through host mode's input ring."""
    page, _, _ = open_inproc_probe(rpc, url, "route")
    if not page:
        RESULT["modes"]["route"] = {"error": "the probe tab did not open", "pass": False}
        return False
    # The hosted page view is a cmux view (no page window): window points over the focused pane's content.
    border = focused_pane_border(rpc)
    if not border:
        RESULT["modes"]["route"] = {"error": "no pane geometry (debug.pane_chrome)", "pass": False}
        return False
    click_point = host_click_point(border)
    before = route_report(rpc)
    if before is None:
        RESULT["modes"]["route"] = {"error": "no input route: the tab is not in host mode with the input ring (feature "
                                             "chromiumHostInputRing, a host the supervisor started with a ring, p01-process-080)",
                                    "pass": False}
        return False
    rows = {}
    # A page that scrolls: the probe fills the viewport.
    page("document.documentElement.style.height = 'auto'; document.body.style.height = '20000px'; scrollTo(0, 0); 0")
    point = click_point("b")

    def scroll(dy, **phase):
        rpc("debug.mouse", {"action": "scroll", "dy": dy, "hover": False, **point, **phase})
        time.sleep(0.004)  # test harness: one tick per 4 ms, a trackpad's rate

    scroll(-4, phase="began")
    for _ in range(60):
        scroll(-8, phase="changed")
    scroll(0, phase="ended")
    time.sleep(0.2)  # test harness: the gesture's last ticks are dispatched
    after_gesture = page("scrollY") or 0
    scroll(-20, momentum="began")
    for _ in range(30):
        scroll(-12, momentum="changed")
    scroll(0, momentum="ended")
    time.sleep(0.3)  # test harness: the momentum ticks are dispatched and drawn
    after_momentum = page("scrollY") or 0
    report = route_report(rpc) or {}
    paced = route_page(report)
    first = report.get("first_wheel_send_us") or []
    rows["scroll_pacing"] = {
        "max_wheels_in_flight": paced.get("max_wheels_in_flight"), "coalesced": paced.get("coalesced"),
        "sent": paced.get("sent"), "first_wheel_send_us": results.percentiles(first),
        "scroll_after_gesture": after_gesture, "scroll_after_momentum": after_momentum,
        "ring_dropped": report.get("ring_dropped"), "unwritten": report.get("unwritten"),
    }
    rows["scroll_pacing"]["pass"] = (paced.get("max_wheels_in_flight") == 1 and bool(first)
                                     and max(first) < FIRST_WHEEL_LIMIT_US and after_gesture > 0
                                     and after_momentum > after_gesture)

    rpc("debug.mouse", click_point("t"))
    time.sleep(0.3)  # test harness: focus lands
    field_before = page("document.getElementById('t').value.length") or 0
    unwritten_before = (route_report(rpc) or {}).get("unwritten") or 0
    for _ in range(opts.count):
        rpc("debug.key", {"key": "a"})
        time.sleep(1 / 30)  # test harness: one key per two frames
    field_after = wait(lambda: (lambda n: n if (n or 0) >= field_before + opts.count else None)(
        page("document.getElementById('t').value.length")), 10) or page("document.getElementById('t').value.length") or 0
    report = route_report(rpc) or {}
    paced = route_page(report)
    rows["key"] = {"keys": opts.count, "field_before": field_before, "field_after": field_after,
                   "unwritten": (report.get("unwritten") or 0) - unwritten_before,
                   "max_moves_in_flight": paced.get("max_moves_in_flight"),
                   "max_wheels_in_flight": paced.get("max_wheels_in_flight")}
    rows["key"]["pass"] = (field_after - field_before == opts.count and rows["key"]["unwritten"] == 0
                           and (paced.get("max_moves_in_flight") or 0) <= 1)
    rows["route"] = report
    RESULT["modes"]["route"] = rows
    return rows["scroll_pacing"]["pass"] and rows["key"]["pass"]


def pump_work_ms(rpc):
    return float(((rpc("debug.cef") or {}).get("pump") or {}).get("work_ms") or 0)


def wake_sample(rpc):
    """The app's kernel wakeups and CPU, and the wakeup ledger's counts (all owners, and CEFMessagePump: the
    in-process pump's timer and cross-thread wakes), from debug.wakeups; and the kernel wakeups of each process it
    lists, by pid with its kind (app, Chromium helpers, the daemon and its terminal hosts)."""
    report = rpc("debug.wakeups") or {}
    processes = report.get("processes") or []
    app = next((p for p in processes if p.get("kind") == "app"), {})
    ledger = report.get("ledger") or []
    return {"app_wakeups": app.get("wakeups") or 0, "app_cpu_ms": app.get("cpu_ms") or 0.0,
            "ledger": sum(e.get("count") or 0 for e in ledger),
            "cef_pump": sum(e.get("count") or 0 for e in ledger if e.get("owner") == "CEFMessagePump"),
            "by_pid": {p["pid"]: (p.get("kind") or "?", p.get("wakeups") or 0) for p in processes if p.get("pid")}}


def wake_rates(before, after, seconds):
    rate = lambda key: round((after[key] - before[key]) / seconds, 2)
    out = {"app_wakeups_per_s": rate("app_wakeups"), "app_cpu_share": round((after["app_cpu_ms"] - before["app_cpu_ms"]) / (seconds * 1000), 4),
           "ledger_per_s": rate("ledger"), "cef_pump_per_s": rate("cef_pump")}
    # Per process kind, over the processes alive at both samples (one that started or ended in between has no rate).
    earlier, kinds = before.get("by_pid") or {}, {}
    for pid, (kind, wakeups) in (after.get("by_pid") or {}).items():
        if pid in earlier:
            kinds[kind] = kinds.get(kind, 0) + wakeups - earlier[pid][1]
    out["by_kind_per_s"] = {kind: round(total / seconds, 2) for kind, total in sorted(kinds.items())}
    # The pump's part of the app's sanctioned main wakes (the ledger), and of all its kernel wakeups.
    out["cef_pump_share_of_ledger"] = round(out["cef_pump_per_s"] / out["ledger_per_s"], 4) if out["ledger_per_s"] > 0 else None
    out["cef_pump_share_of_app_wakeups"] = (round(out["cef_pump_per_s"] / out["app_wakeups_per_s"], 4)
                                            if out["app_wakeups_per_s"] > 0 else None)
    return out


def pump_share(rpc, page, scroll=None):
    """Main-thread share inside Chromium pump passes, and the app's wakes, idle and while the shown page scrolls.
    `scroll` sends one wheel event (default: to the focused in-process page)."""
    scroll = scroll or (lambda: rpc("debug.mouse", {"target": "page", "action": "scroll", "dy": -12}))
    shares = {}
    for phase in ("idle", "scroll"):
        if page:
            page("window.scrollTo(0, 0); document.body.style.height = '40000px'")
        start_ms, start, wakes = pump_work_ms(rpc), time.monotonic(), wake_sample(rpc)
        deadline = start + opts.pump_seconds
        while time.monotonic() < deadline:
            if phase == "scroll":
                scroll()
            time.sleep(1 / 60)  # test harness: one wheel event per 60 Hz frame (idle: just the wait)
        wall_ms = (time.monotonic() - start) * 1000
        shares[phase] = {"share": round((pump_work_ms(rpc) - start_ms) / wall_ms, 4), "wall_ms": round(wall_ms),
                         "wakes": wake_rates(wakes, wake_sample(rpc), wall_ms / 1000)}
    shares["pump"] = (rpc("debug.cef") or {}).get("pump")
    return shares


def run_stress_pump(rpc, url, helper):
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    summary = module.Stress(rpc, selected="chromium").build()
    RESULT["stress_session"] = summary
    # Scroll goes to the focused pane's page: a Chromium page in STRESS (selected chromium).
    RESULT["modes"].setdefault("inproc", {}).setdefault("pump_share", {})["stress"] = pump_share(rpc, None)
    if not opts.baseline:
        return
    stress = RESULT.setdefault("sessions", {}).setdefault("stress", {})
    # STRESS's own tab mix (2 Chromium and 1 WebKit per measured pane, 10 background workspaces with 2 Chromium
    # pages each), not 10 tabs: the topology has no engine, so the row counts browser tabs of both engines.
    stress["idle"] = idle_scenarios(rpc)
    # The probe in the measured pane: keys, clicks, pacing and the 9a stall with the whole STRESS session behind it.
    page, click_point, _ = open_inproc_probe(rpc, url, "stress")
    stress["inproc"] = (drive(rpc, "inproc", lambda: page("document.title"), {"target": "page"}, {"target": "page"}, click_point,
                              record=False) if page else {"error": click_point})
    if helper:
        # The same probe in the host, over the measured pane (the host's page view moves there).
        stress["helper"] = run_host_probe(rpc, f"{url}?probe=stress-host", record=False)


def topology(rpc):
    return (rpc("snapshot.get") or {}).get("topology") or {}


def topology_tabs(rpc):
    """Every tab of every workspace in the app's snapshot."""
    workspaces = topology(rpc).get("workspaces") or []
    return [tab for workspace in workspaces for screen in workspace.get("screens") or [] for pane in screen.get("panes") or []
            for tab in pane.get("tabs") or []]


def idle_wakes(rpc):
    """Wakes per second over --pump-seconds, after --idle-settle-seconds with nothing happening."""
    time.sleep(opts.idle_settle_seconds)  # test harness: hidden pages reach their frozen state
    start, before = time.monotonic(), wake_sample(rpc)
    time.sleep(opts.pump_seconds)  # test harness: the idle sample
    return wake_rates(before, wake_sample(rpc), time.monotonic() - start)


def action(rpc, name, **fields):
    reply = rpc("action.run", {"action": name, "origin": "script", **fields}, timeout=60)
    if not isinstance(reply, dict):
        return "no reply"
    return reply.get("error") or (None if reply.get("ok", True) else "refused")


def idle_scenarios(rpc):
    """Idle wakes in done check 12's three scenarios: the app visible, the workspace hidden (a new workspace is
    selected, as bench_idle.py's chromium-hidden; closed after) and the app hidden (`showHideAllWindows`
    hidden, NSApp.hide; unhidden without activation after). The ledger is the app's sanctioned wakes (mostly its main thread); macOS counts kernel
    wakeups per process, not per thread, so the main thread's own count is not split out."""
    tabs = topology_tabs(rpc)
    row = {"settle_s": opts.idle_settle_seconds, "tabs": len(tabs),
           "browser_tabs": sum(1 for tab in tabs if tab.get("kind") == "browser"),
           "terminals": sum(1 for tab in tabs if tab.get("kind") == "terminal"), "scenarios": {}}
    row["scenarios"]["app_visible"] = {"wakes": idle_wakes(rpc)}
    workspaces = {w.get("id") for w in topology(rpc).get("workspaces") or []}
    refused = action(rpc, "newTab", focus=True)
    added = [w.get("id") for w in topology(rpc).get("workspaces") or [] if w.get("id") not in workspaces]
    if refused or not added:
        row["scenarios"]["workspace_hidden"] = {"error": f"newTab: {refused or 'no new workspace'}"}
    else:
        row["scenarios"]["workspace_hidden"] = {"wakes": idle_wakes(rpc)}
    for workspace in added:
        action(rpc, "closeWorkspace", args={"confirm": True}, target=f"workspace:{workspace}")
    refused = action(rpc, "showHideAllWindows", args={"hidden": True})
    row["scenarios"]["app_hidden"] = {"error": f"showHideAllWindows: {refused}"} if refused else {"wakes": idle_wakes(rpc)}
    action(rpc, "showHideAllWindows", args={"hidden": False})
    return row


TABS_IDLE = 10  # p01-process.md done check 12: idle wakes with 10 Chromium tabs


def tabs10_wakes(rpc, url):
    """Idle wakes with the probe and 9 more in-process Chromium tabs, in the three scenarios; the 9 are closed after."""
    not_in_process = tabs_in_host(rpc)
    if not_in_process:
        return {"not_run": not_in_process}
    before = {tab.get("id") for tab in topology_tabs(rpc)}
    for _ in range(TABS_IDLE - 1):
        rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"}, timeout=120)
    added = wait(lambda: (lambda new: new if len(new) >= TABS_IDLE - 1 else None)(
        [tab.get("id") for tab in topology_tabs(rpc) if tab.get("id") not in before]), 60, 0.5) or []
    if len(added) < TABS_IDLE - 1:
        return {"error": f"{len(added)} of {TABS_IDLE - 1} more Chromium tabs opened"}
    row = idle_scenarios(rpc)
    row["chromium_tabs"] = TABS_IDLE
    for tab in added:
        rpc("action.run", {"action": "closeTab", "target": f"tab:{tab}", "wait": True, "origin": "script"}, timeout=60)
    return row


def host_block():
    """Where the numbers come from: the host's name, macOS, and the build's commit (bench_launch.build_sha)."""
    import platform, socket
    block = {"name": socket.gethostname().split(".")[0], "macos": platform.mac_ver()[0] or None}
    try:
        block["sha"] = build_sha(opts.app)
    except RecordError as error:
        block["sha_error"] = str(error)[:200]
    return block


CENSUS_TIMEOUT_S = 1200  # the heavy session builds 150 workspaces
CENSUS_TOOL = os.path.join(HERE, "process-model-census.py")


def census(app, name, session=None, baseline=None):
    """process-model-census.py (task p01-process-004) on this running app, by its tag and socket (its `--app`
    launches a second instance of the tag and ends the tag's daemons when it stops). `session` builds that census
    session in the app first; `baseline` is an earlier census JSON of this app (per hidden terminal over all
    roles). Returns {"census": its JSON, "path": where it is}, or {"error"}; the terminal counts are the census's
    own (`census.session`)."""
    if not os.path.exists(CENSUS_TOOL):
        return {"error": "process-model-census.py is not in this checkout (task p01-process-004)"}
    path = os.path.join(opts.out, f"census-{name}.json")
    argv = [sys.executable, CENSUS_TOOL, "--tag", app.tag, "--socket", app.socket, "--out", path]
    argv += ["--session", session] if session else []
    argv += ["--baseline", baseline] if baseline else []
    try:
        run = subprocess.run(argv, capture_output=True, text=True, timeout=CENSUS_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return {"error": f"census {name} timed out after {CENSUS_TIMEOUT_S} s"}
    if run.returncode != 0:
        return {"error": f"census {name} exit {run.returncode}: {run.stderr.strip()[-300:]}"}
    try:
        with open(path) as source:
            report = json.load(source)
    except (OSError, ValueError) as error:
        return {"error": f"census {name} wrote no JSON to {path}: {error}"}
    return {"census": report, "path": path}


# The probe's fixed layout: the field spans 10-70 % at 20 % height, the button 10-40 % at 40 % (+40 px).
HOST_SPOTS = {"t": (0.4, 0.2, 10), "b": (0.25, 0.4, 40), "s": (0.2, 0.55, 15), "al": (0.52, 0.55, 20), "f": (0.75, 0.55, 12),
              "pw": (0.55, 0.4, 10)}


def host_click_point(border):
    """click_point for the host page over a pane whose content rect (window points, top left) is `border`."""
    bx, by, bw, bh = border

    def click_point(element):
        fx, fy, dy = HOST_SPOTS[element]
        return {"x": bx + bw * fx, "y": by + bh * fy + dy}
    return click_point


def focused_pane_border(rpc):
    """The focused pane's content rect (debug.focus model pane, debug.pane_chrome border) in the key window (else
    the first), or None."""
    windows = (rpc("debug.focus") or {}).get("windows") or []
    window = next((w for w in windows if w.get("is_key")), windows[0] if windows else {})
    pane = (window.get("model") or {}).get("pane")
    layers = rpc("debug.pane_chrome") or {}
    return next((p.get("border") for w in layers.get("windows") or [] for p in w.get("panes") or []
                 if pane and p.get("pane") == pane and isinstance(p.get("border"), list)), None)


def page_right_click(rpc):
    """A right click (a posted window event, as a person's) on an empty spot of the focused pane's page, low and right
    of the native-ui probe's controls and below any browser toolbar. The pane is read at each call (the probe's tab
    opens after this is made); the click returns False when no pane is focused."""
    def click():
        border = focused_pane_border(rpc)
        if not border:
            return False
        bx, by, bw, bh = border
        rpc("debug.mouse", {"x": bx + bw * 0.75, "y": by + bh * 0.8, "button": "right"})
        return True
    return click


def run_host_probe(rpc, url, record=True):
    """Keys, clicks, pacing and (with --baseline) the 9a stall with the probe in the host over the focused pane.
    `url` carries a query of its own: the row waits for that page, fresh (no keys yet), not an earlier probe."""
    reply = rpc("debug.chromium_host", {"op": "open", "url": url, "focus": True}) or {}
    if reply.get("error"):
        return {"error": f"debug.chromium_host open: {reply['error']}"}
    query = url[url.index("?"):] if "?" in url else url

    def fresh(state):
        stats = probe_stats(state.get("title")) or {}
        return (state if state.get("shown_context_id") and query in (state.get("url") or "")
                and stats.get("key_raw") == [] else None)
    if not wait(lambda: fresh(rpc("debug.chromium_host") or {}), 90, 0.25):
        return {"error": "the host page never showed the probe", "state": rpc("debug.chromium_host") or {}}
    border = focused_pane_border(rpc)
    if not border:
        return {"error": "no geometry for the focused pane (debug.focus, debug.pane_chrome)"}
    time.sleep(0.5)  # test harness: the shown context's first frame reaches the screen
    return drive(rpc, "helper", lambda: (rpc("debug.chromium_host") or {}).get("title"), {}, {}, host_click_point(border),
                 record=record)


def tcc_open_page(rpc, url, holder):
    """Opens the TCC probe in a focused Chromium tab and keeps its tab id in `holder`: {"tab"} or {"error"}."""
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"},
                 timeout=120)
    ready = "document.title.startsWith('tcc ') && location.pathname === '/tcc.html'"
    found = wait(lambda: (lambda value, tab: tab if value is True and tab else None)(*page_eval_reply(rpc, ready)), 60, 0.5)
    if not found:
        return {"error": f"the probe never loaded: {json.dumps(opened)[:200]}"}
    holder["tab"] = found
    return {"tab": found}


def tcc_allow(rpc, holder):
    """Answers the TCC tab's prompt bar question with Allow (browser.prompt.allow); False when it had none (the
    action is unavailable without one)."""
    reply = rpc("action.run", {"action": "browser.prompt.allow", "target": f"tab:{holder.get('tab')}", "origin": "script"})
    return not (isinstance(reply, dict) and "error" in reply)


def tcc_restart_host(rpc, holder):
    """Ends the Chromium host (SIGKILL) and reloads the TCC tab, which starts a new host (CEFTab.reload ->
    CEFRuntime.reloadAfterHostRestart): {"old_pid", "new_pid", "error"}."""
    old = chromium_host_pid()
    if old is None:
        return {"old_pid": None, "new_pid": None, "error": "no Chromium host runs"}
    try:
        os.kill(old, signal.SIGKILL)
    except OSError as error:
        return {"old_pid": old, "new_pid": None, "error": f"SIGKILL to the host: {error}"}
    if not wait(lambda: chromium_host_pid() != old, 15, 0.25):
        return {"old_pid": old, "new_pid": None, "error": f"the host (pid {old}) still runs 15 s after SIGKILL"}
    reload = rpc("action.run", {"action": "browserReload", "target": f"tab:{holder.get('tab')}", "origin": "script"})
    new = wait(lambda: (lambda pid: pid if pid and pid != old else None)(chromium_host_pid()), 60, 0.25)
    return {"old_pid": old, "new_pid": new,
            "error": None if new else f"no new Chromium host 60 s after the tab's Reload: {json.dumps(reload)[:200]}"}


def seed_tcc_keychain(keychain_plan):
    """The tcc mode's seed launch, before the measured one: cmux with Chromium in process and the real keychain opens
    the probe, so cmux's in-process engine makes "Chromium Safe Storage" and stores the probe's cookie with its key,
    then quits (Chromium's shutdown commits the cookie). The keychain row's cross_identity step has the host read that
    item. Returns {"created", "cookie", "backend"} or {"error"}."""
    import chromium_host_tcc as tcc
    if not keychain_plan.get("real_keychain"):
        return {"error": keychain_plan.get("reason") or "the run keeps Chromium's mock keychain"}
    if tcc.keychain_item(opts.keychain_service) is not False:
        return {"error": f"the {opts.keychain_service!r} item exists before the seed launch"}
    out = os.path.join(opts.out, "tcc-seed")
    os.makedirs(out, exist_ok=True)
    tunables = os.path.join(out, "debug-tunables.json")
    json.dump({"version": 1, "values": {**TUNABLES["values"], "browserHost.helper": False}}, open(tunables, "w"))
    pages = tcc.Pages()
    url, _ = pages.start()
    seed = BenchApp(opts.app, out=out, env={"CMUX_NEXT_DEBUG_TUNABLES_FILE": tunables, "CMUX_NEXT_BENCH_REAL_KEYCHAIN": "1"},
                    build_config=opts.build_config, perf_session=opts.session)
    try:
        seed.launch()
        backend = (seed.rpc("debug.cef") or {}).get("backend")
        if backend != "inProcess":
            return {"error": f"the seed launch's Chromium does not run in process (debug.cef backend {backend!r})"}
        holder = {}
        opened = tcc_open_page(seed.rpc, url, holder)
        if opened.get("error"):
            return {"error": f"seed launch: {opened['error']}"}
        load = (tcc.page_state(page_eval(seed.rpc, "document.title", holder["tab"])) or {}).get("_load") or {}
        made = wait(lambda: (tcc.keychain_info(opts.keychain_service) or {}).get("created"), 30, 0.5)
        if not made:
            return {"error": "cmux's in-process engine made no item with a creation date in 30 s"}
        return {"created": made, "cookie": load.get("t"), "backend": backend}
    except LaunchError as error:
        return {"error": f"seed launch: {error.reason}"}
    finally:
        seed.stop()
        pages.stop()


def run_tcc(rpc, app_pid, keychain_plan, seed):
    """TCC attribution rows on the probe in a Chromium tab of the measured launch, whose Chromium must run in the
    host (chromium_host_tcc.py); False on a mode error or when the page never showed."""
    import chromium_host_tcc as tcc
    pages, log = tcc.Pages(), tcc.LogStream()
    url, lan = pages.start()
    log.start()
    holder = {}
    try:
        seams = tcc.Seams(log=log, host_pid=chromium_host_pid, lan_hits=lambda: pages.lan_hits)
        rows = tcc.TccRows(
            tcc.Bundle.read(opts.app),
            open_host=lambda page: tcc_open_page(rpc, page, holder),
            title=lambda: page_eval(rpc, "document.title", holder.get("tab")),
            press=lambda key: rpc("debug.key", {"target": "page", "key": key}),
            allow=lambda: tcc_allow(rpc, holder),
            restart_host=lambda: tcc_restart_host(rpc, holder),
            backend=lambda: (rpc("debug.cef") or {}).get("backend"),
            seams=seams, keychain_service=opts.keychain_service, app_pid=app_pid, keychain_plan=keychain_plan, seed=seed)
        result = rows.run(url)
    finally:
        # Later modes measure their own pages: the probe's tab and its camera or location use end here.
        if holder.get("tab"):
            rpc("action.run", {"action": "closeTab", "target": f"tab:{holder['tab']}", "origin": "script"})
        log.stop()
        pages.stop()
    result.update({"lan_address": lan, "lan_hits": pages.lan_hits, "log_error": log.error, "keychain_plan": keychain_plan})
    RESULT["modes"]["tcc"] = result
    tcc.print_rows(result, lambda line: print(line, flush=True))
    return not result.get("error") and not result.get("mode_errors")


def run_helper(rpc, url, inproc_tab):
    # A pane of its own (the in-process page keeps the left one).
    rpc("action.run", {"action": "splitRight", "focus": True, "origin": "script"}, timeout=60)
    time.sleep(1)  # test harness: the split settles
    pixels = {"before_open": probe_color_share()}
    bundle_id = app_bundle_id()
    DEFAULTS["before"] = defaults_snapshot(bundle_id)
    reply = rpc("debug.chromium_host", {"op": "open", "url": url, "focus": True}) or {}
    if reply.get("error"):
        RESULT["modes"]["helper"] = {"error": reply["error"]}
        return False
    state = wait(lambda: (lambda r: r if r.get("shown_context_id") and (r.get("title") or "").startswith("probe ") else None)(
        rpc("debug.chromium_host") or {}), 90, 0.25)
    if not state:
        failed = rpc("debug.chromium_host") or {}
        RESULT["modes"]["helper"] = {"error": "the host page never showed", "state": failed,
                                     "host_log": log_tail(failed.get("log_file")), "crash_reports": host_crash_reports(),
                                     # The host's children write to cmux's stderr (the app log): sandbox and load errors.
                                     "app_log_children": app_log_lines(("Helper", "sandbox", "Sandbox", "seatbelt", "Check failed",
                                                                        "ERROR", "FATAL", "LoadInHelper", "dlopen"))}
        return False
    time.sleep(0.5)  # test harness: the shown context's first frame reaches the screen
    pixels["shown"] = probe_color_share()
    title = lambda: (rpc("debug.chromium_host") or {}).get("title")
    # The pane is the focused one; the host page view covers its content: click points are the page's own layout
    # (the probe's elements are at fixed fractions of the viewport), turned into window points by the app.
    # The rightmost pane's content rect (window points, top left): the host page view fills it.
    layers = rpc("debug.pane_chrome") or {}
    borders = [pane.get("border") for window in layers.get("windows") or [] for pane in window.get("panes") or []
               if isinstance(pane.get("border"), list)]
    if not borders:
        RESULT["modes"]["helper"] = {"error": "no pane geometry (debug.pane_chrome)"}
        return False
    click_point = host_click_point(max(borders, key=lambda b: b[0]))
    row = drive(rpc, "helper", title, {}, {}, click_point)
    # The host is a second executable of cmux.app with its bundle id: it must stay out of the Dock, the menu bar
    # and Cmd-Tab (UIElement), never be frontmost while cmux takes keys, and `open -b` must reach cmux, not it.
    host_pid, app_pid = state.get("pid"), (rpc("debug.chromium_host") or {}).get("app_pid")
    types = ls_types()
    identity = {"host_pid": host_pid, "app_pid": app_pid, "host_type": types.get(host_pid), "app_type": types.get(app_pid),
                "front_after_input": front_pid()}
    # 10 clicks on the page and a key after each: the frontmost app stays cmux's process the whole time, and the
    # host never becomes active nor owns the key window (its own counters, debug.chromium_host.measure input).
    # The overlay host re-adds its panel above no page across those event cycles in host mode:
    # debug.overlay reorders_per_event stays 0.
    rpc("debug.overlay", {"reset": True})
    fronts = []
    for _ in range(10):
        rpc("debug.mouse", click_point("b"))
        rpc("debug.key", {"key": "a"})
        fronts.append(front_pid())
    overlay = rpc("debug.overlay") or {}
    identity["overlay"] = {"reorders_per_event": overlay.get("reorders_per_event"),
                           "windows": [{k: w.get(k) for k in ("page_surface", "reorders", "event_cycles", "order_checks")}
                                       for w in overlay.get("windows") or []]}
    counters = rpc("debug.chromium_host.measure", {"op": "input"}) or {}
    identity["clicks"] = {"fronts": sorted(set(p for p in fronts if p is not None)), "host_frontmost": fronts.count(host_pid),
                          "activations": counters.get("activations"), "key_windows": counters.get("key_windows")}
    # The host's page windows are detached and its own windows never ordered in: with the
    # page shown and after the clicks, the window server lists no window of the host on screen.
    host_windows = on_screen_windows(host_pid) if host_pid else None
    identity["host_windows_on_screen"] = {"count": None if host_windows is None else len(host_windows),
                                          "windows": (host_windows or [])[:8]}
    try:
        opened = subprocess.run(["/usr/bin/open", "-b", bundle_id], capture_output=True, text=True, timeout=20)
        open_exit, open_err = opened.returncode, opened.stderr.strip()[:200]
    except subprocess.TimeoutExpired:
        open_exit, open_err = None, "timed out after 20 s"
    time.sleep(1.5)  # test harness: LaunchServices activates the target app
    identity["open_b"] = {"exit": open_exit, "stderr": open_err, "front": front_pid(),
                          "host_still_runs": not pid_gone(host_pid), "host_type": ls_types().get(host_pid)}
    identity["pass"] = (identity["host_type"] in ("UIElement", "BackgroundOnly") and identity["front_after_input"] != host_pid
                        and identity["open_b"]["front"] != host_pid and identity["open_b"]["host_type"] in ("UIElement", "BackgroundOnly")
                        and identity["clicks"]["host_frontmost"] == 0 and identity["clicks"]["activations"] == 0
                        and identity["clicks"]["key_windows"] == 0
                        and identity["host_windows_on_screen"]["count"] == 0)
    # The same baseline with the page in the host: cmux's pump still runs for in-process Chromium (the
    # in-process tab, idle in the other pane, and the spare page), the host's page idles and scrolls.
    host_point = click_point("t")
    row["pump_share"] = {"light": pump_share(rpc, None, scroll=lambda: rpc(
        "debug.mouse", {"action": "scroll", "dy": -12, "hover": False, **host_point}))}
    # Pointer moves in a burst: the host folds the moves its UI thread has not run into one (FrameQueue).
    for i in range(200):
        rpc("debug.mouse", {"action": "move", "x": host_point["x"] + (i % 40), "y": host_point["y"]})
    hop = rpc("debug.chromium_host.measure", {"op": "input"}) or {}
    row["hop_us"] = hop
    row["ping_us"] = rpc("debug.chromium_host.measure", {"op": "ping", "count": 500}, timeout=60)
    RESULT["modes"]["helper"] = row
    row["identity"] = identity
    row["host_pid"] = state.get("pid")
    row["fork_api"] = state.get("fork_api")

    row["input"] = input_rows(rpc, url, title, click_point, borders, host_pid)
    bounded(row, "geometry", lambda: geometry_row(rpc))
    if opts.ime:
        bounded(row, "ime", lambda: ime_row(rpc, title, click_point))
        bounded(row, "password", lambda: password_row(rpc, click_point))

    # Kill: cmux keeps running, a new host loads the saved page.
    before = rpc("debug.chromium_host") or {}
    app_pid = before.get("app_pid")
    killed = (rpc("debug.chromium_host", {"op": "kill"}) or {}).get("killed_pid")
    after = wait(lambda: (lambda r: r if r.get("restarts", 0) >= 1 and r.get("shown_context_id") and r.get("pid") != killed else None)(
        rpc("debug.chromium_host") or {}), 90, 0.25)
    windows = rpc("debug.windows") or {}
    inproc_alive = None
    if inproc_tab:
        inproc_alive = page_eval(rpc, "1 + 1", inproc_tab) == 2
    row["kill"] = {
        "killed_pid": killed, "app_pid_before": app_pid, "app_pid_after": (after or {}).get("app_pid"),
        "app_answers": bool(windows.get("windows")), "restarted": bool(after), "new_host_pid": (after or {}).get("pid"),
        "url_after": (after or {}).get("url"), "exits": (after or rpc("debug.chromium_host") or {}).get("exits"),
        "inproc_tab_answers": inproc_alive,
    }
    row["kill"]["pass"] = bool(after) and row["kill"]["app_answers"] and app_pid == (after or {}).get("app_pid")
    if after:
        time.sleep(0.5)  # test harness: as above, for the restarted host's context
        pixels["after_restart"] = probe_color_share()
    if None in (pixels["before_open"], pixels["shown"]):
        pixels["not_measurable"] = "no Screen Recording grant for this account (screencapture could not read the display)"
    else:
        added = lambda key: pixels.get(key) is not None and pixels[key] - pixels["before_open"] >= 0.02
        pixels["pass"] = added("shown") and (not after or added("after_restart"))
    row["pixels"] = pixels
    return True


def run_cursor(rpc, url):
    """The cursor row: the pointer over each band of the cursor probe, then the page view's cursor (debug.cef)."""
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"}, timeout=120)
    tab = {}

    def page(script):
        reply = rpc("browser.page.eval", {"script": script, **({"tab": tab["tab"]} if tab.get("tab") else {})}, timeout=20)
        if not isinstance(reply, dict) or "error" in reply:
            return None
        tab.setdefault("tab", reply.get("tab"))
        return reply.get("value")
    if not wait(lambda: page("document.readyState === 'complete' && document.title === 'cursor probe'"), 60, 0.5):
        RESULT["modes"]["cursor"] = {"error": f"the cursor probe never loaded: {json.dumps(opened)[:200]}"}
        return False

    def shown_cursor():
        entries = (rpc("debug.cef") or {}).get("devtools") or []
        mine = [e for e in entries if (e.get("url") or "").startswith(url)]
        return (mine or [{}])[0].get("page_cursor")

    row = {}
    for band, expected in CURSOR_BANDS.items():
        rect = page(f"(() => {{ const r = document.getElementById('{band}').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; }})()")
        if not rect:
            row[band] = {"error": "no band rect"}
            continue
        moved = rpc("debug.mouse", {"action": "move", "target": "page", "x": rect[0], "y": rect[1]})
        if not isinstance(moved, dict) or moved.get("error"):
            # The pointer never reached the page: the driver's fault, not the cursor's.
            error = moved.get("error") if isinstance(moved, dict) else f"no reply: {moved!r}"
            row[band] = {"expected": expected, "move": moved, "error": f"debug.mouse move: {error}", "pass": False}
            continue
        # The renderer sends a changed cursor after the move reaches it; host mode adds the wire hop.
        shown = wait(lambda: (lambda c: c if c == expected else None)(shown_cursor()), 5, 0.05) or shown_cursor()
        row[band] = {"expected": expected, "move": moved, "shown": shown, "pass": shown == expected}
    bands = [row.get(band) or {} for band in CURSOR_BANDS]
    if all((b.get("move") or {}).get("reason") == "no_host_input_route" for b in bands):
        row["not_measurable"] = ("no pointer route from the page view to the Chromium Host yet (p01-process-042): "
                                 "the renderer never sees the pointer, so it computes no cursor")
    elif all("error" not in b and b.get("shown") is None for b in bands):
        row["not_measurable"] = "no page view cursor: the tab runs in process, where Chromium's page window shows its own cursor"
    else:
        row["pass"] = all(b.get("pass") for b in bands)
    RESULT["modes"]["cursor"] = row
    return True


def build_pointer_probe():
    """pointer-probe.swift built here (an input host's Accessibility grant posts its events); None when it fails."""
    probe = os.path.join(tempfile.mkdtemp(prefix="pointer-probe-"), "pointer-probe")
    built = subprocess.run(["xcrun", "swiftc", "-O", os.path.join(HERE, "pointer-probe.swift"), "-o", probe],
                           capture_output=True, text=True, timeout=300)
    return probe if built.returncode == 0 else None


def run_dragin(rpc, url):
    """The drag-in row (task 050): a real drag session from another app (pointer-probe drag-file, as from Finder)
    of one file onto the drag probe's drop zone, then onto its <input type=file>. Each passes when the page got
    the file with its bytes (the zone's drop event, the input's change event) and the source saw the drop taken."""
    probe = build_pointer_probe()
    if not probe:
        RESULT["modes"]["dragin"] = {"error": "pointer-probe.swift did not build (xcrun swiftc)"}
        return False
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"}, timeout=120)
    tab = {}

    def page(script):
        reply = rpc("browser.page.eval", {"script": script, **({"tab": tab["tab"]} if tab.get("tab") else {})}, timeout=20)
        if not isinstance(reply, dict) or "error" in reply:
            return None
        tab.setdefault("tab", reply.get("tab"))
        return reply.get("value")
    if not wait(lambda: page("document.readyState === 'complete' && document.title === 'drag probe'"), 60, 0.5):
        RESULT["modes"]["dragin"] = {"error": f"the drag probe never loaded: {json.dumps(opened)[:200]}"}
        return False
    border = focused_pane_border(rpc)
    window = next((w for w in (rpc("debug.window_list") or {}).get("windows") or []
                   if w.get("kind") == "main" and w.get("visible")), None)
    screen_h = subprocess.run([probe, "screen"], capture_output=True, text=True, timeout=20).stdout.strip()
    if not border or not window or not screen_h:
        RESULT["modes"]["dragin"] = {"error": "no pane, window or screen geometry (debug.pane_chrome, debug.window_list)"}
        return False
    frame = window.get("frame") or {}
    # Window points from the top left to screen points from the top left (the pane's page view fills its border).
    left = frame.get("x", 0) + border[0]
    top = float(screen_h) - (frame.get("y", 0) + frame.get("height", 0)) + border[1]
    path = os.path.join(opts.out, "drag-in.txt")
    with open(path, "w") as out:
        out.write(DRAG_FILE_TEXT)
    expected = [[os.path.basename(path), len(DRAG_FILE_TEXT.encode())]]
    # The source sits left of the window when there is room, else at its top left corner (it floats above cmux).
    source = (max(30.0, frame.get("x", 0) - 40), top + 20)

    def page_drag():
        # Only a host-mode page view has a page_drag (debug.cef): in process the DevTools relay takes file drags.
        cef = rpc("debug.cef") or {}
        mine = [e for e in cef.get("devtools") or [] if (e.get("url") or "").startswith(url)]
        return (mine or [{}])[0].get("page_drag"), (cef.get("windows") or {}).get("fork_api")

    counts, fork_api = page_drag()
    row = {"backend": "host" if counts else "in_process", "fork_api": fork_api, "page_drag": counts}
    if not counts:
        row["not_measurable"] = "the tab runs in process, where the DevTools relay takes file drags: no DragTarget path"
    elif not isinstance(fork_api, (int, float)) or fork_api < DRAG_TARGET_FORK_API:
        row["not_measurable"] = (f"fork API {fork_api} is below {DRAG_TARGET_FORK_API} (p01-process-178): the page view "
                                 "refuses the drag and the DevTools relay takes the drops")
    elif not counts.get("takes_drags"):
        row["error"] = "the page view takes no drags: feature chromiumHostDragIn is off or the pane never wired it"
    for target, field in (("zone", "dropped"), ("file", "file")):
        rect = page(f"(() => {{ const r = document.getElementById('{target}').getBoundingClientRect(); "
                    "return [r.x + r.width / 2, r.y + r.height / 2]; })()")
        if not rect:
            row[target] = {"error": "no target rect", "pass": False}
            continue
        point = (left + rect[0], top + rect[1])
        dragged = subprocess.run([probe, "drag-file", f"{source[0]:.0f}", f"{source[1]:.0f}", f"{point[0]:.0f}", f"{point[1]:.0f}",
                                  "40", path], capture_output=True, text=True, timeout=60)
        got = wait(lambda: page(f"window.dragLog.{field}"), 5, 0.1)
        log = page("JSON.stringify(window.dragLog)")
        before, after = counts or {}, page_drag()[0] or {}
        # This drop went through cmux_shim_browser_drag_target_*: one more DragTarget drop, and the renderer
        # answered the drag's enter or over through the fork's watch.
        drag_target = {key: (after.get(key) or 0) - (before.get(key) or 0) for key in ("enters", "drops", "answers")}
        counts = after
        row[target] = {"point": point, "source": dragged.stdout.strip() or dragged.stderr.strip()[:200], "got": got, "log": log,
                       "drag_target": drag_target,
                       "pass": (got == expected and dragged.returncode == 0 and drag_target["drops"] == 1
                                and drag_target["answers"] >= 1)}
    if "not_measurable" not in row:
        row["pass"] = "error" not in row and all(row[t].get("pass") for t in ("zone", "file"))
    RESULT["modes"]["dragin"] = row
    return True


def run_mouse(rpc, url):
    """The mouse rows (task 054): the page's tooltip shown while the pointer stays, back and forward clicks that never
    reach the page as a left click, the middle click, and the pinch and smart magnify frames (debug.mouse page)."""
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"}, timeout=120)
    tab = {}

    def page(script):
        value, got = page_eval_reply(rpc, script, tab.get("tab"))
        if got:
            tab.setdefault("tab", got)
        return value
    if not wait(lambda: page("document.readyState === 'complete' && document.title === 'mouse probe'"), 60, 0.5):
        RESULT["modes"]["mouse"] = {"error": f"the mouse probe never loaded: {json.dumps(opened)[:200]}"}
        return False

    def entry():
        entries = (rpc("debug.cef") or {}).get("devtools") or []
        return ([e for e in entries if (e.get("url") or "").startswith(url)] or [{}])[0]

    def center(element):
        return page(f"(() => {{ const r = document.getElementById('{element}').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; }})()")

    def unmeasurable(reply):
        # No route to the host, or a move that went to the in-process page window (no page view).
        return isinstance(reply, dict) and (reply.get("reason") in ("no_host_input_route", "not_host_mode")
                                            or (not reply.get("error") and reply.get("view") != "ChromiumHostPageView"))

    row = {}
    tip = center("tip")
    moved = rpc("debug.mouse", {"action": "move", "target": "page", "x": tip[0], "y": tip[1]}) if tip else {"error": "no band rect"}
    if unmeasurable(moved):
        row["not_measurable"] = (f"no host-mode page view with a pointer route to the Chromium Host ({moved.get('reason') or 'in process'}): "
                                 "in process Chromium's page window shows its own tooltip and gets every button itself")
        RESULT["modes"]["mouse"] = row
        return True
    if not isinstance(moved, dict) or moved.get("error"):
        row["tooltip"] = {"move": moved, "error": "debug.mouse move failed", "pass": False}
    else:
        # The renderer sends the tooltip after the move reaches it; the tooltip then waits AppKit's hover delay. No
        # other move: the pointer stays inside the page view the whole time, as a user's resting on the link.
        text = wait(lambda: entry().get("page_tooltip") == MOUSE_TOOLTIP and MOUSE_TOOLTIP, 5, 0.05)
        shown = wait(lambda: entry().get("tooltip_shown") == MOUSE_TOOLTIP and MOUSE_TOOLTIP, 5, 0.05)
        row["tooltip"] = {"expected": MOUSE_TOOLTIP, "page_tooltip": text or entry().get("page_tooltip"),
                          "shown": shown or entry().get("tooltip_shown"), "pass": bool(text and shown)}

    pad = center("pad") or [0, 0]
    for button in ("back", "forward", "middle"):
        page("window.__mouse = []")
        clicked = rpc("debug.mouse", {"target": "page", "button": button, "x": pad[0], "y": pad[1]})
        time.sleep(1.0)  # test harness: the click's events reach the page through the host, if at all
        events = page("JSON.stringify(window.__mouse)")
        seen = json.loads(events) if isinstance(events, str) else None
        result = {"click": clicked, "events": seen}
        if not isinstance(clicked, dict) or clicked.get("error"):
            result["error"] = "debug.mouse page click failed"
            if button != "middle":
                result["pass"] = False
        elif seen is None:
            result["error"] = "the page's events could not be read"
            if button != "middle":
                result["pass"] = False
        elif button == "middle":
            result["auxclick"] = any(e.get("type") == "auxclick" and e.get("button") == 1 for e in seen)
        else:
            left = [e for e in seen if e.get("button") == 0]
            result["left_events"] = left
            result["pass"] = not left
            if not seen:
                result["note"] = "nothing reached the page: the host sends kBack and kForward from p01-process-054b"
        row[button] = result

    for gesture in ("pinch", "smart_magnify"):
        page("window.__mouse = []")
        before = page("visualViewport.scale")
        sent = rpc("debug.mouse", {"action": gesture, "target": "page", "x": pad[0], "y": pad[1],
                                   **({"scale": 1.5} if gesture == "pinch" else {})})
        time.sleep(1.0)  # test harness: the gesture, if dispatched, zooms within a frame or two
        after = page("visualViewport.scale")
        events = page("JSON.stringify(window.__mouse)")
        wheel = any(e.get("type") == "pinch-wheel" for e in (json.loads(events) if isinstance(events, str) else []))
        result = {"sent": sent, "scale_before": before, "scale_after": after, "ctrl_wheel": wheel}
        if not isinstance(sent, dict) or sent.get("error") or not sent.get("frames"):
            result.update({"error": "the page view sent no gesture frame", "pass": False})
        elif before != after or wheel:
            result["dispatched"] = True
            result["pass"] = True
        else:
            result["not_dispatched"] = "the host drops kGesture until the fork sends PinchEvent and SmartMagnifyEvent (p01-process-054b)"
        row[gesture] = result

    row["pass"] = all(row.get(name, {}).get("pass") is not False for name in ("tooltip", "back", "forward", "pinch", "smart_magnify"))
    RESULT["modes"]["mouse"] = row
    return True


def run_swipe(rpc, url):
    """The swipe row (task 234): a real two-finger swipe (pointer-probe swipe) that drags the content right, over a
    page that does not scroll sideways (Back must happen) and over one scrolled to the middle of its sideways
    scroller (the page scrolls, no navigation), with the page probes and wheel acks each gesture took."""
    probe = build_pointer_probe()
    if not probe:
        RESULT["modes"]["swipe"] = {"error": "pointer-probe.swift did not build (xcrun swiftc)"}
        return False
    page, title_is = tab_page(rpc)

    def swipe_stats():
        return (rpc("debug.cef") or {}).get("swipe") or {}

    row = {}
    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url + "?flat-1"}, "focus": True,
                                "origin": "script"}, timeout=120)
    if not title_is("swipe flat 1"):
        RESULT["modes"]["swipe"] = {"error": f"the swipe probe never loaded: {json.dumps(opened)[:200]}"}
        return False
    backend = rpc("debug.cef") or {}
    row["backend"] = backend.get("backend")
    center = focused_pane_center(rpc, probe)
    if not center:
        RESULT["modes"]["swipe"] = {"error": "no pane, window or screen geometry (debug.pane_chrome, debug.window_list)"}
        return False

    def gesture(variant, expect_title):
        before = swipe_stats()
        left_before = page("window.__scrollLeft()")
        swiped = subprocess.run([probe, "swipe", f"{center[0]:.0f}", f"{center[1]:.0f}", "12", "24"],
                                capture_output=True, text=True, timeout=30)
        back = title_is(expect_title) if expect_title else None
        time.sleep(0.5)  # a late Back would show here; the wide case must still be on its page
        title = page("document.title")
        after = swipe_stats()
        delta = {key: (after.get(key) or 0) - (before.get(key) or 0) for key in ("gestures", "probes", "acks", "swipes")}
        return {"variant": variant, "probe": swiped.stdout.strip() or swiped.stderr.strip()[:200], "title": title,
                "back": bool(back), "scroll_left": [left_before, page("window.__scrollLeft()")], "swipe": delta,
                "host_acks_wheels": after.get("host_acks_wheels")}

    page(f"location.href = {json.dumps(url + '?flat-2')}")
    if not title_is("swipe flat 2"):
        RESULT["modes"]["swipe"] = {"error": "the second flat page never loaded"}
        return False
    flat = gesture("flat", "swipe flat 1")
    flat["pass"] = flat["back"] and flat["title"] == "swipe flat 1"
    row["flat"] = flat

    page(f"location.href = {json.dumps(url + '?wide-1')}")
    title_is("swipe wide 1")
    page(f"location.href = {json.dumps(url + '?wide-2')}")
    if not title_is("swipe wide 2"):
        row["wide"] = {"error": "the wide pages never loaded", "pass": False}
    else:
        wide = gesture("wide", None)
        left = wide["scroll_left"]
        wide["pass"] = wide["title"] == "swipe wide 2" and None not in left and left[1] < left[0]
        row["wide"] = wide
    gestures = [r for r in (row.get("flat"), row.get("wide")) if r and "swipe" in r]
    acks_on = any(r.get("host_acks_wheels") for r in gestures)
    row["host_acks_wheels"] = acks_on
    row["probes_per_gesture"] = max((r["swipe"]["probes"] / max(r["swipe"]["gestures"], 1) for r in gestures), default=None)
    if not gestures or all(r["swipe"]["gestures"] == 0 for r in gestures):
        row["not_measurable"] = ("no gesture reached the swipe: in host mode the page view takes no scrolls before the "
                                 "host input route (p01-process-042); in process, the posted HID gesture never reached "
                                 "a page window")
    else:
        zero_probes = not acks_on or row["probes_per_gesture"] == 0
        row["pass"] = bool(row["flat"].get("pass") and row.get("wide", {}).get("pass") and zero_probes)
    RESULT["modes"]["swipe"] = row
    return True


def tab_page(rpc):
    """`page(script)`, the value of `script` in the tab of the first eval that names one (the focused tab), and
    `title_is(title)`, true once that tab has loaded a page with that title (20 s)."""
    tab = {}

    def page(script):
        reply = rpc("browser.page.eval", {"script": script, **({"tab": tab["tab"]} if tab.get("tab") else {})}, timeout=20)
        if not isinstance(reply, dict) or "error" in reply:
            return None
        tab.setdefault("tab", reply.get("tab"))
        return reply.get("value")

    def title_is(title):
        return wait(lambda: page(f"document.readyState === 'complete' && document.title === {json.dumps(title)}"), 20, 0.2)

    return page, title_is


def focused_pane_center(rpc, probe):
    """The focused pane's center in screen points from the top left (the page view fills its border), or None
    without pane, window or screen geometry."""
    border = focused_pane_border(rpc)
    window = next((w for w in (rpc("debug.window_list") or {}).get("windows") or []
                   if w.get("kind") == "main" and w.get("visible")), None)
    screen_h = subprocess.run([probe, "screen"], capture_output=True, text=True, timeout=20).stdout.strip()
    if not border or not window or not screen_h:
        return None
    frame = window.get("frame") or {}
    return (frame.get("x", 0) + border[0] + border[2] / 2,
            float(screen_h) - (frame.get("y", 0) + frame.get("height", 0)) + border[1] + border[3] / 2)


def run_pinch(rpc, url):
    """The pinch row (task 234): a real trackpad pinch (pointer-probe magnify) over a Chromium tab must zoom the page
    (its visual viewport's scale grows, as Chrome's pinch does) and must not become a swipe, now that the hosted page
    view hands each scroll to the swipe first."""
    probe = build_pointer_probe()
    if not probe:
        RESULT["modes"]["pinch"] = {"error": "pointer-probe.swift did not build (xcrun swiftc)"}
        return False
    page, title_is = tab_page(rpc)

    def swipe_stats():
        return (rpc("debug.cef") or {}).get("swipe") or {}

    opened = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True,
                                "origin": "script"}, timeout=120)
    if not title_is("pinch probe"):
        RESULT["modes"]["pinch"] = {"error": f"the pinch probe never loaded: {json.dumps(opened)[:200]}"}
        return False
    row = {"backend": (rpc("debug.cef") or {}).get("backend")}
    center = focused_pane_center(rpc, probe)
    if not center:
        RESULT["modes"]["pinch"] = {"error": "no pane, window or screen geometry (debug.pane_chrome, debug.window_list)"}
        return False
    before = page("window.__zoom()") or {}
    stats_before = swipe_stats()
    pinched = subprocess.run([probe, "magnify", f"{center[0]:.0f}", f"{center[1]:.0f}", "0.05", "20"],
                             capture_output=True, text=True, timeout=30)
    start = before.get("scale") or 1
    wait(lambda: ((page("window.__zoom()") or {}).get("scale") or start) > start + 0.05, 3, 0.1)
    time.sleep(0.5)  # a swipe or navigation the pinch set off would show here
    after = page("window.__zoom()") or {}
    stats_after = swipe_stats()
    row.update({
        "probe": pinched.stdout.strip() or pinched.stderr.strip()[:200],
        "before": before, "after": after, "title": page("document.title"),
        "swipe": {key: (stats_after.get(key) or 0) - (stats_before.get(key) or 0) for key in ("gestures", "swipes")},
    })
    zoomed = (after.get("scale") or start) > start + 0.05
    reached = zoomed or (after.get("ctrlWheels") or 0) > (before.get("ctrlWheels") or 0)
    row["zoomed"] = zoomed
    if not reached and row["backend"] == "host":
        row["not_measurable"] = ("the pinch never reached the page: in host mode the page view sends the host no "
                                 "magnify before the host input route (p01-process-042) and its PinchEvent "
                                 "(p01-process-054)")
    else:
        row["pass"] = bool(zoomed and row["title"] == "pinch probe" and row["swipe"]["swipes"] == 0
                           and row["swipe"]["gestures"] == 0)
        if not reached:
            row["error"] = "the posted pinch never reached the page (no ctrl+wheel, no zoom)"
    RESULT["modes"]["pinch"] = row
    return True


ROW_LIMIT_S = 90  # one row of the input set; a prompt on the console or a stuck reply ends the row, not the step


def bounded(rows, name, run):
    """Runs one row with ROW_LIMIT_S: a row past it is recorded as timed out and the rest go on. Rows talk to the
    app over its socket (each call has its own timeout) and to LaunchServices, so a row cannot block forever; the
    limit bounds the sum of its waits."""
    import threading
    result = {}

    def body():
        try:
            result["value"] = run()
        except Exception as error:  # noqa: BLE001 - a row's failure is that row's result
            result["value"] = {"error": f"{type(error).__name__}: {error}"[:300], "pass": False}
    thread = threading.Thread(target=body, daemon=True)
    thread.start()
    thread.join(ROW_LIMIT_S)
    rows[name] = result.get("value") if not thread.is_alive() else {"error": f"timed out after {ROW_LIMIT_S} s", "pass": False}


def input_rows(rpc, url, title, click_point, borders, host_pid):
    """The host page's input paths, each a pass/fail row (the page's focus is the fork's embedder-active state on fork
    API 30, DevTools focus emulation below it; no host window is ever key): typing and the caret, focus and blur when cmux's focus moves out and back, copy and paste through
    cmux's Edit menu, and Chromium's own native UI (context menu, <select>, alert, file picker) with the frontmost
    pid and the host's activation counters. IME, find (Cmd-F) and drag are not forwarded by the prototype (slice 2,
    section 4 of the design): rows say so instead of testing (find runs in --find, on a host-backed Chromium tab)."""
    rows = {}
    page_state = lambda: probe_stats(title()) or {}
    counters = lambda: rpc("debug.chromium_host.measure", {"op": "input"}) or {}

    def front_ok():
        # The running host's pid: native rows restart it.
        return front_pid() != ((rpc("debug.chromium_host") or {}).get("pid") or host_pid)

    # 1. Typing and the caret: the field holds what was typed, has the focus, and the caret is at its end.
    rpc("debug.mouse", click_point("t"))
    before = page_state().get("field") or 0
    for _ in range(5):
        rpc("debug.key", {"key": "a"})
    after = wait(lambda: (lambda st: st if (st.get("field") or 0) >= before + 5 else None)(page_state()), 5) or page_state()
    rows["typing"] = {"field_before": before, "field_after": after.get("field"), "active": after.get("active"),
                      "has_focus": after.get("has_focus"), "caret": after.get("caret")}
    rows["typing"]["pass"] = (after.get("field") or 0) >= before + 5 and after.get("active") == "t" and \
        after.get("has_focus") is True and after.get("caret") == after.get("field")

    # 2. Focus out of the page (a click on the left pane) and back (a click on the page): one blur, one focus.
    # run_helper opened the page with focus before it was hosted, so on fork API 30 that first focus went through
    # emulation: has_focus_out must still be False once the page is detached (the host turns emulation off).
    start = page_state()
    left = min(borders, key=lambda b: b[0])
    rpc("debug.mouse", {"x": left[0] + left[2] / 2, "y": left[1] + left[3] / 2})
    out = wait(lambda: (lambda st: st if (st.get("blur") or 0) > (start.get("blur") or 0) else None)(page_state()), 5) or page_state()
    rpc("debug.mouse", click_point("t"))
    back = wait(lambda: (lambda st: st if (st.get("focus") or 0) > (out.get("focus") or 0) else None)(page_state()), 5) or page_state()
    rows["focus_moves"] = {"blur": (out.get("blur") or 0) - (start.get("blur") or 0),
                           "focus": (back.get("focus") or 0) - (out.get("focus") or 0),
                           "has_focus_out": out.get("has_focus"), "has_focus_back": back.get("has_focus")}
    rows["focus_moves"]["pass"] = rows["focus_moves"]["blur"] == 1 and rows["focus_moves"]["focus"] == 1 and \
        out.get("has_focus") is False and back.get("has_focus") is True

    # 3. Copy and paste through cmux's Edit menu (Cmd-A, Cmd-C, Delete, Cmd-V): the field's text comes back.
    typed = page_state().get("field") or 0
    rpc("debug.key", {"key": "a", "modifiers": ["cmd"]})
    rpc("debug.key", {"key": "c", "modifiers": ["cmd"]})
    rpc("debug.key", {"key": "delete"})
    cleared = wait(lambda: (lambda st: st if st.get("field") == 0 else None)(page_state()), 5) or page_state()
    rpc("debug.key", {"key": "v", "modifiers": ["cmd"]})
    pasted = wait(lambda: (lambda st: st if st.get("field") == typed else None)(page_state()), 5) or page_state()
    rows["copy_paste"] = {"typed": typed, "cleared": cleared.get("field"), "pasted": pasted.get("field")}
    rows["copy_paste"]["pass"] = typed > 0 and cleared.get("field") == 0 and pasted.get("field") == typed

    # 4. Chromium's native UI from the host process. Each one in a fresh host (close, open), so a UI that stays
    # open (a menu, a modal panel) cannot leak into the next row.
    def native_row(name, action):
        start_counters = counters()
        action()
        time.sleep(1.5)  # test harness: the UI opens (a menu, a dialog, a panel)
        end_counters = counters()
        out = {"front_is_host": not front_ok(), "page": {k: page_state().get(k) for k in ("dialogs", "menus")},
               "activations": (end_counters.get("activations") or 0) - (start_counters.get("activations") or 0),
               "key_windows": (end_counters.get("key_windows") or 0) - (start_counters.get("key_windows") or 0)}
        out["pass"] = not out["front_is_host"] and out["activations"] == 0 and out["key_windows"] == 0
        rpc("debug.chromium_host", {"op": "close"})
        rpc("debug.chromium_host", {"op": "open", "url": url, "focus": True})
        wait(lambda: (lambda r: r if r.get("shown_context_id") and (r.get("title") or "").startswith("probe ") else None)(
            rpc("debug.chromium_host") or {}), 60, 0.25)
        return out

    def native(name, action):
        bounded(rows, name, lambda: native_row(name, action))

    native("context_menu", lambda: rpc("debug.mouse", {**click_point("t"), "button": "right"}))
    native("select_popup", lambda: rpc("debug.mouse", click_point("s")))
    native("alert", lambda: rpc("debug.mouse", click_point("al")))
    native("file_picker", lambda: rpc("debug.mouse", click_point("f")))
    rows["not_forwarded"] = {"ime": "no NSTextInputClient in ChromiumHostPageView; windowed Ime* are DCHECK(false) in CEF (slice 2)",
                             "find": "the prototype page has no find; --find runs it on a host-backed Chromium tab",
                             "drag": "drag and drop is not forwarded (slice 4)"}
    return rows


IME_STATS = ("changes", "pushes", "frames", "unsent", "watches")


GEOMETRY_STATS = ("frames", "applied", "unchanged", "unplaced")


def geometry_row(rpc, steps=60):
    """Geometry frames per moving page per display frame (task p01-process-053). The host places a page's window only
    when its geometry changed (HostContext::PlaceFrame), so a page that moves every frame costs at most one placement
    per frame. The window moves 1 point per display frame for `steps` frames, then grows 1 point per frame for
    `steps` frames (debug.window_frame: one programmatic setFrame each, as a display change or Rectangle does); the
    host's counters (kOpGeometryStats: frames, applied, unchanged, unplaced) are read before and after through
    `debug.chromium_host.measure {op: geometry}`. Pass: placements per display frame <= 1 for the one moving page, and
    no geometry the host could not place. Until cmux's host session asks the host for them, the row says the counters
    are unavailable instead of passing."""
    counters = lambda: rpc("debug.chromium_host.measure", {"op": "geometry"}) or {}
    before = counters()
    if not all(isinstance(before.get(key), (int, float)) for key in GEOMETRY_STATS):
        return {"unavailable": "the app does not answer debug.chromium_host.measure geometry", "reply": before,
                "pass": None}
    start = (rpc("debug.window_frame") or {}).get("frame")
    if not (isinstance(start, list) and len(start) == 4):
        return {"error": "no window frame (debug.window_frame)", "pass": False}
    hz = main_display_hz() or 60.0
    x, y, w, h = start
    began = time.monotonic()
    for i in range(1, steps + 1):
        rpc("debug.window_frame", {"frame": [x + i, y, w, h]})
        time.sleep(1 / hz)  # test harness: one move per display frame
    for i in range(1, steps + 1):
        rpc("debug.window_frame", {"frame": [x + steps, y, w + i, h]})
        time.sleep(1 / hz)  # test harness: one resize per display frame
    time.sleep(0.2)  # test harness: the last geometry reaches the host
    elapsed = time.monotonic() - began
    after = counters()
    rpc("debug.window_frame", {"frame": start})
    delta = {key: (after.get(key) or 0) - (before.get(key) or 0) for key in GEOMETRY_STATS}
    display_frames = max(1, round(elapsed * hz))
    row = {"steps": 2 * steps, "display_frames": display_frames, "hz": hz, **delta}
    row["applied_per_frame"] = round(delta["applied"] / display_frames, 3)
    row["frames_per_frame"] = round(delta["frames"] / display_frames, 3)
    row["pass"] = delta["applied"] > 0 and delta["applied"] <= display_frames and delta["unplaced"] == 0
    return row


def ime_row(rpc, title, click_point):
    """--ime: TEXT_INPUT_STATE pushes per keystroke (task p01-process-044). The host folds the fork's text input
    notifications of one display frame into one push, so a keystroke whose renderer notifications land in two frames
    costs two; this row measures it. Keys go into the focused field one per 1/15 s (several frames apart, so two
    keys never share a frame); the host's counters (kOpTextInputStats: changes, pushes, frames, unsent, watches)
    are read before and after through `debug.chromium_host.measure {op: text_input}`. Pass: pushes per key <= 1,
    no unsent push. Until cmux's host session asks the host for them (the remote shim's text input watch, tasks 014b
    and 043), the row says the counters are unavailable instead of passing."""
    counters = lambda: rpc("debug.chromium_host.measure", {"op": "text_input"}) or {}
    before = counters()
    if not all(isinstance(before.get(key), (int, float)) for key in IME_STATS):
        return {"unavailable": "the app does not answer debug.chromium_host.measure text_input", "reply": before,
                "pass": None}
    stats = lambda: probe_stats(title()) or {}
    rpc("debug.mouse", click_point("t"))
    start_field = stats().get("field") or 0
    for _ in range(opts.count):
        rpc("debug.key", {"key": "a"})
        time.sleep(1 / 15)  # test harness: keys several frames apart
    wait(lambda: (stats().get("field") or 0) >= start_field + opts.count, 10)
    time.sleep(0.2)  # test harness: the last key's frame flushes
    after = counters()
    delta = {key: (after.get(key) or 0) - (before.get(key) or 0) for key in IME_STATS if key != "watches"}
    keys = (stats().get("field") or 0) - start_field
    row = {"keys": keys, "watches": after.get("watches"), **delta}
    row["pushes_per_key"] = round(delta["pushes"] / keys, 3) if keys else None
    row["changes_per_key"] = round(delta["changes"] / keys, 3) if keys else None
    row["pass"] = bool(keys) and delta["pushes"] <= keys and delta["unsent"] == 0
    return row


def secure_input_pid():
    """The pid that holds the system's secure event input (IORegistry kCGSSessionSecureInputPID), 0 for none, None
    when ioreg cannot say."""
    try:
        done = subprocess.run(["/usr/sbin/ioreg", "-l", "-w", "0", "-d", "1"], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None
    import re
    # The root's IOConsoleUsers holds it, all on one line: ({"kCGSSessionSecureInputPID"=123, ...}).
    found = re.search(r'"kCGSSessionSecureInputPID"\s*=\s*(\d+)', done.stdout)
    if found:
        return int(found.group(1))
    return 0 if done.returncode == 0 else None


def password_row(rpc, click_point):
    """--ime: secure event input while the probe's password field has focus (task p01-process-230). In host mode
    cmux is the frontmost process, so cmux's page view turns it on, as Chrome's browser process holds a
    ScopedPasswordInputEnabler (ui/base/cocoa/secure_password_input.mm). A click into #pw must turn on
    `password_input` of debug.chromium_host, a click back into #t must turn it off; where ioreg shows the system's
    secure input pid it must be cmux's while on and not cmux's after. Until the app reports `password_input` the row
    says it is unavailable instead of passing."""
    state = lambda: rpc("debug.chromium_host") or {}
    first = state()
    if "password_input" not in first:
        return {"unavailable": "debug.chromium_host has no password_input", "pass": None}
    app_pid = first.get("app_pid")
    rpc("debug.mouse", click_point("pw"))
    focused = bool(wait(lambda: state().get("password_input") is True, 5))
    pid_focused = secure_input_pid()
    rpc("debug.mouse", click_point("t"))
    blurred = bool(wait(lambda: state().get("password_input") is False, 5))
    pid_blurred = secure_input_pid()
    row = {"focused": focused, "blurred": blurred, "app_pid": app_pid, "secure_pid_focused": pid_focused,
           "secure_pid_blurred": pid_blurred}
    system_ok = True
    if app_pid and pid_focused is not None and pid_blurred is not None:
        system_ok = pid_focused == app_pid and pid_blurred != app_pid
    row["pass"] = focused and blurred and system_ok
    return row


def run_lifetime(app, url):
    """close, SIGSTOP + close and SIGKILL to cmux (the last row: cmux is gone after it)."""
    rpc = app.rpc
    row = {}
    RESULT["modes"]["helper"]["lifetime"] = row

    def shown_host(not_pid):
        return wait(lambda: (lambda r: r if r.get("shown_context_id") and r.get("pid") and r.get("pid") != not_pid else None)(
            rpc("debug.chromium_host") or {}), 90, 0.25)

    def timed_end(pid, limit):
        start = time.monotonic()
        gone = wait(lambda: pid_gone(pid), limit, 0.05)
        return bool(gone), round(time.monotonic() - start, 2)

    # 1. close: quit over the wire, the host ends by itself and is reaped; no restart.
    state = rpc("debug.chromium_host") or {}
    pid, restarts = state.get("pid"), state.get("restarts")
    rpc("debug.chromium_host", {"op": "close"})
    ended, seconds = timed_end(pid, QUIT_LIMIT_S + 10)
    time.sleep(1)  # test harness: a wrong restart would have started by now
    after = rpc("debug.chromium_host") or {}
    row["close"] = {"pid": pid, "ended": ended, "seconds": seconds, "phase": after.get("phase"),
                    "restarts_before": restarts, "restarts_after": after.get("restarts")}
    row["close"]["pass"] = ended and seconds < QUIT_LIMIT_S and after.get("phase") == "idle" and after.get("restarts") == restarts
    # Keys of cmux's defaults domain that changed while the host ran, less the keys cmux itself changed from its
    # launch to the host's open (the same cmux, no host): any other key is the host's (or cmux's for another
    # reason; the names say which).
    host_ran = defaults_diff(DEFAULTS.get("before"), defaults_snapshot(app_bundle_id()))
    cmux_alone = defaults_diff(DEFAULTS.get("launch"), DEFAULTS.get("before"))
    row_defaults = {"while_host_ran": host_ran, "cmux_alone": cmux_alone}
    if host_ran is not None and cmux_alone is not None:
        own = set(cmux_alone["added"]) | set(cmux_alone["changed"]) | set(cmux_alone["removed"])
        unexplained = sorted((set(host_ran["added"]) | set(host_ran["changed"]) | set(host_ran["removed"])) - own)
        row_defaults["unexplained"] = unexplained
        row_defaults["pass"] = not unexplained
    RESULT["modes"]["helper"]["defaults"] = row_defaults

    # 2. a host whose UI thread never reads quit (SIGSTOP; a child of the cmux this bench started) is SIGKILLed at the limit.
    rpc("debug.chromium_host", {"op": "open", "url": url})  # over the focused pane
    state = shown_host(pid)
    if not state:
        row["stop_close"] = {"error": "no host after the reopen", "state": rpc("debug.chromium_host")}
        return False
    pid = state["pid"]
    os.kill(pid, signal.SIGSTOP)
    rpc("debug.chromium_host", {"op": "close"})
    ended, seconds = timed_end(pid, QUIT_LIMIT_S + 15)
    row["stop_close"] = {"pid": pid, "ended": ended, "seconds": seconds,
                         "exits": (rpc("debug.chromium_host") or {}).get("exits")}
    row["stop_close"]["pass"] = ended and QUIT_LIMIT_S - 1 <= seconds <= QUIT_LIMIT_S + 5

    # 3. A Quit AppleEvent to cmux's bundle id (the Dock's Quit): cmux must get it, not the host (the same bundle
    # id); then the host reads EOF and ends itself within the limit. When cmux does not quit (a confirmation, or
    # Automation not allowed for this bench), SIGKILL to cmux checks the EOF end instead.
    rpc("debug.chromium_host", {"op": "open", "url": url})
    state = shown_host(pid)
    if not state:
        row["cmux_quit"] = {"error": "no host after the second reopen", "state": rpc("debug.chromium_host")}
        return False
    pid = state["pid"]
    # osascript sends the event straight to the app (no System Events), bounded: an Automation prompt on the
    # console must not cost the step's hang limit.
    try:
        quit_event = subprocess.run(["/usr/bin/osascript", "-e", f'with timeout of 10 seconds\ntell application id "{app_bundle_id()}" to quit\nend timeout'],
                                    capture_output=True, text=True, timeout=20)
        ae_exit, ae_err = quit_event.returncode, quit_event.stderr.strip()[:200]
    except subprocess.TimeoutExpired:
        ae_exit, ae_err = None, "timed out after 20 s (an Automation prompt?)"
    try:
        app.process.wait(20)
        cmux_quit = True
    except subprocess.TimeoutExpired:
        cmux_quit = False
    row["ae_quit"] = {"osascript_exit": ae_exit, "stderr": ae_err, "cmux_quit": cmux_quit,
                      "host_ended_first": pid_gone(pid) and not cmux_quit}
    if ae_exit != 0 and not cmux_quit:
        row["ae_quit"]["not_measurable"] = "the Quit AppleEvent did not reach cmux (Automation not allowed for this account?)"
    else:
        row["ae_quit"]["pass"] = cmux_quit and not row["ae_quit"]["host_ended_first"]
    if not cmux_quit:
        app.process.kill()  # the cmux process this bench started
        app.process.wait(30)
    ended, seconds = timed_end(pid, QUIT_LIMIT_S + 15)
    row["cmux_killed" if not cmux_quit else "cmux_quit"] = {"pid": pid, "ended": ended, "seconds": seconds,
                                                             "pass": ended and seconds <= QUIT_LIMIT_S + 1}
    if not ended:
        os.kill(pid, signal.SIGKILL)  # leave no host behind on the measure host (a grandchild of this bench)
    return True


if __name__ == "__main__":
    opts = parse()
    sys.exit(main())
