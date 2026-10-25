#!/usr/bin/env python3
"""Launch smoke of one cmux-next DEV build inside a macOS VM, driven from the VM host.

vm.sh runs it per major (`--suite smoke`) with the same guest, VNC and app arguments as
fuzz.py, and it reuses fuzz.py's guest connection: every app call goes through the guest's
bundled `cmux app call` over SSH, every screenshot is a VNC frame of the guest display. The
guest needs no python3 and no Accessibility grant.

Steps (each one ok/FAIL in result.json, with a screenshot shot-<step>.png):
  launch     the app starts and answers a ping
  window     a main window exists (debug.windows)
  terminal   a New Tab opens a live terminal (debug.surfaces)
  echo       keys typed into it (debug.key) run `echo cmux-matrix-$((6*7))` in the shell and
             the terminal shows the output line cmux-matrix-42 (debug.surfaces text)
  split      Split Right makes a second pane (debug.focus topology)
  chromium   a Chromium tab loads a page served in the guest; debug.cef says Chromium is
             ready with no unavailable reason and no WebKit fallback; debug.layers shows a
             cef page
  webkit     a WebKit tab loads the same page; debug.layers shows a webkit page
  settings   Settings opens and paints (debug.page cmux.settings)
  alive      the app still answers a ping, within 10 s, after the steps
  quit       quitEndEverything ends the process within 30 s with exit status 0 (the guest shell
             that started the app records the status; a crash at quit is a signal status)
Then it copies the app's crash (.ips), hang (.hang) and resource (.diag) reports, the app log
and the unified-log faults of the cmux processes. A crash report fails the run, and so does a
missing step (a run that stopped early).

Main-thread stalls of 1 s or more (debug.hangs) are recorded as a finding with the label
"VM, not comparable": a VM has a paravirtual GPU and no ProMotion, so no timing from it is
perf evidence.

Needs a DEV build: `cmux app call` refuses a release build's socket.

Usage (vm.sh does this): smoke.py --ssh admin@IP --vnc HOST:PORT:PW --app APP --out DIR
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fuzz import Guest, new_reports, report_kind  # noqa: E402
from rfb import RFB  # noqa: E402

TITLE = "cmux-matrix-page"
LAUNCH_DEADLINE = 180  # s: a first launch in a fresh VM signs, verifies and maps the whole bundle
STEP_DEADLINE = 120  # s: a first Chromium start in a VM (cold framework, paravirtual GPU)
QUIT_DEADLINE = 30  # s
PAGE_PORT = 8737
ECHO_COMMAND = "echo cmux-matrix-$((6*7)); touch /tmp/cmux-matrix-typed"
ECHO_OUTPUT = "cmux-matrix-42"
EXIT_FILE = "/tmp/cmux-matrix-app-exit"
REPORT_DEADLINE = 30  # s: ReportCrash writes a report up to ~20 s after a death; it sends no signal over SSH
REPORT_MINIMUM = 15  # s: after a clean quit too, a helper (Chromium, cmux-tui) can have crashed at teardown
# Every step a PASS needs: a run that stopped early (a death, a refused call) is never a PASS.
REQUIRED_STEPS = ("launch", "window", "terminal", "echo", "split", "chromium", "webkit", "settings", "alive", "quit")


class Smoke:
    def __init__(self, g: Guest, vnc_arg: str, out: str):
        self.g, self.out = g, out
        host, port, *pw = vnc_arg.split(":")
        self.vnc_args = (host, int(port), pw[0] if pw else None)
        self.vnc = RFB(*self.vnc_args)
        self.result: dict = {"steps": {}, "findings": [], "suite": "smoke"}
        self.since = time.time() - 5

    # --- plumbing ---------------------------------------------------------------------------
    def call(self, method: str, params: dict | None = None, timeout: float = 60) -> dict:
        """One app control method through the guest's `cmux app call`; {"error": ...} on failure."""
        r = self.g.cmux(["app", "call", method, json.dumps(params or {})], timeout=timeout)
        text = (r.stdout or "").strip().splitlines()
        try:
            value = json.loads(text[-1]) if text else None
        except ValueError:
            value = None
        if r.returncode != 0 or not isinstance(value, dict):
            return {"error": (r.stderr or r.stdout or f"exit {r.returncode}").strip()[-600:]}
        return value

    def wait(self, probe, seconds: float, every: float = 1.0):
        """Bounded wait for an app state that has no change stream over the control socket."""
        end = time.time() + seconds
        while time.time() < end:
            value = probe()
            if value:
                return value
            if self.g.pid() is None:
                return None
            time.sleep(every)
        return None

    def shot(self, name: str) -> None:
        try:
            data = self.vnc.screenshot_png()
        except (ConnectionError, OSError, RuntimeError):
            self.vnc = RFB(*self.vnc_args)  # the server drops idle clients: one reconnect
            data = self.vnc.screenshot_png()
        open(os.path.join(self.out, f"shot-{name}.png"), "wb").write(data)

    def step(self, name: str, ok: bool, detail=None) -> bool:
        self.result["steps"][name] = {"ok": bool(ok), **({"detail": detail} if detail is not None else {})}
        print("%-9s %s %s" % (name, "ok" if ok else "FAIL", "" if detail is None else json.dumps(detail)[:600]), flush=True)
        try:
            self.shot(name)
        except Exception as error:  # a screenshot is evidence, never the verdict
            self.result["findings"].append({"kind": "screenshot-failed", "step": name, "error": str(error)})
        return ok

    # --- app reads ----------------------------------------------------------------------------
    def windows(self) -> list:
        return self.call("debug.windows").get("windows") or []

    def terminals(self) -> int:
        return int(self.call("debug.surfaces").get("live_terminals") or 0)

    def panes(self) -> int:
        windows = self.call("debug.focus").get("windows") or []
        window = next((w for w in windows if w.get("is_key")), windows[0] if windows else {})
        return len(window.get("topology") or [])

    def engines(self) -> list[str]:
        """Engines of the pages shown in the app's panes (debug.layers): "cef" or "webkit"."""
        return [b.get("engine") for w in self.call("debug.layers").get("windows") or []
                for b in w.get("browsers") or []]

    def page_state(self, url: str) -> dict | None:
        state = self.call("browser.page.state")
        return state if state.get("title") == TITLE and str(state.get("url", "")).startswith(url) else None

    # --- the run ------------------------------------------------------------------------------
    def run(self) -> None:
        g = self.g
        self.result["os"] = g.sh("sw_vers -productVersion").stdout.strip()
        self.result["build"] = g.sh("sw_vers -buildVersion").stdout.strip()
        g.sh(": >/tmp/cmux-fuzz-app.log")
        started = time.time()
        if not self.step("launch", g.launch(LAUNCH_DEADLINE, exit_file=EXIT_FILE), {"seconds_vm": round(time.time() - started, 1),
                                                               "socket": g.socket}):
            return
        if "error" in self.call("system.identify"):
            self.step("debug_build", False, "the app refused `cmux app call`: the smoke needs a DEV build")
            return
        windows = self.wait(self.windows, 30)
        if not self.step("window", bool(windows), {"windows": len(windows or [])}):
            return

        before = self.terminals()
        opened = self.call("action.run", {"action": "newTab", "focus": True, "wait": True})
        grown = self.wait(lambda: self.terminals() > before, STEP_DEADLINE)
        self.step("terminal", bool(grown) and "error" not in opened, {"run": opened, "before": before})

        g.sh("rm -f /tmp/cmux-matrix-typed")
        keys = [{"key": "space" if ch == " " else ch} for ch in ECHO_COMMAND] + [{"key": "return"}]
        errors = [k for k in (self.call("debug.key", k) for k in keys) if "error" in k]
        ran = self.wait(lambda: g.sh("test -e /tmp/cmux-matrix-typed").returncode == 0, 30)

        def shown() -> bool:
            text = json.dumps(self.call("debug.surfaces", {"text": True}))
            # The output line, not the typed command (which holds "$((6*7))", never "-42").
            return ECHO_OUTPUT in text
        echoed = self.wait(shown, 30) if ran else False
        self.step("echo", bool(ran) and bool(echoed) and not errors,
                  {"shell_ran_it": bool(ran), "output_shown": bool(echoed), "key_errors": errors[:3]})

        panes = self.panes()
        split = self.call("action.run", {"action": "splitRight", "focus": True})
        more = self.wait(lambda: self.panes() > panes, 30)
        self.step("split", bool(more) and "error" not in split, {"run": split, "panes_before": panes, "after": self.panes()})

        # A local page in the guest: no network dependency, one origin for both engines.
        server = (f"mkdir -p /tmp/cmux-matrix-www && printf '<!doctype html><title>{TITLE}</title><h1>{TITLE}</h1>' "
                  "> /tmp/cmux-matrix-www/index.html && cd /tmp/cmux-matrix-www && "
                  f"( trap '' HUP; exec /usr/bin/perl -MIO::Socket::INET -e '{PERL_HTTP}' {PAGE_PORT} "
                  ">/tmp/cmux-matrix-www.log 2>&1 </dev/null ) & echo $! >/tmp/cmux-matrix-www.pid; disown; true")
        g.sh(server)
        page = f"http://127.0.0.1:{PAGE_PORT}/"
        opened = self.call("action.run", {"action": "openBrowser", "args": {"url": page + "?chromium", "engine": "cef"},
                                          "focus": True}, timeout=STEP_DEADLINE)
        state = self.wait(lambda: self.page_state(page + "?chromium"), STEP_DEADLINE)
        cef = self.call("debug.cef")
        engines = self.engines()
        engine_ok = (cef.get("state") == "ready" and not cef.get("unavailable") and not cef.get("fallback")
                     and "cef" in engines)
        self.step("chromium", bool(state) and engine_ok and "error" not in opened,
                  {"run": opened, "state": state or self.call("browser.page.state"), "engines": engines,
                   "cef": {k: cef.get(k) for k in ("state", "unavailable", "fallback", "default_engine", "error")}})

        opened = self.call("action.run", {"action": "openBrowser", "args": {"url": page + "?webkit", "engine": "webkit"},
                                          "focus": True})
        state = self.wait(lambda: self.page_state(page + "?webkit"), STEP_DEADLINE)
        engines = self.engines()
        self.step("webkit", bool(state) and "webkit" in engines and "error" not in opened,
                  {"run": opened, "state": state or self.call("browser.page.state"), "engines": engines})

        opened = self.call("settings.open", {"focus": True})
        painted = self.wait(lambda: self.call("debug.page", {"page": "cmux.settings"}).get("painted"), STEP_DEADLINE)
        self.step("settings", opened.get("opened") is True and bool(painted), {"run": opened, "painted": bool(painted)})

        stalls = [{"ms": round(r.get("duration_ms", 0)), "top": (r.get("frames") or [])[:6]}
                  for r in self.call("debug.hangs", {"after": 0}).get("records") or []
                  if r.get("kind", "stall") == "stall" and r.get("duration_ms", 0) >= 1000]
        if stalls:
            self.result["findings"].append({"kind": "main-thread-stalls-over-1s", "label": "VM, not comparable",
                                            "stalls": stalls[:10]})
        ms = g.ping_ms(10)
        # ping_ms gives its timeout for a hung app: only an answer before it counts.
        self.step("alive", ms is not None and ms < 10000, {"pid": g.pid(), "ping_answered": ms is not None and ms < 10000})

    def exit_status(self) -> int | None:
        r = self.g.sh(f"cat {EXIT_FILE} 2>/dev/null")
        return int(r.stdout.strip()) if r.stdout.strip().lstrip("-").isdigit() else None

    def finish(self) -> None:
        g = self.g
        pid = g.pid()
        if pid is not None:
            reply = self.call("action.run", {"action": "quitEndEverything"}, timeout=20)
            end = time.time() + QUIT_DEADLINE
            # The exit file is the quit signal: the guest shell writes it after the app exited.
            while self.exit_status() is None and time.time() < end:  # no exit event reaches the host over SSH
                time.sleep(0.5)
            gone = self.exit_status() is not None and g.pid() is None
            if not gone:
                g.sh(f"sample {pid} 3 -file /tmp/cmux-matrix-quit.sample.txt >/dev/null 2>&1; kill -9 {pid}", timeout=30)
                open(os.path.join(self.out, "quit-hang.sample.txt"), "w").write(g.sh("cat /tmp/cmux-matrix-quit.sample.txt").stdout)
            status = self.exit_status()
            self.step("quit", gone and status == 0,
                      {"run": reply, "exit_status": status,
                       "detail": None if gone else f"still running {QUIT_DEADLINE} s after quit; sampled, killed"})
        elif "launch" in self.result["steps"]:
            self.step("quit", False, {"detail": "the app was gone before the quit", "exit_status": self.exit_status()})
        g.sh("kill $(cat /tmp/cmux-matrix-www.pid 2>/dev/null) 2>/dev/null; true")
        # ReportCrash writes a report up to ~20 s after a death and sends no signal over SSH: after a
        # death (exit status not 0) look until a report appears or the deadline passes.
        reports: list[dict] = []
        seen: set[str] = set()
        died = self.exit_status() not in (0, None) or not self.result["steps"].get("quit", {}).get("ok", False)
        end = time.time() + (REPORT_DEADLINE if died else REPORT_MINIMUM)
        while True:
            for path in new_reports(g, self.since, seen):
                seen.add(path)
                name = os.path.basename(path)
                open(os.path.join(self.out, name), "w").write(g.sh(f"cat {shlex.quote(path)}", timeout=30).stdout)
                reports.append({"kind": report_kind(name), "report": name})
            if (died and reports) or time.time() >= end:
                break
            time.sleep(2)
        self.result["reports"] = reports
        open(os.path.join(self.out, "app.log"), "w").write(g.sh("cat /tmp/cmux-fuzz-app.log", timeout=30).stdout)
        faults = g.sh(f"log show --style ndjson --start '@{int(self.since)}' --predicate "
                      "'(process CONTAINS \"cmux\") AND (messageType == fault)' 2>/dev/null | tail -500", timeout=120)
        open(os.path.join(self.out, "faults.ndjson"), "w").write(faults.stdout)
        self.result["faults"] = sum(1 for line in faults.stdout.splitlines() if line.startswith("{"))
        failed = [name for name, s in self.result["steps"].items() if not s["ok"]]
        missing = [name for name in REQUIRED_STEPS if name not in self.result["steps"]]
        crashes = [r for r in reports if r["kind"] == "crash"]
        self.result.update(failed_steps=failed + [f"{name} (not run)" for name in missing], crashes=len(crashes),
                           hang_reports=sum(1 for r in reports if r["kind"] == "hang-report"),
                           ok=not failed and not missing and not crashes)
        json.dump(self.result, open(os.path.join(self.out, "result.json"), "w"), indent=1)
        print("SMOKE %s os=%s failed=%s crashes=%d" % ("PASS" if self.result["ok"] else "FAIL", self.result.get("os"),
                                                       ",".join(self.result["failed_steps"]) or "-", len(crashes)), flush=True)


# A one-file HTTP server in the guest's system perl (a base image's python3 may be the CLT stub).
PERL_HTTP = (
    "my $s = IO::Socket::INET->new(LocalAddr => q(127.0.0.1), LocalPort => $ARGV[0], Listen => 8, ReuseAddr => 1) or die $!;"
    " while (my $c = $s->accept) { my $line = <$c>; while (my $h = <$c>) { last if $h =~ /^\\r?\\n$/ }"
    " open(my $f, q(<), q(index.html)); local $/; my $b = <$f>; close $f;"
    " print $c qq(HTTP/1.1 200 OK\\r\\nContent-Type: text/html\\r\\nContent-Length: ) . length($b) . qq(\\r\\nConnection: close\\r\\n\\r\\n) . $b;"
    " close $c }"
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ssh", required=True, help="guest user@ip")
    ap.add_argument("--vnc", required=True, help="host:port[:password]")
    ap.add_argument("--app", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--ssh-opt", action="append", default=[], help="extra ssh option (repeatable)")
    o = ap.parse_args()
    os.makedirs(o.out, exist_ok=True)
    g = Guest(o.ssh, o.app, o.ssh_opt)
    if g.sh(f"test -d {shlex.quote(o.app)}").returncode != 0:
        sys.exit(f"no app at {o.app!r} in the guest")
    smoke = Smoke(g, o.vnc, o.out)
    try:
        smoke.run()
    finally:
        smoke.finish()
    return 0


if __name__ == "__main__":
    sys.exit(main())
