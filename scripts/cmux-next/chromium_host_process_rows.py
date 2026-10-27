"""The process rows of chromium-host-bench.py (task p01-process-160): what happens to Chromium pages in the Chromium
Host when a process dies, hangs or is replaced, and the input and display rows the done checks name
(plans/cmux-next/chrome-parity/p01-process.md section 5). Each row writes its checks (chromium_host_rows.py), so each
prints PASS or FAIL with its number.

Every row drives a Chromium tab of the app's backend (`openBrowser.chromium`) and needs that backend to be the
Chromium Host (`debug.cef` backend `host`); in process, every check of the row is not measured, so it fails.

  kill-host       done check 4. A tab is given typed text and a scroll offset; the host gets each of --signals in
                  turn (TRAP, SEGV, ABRT, KILL). Per signal: cmux's pid is unchanged; the crash page shows within 1
                  frame of the exit; the signaled host ends and a new one has the tab back at its URL with its text
                  and scroll within 2000 ms; debug.crashes has a record naming the signal, with a minidump of
                  symbolized frames and no URL or title. The 4th
                  crash within 5 minutes starts no host and leaves the crash page's Reload. Then a host started by
                  Reload and ended before its context is up shows "cannot start" and is not retried. While the host
                  dies, keys go to a terminal (the typing probe, CMUX_NEXT_TYPING_PROBE): its key-to-frame p99, and
                  no key lost.
  helper-kill     SIGKILL to the host's GPU helper, then to every renderer: one debug.crashes record each, the
                  host and cmux keep running, the page answers again after the GPU loss and shows its sad tab after
                  the renderer's.
  hang            done check 11, --hang MS: the host's UI thread is blocked for MS (`debug.cef` host_block_ms, or
                  SIGSTOP when the build has no such hook) while a key waits: cmux's banner at 2000 +/- 100 ms after
                  the key, cmux's main-turn p99 <= 4 ms meanwhile, the banner gone after; with cmux hidden a key to
                  the stopped host arms no hang timer (the visible key's armed timer is the control); the host's own
                  hang shows in debug.hangs tagged as the host's.
  renderer-hang   done check 11: `for (;;) {}` in a page gives the tab's own unresponsive prompt and never the host
                  banner.
  ime             done check 8: a dead key composes and commits; the host's firstRect reads stay under 0.1 ms and
                  it asks cmux for no synchronous IME state; secure event input is on while a password field has
                  focus and off after blur, a host crash and a tab close. Kotoeri (selected by the bench) composes
                  `nihon` and commits it; the emoji picker and dictation have no bench driver: those checks fail
                  naming the task whose input path they exercise.
  ax              done check 9: the tab's page view has remote accessibility children (`page_accessibility`
                  connected) and the probe's h1 is readable through the Accessibility API.
  ordering        done check 7: --ordering-keys keys interleaved with focus changes between two tabs, dead-key
                  commits and window resizes; each tab's field must hold exactly the keys sent while it was active,
                  in order, IME text in send order.
  visibility      done check 12: a tab in a workspace that is hidden, and in a hidden app, has
                  visibilityState hidden and draws 0 animation frames per second; it draws again when shown.
  stall           done check 5, --stall MS/EVERY: the page animates at the display's rate with 0 long frames while
                  cmux's main thread stalls MS every EVERY ms; the same after --stall-idle-minutes with cmux made
                  frontmost before the idle and still frontmost after it (no App Nap of the host).
  quit            task 087: Cmd-Q with a page that has a beforeunload handler asks; Stay keeps cmux, the host and
                  the tab.
  runtime-update  task 087: a staged Chromium runtime (`debug.cef` stage_runtime_update) is used after the host's
                  idle restart, and the tab is back at its URL.
  kill-app        done check 20: SIGKILL to cmux with browserHost.survivesAppCrash on, then a relaunch: the host
                  is the same process, the page was not reloaded (performance.timeOrigin unchanged), and every
                  terminal screen shows within 300 ms of the first frame.

What the rows read that a later task adds (a missing field makes its check not measured, naming the task):
`debug.cef` `host` {crash_page, exit_ns, crash_page_ns (CLOCK_UPTIME_RAW ns; 082), phase (cannot start: 081),
context_initialized (081), hang_banner, hang_timer_armed (084), first_rect_max_ms (043), runtime_version (087)};
`debug.cef` params host_block_ms (084) and stage_runtime_update (087); `debug.crashes` chromium records' `minidump`
{symbolized_frames} (226); `debug.hangs` records' `process` "chromium-host" (084); the relaunch's
`terminal_screens_shown` launch mark (152). `ime_sync_requests` comes from `debug.chromium_host` (043).
"""
import ctypes
import ctypes.util
import json
import signal
import threading

import chromium_host_native_ui_dialogs as dialogs
import chromium_host_rows as rows
from chromium_host_rows import at_most, check, holds, unmeasured, within

# In run order. The host-ending rows come last: kill-app relaunches cmux, and kill-host spends the host's restart
# budget (its last kill and the cannot-start check leave no host for a later row).
ROWS = ("ime", "ax", "visibility", "ordering", "stall", "hang", "renderer-hang", "helper-kill", "runtime-update",
        "quit", "kill-app", "kill-host")
DEFAULT_SIGNALS = ("TRAP", "SEGV", "ABRT", "KILL")
# Each row's own limit (the bench's bounded()): kill-host waits out four restarts and the budget, ordering sends
# 10,000 keys, stall idles --stall-idle-minutes (added by the bench).
ROW_LIMIT_S = {"kill-host": 240 + int(rows.RESTART_WINDOW_S), "ordering": 900, "hang": 120, "renderer-hang": 120, "kill-app": 300,
               "runtime-update": 180, "stall": 120}

RESTORE_TEXT = "kill"
RESTORE_SCROLL = 1200
RESTORE_POLL_S = 0.025
RESTORE_GRACE_S = 8.0  # past the 2000 ms limit, so a late restore is measured, not lost
BUDGET_SETTLE_S = 5.0
CANNOT_START_SETTLE_S = 3.0
RECORD_WAIT_S = 10.0
HIDDEN_HANG_S = 3.0
SAMPLE_S = 1.0
RENDERER_HANG_DEADLINE_S = 45.0  # Chromium's 15 s hang delay plus its ping (chromium_host_native_ui_dialogs)
RENDERER_HANG_PROMPT_LIMIT_S = rows.RENDERER_HANG_PROMPT_S + 5.0
TYPING_INTERVAL_S = 1 / 30
ORDER_FOCUS_EVERY, ORDER_IME_EVERY, ORDER_RESIZE_EVERY = 50, 200, 500
NO_FIELD = "the app does not report {} (task p01-process-{})"

# The tab whose state a restart must give back. `__raf` counts animation frames (the visibility row).
RESTORE_PAGE = """<!doctype html><meta charset=utf-8><title>restore probe</title>
<style>html,body{margin:0;background:#204080;color:#fff;font:16px system-ui}#tall{height:600vh}
#f{position:fixed;left:10%;top:10%;width:50%;font-size:20px}#pw{position:fixed;left:10%;top:25%;width:30%}</style>
<input id=f><input id=pw type=password><div id=tall></div>
<script>window.__raf = 0; (function tick() { window.__raf++; requestAnimationFrame(tick); })();</script>"""
RESTORE_STATE = ("JSON.stringify({search: location.search, field: document.getElementById('f').value, "
                 "scroll: Math.round(scrollY), origin: performance.timeOrigin})")

KOTOERI_SOURCE = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
KOTOERI_KEYS, KOTOERI_COMMIT = "nihon", "にほん"
# Done check 8's input methods the bench has no driver for: each names the task whose path it exercises, so Q6
# gives the row an owner. Both insert through the page view's NSTextInputClient from another process's UI.
NO_IME_DRIVER = {
    "emoji_picker": "no bench driver: the emoji picker is system UI in another process; it inserts through "
                    "insertText: on the page view (task p01-process-043)",
    "dictation": "no bench driver: dictation needs audio input; it inserts through the page view's text input "
                 "(task p01-process-047, 'dictation inserts text')",
}

AX_HEADING = "cmux accessibility probe"
AX_PAGE = f"<!doctype html><meta charset=utf-8><title>ax probe</title><h1>{AX_HEADING}</h1>"

# The ordering row's tab: its field keeps focus, so its value is every key and commit the tab got, in order.
ORDER_PAGE = """<!doctype html><meta charset=utf-8><title>order probe</title>
<input id=f style="position:fixed;inset:10% 10% auto 10%;font-size:20px">
<script>const f = document.getElementById('f'); f.focus(); addEventListener('focus', () => f.focus());</script>"""


class Lab:
    """What the rows touch, injected: the bench builds it over the app, the tests over a fake.

    rpc(method, params=None, timeout=60), wait(check, seconds, step), sleep(seconds), now() (monotonic seconds),
    uptime() (CLOCK_UPTIME_RAW seconds, debug.key's timestamp), kill(pid, signal), pid_gone(pid), host_pid(),
    app_pid(), helpers(host_pid) -> [{pid, type}], typing_rows() -> the typing probe's CSV rows,
    focus_terminal() -> True when a terminal pane has the focus, secure_pid() -> the secure event input's pid (0 none,
    None unreadable), ax_text(pid, text) -> True/False, None without an Accessibility grant, front() -> frontmost pid,
    write_page(name, html) -> its file URL, stall_pace(ms, every_ms) -> stall_row's dict, relaunch() -> SIGKILL to
    cmux and a relaunch that adopts the surviving host: ``relaunch_timings``' {first_frame_ms, terminal_screens_ms}
    or {error}, activate() -> {activated, error} (cmux made frontmost), input_source(id) -> the input source id
    selected before (``select_input_source``) or None, hz (the display's refresh rate), host_deaths (now() of each
    host end the run caused before and during the rows: kill-host waits out the restart window after the last)."""

    def __init__(self, **parts):
        self.host_deaths = []
        self.__dict__.update(parts)


def failed(number, row, reason, **fields):
    return {"error": reason, **fields, "checks": [unmeasured(number, row, "pass", reason)]}


def cef(lab):
    return lab.rpc("debug.cef") or {}


def host_state(lab):
    return cef(lab).get("host") or {}


def field_check(number, row, name, state, key, task, judge):
    """holds() on `judge(state[key])`, not measured when the app does not report `key`."""
    if key not in state:
        return unmeasured(number, row, name, NO_FIELD.format(key, task))
    return holds(number, row, name, judge(state[key]), state[key])


def require_host(lab, row, number):
    backend = cef(lab).get("backend")
    if backend == "host":
        return None
    return failed(number, row, f"the Chromium backend is {backend!r}, not the Chromium Host (browserHost.helper off, "
                               "a Release build, or no host backend in this build)")


def open_tab(lab, url, title, query):
    """A focused Chromium tab on `url`; its tab id once it shows `title` with `query`, else None."""
    lab.rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"},
            timeout=120)
    ready = (f"document.readyState === 'complete' && document.title === {json.dumps(title)} "
             f"&& location.search === {json.dumps(query)}")

    def loaded():
        reply = lab.rpc("browser.page.eval", {"script": ready}, timeout=20)
        return reply.get("tab") if isinstance(reply, dict) and reply.get("value") is True else None
    return lab.wait(loaded, 60, 0.25)


def page(lab, tab, script):
    reply = lab.rpc("browser.page.eval", {"script": script, "tab": tab}, timeout=20)
    return reply.get("value") if isinstance(reply, dict) and "error" not in reply else None


def page_json(lab, tab, script):
    value = page(lab, tab, script)
    try:
        return json.loads(value) if isinstance(value, str) else None
    except ValueError:
        return None


def center(lab, tab, element):
    rect = page(lab, tab, f"(() => {{ const r = document.getElementById('{element}').getBoundingClientRect(); "
                          "return [r.x + r.width / 2, r.y + r.height / 2]; })()")
    return {"x": rect[0], "y": rect[1]} if isinstance(rect, list) and len(rect) == 2 else {}


def click(lab, tab, element):
    lab.rpc("debug.mouse", {"target": "page", **center(lab, tab, element)})


def type_keys(lab, text):
    for key in text:
        lab.rpc("debug.key", {"target": "page", "key": key})


def crash_records(lab):
    return list((lab.rpc("debug.crashes") or {}).get("chromium") or [])


def records_of(lab, before, pid):
    """The debug.crashes records added since `before` for `pid`."""
    return [r for r in crash_records(lab)[len(before):] if r.get("pid") == pid]


def names_signal(record, sig):
    return record.get("code") == int(sig) or sig.name in str(record.get("code_text") or "").upper()


def minidump_ok(record):
    """A minidump with symbolized frames, and nothing in the record that names a page: no URL, no probe title."""
    dump = record.get("minidump") or {}
    text = json.dumps(record)
    return (dump.get("symbolized_frames") or 0) > 0 and not any(
        mark in text for mark in ("file://", "http://", "https://", "restore probe"))


def percentile(values, q):
    """Linear interpolation between closest ranks (scripts/perf-lab/perf_stats.py's pct)."""
    ordered = sorted(values)
    if not ordered:
        return None
    rank = (len(ordered) - 1) * q
    low = int(rank)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (rank - low)


class Typing:
    """Keys into the focused terminal on a thread, each stamped for the typing probe, until stop()."""

    def __init__(self, lab):
        self.lab, self.sent = lab, 0
        self.rows_before = len(lab.typing_rows())
        self.done = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        keys = "abcdefghij"
        while not self.done.is_set():
            self.lab.rpc("debug.key", {"key": keys[self.sent % len(keys)], "timestamp": self.lab.uptime()}, timeout=10)
            self.sent += 1
            self.done.wait(TYPING_INTERVAL_S)  # test harness: one key every two 60 Hz frames

    def stop(self):
        """The typed keys' key-to-frame percentiles, and `lost`: the keys sent with no complete probe row (a press
        whose echo never reached a frame writes complete 0, or no row at all)."""
        self.done.set()
        self.thread.join(15)
        self.lab.sleep(0.5)  # test harness: the last key's frame lands
        written = self.lab.typing_rows()[self.rows_before:]
        self.lab.rpc("debug.key", {"key": "u", "modifiers": ["ctrl"]})  # clears the typed line, after the read
        complete = [r for r in written if str(r.get("complete")).lower() in ("1", "true")]
        frames = [float(r["contents_ms"]) for r in complete if r.get("contents_ms") not in (None, "")]
        return {"keys": self.sent, "rows": len(written), "complete": len(complete), "frames": len(frames),
                "lost": max(0, self.sent - len(complete)), "p50": percentile(frames, 0.5),
                "p99": percentile(frames, 0.99), "max": max(frames) if frames else None}


# ---------------------------------------------------------------- kill-host (done check 4)

def seed_restore(lab, tab):
    """Typed text and a scroll offset in the tab (what PageState must restore, task 093); the state, or None."""
    click(lab, tab, "f")
    page(lab, tab, "document.getElementById('f').value = ''")
    type_keys(lab, RESTORE_TEXT)
    page(lab, tab, f"window.scrollTo(0, {RESTORE_SCROLL})")
    return lab.wait(lambda: (lambda s: s if s and s.get("field") == RESTORE_TEXT and s.get("scroll") == RESTORE_SCROLL
                             else None)(page_json(lab, tab, RESTORE_STATE)), 10, 0.1)


def same_page(state, expected):
    return bool(state) and all(state.get(k) == expected.get(k) for k in ("search", "field", "scroll")) and state


def crash_page_frames(lab, row):
    state = host_state(lab)
    exit_ns, shown_ns = state.get("exit_ns"), state.get("crash_page_ns")
    if not all(isinstance(v, (int, float)) for v in (exit_ns, shown_ns)):
        return unmeasured(4, row, "crash_page_frames", NO_FIELD.format("exit_ns and crash_page_ns", "082"))
    return at_most(4, row, "crash_page_frames", (shown_ns - exit_ns) / 1e9 * lab.hz, rows.KILL_CRASH_PAGE_FRAMES,
                   "frames")


def crash_checks(lab, row, before, pid, sig):
    """The crash record of `pid` naming `sig` (task 085) and its minidump (task 226)."""
    found = lab.wait(lambda: records_of(lab, before, pid), RECORD_WAIT_S, 0.2) or []
    record = found[0] if found else None
    out = [holds(4, row, "crash_record", names_signal(record, sig), record.get("code")) if record else
           unmeasured(4, row, "crash_record", "no debug.crashes record for the host's pid (task p01-process-085)")]
    if record and isinstance(record.get("minidump"), dict):
        out.append(holds(4, row, "minidump", minidump_ok(record)))
    else:
        out.append(unmeasured(4, row, "minidump", "no minidump on the host's crash record (task p01-process-226)"))
    return out, record


def one_kill(lab, tab, expected, name, budget_spent, app_pid):
    row = f"kill-host.{name}"
    sig = getattr(signal, f"SIG{name}")
    pid = lab.host_pid()
    if not pid:
        return {"signal": name, "checks": [unmeasured(4, row, "pass", "no Chromium Host process to signal")]}
    before = crash_records(lab)
    started = lab.now()
    lab.kill(pid, sig)
    lab.host_deaths.append(started)
    out, checks = {"signal": name, "pid": pid}, []
    if budget_spent:
        lab.sleep(BUDGET_SETTLE_S)  # test harness: a restart the budget forbids would have started by now
        again, state = lab.host_pid(), host_state(lab)
        out.update(new_pid=again)
        checks.append(holds(4, row, "no_restart", again is None, again))
        checks.append(field_check(4, row, "reload_shown", state, "crash_page", "082", lambda v: v is True))
    else:
        def restored():
            # Only a new host's page counts: the old one still answers while it is in its crash handler, or when
            # it ignored the signal, and its page is the seeded one.
            new = lab.host_pid()
            if not (lab.pid_gone(pid) and new and new != pid):
                return None
            return same_page(page_json(lab, tab, RESTORE_STATE), expected)
        back = lab.wait(restored, rows.KILL_RESTORE_MS / 1000 + RESTORE_GRACE_S, RESTORE_POLL_S)
        restore_ms = (lab.now() - started) * 1000 if back else None
        new_pid, gone = lab.host_pid(), lab.pid_gone(pid)
        restarted = gone and bool(new_pid) and new_pid != pid
        out.update(restore_ms=restore_ms, new_pid=new_pid, after=back or page_json(lab, tab, RESTORE_STATE))
        checks.append(holds(4, row, "restarted", restarted, new_pid, reason=None if restarted else
                            "no new Chromium Host started" if gone else "the signaled host did not end"))
        why = (f"not back with its URL, text and scroll: {json.dumps(out['after'])[:120]}" if restarted
               else "no new host restored it")
        checks.append(at_most(4, row, "restore_ms", restore_ms, rows.KILL_RESTORE_MS) if back else
                      check(4, row, "restore_ms", False, None, f"<= {rows.KILL_RESTORE_MS:g}", "ms", why))
    checks.append(holds(4, row, "app_pid", lab.app_pid() == app_pid, lab.app_pid()))
    checks.append(crash_page_frames(lab, row))
    records, out["record"] = crash_checks(lab, row, before, pid, sig)
    checks += records
    out["checks"] = checks
    return out


def cannot_start(lab, tab):
    """With the budget spent, Reload starts a host; ended before its context is up, it must not be retried."""
    row = "kill-host.cannot_start"
    lab.rpc("action.run", {"action": "browserReload", "target": f"tab:{tab}", "origin": "script"}, timeout=30)
    pid = lab.wait(lab.host_pid, 10, 0.005)
    if not pid:
        return {"checks": [unmeasured(4, row, "no_retry", "Reload started no Chromium Host (task p01-process-081)")]}
    state = host_state(lab)
    if state.get("context_initialized") is not False:
        lab.kill(pid, signal.SIGKILL)
        reason = (NO_FIELD.format("context_initialized", "081") if "context_initialized" not in state else
                  "the host's context was up before the bench could end it")
        return {"pid": pid, "checks": [unmeasured(4, row, "no_retry", reason)]}
    lab.kill(pid, signal.SIGKILL)
    lab.sleep(CANNOT_START_SETTLE_S)  # test harness: a retry would have started by now
    again, state = lab.host_pid(), host_state(lab)
    return {"pid": pid, "new_pid": again, "phase": state.get("phase"),
            "checks": [holds(4, row, "no_retry", again is None, again),
                       field_check(4, row, "cannot_start_shown", state, "phase", "081",
                                   lambda v: "cannot" in str(v).lower())]}


def rest_after_deaths(lab):
    """Waits out the restart window after the host ends earlier rows caused, so the budget counts only this row's
    kills; returns the seconds waited."""
    rest = lab.host_deaths[-1] + rows.RESTART_WINDOW_S - lab.now() if lab.host_deaths else 0
    if rest > 0:
        lab.sleep(rest)  # test harness: Chrome's rule forgives one crash per window
    return max(0.0, rest)


def kill_host(lab, signals=DEFAULT_SIGNALS):
    skipped = require_host(lab, "kill-host", 4)
    if skipped:
        return skipped
    rested_s = rest_after_deaths(lab)
    url = lab.write_page("restore.html", RESTORE_PAGE)
    tab = open_tab(lab, f"{url}?kill", "restore probe", "?kill")
    if not tab:
        return failed(4, "kill-host", "the restore probe never loaded")
    expected = seed_restore(lab, tab)
    if not expected:
        return failed(4, "kill-host", "the probe kept no typed text and scroll")
    typing = Typing(lab) if lab.focus_terminal() else None
    app_pid, kills, checks = lab.app_pid(), [], []
    try:
        for index, name in enumerate(signals):
            kill = one_kill(lab, tab, expected, name, index >= rows.RESTART_LIMIT, app_pid)
            checks += kill.pop("checks")
            kills.append(kill)
    finally:
        typed = typing.stop() if typing else None
    if typed is None:
        checks += [unmeasured(4, "kill-host.typing", name, "no terminal pane took the focus")
                   for name in ("key_to_frame_p99_ms", "lost")]
    else:
        checks.append(at_most(4, "kill-host.typing", "key_to_frame_p99_ms", typed["p99"], rows.KILL_TYPING_P99_MS,
                              reason="the typing probe wrote no frame rows (CMUX_NEXT_TYPING_PROBE)"))
        checks.append(holds(4, "kill-host.typing", "lost", typed["lost"] == 0, typed["lost"]))
    start = cannot_start(lab, tab) if len(signals) > rows.RESTART_LIMIT else {
        "checks": [unmeasured(4, "kill-host.cannot_start", "no_retry",
                              f"needs more than {rows.RESTART_LIMIT} signals to spend the restart budget")]}
    checks += start.pop("checks")
    return {"rested_s": rested_s, "expected": expected, "kills": kills, "typing": typed, "cannot_start": start,
            "checks": checks}


# ---------------------------------------------------------------- helper-kill

def helper_kill(lab):
    skipped = require_host(lab, "helper-kill", 4)
    if skipped:
        return skipped
    url = lab.write_page("restore.html", RESTORE_PAGE)
    tab = open_tab(lab, f"{url}?helper", "restore probe", "?helper")
    if not tab:
        return failed(4, "helper-kill", "the restore probe never loaded")
    host_pid, app_pid, checks, out = lab.host_pid(), lab.app_pid(), [], {}
    for kind, short in (("gpu-process", "gpu"), ("renderer", "renderer")):
        row = f"helper-kill.{short}"
        found = [h["pid"] for h in lab.helpers(host_pid) if h.get("type") == kind] if host_pid else []
        if not found:
            checks.append(unmeasured(4, row, "one_record", f"no {kind} child of the Chromium Host"))
            continue
        # Every renderer, not one: ps cannot tell which renderer draws the probe tab (earlier rows' tabs and
        # Chromium's spare renderer have their own, and debug.energy matches tab renderers in process only).
        victims = found if short == "renderer" else found[:1]
        before = crash_records(lab)
        for victim in victims:
            lab.kill(victim, signal.SIGKILL)
        lab.wait(lambda: all(records_of(lab, before, victim) for victim in victims), RECORD_WAIT_S, 0.2)
        lab.sleep(1.0)  # test harness: a second record for the same exit would have come by now
        counts = [len(records_of(lab, before, victim)) for victim in victims]
        out[short] = {"pids": victims, "records": counts}
        checks.append(holds(4, row, "one_record", all(count == 1 for count in counts), counts) if any(counts) else
                      unmeasured(4, row, "one_record", "no debug.crashes record for the helper (task p01-process-225)"))
        checks.append(holds(4, row, "host_alive", lab.host_pid() == host_pid, lab.host_pid()))
        checks.append(holds(4, row, "app_alive", lab.app_pid() == app_pid, lab.app_pid()))
        if short == "gpu":
            checks.append(holds(4, row, "page_answers", lab.wait(lambda: page(lab, tab, "1 + 1") == 2, 10, 0.2)))
        else:
            checks.append(holds(4, row, "sad_tab",
                                lab.wait(lambda: dialogs.page_status(lab.rpc).get("gone") == "1", 10, 0.2)))
    out["checks"] = checks
    return out


# ---------------------------------------------------------------- hang and renderer-hang (done check 11)

def host_hang_reports(hangs):
    return [r for key in ("records", "thread_hangs", "task_hangs") for r in hangs.get(key) or []
            if r.get("process") == "chromium-host" and (r.get("duration_ms") or r.get("ms") or 0) > rows.HOST_HANG_REPORT_MS]


def hang(lab, hang_ms):
    skipped = require_host(lab, "hang", 11)
    if skipped:
        return skipped
    url = lab.write_page("restore.html", RESTORE_PAGE)
    tab = open_tab(lab, f"{url}?hang", "restore probe", "?hang")
    if not tab:
        return failed(11, "hang", "the probe never loaded")
    click(lab, tab, "f")
    pid = lab.host_pid()
    lab.rpc("debug.hangs", {"clear": True})
    blocked = (lab.rpc("debug.cef", {"host_block_ms": hang_ms}) or {}).get("host_blocked") is True
    if not blocked and pid:
        lab.kill(pid, signal.SIGSTOP)
    started = lab.now()
    lab.rpc("debug.key", {"target": "page", "key": "a"})  # an input the blocked host cannot ack
    banner_ms, state, armed = None, {}, False
    while lab.now() - started < hang_ms / 1000:
        state = host_state(lab)
        armed = armed or state.get("hang_timer_armed") is True
        if banner_ms is None and state.get("hang_banner"):
            banner_ms = (lab.now() - started) * 1000
        lab.sleep(0.02)  # test harness: banner poll, within the 100 ms tolerance
    if not blocked and pid:
        lab.kill(pid, signal.SIGCONT)
    hangs = lab.rpc("debug.hangs") or {}
    turn = ((hangs.get("turn_histogram") or {}).get("main_turn") or {}).get("p99_ms")
    checks = [within(11, "hang", "banner_ms", banner_ms, rows.HANG_BANNER_MS, rows.HANG_BANNER_TOLERANCE_MS,
                     reason=NO_FIELD.format("hang_banner", "084") if "hang_banner" not in state else
                     f"no banner in {hang_ms} ms"),
              at_most(11, "hang", "main_turn_p99_ms", turn, rows.HANG_TURN_P99_MS,
                      reason="debug.hangs has no main_turn histogram"),
              holds(11, "hang", "banner_clears",
                    bool(lab.wait(lambda: host_state(lab).get("hang_banner") is False, 5, 0.1))) if "hang_banner" in state
              else unmeasured(11, "hang", "banner_clears", NO_FIELD.format("hang_banner", "084"))]
    if blocked:
        reports = host_hang_reports(hangs)
        checks.append(holds(11, "hang", "host_report", bool(reports), len(reports)))
    else:
        checks.append(unmeasured(11, "hang", "host_report",
                                 "no debug.cef host_block_ms (task p01-process-084): SIGSTOP stops the host's watcher too"))
    checks.append(hidden_hang(lab, pid, armed))
    return {"hang_ms": hang_ms, "blocked_by": "host" if blocked else "SIGSTOP", "banner_ms": banner_ms,
            "timer_armed_visible": armed, "main_turn_p99_ms": turn, "checks": checks}


def hidden_hang(lab, pid, control):
    """With cmux hidden, an input to a stopped host arms no hang timer (done check 11). `control`: the visible hang
    armed one for its input; without it a False here would prove nothing."""
    row = "hang.hidden"
    if not pid:
        return unmeasured(11, row, "no_timer", "no Chromium Host process")
    lab.rpc("action.run", {"action": "showHideAllWindows", "args": {"hidden": True}, "origin": "script"}, timeout=60)
    lab.kill(pid, signal.SIGSTOP)
    lab.rpc("debug.key", {"target": "page", "key": "b"})  # an outstanding input: what arms the timer when shown
    started, armed, state = lab.now(), False, {}
    while lab.now() - started < HIDDEN_HANG_S:  # past the 2 s banner deadline
        state = host_state(lab)
        armed = armed or state.get("hang_timer_armed") is True
        lab.sleep(0.1)  # test harness: timer poll
    lab.kill(pid, signal.SIGCONT)
    lab.rpc("action.run", {"action": "showHideAllWindows", "args": {"hidden": False}, "origin": "script"}, timeout=60)
    if "hang_timer_armed" not in state:
        return unmeasured(11, row, "no_timer", NO_FIELD.format("hang_timer_armed", "084"))
    if not control:
        return unmeasured(11, row, "no_timer", "the visible hang armed no timer for its input, so no timer "
                                               "while hidden proves nothing (task p01-process-084)")
    return holds(11, row, "no_timer", not armed, armed)


def renderer_hang(lab):
    skipped = require_host(lab, "renderer-hang", 11)
    if skipped:
        return skipped
    url = lab.write_page("hang.html", dialogs.HANG_PAGE)
    tab = open_tab(lab, f"{url}?renderer", "hang probe", "?renderer")
    if not tab:
        return failed(11, "renderer-hang", "the hang probe never loaded")
    lab.rpc("debug.mouse", {"target": "page"})
    started, banner, state = lab.now(), False, {}

    def prompt():
        nonlocal banner, state
        state = host_state(lab)
        banner = banner or bool(state.get("hang_banner"))
        return dialogs.page_status(lab.rpc).get("unresponsive") == "1"
    shown = lab.wait(prompt, RENDERER_HANG_DEADLINE_S, 0.25)
    prompt_s = lab.now() - started if shown else None
    dialogs.page_status(lab.rpc, press="exit")
    return {"prompt_s": prompt_s, "banner": banner, "checks": [
        at_most(11, "renderer-hang", "prompt_s", prompt_s, RENDERER_HANG_PROMPT_LIMIT_S, "s",
                reason=f"no unresponsive prompt in {RENDERER_HANG_DEADLINE_S:g} s"),
        holds(11, "renderer-hang", "no_host_banner", not banner, banner) if "hang_banner" in state
        else unmeasured(11, "renderer-hang", "no_host_banner", NO_FIELD.format("hang_banner", "084"))]}


# ---------------------------------------------------------------- ime (done check 8)

def ime(lab):
    skipped = require_host(lab, "ime", 8)
    if skipped:
        return skipped
    url = lab.write_page("restore.html", RESTORE_PAGE)
    tab = open_tab(lab, f"{url}?ime", "restore probe", "?ime")
    if not tab:
        return failed(8, "ime", "the probe never loaded")
    click(lab, tab, "f")
    page(lab, tab, "document.getElementById('f').value = ''")
    lab.rpc("debug.key", {"target": "page", "key": "e", "modifiers": ["alt"]})  # the dead acute accent
    lab.rpc("debug.key", {"target": "page", "key": "e"})
    composed = lab.wait(lambda: (lambda v: v if v else None)(page(lab, tab, "document.getElementById('f').value")), 5)
    state, prototype = host_state(lab), lab.rpc("debug.chromium_host") or {}
    checks = [holds(8, "ime.dead_key", "commit", composed == "é", composed), kotoeri(lab, tab)]
    for source, reason in NO_IME_DRIVER.items():
        checks.append(unmeasured(8, f"ime.{source}", "commit", reason))
    checks.append(at_most(8, "ime.first_rect", "max_ms", state.get("first_rect_max_ms"), rows.IME_FIRST_RECT_MS,
                          reason=NO_FIELD.format("first_rect_max_ms", "043")))
    checks.append(at_most(8, "ime.sync", "requests", prototype.get("ime_sync_requests"), rows.IME_SYNC_REQUESTS, "",
                          reason=NO_FIELD.format("ime_sync_requests", "043")))
    secure = secure_input(lab, tab)
    checks += secure.pop("checks")
    return {"composed": composed, "secure": secure, "checks": checks}


def field_value(lab, tab):
    return page(lab, tab, "document.getElementById('f').value")


def kotoeri(lab, tab):
    """Kotoeri's romaji input composes `nihon` and Return commits it as にほん (done check 8). The bench selects
    the input source (``select_input_source``) and puts the one before it back."""
    row = "ime.kotoeri"
    page(lab, tab, "document.getElementById('f').value = ''")
    previous = lab.input_source(KOTOERI_SOURCE)
    if previous is None:
        return unmeasured(8, row, "commit", f"the bench could not select {KOTOERI_SOURCE} (TISSelectInputSource: not "
                                            "macOS, or the input source is not installed)")
    try:
        lab.sleep(0.3)  # test harness: the input source change reaches cmux's text input context
        type_keys(lab, KOTOERI_KEYS)
        lab.rpc("debug.key", {"target": "page", "key": "return"})
        committed = lab.wait(lambda: (lambda v: v if v == KOTOERI_COMMIT else None)(field_value(lab, tab)), 5)
    finally:
        lab.input_source(previous)
    value = committed or field_value(lab, tab)
    return holds(8, row, "commit", value == KOTOERI_COMMIT, value)


def secure_input(lab, tab):
    """Secure event input is cmux's while the password field has focus, and off after blur, a host crash and close."""
    app_pid = lab.app_pid()

    def owner_is_app(want):
        return lab.wait(lambda: (lambda p: p if p is not None and (p == app_pid) == want else None)(lab.secure_pid())
                        is not None, 5, 0.1)
    if lab.secure_pid() is None:
        return {"checks": [unmeasured(8, "ime.secure_input", name, "ioreg shows no secure input owner")
                           for name in ("focused", "blurred", "after_crash", "after_close")]}
    out, checks = {}, []
    click(lab, tab, "pw")
    out["focused"] = bool(owner_is_app(True))
    click(lab, tab, "f")
    out["blurred"] = bool(owner_is_app(False))
    click(lab, tab, "pw")
    pid = lab.host_pid()
    if owner_is_app(True) and pid:
        lab.kill(pid, signal.SIGKILL)
        lab.host_deaths.append(lab.now())
        out["after_crash"] = bool(owner_is_app(False))
    lab.wait(lambda: page(lab, tab, "1 + 1") == 2, rows.KILL_RESTORE_MS / 1000 + RESTORE_GRACE_S, 0.1)
    click(lab, tab, "pw")
    if owner_is_app(True):
        lab.rpc("action.run", {"action": "closeTab", "target": f"tab:{tab}", "wait": True, "origin": "script"}, timeout=60)
        out["after_close"] = bool(owner_is_app(False))
    for name in ("focused", "blurred", "after_crash", "after_close"):
        checks.append(holds(8, "ime.secure_input", name, out[name]) if name in out else
                      unmeasured(8, "ime.secure_input", name, "the password field never turned secure input on"))
    out["checks"] = checks
    return out


# ---------------------------------------------------------------- ax (done check 9)

def ax(lab):
    skipped = require_host(lab, "ax", 9)
    if skipped:
        return skipped
    url = lab.write_page("ax.html", AX_PAGE)
    tab = open_tab(lab, f"{url}?ax", "ax probe", "?ax")
    if not tab:
        return failed(9, "ax", "the ax probe never loaded")
    readable = lab.ax_text(lab.app_pid(), AX_HEADING)  # the first read asks for the remote element

    def phase():
        return next((d.get("page_accessibility") for d in cef(lab).get("devtools") or [] if d.get("tab") == tab), None)
    connected = lab.wait(lambda: phase() == "connected", 10, 0.2)
    if readable is not True and connected:
        readable = lab.ax_text(lab.app_pid(), AX_HEADING)
    return {"phase": phase(), "readable": readable, "checks": [
        holds(9, "ax", "remote_children", bool(connected), phase()),
        holds(9, "ax", "h1_readable", readable) if readable is not None else
        unmeasured(9, "ax", "h1_readable", "this account gives the bench no Accessibility grant")]}


AX_ROLE_LIMIT = 6000


def ax_find_text(pid, text, limit=AX_ROLE_LIMIT):
    """True when an element of app `pid` has `text` as its title, value or description (breadth first, at most
    `limit` elements), False when none does, None when the Accessibility API cannot be read (not macOS, no grant)."""
    try:
        ax_lib = ctypes.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    except OSError:
        return None
    ptr = ctypes.c_void_p
    ax_lib.AXIsProcessTrusted.restype = ctypes.c_bool
    if not pid or not ax_lib.AXIsProcessTrusted():
        return None
    ax_lib.AXUIElementCreateApplication.restype, ax_lib.AXUIElementCreateApplication.argtypes = ptr, [ctypes.c_int]
    ax_lib.AXUIElementCopyAttributeValue.restype = ctypes.c_int32
    ax_lib.AXUIElementCopyAttributeValue.argtypes = [ptr, ptr, ctypes.POINTER(ptr)]
    cf.CFStringCreateWithCString.restype, cf.CFStringCreateWithCString.argtypes = ptr, [ptr, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringGetCString.restype = ctypes.c_bool
    cf.CFStringGetCString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    cf.CFGetTypeID.restype, cf.CFGetTypeID.argtypes = ctypes.c_ulong, [ptr]
    cf.CFStringGetTypeID.restype = cf.CFArrayGetTypeID.restype = ctypes.c_ulong
    cf.CFArrayGetCount.restype, cf.CFArrayGetCount.argtypes = ctypes.c_long, [ptr]
    cf.CFArrayGetValueAtIndex.restype, cf.CFArrayGetValueAtIndex.argtypes = ptr, [ptr, ctypes.c_long]
    cf.CFRetain.restype, cf.CFRetain.argtypes = ptr, [ptr]
    cf.CFRelease.argtypes = [ptr]
    utf8 = 0x08000100
    names = {n: cf.CFStringCreateWithCString(None, n.encode(), utf8)
             for n in ("AXChildren", "AXTitle", "AXValue", "AXDescription")}

    def attribute(element, name):
        out = ptr()
        return out if ax_lib.AXUIElementCopyAttributeValue(element, names[name], ctypes.byref(out)) == 0 and out else None

    def string(value):
        if not value or cf.CFGetTypeID(value) != cf.CFStringGetTypeID():
            return None
        buffer = ctypes.create_string_buffer(4096)
        return buffer.value.decode(errors="replace") if cf.CFStringGetCString(value, buffer, 4096, utf8) else None

    queue, seen, found = [ax_lib.AXUIElementCreateApplication(pid)], 0, False
    try:
        while queue and seen < limit and not found:
            element = queue.pop(0)
            seen += 1
            for name in ("AXTitle", "AXValue", "AXDescription"):
                value = attribute(element, name)
                found = found or text in (string(value) or "")
                if value:
                    cf.CFRelease(value)
            children = attribute(element, "AXChildren")
            if children and cf.CFGetTypeID(children) == cf.CFArrayGetTypeID():
                queue += [cf.CFRetain(cf.CFArrayGetValueAtIndex(children, i)) for i in range(cf.CFArrayGetCount(children))]
            if children:
                cf.CFRelease(children)
            cf.CFRelease(element)
    finally:
        for element in queue:
            cf.CFRelease(element)
        for name in names.values():
            cf.CFRelease(name)
    return found


def select_input_source(source_id):
    """Selects the keyboard input source `source_id` (Text Input Sources: TISEnableInputSource, then
    TISSelectInputSource) and returns the id that was selected before it, or None when it cannot (not macOS, the
    source is not installed, or the selection fails)."""
    try:
        tis = ctypes.CDLL("/System/Library/Frameworks/Carbon.framework/Carbon")
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    except OSError:
        return None
    ptr = ctypes.c_void_p
    id_key = ptr.in_dll(tis, "kTISPropertyInputSourceID")
    tis.TISCopyCurrentKeyboardInputSource.restype = ptr
    tis.TISGetInputSourceProperty.restype, tis.TISGetInputSourceProperty.argtypes = ptr, [ptr, ptr]
    tis.TISCreateInputSourceList.restype, tis.TISCreateInputSourceList.argtypes = ptr, [ptr, ctypes.c_bool]
    tis.TISEnableInputSource.restype = tis.TISSelectInputSource.restype = ctypes.c_int32
    tis.TISEnableInputSource.argtypes = tis.TISSelectInputSource.argtypes = [ptr]
    cf.CFStringGetCString.restype = ctypes.c_bool
    cf.CFStringGetCString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    cf.CFArrayGetCount.restype, cf.CFArrayGetCount.argtypes = ctypes.c_long, [ptr]
    cf.CFArrayGetValueAtIndex.restype, cf.CFArrayGetValueAtIndex.argtypes = ptr, [ptr, ctypes.c_long]
    cf.CFRelease.argtypes = [ptr]

    def source_id_of(source):
        value = tis.TISGetInputSourceProperty(source, id_key) if source else None  # not owned: no release
        buffer = ctypes.create_string_buffer(256)
        return buffer.value.decode() if value and cf.CFStringGetCString(value, buffer, 256, 0x08000100) else None
    current = tis.TISCopyCurrentKeyboardInputSource()
    previous = source_id_of(current)
    if current:
        cf.CFRelease(current)
    sources = tis.TISCreateInputSourceList(None, True)
    if not sources or previous is None:
        return None
    try:
        for index in range(cf.CFArrayGetCount(sources)):
            source = cf.CFArrayGetValueAtIndex(sources, index)
            if source_id_of(source) == source_id:
                tis.TISEnableInputSource(source)
                return previous if tis.TISSelectInputSource(source) == 0 else None
        return None
    finally:
        cf.CFRelease(sources)


# ---------------------------------------------------------------- ordering (done check 7)

def ordering(lab, keys):
    skipped = require_host(lab, "ordering", 7)
    if skipped:
        return skipped
    url = lab.write_page("order.html", ORDER_PAGE)
    left = open_tab(lab, f"{url}?left", "order probe", "?left")
    lab.rpc("action.run", {"action": "splitRight", "focus": True, "origin": "script"}, timeout=60)
    right = open_tab(lab, f"{url}?right", "order probe", "?right") if left else None
    if not (left and right):
        return failed(7, "ordering", "the two order probes never loaded")
    frame = (lab.rpc("debug.window_frame") or {}).get("frame")
    sent, active, letters = {left: [], right: []}, right, "abcdefghijklmnopqrstuvwxyz"
    for index in range(keys):
        if index and index % ORDER_FOCUS_EVERY == 0:
            active = left if active == right else right
            lab.rpc("action.run", {"action": "focusLeft" if active == left else "focusRight", "origin": "script"},
                    timeout=30)
        if index and index % ORDER_IME_EVERY == 0:
            lab.rpc("debug.key", {"key": "e", "modifiers": ["alt"]})
            lab.rpc("debug.key", {"key": "e"})
            sent[active].append("é")
        if index and index % ORDER_RESIZE_EVERY == 0 and isinstance(frame, list) and len(frame) == 4:
            grow = 20 if (index // ORDER_RESIZE_EVERY) % 2 else 0
            lab.rpc("debug.window_frame", {"frame": [frame[0], frame[1], frame[2] + grow, frame[3]]})
        letter = letters[index % len(letters)]
        lab.rpc("debug.key", {"key": letter})
        sent[active].append(letter)
    if isinstance(frame, list):
        lab.rpc("debug.window_frame", {"frame": frame})
    expected = {tab: "".join(chars) for tab, chars in sent.items()}
    value = lambda tab: page(lab, tab, "document.getElementById('f').value") or ""  # noqa: E731
    lab.wait(lambda: all(len(value(tab)) >= len(text) for tab, text in expected.items()), 30, 0.5)
    got = {tab: value(tab) for tab in expected}
    misplaced = sum(sum(a != b for a, b in zip(got[tab], text)) + abs(len(got[tab]) - len(text))
                    for tab, text in expected.items())
    commits = lambda text: [i for i, c in enumerate(text) if c == "é"]  # noqa: E731
    ime_ok = all(commits(got[tab]) == commits(text) for tab, text in expected.items())
    return {"keys": keys, "expected_lengths": {t: len(v) for t, v in expected.items()},
            "got_lengths": {t: len(v) for t, v in got.items()}, "misplaced": misplaced, "checks": [
                holds(7, "ordering", "keys_on_active_page", misplaced == 0, misplaced),
                holds(7, "ordering", "ime_in_send_order", ime_ok)]}


# ---------------------------------------------------------------- visibility (done check 12)

def visibility(lab):
    skipped = require_host(lab, "visibility", 12)
    if skipped:
        return skipped
    url = lab.write_page("restore.html", RESTORE_PAGE)
    tab = open_tab(lab, f"{url}?visibility", "restore probe", "?visibility")
    if not tab:
        return failed(12, "visibility", "the probe never loaded")

    def sample():
        first = page(lab, tab, "window.__raf")
        lab.sleep(SAMPLE_S)  # test harness: one sample window of animation frames
        last = page(lab, tab, "window.__raf")
        rate = (last - first) / SAMPLE_S if isinstance(first, (int, float)) and isinstance(last, (int, float)) else None
        return page(lab, tab, "document.visibilityState"), rate

    out, checks = {"shown": sample()}, []
    workspaces = {w.get("id") for w in ((lab.rpc("snapshot.get") or {}).get("topology") or {}).get("workspaces") or []}
    lab.rpc("action.run", {"action": "newTab", "focus": True, "origin": "script"}, timeout=60)
    out["workspace_hidden"] = sample()
    added = [w.get("id") for w in ((lab.rpc("snapshot.get") or {}).get("topology") or {}).get("workspaces") or []
             if w.get("id") not in workspaces]
    for workspace in added:
        lab.rpc("action.run", {"action": "closeWorkspace", "args": {"confirm": True}, "target": f"workspace:{workspace}",
                               "origin": "script"}, timeout=60)
    lab.rpc("action.run", {"action": "showHideAllWindows", "args": {"hidden": True}, "origin": "script"}, timeout=60)
    out["app_hidden"] = sample()
    lab.rpc("action.run", {"action": "showHideAllWindows", "args": {"hidden": False}, "origin": "script"}, timeout=60)
    out["shown_again"] = sample()
    for name in ("workspace_hidden", "app_hidden"):
        state, rate = out[name]
        checks.append(holds(12, f"visibility.{name}", "state_hidden", state == "hidden", state))
        checks.append(at_most(12, f"visibility.{name}", "raf_per_s", rate, rows.HIDDEN_RAF_PER_S, "/s",
                              reason="the page did not answer"))
    state, rate = out["shown_again"]
    checks.append(holds(12, "visibility.shown_again", "draws", state == "visible" and (rate or 0) > 0, rate))
    out["checks"] = checks
    return out


# ---------------------------------------------------------------- stall (done check 5)

def stall(lab, ms, every_ms, idle_minutes):
    skipped = require_host(lab, "stall", 5)
    if skipped:
        return skipped
    out, checks = {"stall_ms": ms, "every_ms": every_ms, "hz": lab.hz}, []

    def judged(row, result):
        checks.append(holds(5, row, "stalls_sent", (result.get("stalls") or 0) > 0, result.get("stalls")))
        checks.append(at_most(5, row, "long_frames", result.get("long_frames"), rows.STALL_LONG_FRAMES, "frames",
                              reason=result.get("error") or "no frame intervals from the page"))
    out["fresh"] = lab.stall_pace(ms, every_ms)
    judged("stall", out["fresh"])
    if idle_minutes <= 0:
        checks.append(unmeasured(5, "stall.after_idle", "long_frames", "run with --stall-idle-minutes 10"))
        out["checks"] = checks
        return out
    # Done check 5 excludes App Nap: cmux is made frontmost before the idle and must still be after it.
    out["activated"] = lab.activate()
    if not out["activated"].get("activated"):
        reason = f"cmux could not be made frontmost: {out['activated'].get('error') or 'no reason given'}"
        checks += [unmeasured(5, "stall.after_idle", name, reason) for name in ("cmux_frontmost", "long_frames")]
        out["checks"] = checks
        return out
    lab.sleep(idle_minutes * 60)  # test harness: done check 5's idle with cmux frontmost
    out["front_after_idle"] = lab.front()
    checks.append(holds(5, "stall.after_idle", "cmux_frontmost", out["front_after_idle"] == lab.app_pid(),
                        out["front_after_idle"]))
    lab.activate()  # the pacing itself runs with cmux frontmost, also when something took the front meanwhile
    out["after_idle"] = lab.stall_pace(ms, every_ms)
    judged("stall.after_idle", out["after_idle"])
    out["checks"] = checks
    return out


# ---------------------------------------------------------------- quit and runtime-update (task 087)

def quit_row(lab):
    skipped = require_host(lab, "quit", 4)
    if skipped:
        return skipped
    url = lab.write_page("unload.html", dialogs.UNLOAD_PAGE)
    tab = open_tab(lab, f"{url}?quit", "unload probe", "?quit")
    if not tab:
        return failed(4, "quit", "the unload probe never loaded")
    lab.rpc("debug.mouse", {"target": "page"})  # Chromium asks only a page the person used
    armed = lab.wait(lambda: page(lab, tab, "document.title") == "unload armed", 10, 0.2)
    app_pid, host_pid = lab.app_pid(), lab.host_pid()
    lab.rpc("debug.key", {"key": "q", "modifiers": ["cmd"]})
    asked = lab.wait(lambda: dialogs.questions(lab.rpc), dialogs.SHOW_DEADLINE_S, 0.2)
    lab.rpc("debug.dialog", {"press": "cancel"})
    lab.sleep(2.0)  # test harness: a quit that ignored Stay would have ended cmux by now
    stayed = lab.app_pid() == app_pid
    return {"armed": bool(armed), "asked": bool(asked), "checks": [
        holds(4, "quit", "asked", bool(armed) and bool(asked)),
        holds(4, "quit", "stay_keeps_cmux", stayed, lab.app_pid()),
        holds(4, "quit", "host_kept", stayed and lab.host_pid() == host_pid, lab.host_pid()),
        holds(4, "quit", "tab_kept", stayed and page(lab, tab, "location.search") == "?quit")]}


def runtime_update(lab):
    skipped = require_host(lab, "runtime-update", 4)
    if skipped:
        return skipped
    url = lab.write_page("restore.html", RESTORE_PAGE)
    tab = open_tab(lab, f"{url}?runtime", "restore probe", "?runtime")
    if not tab:
        return failed(4, "runtime-update", "the probe never loaded")
    staged = (lab.rpc("debug.cef", {"stage_runtime_update": True}) or {}).get("staged_runtime")
    if not staged:
        return failed(4, "runtime-update", "the app stages no runtime update: debug.cef stage_runtime_update "
                                           "(task p01-process-087)")
    host_pid = lab.host_pid()
    restarted = lab.wait(lambda: (lambda p: p if p and p != host_pid else None)(lab.host_pid()), 120, 0.5)
    back = lab.wait(lambda: page(lab, tab, "location.search") == "?runtime", 10, 0.2) if restarted else False
    state = host_state(lab)
    return {"staged": staged, "new_pid": restarted, "checks": [
        holds(4, "runtime-update", "idle_restart", bool(restarted), restarted),
        holds(4, "runtime-update", "tab_back", bool(back)),
        field_check(4, "runtime-update", "uses_staged", state, "runtime_version", "087", lambda v: v == staged)]}


# ---------------------------------------------------------------- kill-app (done check 20)

def kill_app(lab):
    skipped = require_host(lab, "kill-app", 20)
    if skipped:
        return skipped
    url = lab.write_page("restore.html", RESTORE_PAGE)
    tab = open_tab(lab, f"{url}?app", "restore probe", "?app")
    if not tab:
        return failed(20, "kill-app", "the probe never loaded")
    before = page_json(lab, tab, RESTORE_STATE) or {}
    host_pid = lab.host_pid()
    launch = lab.relaunch() or {}
    if launch.get("error"):
        return failed(20, "kill-app", f"relaunch: {launch['error']}")
    after = lab.wait(lambda: page_json(lab, tab, RESTORE_STATE), 30, 0.25) or {}
    origin = before.get("origin")
    return {"host_pid": host_pid, "launch": launch, "before": before, "after": after, "checks": [
        holds(20, "kill-app", "host_adopted", bool(host_pid) and lab.host_pid() == host_pid, lab.host_pid()),
        holds(20, "kill-app", "no_reload", origin is not None and after.get("origin") == origin, after.get("origin")),
        at_most(20, "kill-app", "terminal_screens_ms", launch.get("terminal_screens_ms"), rows.REATTACH_SCREEN_MS,
                reason=launch.get("terminal_screens_missing") or "the relaunch reported no launch marks")]}


FIRST_FRAME_MARK = "first_window_frame_committed"
TERMINAL_SCREENS_MARK = "terminal_screens_shown"  # the mark task p01-process-152 writes


def relaunch_timings(timings):
    """From a relaunched app's debug.timings: first_frame_ms (its launch mark, ms since process start, as
    bench_launch's socket probe reads it) and terminal_screens_ms (every terminal screen shown, ms after that first
    frame); a missing mark gives None and terminal_screens_missing says which."""
    marks = (timings.get("launch_ms_since_process_start") if isinstance(timings, dict) else None) or {}
    first, screens = marks.get(FIRST_FRAME_MARK), marks.get(TERMINAL_SCREENS_MARK)
    out = {"first_frame_ms": first if rows.is_number(first) else None, "terminal_screens_ms": None}
    if out["first_frame_ms"] is None:
        out["terminal_screens_missing"] = f"the relaunch wrote no {FIRST_FRAME_MARK} launch mark"
    elif not rows.is_number(screens):
        out["terminal_screens_missing"] = NO_FIELD.format(f"the {TERMINAL_SCREENS_MARK} launch mark", "152")
    else:
        out["terminal_screens_ms"] = screens - first
    return out


def run_row(lab, name, params):
    """One row by name; `params` holds signals, hang_ms, ordering_keys, stall (ms, every_ms) and stall_idle_minutes."""
    if name == "kill-host":
        return kill_host(lab, params.get("signals") or DEFAULT_SIGNALS)
    if name == "hang":
        return hang(lab, params.get("hang_ms") or 5000)
    if name == "ordering":
        return ordering(lab, params.get("ordering_keys") or 10000)
    if name == "stall":
        ms, every = params.get("stall") or (50, 100)
        return stall(lab, ms, every, params.get("stall_idle_minutes", 10))
    runners = {"helper-kill": helper_kill, "renderer-hang": renderer_hang, "ime": ime, "ax": ax,
               "visibility": visibility, "quit": quit_row, "runtime-update": runtime_update, "kill-app": kill_app}
    return runners[name](lab)
