"""Pass/fail rows of chromium-host-bench.py against the done checks of the Chromium Host program
(plans/cmux-next/chrome-parity/p01-process.md section 5, task p01-process-160).

Every measured row becomes one or more checks. A check names its done check (`number`), its row, the value the bench
measured, and the threshold it is held to; it prints as one line:

  ROW 4 kill-host.SEGV restore_ms PASS 1430 (<= 2000 ms)
  ROW 10 native-ui.color FAIL - (no runner yet: task p01-process-228)

A check the bench could not measure (the app does not answer the debug field yet, no Screen Recording grant, one
display) is a FAIL with its reason, never a PASS: the done check is not met until it is measured. `--list-failing`
prints each failing row's name once (`FAILING <row>`) and writes them to `failing.txt` in --out: the machine queue
Q6 of section 6 reads `--native-ui --list-failing`.

The done-check numbers and thresholds are the constants below; `from_result` turns the bench's result (the rows the
older modes wrote with `pass`/`ok`, and the `checks` lists the process rows of chromium_host_process_rows.py write)
into checks. It runs anywhere: no app, no macOS.
"""

# Done check 4 (--kill-host).
KILL_RESTORE_MS = 2000.0
KILL_CRASH_PAGE_FRAMES = 1
KILL_TYPING_P99_MS = 16.7
# Chrome's GPU restart rule as p01-process-081 sets it: 3 crashes within 5 minutes end the restarts.
RESTART_LIMIT = 3
RESTART_WINDOW_S = 300.0
# Done check 5 (--stall 50/100).
STALL_LONG_FRAMES = 0
# Done check 6: key and click to page paint.
PAINT_P50_MS = 8.3
PAINT_P99_MS = 16.7
PAINT_HOST_OVER_INPROC_P95_MS = 1.0
# Done check 8 (--ime).
IME_FIRST_RECT_MS = 0.1
IME_SYNC_REQUESTS = 0
# Done check 11 (--hang 5000).
HANG_BANNER_MS = 2000.0
HANG_BANNER_TOLERANCE_MS = 100.0
HANG_TURN_P99_MS = 4.0
RENDERER_HANG_PROMPT_S = 15.0
HOST_HANG_REPORT_MS = 250.0
# Done check 12: hidden pages draw nothing.
HIDDEN_RAF_PER_S = 0.0
# Done check 20 (--kill-app).
REATTACH_SCREEN_MS = 300.0

# Done check 10: every native UI row, with the task that builds its runner. A row with no runner is a FAIL that names
# its task: --list-failing is then the whole queue, not only what already runs.
NATIVE_UI_ROWS = {
    "select": "p01-process-060", "date": "p01-process-066", "datalist": "p01-process-066",
    "color": "p01-process-228", "autofill": "p01-process-061", "password": "p01-process-061",
    "permission_camera": "p01-process-062", "permission_mic": "p01-process-062",
    "permission_location": "p01-process-062", "permission_notifications": "p01-process-062",
    "alert": "p01-process-063", "confirm": "p01-process-063", "prompt": "p01-process-063",
    "http_auth": "p01-process-063", "file_picker": "p01-process-064", "certificate_error": "p01-process-064",
    "beforeunload": "p01-process-064", "unresponsive": "p01-process-064", "print": "p01-process-065",
    "extension_popup": "p01-process-066", "side_panel": "p01-process-066", "devtools_docked": "p01-process-066",
    "devtools_window": "p01-process-066", "popup_window": "p01-process-066", "device_chooser": "p01-process-228",
    "screen_share": "p01-process-228", "external_protocol": "p01-process-228", "web_share": "p01-process-228",
    "pip": "p01-process-228", "fullscreen": "p01-process-229", "pointer_lock": "p01-process-229",
    "keyboard_lock": "p01-process-229", "swipe_back": "p01-process-234",
}

# Done check 10's "0 visible host windows" through the native UI rows: the task that reports them.
HOST_WINDOWS_TASK = "p01-process-068"
# The checks a mode would have written, for a mode that was asked for and has no result.
ASKED_MODE_ROWS = {
    "inproc": [(6, "paint.inproc", "key_p50_ms")],
    "helper": [(6, "paint.helper", "key_p50_ms"), (10, "identity", "host_page")],
    "display": [(6, "display", "pass")],
}

# Each row and the done check it answers. display is task 221's row: the page's frames at the display's rate, the
# 120 Hz of done check 6. identity is done check 10's "never frontmost, 0 visible windows" outside the native UI.
# helper-kill, quit and runtime-update keep tabs alive across a process end, as done check 4 does for the host.
PROCESS_ROWS = {
    "kill-host": 4, "kill-app": 20, "stall": 5, "hang": 11, "renderer-hang": 11, "ime": 8, "ax": 9,
    "ordering": 7, "visibility": 12, "display": 6, "identity": 10, "helper-kill": 4, "quit": 4,
    "runtime-update": 4,
}


def check(number, row, name, ok, value=None, limit=None, unit="", reason=None):
    """One check. `ok` None means not measured: a FAIL whose reason says why."""
    return {"number": number, "row": row, "name": name, "verdict": "PASS" if ok is True else "FAIL",
            "value": value, "limit": limit, "unit": unit, "reason": reason, "measured": ok is not None}


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def at_most(number, row, name, value, limit, unit="ms", reason=None):
    """`value <= limit`; a missing value is not measured (`reason` says why)."""
    bound = f"<= {limit:g}"
    if not is_number(value):
        return check(number, row, name, None, None, bound, unit, reason or "not measured")
    return check(number, row, name, value <= limit, round(value, 3), bound, unit)


def within(number, row, name, value, target, tolerance, unit="ms", reason=None):
    bound = f"{target:g} +/- {tolerance:g}"
    if not is_number(value):
        return check(number, row, name, None, None, bound, unit, reason or "not measured")
    return check(number, row, name, abs(value - target) <= tolerance, round(value, 3), bound, unit)


def holds(number, row, name, ok, value=None, reason=None):
    """A yes/no check; `ok` None is not measured."""
    return check(number, row, name, ok if ok is None else bool(ok), value, "true", "", reason)


def unmeasured(number, row, name, reason):
    return check(number, row, name, None, reason=reason)


def line(c):
    value = "-" if c["value"] is None else (str(c["value"]) if not isinstance(c["value"], float) else f"{c['value']:g}")
    limit = f"{c['limit']} {c['unit']}".strip() if c["limit"] is not None else ""
    detail = "; ".join(filter(None, [limit, c["reason"]]))
    return f"ROW {c['number']} {c['row']} {c['name']} {c['verdict']} {value}" + (f" ({detail})" if detail else "")


def failing(checks):
    """Each row with a failing check, once, in check order."""
    seen = []
    for c in checks:
        if c["verdict"] != "PASS" and c["row"] not in seen:
            seen.append(c["row"])
    return seen


def summary(checks):
    return {"checks": len(checks), "pass": sum(c["verdict"] == "PASS" for c in checks),
            "fail": sum(c["verdict"] != "PASS" for c in checks),
            "unmeasured": sum(not c["measured"] for c in checks), "failing_rows": failing(checks)}


def _passed(row):
    """A row dict's own verdict: `pass` or `ok` True; None when it says it was not measured."""
    if not isinstance(row, dict):
        return None
    for key in ("pass", "ok"):
        if key in row:
            return None if row[key] is None else bool(row[key])
    return False if row.get("error") else None


def _why(row):
    if not isinstance(row, dict):
        return "the row did not run"
    for key in ("error", "not_measurable", "unavailable", "not_run"):
        if row.get(key):
            return str(row[key])[:160]
    return None


def _row_check(number, row_name, name, row):
    return check(number, row_name, name, _passed(row), reason=_why(row) if _passed(row) is not True else None)


def paint_checks(modes):
    """Done check 6 from the key and click rows of the inproc and helper modes."""
    out = []
    helper, inproc = modes.get("helper") or {}, modes.get("inproc") or {}
    for mode, row in (("inproc", inproc), ("helper", helper)):
        for event in ("key", "click"):
            stats = row.get(f"{event}_to_paint_ms")
            if row.get("error") or not isinstance(stats, dict):
                if mode in modes:
                    out.append(unmeasured(6, f"paint.{mode}", f"{event}_p50_ms", _why(row) or "no paint samples"))
                continue
            out.append(at_most(6, f"paint.{mode}", f"{event}_p50_ms", stats.get("p50"), PAINT_P50_MS))
            out.append(at_most(6, f"paint.{mode}", f"{event}_p99_ms", stats.get("p99"), PAINT_P99_MS))
            lost = (stats.get("sent") or 0) - (stats.get("n") or 0)
            out.append(holds(6, f"paint.{mode}", f"{event}_lost", lost == 0, lost))
    for event in ("key", "click"):
        host, own = (helper.get(f"{event}_to_paint_ms") or {}), (inproc.get(f"{event}_to_paint_ms") or {})
        if isinstance(host.get("p95"), (int, float)) and isinstance(own.get("p95"), (int, float)):
            out.append(at_most(6, "paint.helper", f"{event}_p95_over_inproc_ms", host["p95"] - own["p95"],
                               PAINT_HOST_OVER_INPROC_P95_MS))
    return out


def helper_checks(helper):
    """The helper mode's own pass/fail rows (identity, kill, pixels, geometry, input, ime, password, lifetime)."""
    out = []
    if not helper or helper.get("error"):
        if helper:
            out.append(unmeasured(10, "identity", "host_page", _why(helper)))
        return out
    out.append(_row_check(10, "identity", "pass", helper.get("identity")))
    out.append(_row_check(4, "kill", "restart", helper.get("kill")))
    out.append(_row_check(10, "pixels", "composited", helper.get("pixels")))
    out.append(_row_check(10, "geometry", "placements", helper.get("geometry")))
    if "defaults" in helper:
        out.append(_row_check(10, "identity", "defaults", helper.get("defaults")))
    for name, row in sorted((helper.get("input") or {}).items()):
        if name != "not_forwarded":
            out.append(_row_check(10, f"input.{name}", "pass", row))
    for name in ("ime", "password"):
        if name in helper:
            out.append(_row_check(8, name, "pass", helper[name]))
    for name, row in sorted((helper.get("lifetime") or {}).items()):
        out.append(_row_check(20, f"lifetime.{name}", "pass", row))
    return out


def native_ui_checks(native, ran):
    """Done check 10: one check per row of NATIVE_UI_ROWS that was asked for (`ran`, None for all of them)."""
    out = []
    native = native or {}
    if native.get("error") and len(native) == 1:
        return [unmeasured(10, f"native-ui.{name}", "pass", native["error"]) for name in (ran or NATIVE_UI_ROWS)]
    for name in (ran if ran is not None else NATIVE_UI_ROWS):
        row = native.get(name)
        if row is None:
            task = NATIVE_UI_ROWS.get(name, "p01-process-228")
            out.append(unmeasured(10, f"native-ui.{name}", "pass", f"no runner yet: task {task}"))
        else:
            out.append(_row_check(10, f"native-ui.{name}", "pass", row))
    windows = native.get("host_windows_seen")
    if windows is not None:
        out.append(holds(10, "native-ui.host_windows", "visible", windows == 0, windows))
    elif ran is None:
        out.append(unmeasured(10, "native-ui.host_windows", "visible", f"no runner yet: task {HOST_WINDOWS_TASK}"))
    return out


def stall_checks(modes):
    out = []
    for mode in ("inproc", "helper"):
        stall = (modes.get(mode) or {}).get("stall")
        if isinstance(stall, dict):
            out.append(at_most(5, f"stall.{mode}", "long_frames", stall.get("long_frames"), STALL_LONG_FRAMES, "frames",
                               reason=_why(stall)))
    return out


def not_run_reason(result):
    """Why an asked row has no result: the run's own error (a launch that failed), else that it did not run."""
    return f"did not run: {result['error']}" if result.get("error") else "did not run"


def process_row_checks(result, asked=()):
    """Each process row's own checks; an asked row (`asked`) with no result fails as not measured."""
    out, ran = [], result.get("rows") or {}
    for name in sorted(ran):
        row = ran[name]
        checks = row.get("checks") if isinstance(row, dict) else None
        if checks:
            out += checks
        else:
            out.append(unmeasured(PROCESS_ROWS.get(name.split(".")[0], 0), name, "pass",
                                  _why(row) or "the row wrote no checks"))
    out += [unmeasured(PROCESS_ROWS.get(name, 0), name, "pass", not_run_reason(result))
            for name in asked if name not in ran]
    return out


def from_result(result, native_rows=None, asked=None):
    """Every check of a chromium-host-bench result: the older modes' rows, then each process row's own checks.

    `asked` ({"modes": [...], "process_rows": [...], "native_ui": bool}) is what the run was asked for: an asked mode,
    native UI set or process row with no result (the launch failed, a step stopped before it) fails as not measured,
    so --list-failing never writes an empty failing.txt for a run that measured nothing."""
    asked = asked or {}
    modes = result.get("modes") or {}
    out = []
    if "inproc" in modes or "helper" in modes:
        out += paint_checks(modes)
        out += stall_checks(modes)
    out += helper_checks(modes.get("helper"))
    if "native_ui" in modes:
        out += native_ui_checks(modes["native_ui"], native_rows)
    elif asked.get("native_ui"):
        out += native_ui_checks({"error": not_run_reason(result)}, native_rows)
    if "display" in modes:
        out.append(_row_check(PROCESS_ROWS["display"], "display", "pass", modes["display"]))
    for mode in asked.get("modes") or ():
        if mode not in modes:
            out += [unmeasured(number, row, name, not_run_reason(result))
                    for number, row, name in ASKED_MODE_ROWS.get(mode, ())]
    out += process_row_checks(result, asked.get("process_rows") or ())
    return out


def report(checks, write, list_failing=False, failing_path=None):
    """Prints every check line, then with `list_failing` each failing row; returns the summary."""
    for c in checks:
        write(line(c))
    rows = failing(checks)
    if list_failing:
        for row in rows:
            write(f"FAILING {row}")
        if failing_path:
            with open(failing_path, "w") as out:
                out.write("".join(f"{row}\n" for row in rows))
    return summary(checks)
