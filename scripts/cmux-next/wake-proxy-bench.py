#!/usr/bin/env python3
"""The app after a wake, by a freeze proxy: every process of the app stopped for --sleep seconds, then resumed, and how
long until the app answers and a terminal shows a typed command's output again (the perf cron's wake part).

Leo, 2026-11-19: "a lot of this is just applying things properly and having those measurements in so that we're aware
of things". The perf cron had no row for the app after a Mac sleeps.

Why a proxy: a measure Mac cannot sleep and wake itself in a cron step. `pmset sleepnow` takes the worker off the
network mid-step and a scheduled wake (`pmset schedule wake`) needs root; a display sleep locks the console of a fleet
mini, and only a restart unlocks it (a lane VM note, 2026-11-18). So this bench does what a sleep does to the app's
processes: none of them runs for a while, and then all of them run again at once, with every timer overdue and the
wall clock jumped. It stops (SIGSTOP) the app, its Chromium helpers, cmux-tui and its terminal hosts, acpmux, and the
shells under them, waits --sleep seconds, and resumes them (SIGCONT). What a real wake adds and this does not: the
system's wake notices (NSWorkspace didWake and screensDidWake, which the app's Cloud, SSH, Feed, updater and wallpaper
services follow), the display coming back, and network changes. The rows say so in their name (launch.wake_proxy.).

Each round, in ms from the resume:
  app_answer_ms    the app's main thread answers its control socket (debug.frames, a main-actor method);
  terminal_echo_ms a command typed into the shown terminal right at the resume (`echo $((A+B))` through the app's own
                   CLI) shows its output in the app's terminal view (debug.surfaces text): the keyboard, the app, the
                   daemon, the PTY, the shell and back to a drawn view;
and before each freeze the same echo awake (awake_echo_ms), the same path with nothing frozen.

  wake-proxy-bench.py --app BUNDLE [--rounds 3] [--sleep 30] [--out FILE.json]
macOS only, on a fleet Mac (it launches the app with a scratch HOME, CMUX_BENCH_LAUNCH=direct on a fleet step).
"""
from __future__ import annotations

import argparse
import json
import os
import random
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_memory as bm  # noqa: E402  (launch, App, bundle_pids, process_table, end_bundle)

ECHO_TIMEOUT_S = 20.0
ANSWER_TIMEOUT_S = 20.0
PROMPT_TIMEOUT_S = 30.0
# The shell the bench types into: zsh with no startup files. The app launches with a scratch HOME, where a login zsh
# has no dotfiles; it runs no rc files, no new-user menu and no plugins, so the first prompt is up at once and each
# typed line runs as typed (typing-frame-bench.py makes its typed terminal the same way).
SHELL_COMMAND = "exec /bin/zsh -f"


def descendants(roots: set[int], table: list[tuple[int, int, str]]) -> set[int]:
    """`roots` and every process under them (pure): the shells and their children the terminal hosts started."""
    children: dict[int, list[int]] = {}
    for pid, ppid, _ in table:
        children.setdefault(ppid, []).append(pid)
    out, todo = set(), list(roots)
    while todo:
        pid = todo.pop()
        if pid in out:
            continue
        out.add(pid)
        todo.extend(children.get(pid, []))
    return out


def find_key(value, key: str) -> str | None:
    """The first string under `key` anywhere in `value` (a CLI `--json` answer; pure)."""
    if isinstance(value, dict):
        if isinstance(value.get(key), str):
            return value[key]
        value = list(value.values())
    if isinstance(value, list):
        for item in value:
            found = find_key(item, key)
            if found:
                return found
    return None


def freeze_set(bundle: str, app_pid: int) -> list[int]:
    """Every process of this run's app, the app last: it is stopped first and resumed last (signal order)."""
    pids = descendants(bm.bundle_pids(bundle) | {app_pid}, bm.process_table())
    pids.discard(os.getpid())
    return sorted(pids - {app_pid}) + [app_pid]


def signal_all(pids: list[int], sig: int) -> int:
    sent = 0
    for pid in pids:
        try:
            os.kill(pid, sig)
            sent += 1
        except ProcessLookupError:
            pass
    return sent


class Terminal:
    """The shown terminal of one workspace, through the app's own CLI and its debug.surfaces view text."""

    def __init__(self, app: bm.App):
        self.app = app
        self.env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_SOCKET_PATH": app.socket, "CMUX_QUIET": "1",
                    "HOME": os.environ.get("HOME", "/tmp")}
        self.surface = self.workspace = None
        self.last_write: dict = {}
        self.last_expect: str | None = None

    def argv(self, *args) -> list[str]:
        # The app's control socket (`--app-socket`), as bench_memory.App and the other benches of this build call it.
        return [self.app.cli_path, "--app-socket", self.app.socket, *args]

    def cli(self, *args, timeout=30):
        return subprocess.run(self.argv(*args), capture_output=True, text=True, timeout=timeout, env=self.env,
                              stdin=subprocess.DEVNULL)

    def open(self) -> str:
        """A new focused workspace (`workspace create --focus`, as attention-ring-clear-live and
        automation-typing-bench make theirs), shown in the window, and its terminal (the daemon's `term_...`)."""
        done = self.cli("--json", "workspace", "create", "--name", "wake-proxy", "--focus", "--shell", SHELL_COMMAND)
        try:
            made = json.loads(done.stdout)
        except ValueError:
            made = {}
        term, workspace = find_key(made, "terminal_id"), find_key(made, "workspace_id")
        if not term:
            raise SystemExit(f"wake-proxy: workspace create answered {(done.stdout + done.stderr).strip()[:300]}")
        self.app.call("action.run", {"action": "goToWorkspace", "target": f"workspace:{workspace}", "origin": "script",
                                     "focus": True}, timeout=ECHO_TIMEOUT_S)
        self.surface, self.workspace = term, workspace
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.view_panes():
                break
            time.sleep(0.5)  # test script: the workspace's terminal view appears by itself
        else:
            raise SystemExit(f"wake-proxy: {workspace} never showed its terminal; panes {self.pane_summary()}")
        # The shell's first prompt on the daemon's screen: a line typed before the shell reads its terminal can be
        # eaten by its startup, and the echo would wait for nothing.
        deadline = time.monotonic() + PROMPT_TIMEOUT_S
        while time.monotonic() < deadline:
            if self.screen_text().strip():
                return term
            time.sleep(0.25)  # test script: the shell starts by itself
        raise SystemExit(f"wake-proxy: {term}'s shell drew no prompt in {PROMPT_TIMEOUT_S:.0f} s; {json.dumps(self.diagnose())}")

    def screen_text(self) -> str:
        """The daemon's screen of the typed terminal (`terminal ID screen read`): what the shell printed, apart from
        whether the app's view drew it."""
        try:
            done = self.cli("terminal", self.surface, "screen", "read", timeout=ECHO_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            return ""
        return done.stdout if done.returncode == 0 else ""

    def diagnose(self, expect: str | None = None) -> dict:
        """Where a typed line got lost, for the report: the write's answer, the daemon's screen (the shell's side) and
        every terminal view of the window with its tab, focus and drawing state (the app's side)."""
        expect = expect or self.last_expect
        screen = self.screen_text()
        reply = self.app.call("debug.surfaces", {"text": True}, timeout=ECHO_TIMEOUT_S)
        panes = []
        for window in reply.get("windows") or []:
            for p in window.get("panes") or []:
                text = str(p.get("text") or "")
                panes.append({k: p.get(k) for k in ("pane", "kind", "workspace", "focused", "presence", "selected_tab",
                                                    "shown_tab", "blank_reason", "attach", "link", "phase")}
                             | {"drawing": (p.get("surface") or {}).get("drawing"),
                                "text_chars": len(text), "text_tail": text.strip()[-160:]})
        return {"terminal": self.surface, "workspace": self.workspace, "write": self.last_write,
                "screen_tail": screen.strip()[-400:], "expect": expect,
                "expect_on_screen": bool(expect) and expect in screen.replace("\n", ""),
                "expect_in_view": bool(expect) and expect in self.view_text().replace("\n", ""),
                "panes": panes or reply}

    def view_panes(self) -> list[dict]:
        """The terminal views that draw this workspace (a pane's `workspace`, as shared-space-windows-e2e reads it),
        else the focused terminal view (the workspace was created with --focus)."""
        reply = self.app.call("debug.surfaces", {"text": True}, timeout=ECHO_TIMEOUT_S)
        panes = [p for w in reply.get("windows") or [] for p in w.get("panes") or [] if p.get("kind") == "terminal"]
        mine = [p for p in panes if self.workspace and p.get("workspace") == self.workspace]
        return mine or [p for p in panes if p.get("focused")]

    def pane_summary(self) -> str:
        reply = self.app.call("debug.surfaces", {"text": True}, timeout=ECHO_TIMEOUT_S)
        return json.dumps([{k: p.get(k) for k in ("kind", "workspace", "presence", "focused")} | {"text": len(p.get("text") or "")}
                           for w in reply.get("windows") or [] for p in w.get("panes") or []] or reply)[:600]

    def view_text(self) -> str:
        return "\n".join(str(p.get("text") or "") for p in self.view_panes())

    def echo_start(self) -> tuple[subprocess.Popen, str]:
        """Types `echo wake-$((A+B))`; only the shell's output line holds wake-<sum>, never the typed text."""
        a, b = random.randrange(1 << 20), random.randrange(1 << 20)
        # `\r` is Return to the shell, as evicted-terminal-frame-live and bench_workspace_hibernation type it.
        proc = subprocess.Popen(self.argv("terminal", self.surface, "write", "--text", f"echo wake-$(({a}+{b}))\r"),
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                                env=self.env, text=True)
        self.last_expect = f"wake-{a + b}"
        return proc, self.last_expect

    def finish_write(self, proc: subprocess.Popen) -> None:
        """Waits for the write and keeps its answer: a refused write is the reason no echo came, not a slow app."""
        try:
            _, err = proc.communicate(timeout=30)
            self.last_write = {"exit": proc.returncode, "stderr": (err or "").strip()[-300:]}
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate()
            self.last_write = {"exit": None, "stderr": "write timed out after 30 s"}

    def wait_text(self, expect: str, since: float) -> float | None:
        while time.monotonic() - since < ECHO_TIMEOUT_S:
            if expect in self.view_text().replace("\n", ""):
                return round((time.monotonic() - since) * 1000, 1)
            time.sleep(0.02)  # test script: the view draws by itself; this only reads it (20 ms resolution)
        return None

    def echo(self, since: float | None = None) -> float | None:
        start = time.monotonic() if since is None else since
        proc, expect = self.echo_start()
        try:
            return self.wait_text(expect, start)
        finally:
            self.finish_write(proc)


def app_answer_ms(app: bm.App, since: float) -> float | None:
    while time.monotonic() - since < ANSWER_TIMEOUT_S:
        if "error" not in app.call("debug.frames", {"action": "read"}, timeout=ANSWER_TIMEOUT_S):
            return round((time.monotonic() - since) * 1000, 1)
        time.sleep(0.01)  # a refused connection during the resume: ask again
    return None


def run_round(bundle: str, app_pid: int, app: bm.App, term: Terminal | None, sleep_s: float) -> dict:
    """One freeze. With no working terminal (`term` None) only the app's answer is timed."""
    awake = term.echo() if term else None
    pids = freeze_set(bundle, app_pid)
    stopped = []
    try:
        for pid in reversed(pids):  # the app first: it sees none of the others stop
            if signal_all([pid], signal.SIGSTOP):
                stopped.append(pid)
        time.sleep(sleep_s)  # sleep-ok: the measured freeze length; nothing of the app runs for sleep_s
    finally:
        signal_all(list(reversed(stopped)), signal.SIGCONT)  # the app last: everything it talks to runs again first
    resumed = time.monotonic()
    if term is None:
        return {"sleep_s": sleep_s, "frozen": len(stopped), "awake_echo_ms": None,
                "app_answer_ms": app_answer_ms(app, resumed), "terminal_echo_ms": None}
    proc, expect = term.echo_start()  # the key press right at the wake
    answer = app_answer_ms(app, resumed)
    echo = term.wait_text(expect, resumed)
    term.finish_write(proc)
    entry = {"sleep_s": sleep_s, "frozen": len(stopped), "awake_echo_ms": awake, "app_answer_ms": answer,
             "terminal_echo_ms": echo}
    if echo is None:
        entry["missed"] = term.diagnose(expect)
    return entry


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--sleep", type=float, default=30.0, help="seconds every process of the app stays stopped")
    parser.add_argument("--settle", type=float, default=5.0, help="seconds between rounds")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    signal.signal(signal.SIGTERM, bm.interrupted)
    report = {"app": args.app, "proxy": "SIGSTOP/SIGCONT of every app process", "sleep_s": args.sleep, "rounds": []}
    scratch = None
    try:
        app_pid, sock, scratch = bm.launch(args.app, {})
        app = bm.App(args.app, sock)
        term = Terminal(app)
        try:
            term.open()
            if term.echo() is None:
                diag = term.diagnose()
                report["terminal_diag"] = diag
                raise SystemExit(f"the terminal never echoed before any freeze; {json.dumps(diag)}")
        except (SystemExit, subprocess.SubprocessError, OSError) as error:
            # The app's answer still says how long a wake holds it; the echo rows stay empty (missed_rounds counts
            # them) and the report says why, instead of the part measuring nothing.
            report["terminal_error"] = str(error)[:4000]
            print(f"wake-proxy: no terminal echo, timing the app only: {report['terminal_error']}", flush=True)
            term = None
        for index in range(args.rounds):
            time.sleep(args.settle)  # test script: an idle app between rounds
            entry = run_round(args.app, app_pid, app, term, args.sleep)
            entry["round"] = index + 1
            report["rounds"].append(entry)
            print(f"PERF-WAKE {json.dumps(entry)}", flush=True)
    finally:
        bm.end_bundle(args.app)
        if scratch:
            import shutil
            shutil.rmtree(scratch, ignore_errors=True)
        with open(args.out, "w") as handle:
            json.dump(report, handle, indent=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
