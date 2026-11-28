#!/usr/bin/env python3
"""The diff tab cells of an idle measurement (bench_memory.py --diff-tab; perf-idle-ab.sh cells=).

A visible diff tab asks the app for a fingerprint of its repository on a timer: each 4 s while its
page has the focus, each 30 s while it has not, never while it is hidden (webviews/src/diff-viewer/
freshness.ts). This module gives an idle window that work, in a way that is the same for each arm:

  make_repository  a git repository of a fixed size with uncommitted changes (`small`, `large`);
                   the same bytes each time, so the base arm and the head arm read the same tree
  open_tab         one diff tab on that repository in the focused pane (the `openDiffViewer`
                   action with its `path`), shown, and its first file drawn
  page_facts       what the page says before the window: the engine, visible or hidden, and
                   `document.hasFocus()`, which decides the timer's interval
  require_visible  ends the run for a hidden page: it asks nothing
  window_seconds   the window for that focus state: the page compares 15 times in 60 s with the
                   focus and 2 times in 60 s without it, so a window without the focus is longer
  Scroller         wheel events on the page for the whole window (a Chromium page, through DevTools)
  child_cpu_ns     the CPU time of a process's ended children (`ri_child_user_time` and
                   `ri_child_system_time` of `proc_pid_rusage`): the daemon runs git as children
                   that start and end inside the window, so the daemon's own time does not have them
  child_time_check proves that last read on this Mac with a child of this script: the read agrees
                   with the child time that `getrusage` gives for the same child

The module does not count the page's reads. `page_facts` says how many the timer makes in the window
(`reads_expected`), and `open_tab` proves one read through the page's own router before the window.
"""
from __future__ import annotations

import json
import os
import resource
import subprocess
import sys
import threading
import time

PAGE = "cmux.diff"
ORIGIN = "cmux-page://cmux.diff"
FINGERPRINT_OP = "cmux.diff.git.fingerprint"
# freshness.ts: FRESHNESS_INTERVAL and UNFOCUSED_FRESHNESS_INTERVAL, in seconds.
FOCUSED_INTERVAL_S = 4
UNFOCUSED_INTERVAL_S = 30

# files, changed files, changed lines in each changed file, bytes of one untracked text file.
SIZES = {
    "small": {"files": 200, "changed": 5, "lines": 20, "untracked_bytes": 0},
    "large": {"files": 20000, "changed": 200, "lines": 100, "untracked_bytes": 1 << 20},
}
# RUSAGE_INFO_V4 in u64 words (bsd/sys/resource.h): the uuid is words 0 and 1, `ri_user_time` is
# word 2, and `ri_child_user_time`, `ri_child_system_time` are words 12 and 13 (mach ticks).
CHILD_USER, CHILD_SYSTEM = 12, 13

_GIT_ENV = {
    "GIT_AUTHOR_NAME": "bench", "GIT_AUTHOR_EMAIL": "bench@example.com",
    "GIT_COMMITTER_NAME": "bench", "GIT_COMMITTER_EMAIL": "bench@example.com",
    "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z",
    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
    # No background maintenance after a commit: a detached `git maintenance run --auto` still writing in `.git`
    # when the scratch folder is removed made that removal fail with "Directory not empty: '.git'".
    "GIT_CONFIG_COUNT": "3",
    "GIT_CONFIG_KEY_0": "maintenance.auto", "GIT_CONFIG_VALUE_0": "false",
    "GIT_CONFIG_KEY_1": "gc.auto", "GIT_CONFIG_VALUE_1": "0",
    "GIT_CONFIG_KEY_2": "core.fsmonitor", "GIT_CONFIG_VALUE_2": "false",
}


def _line(index: int, line: int, changed: bool) -> str:
    return f"value {index} {line} = {line * 7 if changed else line}; // {'after' if changed else 'before'} the change\n"


def make_repository(root: str, size: str) -> dict:
    """A repository at `root` with the uncommitted changes of `SIZES[size]`; returns its numbers.

    Each file has 8 lines; a file that changes has 2 lines for each changed line and each second
    line of it changes. The changed files are spread over the folders (100 files in a folder)."""
    spec = SIZES[size]
    files, changed, lines = spec["files"], spec["changed"], spec["lines"]
    step = files // changed
    # No GIT_DIR, GIT_WORK_TREE or GIT_INDEX_FILE of the caller: git writes only below `root`.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(_GIT_ENV)

    def git(*args):
        subprocess.run(["git", "-C", root, *args], check=True, capture_output=True, env=env)

    def path_of(index: int) -> str:
        return os.path.join(root, "src", f"d{index // 100:03d}", f"f{index:05d}.txt")

    def changes(index: int) -> bool:
        return index % step == 0 and index // step < changed

    os.makedirs(root)
    git("init", "-q", "-b", "main")
    for index in range(files):
        if index % 100 == 0:
            os.makedirs(os.path.dirname(path_of(index)), exist_ok=True)
        with open(path_of(index), "w") as handle:
            handle.writelines(_line(index, line, False) for line in range(lines * 2 if changes(index) else 8))
    git("add", "-A")
    git("-c", "commit.gpgsign=false", "commit", "-q", "-m", "base")
    for index in range(files):
        if changes(index):
            with open(path_of(index), "w") as handle:
                handle.writelines(_line(index, line, line % 2 == 0) for line in range(lines * 2))
    if spec["untracked_bytes"]:
        row = "an untracked line of the measurement, 64 bytes with its end".ljust(63) + "\n"
        with open(os.path.join(root, "untracked.txt"), "w") as handle:
            handle.writelines(row for _ in range(spec["untracked_bytes"] // len(row)))
    return {"size": size, "root": root, "files": files, "changed_files": changed,
            "changed_lines": changed * lines, "untracked_bytes": spec["untracked_bytes"]}


def window_seconds(focused: bool | None, with_focus: float, without_focus: float) -> float:
    """The idle window: `with_focus` seconds only when the page said that it has the focus."""
    return with_focus if focused is True else without_focus


def reads_expected(focused: bool | None, hidden: bool | None, seconds: float) -> int:
    """How many times the page's timer compares in `seconds` (0 for a hidden page)."""
    if hidden:
        return 0
    return int(seconds // (FOCUSED_INTERVAL_S if focused is True else UNFOCUSED_INTERVAL_S))


def child_cpu_ns(words, numer: int, denom: int) -> int:
    """The CPU time of the ended children of a process, from its `proc_pid_rusage` words."""
    return (words[CHILD_USER] + words[CHILD_SYSTEM]) * numer // denom


_rusage = None


def read_child_ns(pid: int) -> int | None:
    """`child_cpu_ns` of process `pid` now (macOS), or None once the pid is gone."""
    global _rusage
    if _rusage is None:
        import ctypes

        class Timebase(ctypes.Structure):
            _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

        timebase = Timebase()
        ctypes.CDLL("/usr/lib/libSystem.B.dylib").mach_timebase_info(ctypes.byref(timebase))
        _rusage = (ctypes, ctypes.CDLL("/usr/lib/libproc.dylib"), timebase.numer, timebase.denom)
    ctypes, libproc, numer, denom = _rusage
    words = (ctypes.c_uint64 * 64)()
    if libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(4), ctypes.byref(words)) != 0:
        return None
    return child_cpu_ns(words, numer, denom)


def _own_children_ms() -> float:
    used = resource.getrusage(resource.RUSAGE_CHILDREN)
    return (used.ru_utime + used.ru_stime) * 1000


def child_time_check(read_child_ns=read_child_ns, burn_s: float = 0.3) -> dict:
    """Runs one child of this script that uses the CPU for `burn_s` seconds, in its own code and in
    the kernel (`os.stat` calls), and reads this script's own child time before and after with
    `read_child_ns(pid)` and with `getrusage(RUSAGE_CHILDREN)`. `ok` when the read saw that child
    and agrees with `getrusage`: a wrong word for the user time or for the system time does not agree."""
    before, times_before = read_child_ns(os.getpid()), _own_children_ms()
    code = (f"import os, time\nend = time.process_time() + {burn_s}\n"
            "while time.process_time() < end:\n    os.stat('.')\n")
    subprocess.run([sys.executable, "-I", "-c", code], check=False, timeout=60)
    after, times_after = read_child_ns(os.getpid()), _own_children_ms()
    if before is None or after is None:
        return {"ok": False, "error": "no rusage of this script"}
    seen_ms, times_ms = round((after - before) / 1e6, 1), round(times_after - times_before, 1)
    # The child also starts an interpreter: at least the burn. The 2 reads are of the same child.
    agrees = abs(seen_ms - times_ms) <= max(20.0, 0.1 * times_ms)
    return {"ok": times_ms >= burn_s * 1000 * 0.8 and agrees, "burn_ms": burn_s * 1000, "seen_ms": seen_ms,
            "times_ms": times_ms}


def chromium_page(pages) -> dict | None:
    """The diff page among `debug.cef_pages`' pages (the one that is not hidden first), or None."""
    found = [page for page in pages or [] if isinstance(page, dict) and str(page.get("origin", "")).startswith(ORIGIN)]
    found.sort(key=lambda page: bool(page.get("hidden")))
    return found[0] if found else None


def devtools(app, browser: int, method: str, params: dict | None = None, timeout: float = 40) -> dict:
    """A DevTools method on one of the app's own Chromium pages (`debug.cef_page_devtools`), parsed."""
    # `timeout_ms`: how long the app waits for Chromium's answer (builds before it wait 5 s, whatever `timeout` says).
    reply = app.call("debug.cef_page_devtools", {"browser": browser, "method": method, "params": params or {},
                                                 "timeout_ms": int(max(timeout - 2, 1) * 1000)}, timeout=timeout)
    if reply.get("error") or not isinstance(reply.get("result"), str):
        return {"error": str(reply.get("error") or "no reply")[:300]}
    try:
        return json.loads(reply["result"])
    except ValueError as error:
        return {"error": str(error)}


def evaluate(app, browser: int, expression: str):
    """`expression` (it gives JSON text) in the page; its value, or {"error": ...}."""
    reply = devtools(app, browser, "Runtime.evaluate", {"expression": expression, "returnByValue": True})
    value = (reply.get("result") or {}).get("value") if isinstance(reply.get("result"), dict) else None
    if not isinstance(value, str):
        return {"error": json.dumps(reply)[:300]}
    try:
        return json.loads(value)
    except ValueError as error:
        return {"error": str(error)}


_FACTS = ("JSON.stringify({focus: document.hasFocus(), visibility: document.visibilityState, "
          "files: document.querySelectorAll('.file-header').length, width: innerWidth, height: innerHeight})")


def page_facts(app) -> dict:
    """The diff page before the window. `focus` is None when the page cannot say (a WebKit page:
    this script has no script call into it), and the window is then the one without the focus."""
    state = app.call("debug.page", {"page": PAGE, "action": "state"}, timeout=30) or {}
    facts = {key: state.get(key) for key in ("engine", "in_window", "view_hidden", "window_visible", "window_occluded",
                                             "painted", "frame", "error") if key in state}
    facts.update(focus=None, visibility=None, browser=None)
    page = chromium_page((app.call("debug.cef_pages", timeout=30) or {}).get("pages"))
    if page is not None:
        facts["browser"] = page.get("browser")
        facts["hidden"] = page.get("hidden")
        said = evaluate(app, page["browser"], _FACTS)
        if said.get("error"):
            facts["page_error"] = said["error"]
        else:
            facts.update(said)
    return facts


def require_visible(facts: dict) -> dict:
    """`facts`, or the end of the run (SystemExit) for a diff page that is hidden, was not found, or
    did not answer: such a page asks nothing, and a window with no read proves nothing. A page that
    cannot say if it is visible (no script call into it) ends the run when its window is not shown."""
    hidden = (facts.get("error") or facts.get("page_error") or facts.get("hidden") is True
              or facts.get("visibility") == "hidden" or facts.get("view_hidden") is True)
    if facts.get("visibility") is None:
        hidden = (hidden or facts.get("window_occluded") is True or facts.get("in_window") is False
                  or facts.get("window_visible") is False)
    if hidden:
        raise SystemExit(f"diff-tab: the diff page is not visible before the window: {json.dumps(facts)[:400]}")
    return facts


def open_tab(app, folder: str, scope: str = "uncommitted") -> dict:
    """One diff tab on `folder` in the focused pane, shown, with its first file drawn and one
    fingerprint read answered. Ends the run (SystemExit) when one of these did not occur: a window
    that follows would measure no diff tab."""
    opened = app.action("openDiffViewer", focus=True, path=folder)
    # The action answers at its own limit while the open goes on (state "in_progress"): the wait
    # for the first file below is then the proof.
    late = "in_progress" in json.dumps(opened) or "timeout" in str(opened.get("code") or opened.get("error") or "")
    if (opened.get("error") or opened.get("code")) and not late:
        raise SystemExit(f"diff-tab: openDiffViewer: {opened.get('message') or opened.get('error')}")
    # `wait` answers at its timeout too (90 s at most): the large repository draws 200 files.
    waited = app.call("debug.page", {"page": PAGE, "action": "wait", "selector": ".file-header", "timeout_ms": 90000},
                      timeout=100) or {}
    if waited.get("error") or waited.get("matched") is not True:
        raise SystemExit(f"diff-tab: the page drew no file of {folder}: {waited.get('error') or waited}")
    read = app.call("debug.page", {"page": PAGE, "action": "call", "op": FINGERPRINT_OP, "params": {"scope": scope}},
                    timeout=120) or {}
    # The page router's reply: {"t": "ok", "value": {"fingerprint": ...}}, or {"t": "err", "code": ...}.
    value = read.get("value")
    if read.get("t") != "ok" or not isinstance(value, dict) or not value.get("fingerprint"):
        raise SystemExit(f"diff-tab: {FINGERPRINT_OP} gave no fingerprint: {json.dumps(read)[:300]}")
    return {"opened": {key: opened[key] for key in ("created", "state") if key in opened}, "waited": waited,
            "read": json.dumps(read)[:200]}


class Scroller:
    """Wheel events on the diff page from `start` to `stop`: `rate` each second at the middle of
    the page, down for 20 events and then up for 20 (a diff shorter than that rests at an end for
    some of them; the 2 arms get the same events). A Chromium page only (DevTools
    `Input.dispatchMouseEvent`); `start` ends the run for another page. It does not read where the
    page is: `stop` gives the events that were sent and the ones that failed."""

    def __init__(self, app, facts: dict, rate: float = 5, delta: int = 240):
        self.app, self.facts, self.rate, self.delta = app, facts, rate, delta
        self.sent = self.errors = 0
        self.last_error = None
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        if self.facts.get("browser") is None:
            raise SystemExit("diff-tab: the scroll needs a Chromium diff page; this page is "
                             f"{self.facts.get('engine') or 'not found'}")
        self._thread.start()

    def _run(self):
        x = int((self.facts.get("width") or 800) / 2)
        y = int((self.facts.get("height") or 600) / 2)
        while not self._stop.wait(1 / self.rate):
            down = (self.sent // 20) % 2 == 0
            reply = devtools(self.app, self.facts["browser"], "Input.dispatchMouseEvent",
                             {"type": "mouseWheel", "x": x, "y": y, "deltaX": 0, "deltaY": self.delta if down else -self.delta},
                             timeout=10)
            self.sent += 1
            if reply.get("error"):
                self.errors += 1
                self.last_error = reply["error"]

    def stop(self) -> dict:
        self._stop.set()
        if self._thread.is_alive():
            self._thread.join(timeout=15)
        return {"events": self.sent, "errors": self.errors, "last_error": self.last_error,
                "rate_per_s": self.rate, "delta_px": self.delta}
