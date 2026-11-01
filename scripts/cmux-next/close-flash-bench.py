#!/usr/bin/env python3
"""Close Window and the close key: each close's action-budget commit time, in an active app (close-flash).

NSWindow.performClose(_:) flashes the close button through -[NSButtonCell performClick:], a nested event-tracking run
loop of about 100 ms on the key turn (v2.2.4-opt: debug.action_budget closeWindow 100.7 ms, outcome `nested`). AppKit
draws that flash only in an active app with the window on screen, so a unit test cannot see it; this bench can.

It launches a tagged bench or Debug `cmux DEV <tag>.app` ACTIVATED, then per round:
  * closeWindow: New Window (action.run), then Ctrl-Cmd-W through `debug.key` into the new window (origin user);
  * close key:   Open Debug Settings (action.run), then Cmd-W through `debug.key` with target debugSettings (the key
                 window route, WindowKeyTable's .closeWindow). Debug Settings exists only where DevTools is on (a Debug
                 compile or a nightly bundle), so a bench build measures `--kinds=closeWindow` and the close key runs
                 with `--config=debug`.
After each close it reads `debug.action_budget` and keeps that close's run (id, entrypoint, commit_ms, outcome), and
`debug.focus` before the close (app_active, key_window). It records the bundle's cmux-tui build and every running
cmux-tui daemon of the bundle with its `identify` build id. Prints `CLOSE-FLASH {json}` (p50/p95/p99/max of commit_ms
and the outcome counts per close kind) and `CLOSE-FLASH-DAEMON {json}`, and writes report.json to --out. Exit 1 when
fewer than 4/5 of the closes left a run, or no daemon runs from the bundle.

A close counts only when the app was active before it, the window closed and the close left its run (Close Window:
the key went through the app's own dispatch); the rest are counted by reason and left out of the numbers. The
headline commit_ms leaves out `missed` commits (their time includes idle time); commit_ms_by_outcome has each outcome.

Usage (a fleet GUI host, never a person's Mac):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/close-flash.sh --ref SHA \
    --artifact artifacts/close-flash/report.json --arg=--config=bench --arg=--kinds=closeWindow [--arg=--close-rounds=25]
  (the close key: --arg=--config=debug with the default --kinds; --arg=--arm=base labels an A/B arm)
"""
import importlib.util, json, os, re, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


AP = load("activation_perf", "activation-perf.py")


class ActiveApp(AP.App):
    """activation-perf's App, launched with activation (no CMUX_NEXT_NO_ACTIVATE) and activated again by `open`."""

    def launch(self):
        with open(self.config, "w") as f:
            json.dump({"appearance": {"backgroundOpacity": 1}}, f)
        ghostty = os.path.join(self.scratch, "ghostty")
        open(ghostty, "w").close()
        if os.path.exists(self.socket):
            os.unlink(self.socket)
        env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation",
               "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1440,900",
               "CMUX_NEXT_CONFIG_FILE": self.config, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty,
               "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(self.scratch, "chief"),
               "CMUX_NEXT_HANG_THRESHOLD_MS": str(self.hang_ms), "ACPMUX_AGENT_LAUNCH": "deny"}
        try:
            from tag_teardown import TagTeardown
            self.teardown = TagTeardown(self.bundle)
            self.teardown.install()
        except ImportError:
            self.teardown = None
        log = open(os.path.join(self.out, "app.log"), "a")
        self.started = time.time()
        self.process = subprocess.Popen([os.path.join(self.bundle, "Contents/MacOS/cmux DEV")], env=env,
                                        stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        print(f"close-flash: launched {self.tag} pid {self.process.pid}", flush=True)
        if not AP.wait(lambda: os.path.exists(self.socket) and "error" not in (self.rpc("debug.layout_counters") or {"error": 1}), 180):
            raise SystemExit("close-flash: the app's debug socket never answered (a bench or Debug build is required)")
        AP.wait(lambda: AP.Session(self, self.scratch).workspace_ids(), 60)
        if not self.activate():
            raise SystemExit("close-flash: the app never became active (the close button flashes only in an active app)")

    def activate(self):
        subprocess.run(["open", self.bundle], capture_output=True, timeout=30)
        return AP.wait(lambda: (self.rpc("debug.focus") or {}).get("app_active") is True, 10)


# ---------------------------------------------------------------- the daemon build (as the item 4 A/B overlay)
def _ps_rows():
    out = subprocess.run(["ps", "-axww", "-o", "pid=,lstart=,command="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+[\d:]+\s+\d{4})\s+(.*)", line)
        if m:
            rows.append((int(m.group(1)), m.group(2), m.group(3)))
    return rows


def _flag(command, name):
    words = command.split()
    return words[words.index(name) + 1] if name in words and words.index(name) + 1 < len(words) else None


def _identify(sock):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(5)
            s.connect(sock)
            s.sendall(b'{"id":1,"cmd":"identify"}\n')
            buf, deadline = b"", time.time() + 5
            while time.time() < deadline:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
                for line in buf.split(b"\n"):
                    try:
                        msg = json.loads(line)
                    except ValueError:
                        continue
                    found = []

                    def walk(node):
                        if isinstance(node, dict):
                            if "build_id" in node or "build_commit" in node:
                                found.append(node)
                            for v in node.values():
                                walk(v)
                    walk(msg)
                    if found:
                        return {k: found[0].get(k) for k in ("build_id", "build_commit", "pid", "version", "session")}
    except OSError as error:
        return {"error": repr(error)[:200]}
    return {"error": "no identify reply"}


def bundle_build(app_path):
    info = {}
    try:
        got = subprocess.run([os.path.join(app_path, "Contents/Resources/bin/cmux-tui"), "--version", "--json"],
                             capture_output=True, text=True, timeout=30)
        data = json.loads(got.stdout)
        info["build_identity"] = data.get("build_identity") or data.get("build_id")
        info["build_commit"] = data.get("build_commit")
    except Exception as error:  # noqa: BLE001  recorded, judged below
        info["version_error"] = repr(error)[:200]
    try:
        import plistlib
        with open(os.path.join(app_path, "Contents/Info.plist"), "rb") as f:
            plist = plistlib.load(f)
        info["app_plist"] = {k: v for k, v in plist.items() if "ommit" in k or "Build" in k or k == "CFBundleIdentifier"}
    except Exception as error:  # noqa: BLE001
        info["plist_error"] = repr(error)[:200]
    return info


def daemon_check(app_path):
    """Every headless cmux-tui daemon that runs from this bundle, with its identify build id against the bundle's."""
    # The bundle's path has spaces (`cmux DEV <tag>.app`): match the executable as a prefix of the command line,
    # then split only the arguments after it (as restore-journey.py's daemon_pids does).
    exe = os.path.join(app_path, "Contents/Resources/bin/cmux-tui")
    expect = bundle_build(app_path)
    daemons = []
    for pid, start, command in _ps_rows():
        if not command.startswith(exe + " "):
            continue
        args = command[len(exe):]
        if "--headless" not in args.split():
            continue
        sock = _flag(args, "--socket")
        daemons.append({"pid": pid, "start": start, "exe": exe, "session": _flag(args, "--session"),
                        "identify": _identify(sock) if sock else {"error": "no --socket"}})
    want = expect.get("build_identity")
    got = {d["identify"].get("build_id") for d in daemons}
    why = None
    if not daemons:
        why = "no daemon runs from the bundle"
    elif want and got != {want}:
        why = f"daemon build {sorted(map(str, got))} is not the bundle's {want}"
    return {"ok": why is None, "why": why, "daemons": daemons, "bundle": expect}


# ---------------------------------------------------------------- the closes
def budget_recent(app):
    """The monitor's newest runs, or None when `debug.action_budget` did not answer."""
    reply = app.rpc("debug.action_budget", {"limit": 64})
    if not isinstance(reply, dict) or reply.get("error") or not isinstance(reply.get("recent"), list):
        return None
    return reply["recent"]


def budget_runs(app, after):
    recent = budget_recent(app)
    return None if recent is None else [r for r in recent if r.get("sequence", -1) > after]


def last_sequence(app):
    """The newest run's sequence (-1 with no run yet), or None when the budget read failed."""
    recent = budget_recent(app)
    return None if recent is None else max([r.get("sequence", -1) for r in recent] or [-1])


def open_windows(app):
    """The ids of the open, visible main windows, or None when `debug.windows` did not answer."""
    report = app.rpc("debug.windows")
    if not isinstance(report, dict) or report.get("error") or not isinstance(report.get("windows"), list):
        return None
    return {w["id"] for w in report["windows"] if w.get("open") and w.get("visible")}


def debug_settings_open(app):
    """Whether Debug Settings is open: with it closed `debug.key` answers "Debug Settings is not open"; with it open,
    a dry run answers "dry_run needs the shell window" and runs nothing. None when neither answer came."""
    error = str((app.rpc("debug.key", {"target": "debugSettings", "key": "escape", "dry_run": True}) or {}).get("error", ""))
    return False if "not open" in error else True if "dry_run" in error else None


def close_window_round(app):
    before = open_windows(app)
    if before is None:
        return {"error": "debug.windows did not answer"}
    app.rpc("action.run", {"action": "newWindow", "args": {}, "focus": True, "origin": "script"}, timeout=120)
    fresh = AP.wait(lambda: sorted((open_windows(app) or set()) - before), 30)
    if not fresh:
        return {"error": "New Window opened no window"}
    active = app.activate()
    time.sleep(0.4)  # test script: let the new window settle (ordering in, first frame) before the close
    focus = app.rpc("debug.focus") or {}
    seq = last_sequence(app)
    if seq is None:
        return {"error": "debug.action_budget did not answer before the close"}
    reply = app.rpc("debug.key", {"window": fresh[0], "key": "w", "modifiers": ["control", "cmd"]})
    closed = AP.wait(lambda: (lambda now: now is not None and fresh[0] not in now)(open_windows(app)), 10)
    time.sleep(0.3)  # test script: the monitor hands the run over after its commit
    runs = budget_runs(app, seq)
    if runs is None:
        return {"error": "debug.action_budget did not answer after the close"}
    runs = [r for r in runs if r.get("id") == "closeWindow"]
    key = {k: reply.get(k) for k in ("handled_by", "action", "error")} if isinstance(reply, dict) else {"error": str(reply)}
    return {"window": fresh[0], "closed": bool(closed), "activated": bool(active), "app_active": focus.get("app_active"),
            "key_window": focus.get("key_window"), "key_reply": key, "run": runs[0] if runs else None,
            # Counted only when the app was active (the flash draws only then), the key went through the app's own
            # dispatch, the window closed and the close left its closeWindow run.
            "valid": bool(closed and runs and focus.get("app_active") is True and key.get("handled_by") == "app")}


def close_key_round(app):
    app.rpc("action.run", {"action": "openDebugSettings", "args": {}, "focus": True, "origin": "script"}, timeout=60)
    if not AP.wait(lambda: debug_settings_open(app) is True, 10):
        return {"error": "Debug Settings did not open (DevTools is off in a Release or bench build: use --config=debug)"}
    active = app.activate()
    time.sleep(0.4)  # test script: let the window settle before the close
    focus = app.rpc("debug.focus") or {}
    seq = last_sequence(app)
    if seq is None:
        return {"error": "debug.action_budget did not answer before the close"}
    reply = app.rpc("debug.key", {"target": "debugSettings", "key": "w", "modifiers": ["cmd"]})
    if isinstance(reply, dict) and reply.get("error"):
        return {"error": f"close key: {reply['error']}"}
    closed = AP.wait(lambda: debug_settings_open(app) is False, 10)
    time.sleep(0.3)  # test script: the monitor hands the run over after its commit
    runs = budget_runs(app, seq)
    if runs is None:
        return {"error": "debug.action_budget did not answer after the close"}
    # The close key runs a close action (closeTab, ...) through the key window route, which closes Debug Settings.
    # A key that fell through to a main window would close a tab and leave Debug Settings open: not counted.
    runs = [r for r in runs if str(r.get("id", "")).startswith("close")]
    key = {k: reply.get(k) for k in ("handled_by", "action", "error")} if isinstance(reply, dict) else {"error": str(reply)}
    return {"closed": bool(closed), "activated": bool(active), "app_active": focus.get("app_active"),
            "key_window": focus.get("key_window"), "key_reply": key, "runs": runs, "run": runs[0] if runs else None,
            "valid": bool(closed and runs and focus.get("app_active") is True)}


def stats(values):
    if not values:
        return None
    s = sorted(values)

    def q(p):
        return round(s[min(len(s) - 1, max(0, int(round(p * (len(s) - 1)))))], 3)
    return {"n": len(s), "p50": q(0.5), "p95": q(0.95), "p99": q(0.99), "max": round(s[-1], 3), "min": round(s[0], 3)}


def main(argv):
    import argparse
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="close-flash-"))
    parser.add_argument("--close-rounds", type=int, default=25)
    parser.add_argument("--arm", default="", help="a label for the A/B arm, printed in the report")
    parser.add_argument("--kinds", default="closeWindow,closeKey", help="the closes to measure (closeWindow, closeKey)")
    opts = parser.parse_args(argv)
    rounds_of = {"closeWindow": close_window_round, "closeKey": close_key_round}
    kinds = [k for k in opts.kinds.split(",") if k]
    if not kinds or any(k not in rounds_of for k in kinds):
        parser.error(f"--kinds takes closeWindow and/or closeKey (got {opts.kinds!r})")
    os.makedirs(opts.out, exist_ok=True)
    report = {"arm": opts.arm, "host": os.uname().nodename, "kinds": kinds,
              "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip(),
              "rounds": {kind: [] for kind in kinds}, "failures": []}
    app = ActiveApp(os.path.abspath(opts.app), opts.out, 50)
    try:
        app.launch()
        report["daemon_start"] = daemon_check(app.bundle)
        for _ in range(opts.close_rounds):
            for kind in kinds:
                report["rounds"][kind].append(rounds_of[kind](app))
        report["daemon_end"] = daemon_check(app.bundle)
    finally:
        app.stop()
    summary = {}
    for kind, rounds in report["rounds"].items():
        valid = [r["run"] for r in rounds if r.get("valid")]
        timed = [r for r in valid if r.get("outcome") != "missed"]
        by_outcome = {}
        for run in valid:
            by_outcome.setdefault(str(run.get("outcome")), []).append(run["commit_ms"])
        checked = [r for r in rounds if not r.get("error")]
        summary[kind] = {
            # The A/B number: valid closes whose commit was timed (a `missed` commit's time includes idle time).
            "commit_ms": stats([r["commit_ms"] for r in timed]),
            "commit_ms_by_outcome": {o: stats(v) for o, v in sorted(by_outcome.items())},
            "outcomes": {o: len(v) for o, v in sorted(by_outcome.items())},
            "ids": sorted({r.get("id") for r in valid}), "entrypoints": sorted({r.get("entrypoint") for r in valid}),
            "rounds": len(rounds), "valid": len(valid),
            "invalid": {"error": len(rounds) - len(checked),
                        "app_inactive": sum(1 for r in checked if r.get("app_active") is not True),
                        "not_closed": sum(1 for r in checked if not r.get("closed")),
                        "no_run": sum(1 for r in checked if not r.get("run")),
                        "not_app_dispatch": sum(1 for r in checked if kind == "closeWindow"
                                                and (r.get("key_reply") or {}).get("handled_by") != "app")},
            "errors": sorted({r["error"] for r in rounds if r.get("error")})[:5]}
        if len(valid) < max(1, opts.close_rounds * 4 // 5):
            report["failures"].append(f"{kind}: only {len(valid)} of {len(rounds)} closes are valid (active app, closed, "
                                      f"its close run recorded): {summary[kind]['invalid']}")
    if not (report.get("daemon_start") or {}).get("ok"):
        report["failures"].append(f"daemon: {(report.get('daemon_start') or {}).get('why')}")
    report["summary"] = summary
    with open(os.path.join(opts.out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    print("CLOSE-FLASH-DAEMON " + json.dumps({"arm": opts.arm, "start": report.get("daemon_start"), "end": report.get("daemon_end")}), flush=True)
    print("CLOSE-FLASH " + json.dumps({"arm": opts.arm, "host": report["host"], "summary": summary, "failures": report["failures"]}), flush=True)
    return 1 if report["failures"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
