#!/usr/bin/env python3
"""Render damage per owner at idle and in motion: the MQ-damage-owners queue (plans/cmux-next/chrome-parity/
p03-rendering.md, R4, DC7r and task 003).

Chrome's model: cc::DamageTracker (cc/trees/damage_tracker.cc) names the layers that damaged a frame, and
viz::DisplayDamageTracker (components/viz/service/display/display_damage_tracker.cc) draws no frame when no surface
has damage. An idle cmux window should damage nothing: 0 damage rects per second and 0 Ghostty frames.

What it does, through the debug socket of a tagged DEBUG or bench app (`debug.damage`, CmuxNextDesign RenderDamageWindow.swift):

  1. The session. `--session stress` (default) builds STRESS (perf-stress-session.py: 60 workspaces, the 4x3 grid,
     its shape checked) and then stops its 10 busy terminals' output loops, so the session is at rest.
     `--session light` builds nothing more. Then the idle workspace, new, shown and last: one pane with
     `--tabs` (10) Chromium tabs on a static local page (no script, no animation) and a terminal at a shell prompt,
     selected and focused, with a blinking cursor (`cursor-style-blink = true`; Ghostty blinks only in the key
     window, so the app is launched without CMUX_NEXT_NO_ACTIVATE; `--no-activate` keeps it, and the report then
     says the cursor did not blink).
  2. The idle pass: `--settle` seconds (pages load, the session settles), then one `debug.damage` window of
     `--idle-s` (60) seconds.
  3. The motion pass (`--no-motion` skips it): the DC2 scenarios, `--rounds` (3) each, one `debug.damage` window
     per round around the measured step only (setup and undo stay outside). Counts, never time: RenderStats' hooks
     cost time, so nothing here reports ms (motion-hitches.py times the same scenarios with the hooks off).

The session is checked before anything is measured: a STRESS shape problem, Chromium that is not running
(`debug.cef`), an idle pane without its tabs, or a terminal that is not the selected tab exits 2 with the reason.
An app without the hooks (a Release build: `debug.damage` is `method_not_found`, or `available: false`) exits 2 with
"unavailable". A socket that does not answer (no app, a wrong `--socket`, a crash) or an idle window that did not
open or whose stop has no counts exits 3 with the reply: never a pass without data. A motion round whose window did
not open or whose stop has no counts goes into its scenario's `errors` and `failed_rounds` and is left out of the
sums; the socket going away in the motion pass ends it (`motion_incomplete`) and the report is still written.
Otherwise it writes the report and exits 0, or 1 with `--fail-on-damage` when the idle pass has damage or Ghostty
frames (the DC7r target).

Usage (on the fleet; never on a person's Mac):
  python3 scripts/cmux-next/render-idle-damage.py --app "/path/cmux DEV <tag>.app" --out DIR --vdisplay 120
  python3 scripts/cmux-next/render-idle-damage.py --socket ~/.local/state/cmux/cmux-debug-<tag>.sock --session light

Output: DIR/render-idle-damage.json, the table of owners on stdout, and one line `RENDER-IDLE-DAMAGE {summary}`.

JSON schema (`schema: "cmux-render-idle-damage/v1"`):
  schema            "cmux-render-idle-damage/v1"
  host              {host, macos, macos_build, chip, memory_bytes, display_hz, low_power_mode} (bench_launch)
  app               {tag, sha, socket} of the measured app
  conditions        {session: "stress" | "light", vdisplay_hz, chromium_tabs, idle_s, settle_s, rounds,
                     key_window: bool, cursor_blink: bool, busy_stopped: int, stress: <STRESS summary> | null}
  idle              the `debug.damage` stop reply of the idle pass (below)
  motion            [{scenario, rounds: [<debug.damage stop reply>], failed_rounds: int, errors: [str], damage,
                    owners: [owner row]}] (the rounds with counts only, owners summed over them; [] with --no-motion)
  motion_incomplete null, or why the motion pass ended early (the socket stopped answering)
  queue             the MQ-damage-owners queue: every owner with damage > 0 at idle or in a motion scenario,
                    [{owner, idle_damage, idle_damage_per_s, idle_damage_area, idle_contents_sets,
                      motion_damage, scenarios: {scenario: damage}}], most idle damage first, then most motion
                    damage, then by name
  pass              {idle_damage_zero: bool, ghostty_idle_frames_zero: bool}

A `debug.damage` reply: {available, running, seconds, totals: {frame_sets, layouts, damage_rects, damage_area,
contents_sets, window_calls, tracking_area_adds}, damage (damage_rects + contents_sets of all owners),
damage_per_s, owners: [owner row], ghostty: {frames (contents sets of TerminalSurfaceView / IOSurfaceLayer),
frames_per_s, display_calls (-[IOSurfaceLayer display] calls in the window, or null)}, hidden_looping_animations,
hidden_looping_owners: {owner: count}}. An owner row: {owner (class name), damage, damage_per_s, and each nonzero
counter key}; only owners with damage > 0, most first.

Tests: python3 -I scripts/cmux-next/tests/test_render_idle_damage.py (no app).
"""
import argparse
import http.server
import importlib.util
import json
import os
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA = "cmux-render-idle-damage/v1"
STATIC_PAGE = "<!doctype html><meta charset='utf-8'><title>idle %d</title><h1>static page %d</h1><p>no script, no animation</p>"
GHOSTTY_CONFIG = "cursor-style-blink = true\n"
COUNTERS = ("frame_sets", "layouts", "damage_rects", "damage_area", "contents_sets", "window_calls", "tracking_area_adds")


class Unavailable(Exception):
    """The app has no render hooks (Release) or no `debug.damage`: exit 2."""


class MeasureError(Exception):
    """The socket did not answer, or the idle window gave no counts: exit 3, never a pass."""


class ShapeError(Exception):
    """The session is not the one this bench measures: exit 2."""


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, HERE)
    spec.loader.exec_module(module)
    return module


# ---------------------------------------------------------------------------
# Pure parts (tested without an app)

def unreachable_reason(reply):
    """Why the debug socket gave no reply (bench_launch.rpc_at's `unreachable`), or None."""
    if isinstance(reply, dict) and reply.get("unreachable"):
        return f"the debug socket did not answer: {str(reply.get('error'))[:200]}"
    return None


def unavailable_reason(reply):
    """Why `reply` (to `debug.damage`) says this build has no hooks, or None. Only `available: false` or the router's
    `method_not_found` (a Release build registers no debug.* method) mean that; an unreachable socket does not."""
    if not isinstance(reply, dict) or reply.get("unreachable"):
        return None
    if reply.get("available") is False:
        return str(reply.get("error") or "debug.damage is unavailable in this build")
    error = reply.get("error")
    if "available" not in reply and isinstance(error, dict) and error.get("code") == "method_not_found":
        return f"debug.damage is not a method of this app (a Release build registers no debug.* method): {str(error)[:160]}"
    return None


def read_problem(reply):
    """Why a `debug.damage` read reply is not a working one (unreachable, unavailable or failed), or None."""
    reason = unreachable_reason(reply) or unavailable_reason(reply)
    if reason:
        return reason
    if not isinstance(reply, dict) or reply.get("error") or reply.get("available") is not True:
        return f"debug.damage read answered {str(reply)[:200]}"
    return None


def start_problem(reply):
    """Why a `debug.damage` start did not open a window, or None."""
    if isinstance(reply, dict) and reply.get("running") is True and not reply.get("error"):
        return None
    return unreachable_reason(reply) or f"debug.damage start answered {str(reply)[:200]}"


def stop_problem(reply):
    """Why a `debug.damage` stop reply holds no counts of a window, or None."""
    if not isinstance(reply, dict):
        return f"debug.damage stop answered {str(reply)[:120]}"
    if reply.get("unreachable"):
        return unreachable_reason(reply)
    if reply.get("error") or reply.get("available") is not True:
        return f"debug.damage stop failed: {str(reply)[:200]}"
    if not is_count(reply.get("damage")) or not is_count(reply.get("seconds")):
        return f"debug.damage stop has no counts (no window was open): {str(reply)[:200]}"
    return None


def is_count(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def damage_of(row):
    return int(row.get("damage_rects") or 0) + int(row.get("contents_sets") or 0)


def sum_owners(replies):
    """The owner rows of several `debug.damage` replies, summed by owner (damage > 0 only), most damage first."""
    sums = {}
    for reply in replies:
        for row in (reply or {}).get("owners") or []:
            owner = row.get("owner")
            if not owner:
                continue
            total = sums.setdefault(owner, {"owner": owner})
            for key in COUNTERS:
                if row.get(key):
                    total[key] = total.get(key, 0) + int(row[key])
    rows = []
    for total in sums.values():
        total["damage"] = damage_of(total)
        if total["damage"] > 0:
            rows.append(total)
    return sorted(rows, key=lambda r: (-r["damage"], -r.get("damage_area", 0), r["owner"]))


def owner_queue(idle, motion):
    """The MQ-damage-owners queue: every owner with damage at idle (`idle`, a debug.damage reply) or in a motion
    scenario (`motion`, the report's motion list)."""
    queue = {}

    def entry(owner):
        return queue.setdefault(owner, {"owner": owner, "idle_damage": 0, "idle_damage_per_s": 0.0, "idle_damage_area": 0,
                                        "idle_contents_sets": 0, "motion_damage": 0, "scenarios": {}})
    for row in (idle or {}).get("owners") or []:
        if not row.get("owner") or damage_of(row) <= 0:
            continue
        item = entry(row["owner"])
        item["idle_damage"] = damage_of(row)
        item["idle_damage_per_s"] = float(row.get("damage_per_s") or 0)
        item["idle_damage_area"] = int(row.get("damage_area") or 0)
        item["idle_contents_sets"] = int(row.get("contents_sets") or 0)
    for scenario in motion or []:
        for row in scenario.get("owners") or []:
            if not row.get("owner") or damage_of(row) <= 0:
                continue
            item = entry(row["owner"])
            item["motion_damage"] += damage_of(row)
            item["scenarios"][scenario["scenario"]] = item["scenarios"].get(scenario["scenario"], 0) + damage_of(row)
    return sorted(queue.values(), key=lambda q: (-q["idle_damage"], -q["motion_damage"], q["owner"]))


def verdict(idle):
    """The DC7r target; a reply without the counts never passes (`run` exits 3 before it gets here)."""
    counted = stop_problem(idle) is None
    damage = idle.get("damage") if counted else None
    frames = (idle.get("ghostty") or {}).get("frames") if counted else None
    return {"idle_damage_zero": is_count(damage) and damage == 0,
            "ghostty_idle_frames_zero": is_count(frames) and frames == 0}


def table(queue, limit=40):
    """The queue as text, one owner per line."""
    if not queue:
        return "render-idle-damage: no owner damaged anything (idle and motion)"
    lines = [f"{'owner':<48} {'idle/s':>8} {'idle':>8} {'area':>12} {'motion':>8}  scenarios"]
    for item in queue[:limit]:
        scenarios = ", ".join(f"{name} {count}" for name, count in sorted(item["scenarios"].items(), key=lambda s: (-s[1], s[0])))
        lines.append(f"{item['owner'][:48]:<48} {item['idle_damage_per_s']:>8.2f} {item['idle_damage']:>8} "
                     f"{item['idle_damage_area']:>12} {item['motion_damage']:>8}  {scenarios}")
    if len(queue) > limit:
        lines.append(f"... {len(queue) - limit} more in the JSON")
    return "\n".join(lines)


def idle_problems(pane_tabs, chromium_tabs, cef, cef_problems):
    """Why the idle pane is not `chromium_tabs` Chromium tabs and a selected terminal (topology tabs), or []."""
    problems = []
    kinds = [t.get("kind") for t in pane_tabs]
    browsers = kinds.count("browser")
    if browsers < chromium_tabs:
        problems.append(f"the idle pane has {browsers} browser tabs, not {chromium_tabs} ({kinds})")
    selected = next((t for t in pane_tabs if t.get("selected")), None)
    if not selected or selected.get("kind") != "terminal":
        problems.append(f"the idle pane's selected tab is {selected and selected.get('kind')}, not a terminal")
    problems += cef_problems(cef)
    return problems


# ---------------------------------------------------------------------------
# The run

class StaticPages:
    """Local static pages for the idle pane's Chromium tabs, served on 127.0.0.1 (no script, no animation, no
    network). Same interface as perf-stress-session's Pages (`url()`, `close()`), whose pages run a rAF spinner."""

    def __init__(self):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                index = page_index(self.path)
                data = (STATIC_PAGE % (index, index)).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
        self.next = 0

    def url(self):
        self.next += 1
        return f"http://127.0.0.1:{self.server.server_address[1]}/idle/{self.next}"

    def close(self):
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
            self.server = None


def page_index(path):
    """The page number at the end of a StaticPages URL path, 0 when there is none."""
    last = path.split("?")[0].rstrip("/").split("/")[-1]
    return int(last) if last.isdigit() else 0


class Bench:
    def __init__(self, rpc, stress_module, opts, log=print):
        self.rpc, self.opts, self.log = rpc, opts, log
        self.stress_module = stress_module
        self.stress = stress_module.Stress(rpc, log=lambda line: log(line, flush=True))
        self.workspace = self.pane = self.terminal = None
        self.chromium = []

    def action(self, name, args=None, target=None, focus=True, timeout=60):
        params = {"action": name, "args": args or {}, "focus": focus, "origin": "script"}
        if target:
            params["target"] = target
        return self.rpc("action.run", params, timeout=timeout)

    def panes(self):
        return [p["id"] for p in self.stress.panes(self.stress.workspace(self.workspace))]

    def check_available(self):
        reply = self.rpc("debug.damage", {"action": "read"})
        reason = unavailable_reason(reply)
        if reason:
            raise Unavailable(f"render-idle-damage: unavailable: {reason}")
        reason = read_problem(reply)
        if reason:
            raise MeasureError(f"render-idle-damage: {reason}")

    def build(self):
        summary, busy_stopped = None, 0
        if self.opts.session == "stress":
            try:
                summary = self.stress.build()
            except self.stress_module.StressShapeError as error:
                raise ShapeError(f"render-idle-damage: wrong session shape: {error}")
            for tab in getattr(self.stress, "busy", []):
                self.stress.send(tab, "\x03")  # ETX: the shell's SIGINT ends the output loop
                busy_stopped += 1
        self.stress.pages.close()
        self.stress.pages = StaticPages()
        workspace = self.stress.new_workspace()
        if not workspace:
            raise ShapeError("render-idle-damage: wrong session shape: the idle workspace did not appear")
        self.workspace = workspace
        self.stress.show(workspace)
        self.pane = self.panes()[0]
        self.stress.focus_pane(self.pane)
        try:
            for _ in range(self.opts.tabs):
                self.stress.add_tab(workspace, self.pane, "chromium")
            self.stress.add_tab(workspace, self.pane, "terminal")
        except RuntimeError as error:  # add_tab: the tab did not appear
            raise ShapeError(f"render-idle-damage: wrong session shape: {error}")
        tabs = self.stress.tabs(workspace, self.pane)
        self.chromium = [t["id"] for t in tabs if t.get("kind") != "terminal" and t.get("id")]
        self.terminal = next((t["id"] for t in tabs if t.get("kind") == "terminal" and t.get("selected")), None)
        problems = idle_problems(tabs, self.opts.tabs, self.rpc("debug.cef"),
                                 lambda cef: self.stress_module.cef_problems(cef, self.stress.web_dev_config))
        if problems:
            raise ShapeError("render-idle-damage: wrong session shape: " + "; ".join(problems))
        self.stress.focus_pane(self.pane)
        return summary, busy_stopped

    def main_window(self):
        windows = (self.rpc("debug.window_list") or {}).get("windows") or []
        return next((w for w in windows if w.get("kind") == "main" and w.get("visible")), None) or {}

    def start_window(self):
        """Opens one `debug.damage` window (the caller stops it); why it did not open, or None."""
        return start_problem(self.rpc("debug.damage", {"action": "start"}, timeout=60))

    def stop_window(self):
        """Stops the window: (the reply, why it holds no counts or None)."""
        stopped = self.rpc("debug.damage", {"action": "stop"})
        return stopped, stop_problem(stopped)

    def idle(self):
        time.sleep(self.opts.settle)  # bench script: pages load and the session settles before the idle window
        problem = self.start_window()
        if problem:
            raise MeasureError(f"render-idle-damage: the idle window did not open: {problem}")
        time.sleep(self.opts.idle_s)  # bench script: the measured idle window
        stopped, problem = self.stop_window()
        if problem:
            raise MeasureError(f"render-idle-damage: the idle pass has no counts: {problem}")
        return stopped

    # The DC2 scenarios: (name, setup, measured step, undo). Each returns the replies it got.

    def new_pane(self, verb, target=None):
        before = set(self.panes())
        self.action(verb, target=f"pane:{target or self.pane}")
        made = self.stress_module.wait(lambda: next((p for p in self.panes() if p not in before), None), 15, step=0.1)
        self.made = made
        return {"made": made}

    def close_made(self):
        made, self.made = getattr(self, "made", None), None
        return self.action("closePane", target=f"pane:{made}") if made else {"error": "no pane to close"}

    def hover_band(self):
        height = (self.main_window().get("frame") or {}).get("height") or 0
        return self.rpc("debug.pointer_hover", {"point": [40, height - 14]}) if height else {"error": "no main window"}

    def scenarios(self):
        a = self.action
        pane = lambda: f"pane:{self.pane}"
        ws = lambda: f"workspace:{self.workspace}"
        other = lambda: next((w["id"] for w in self.stress.workspaces() if w["id"] != self.workspace), None)
        return [
            ("split-right", None, lambda: self.new_pane("splitRight"), self.close_made),
            ("split-down", None, lambda: self.new_pane("splitDown"), self.close_made),
            ("close-pane", lambda: self.new_pane("splitRight"), self.close_made, None),
            ("zoom", lambda: self.new_pane("splitRight"), lambda: a("toggleSplitZoom", target=pane()),
             lambda: (a("toggleSplitZoom", target=pane()), self.close_made())),
            ("new-column", None, lambda: self.new_pane("newColumn"), self.close_made),
            ("close-last-column", lambda: self.new_pane("newColumn"), self.close_made, None),
            ("workspace-switch", None, lambda: a("goToWorkspace", {"workspace": other()}),
             lambda: a("goToWorkspace", {"workspace": self.workspace})),
            ("strip-pan", lambda: self.new_pane("newColumn"), lambda: a("focusLeft"),
             lambda: (a("focusRight"), self.close_made())),
            ("sidebar-toggle", None, lambda: a("toggleSidebar"), lambda: a("toggleSidebar")),
            ("omnibar-toggle", lambda: a("tab.focus", target=f"tab:{self.chromium[0]}"),
             lambda: a("palette.browserToggleOmnibar"),
             lambda: (a("palette.browserToggleOmnibar"), a("tab.focus", target=f"tab:{self.terminal}"))),
            ("band-reveal", lambda: a("toggleSidebar"), self.hover_band,
             lambda: (self.rpc("debug.pointer_hover", {"point": None}), a("toggleSidebar"))),
            ("window-zoom", None, lambda: a("zoomWindow"), lambda: a("zoomWindow")),
            ("hover-card", None, lambda: self.rpc("debug.hover_sweep", {"tabs": [0, 1, 2, 1, 0]}, timeout=30),
             lambda: self.rpc("debug.pointer_hover", {"point": None})),
            ("sidebar-reorder", None, lambda: a("moveWorkspaceUp", target=ws()), lambda: a("moveWorkspaceDown", target=ws())),
        ]

    def motion(self):
        """The motion pass: (the scenario results, why it ended early or None)."""
        results, incomplete = [], None
        for name, setup, step, undo in self.scenarios():
            rounds, round_errors, errors = [], [], []
            for number in range(1, self.opts.rounds + 1):
                if setup:
                    errors += replies_errors(setup())
                    time.sleep(self.opts.step_settle)  # bench script: the setup's motion ends outside the window
                # The step and its undo run even when the window did not open, so the session stays the same.
                problem = self.start_window()
                errors += replies_errors(step())
                time.sleep(self.opts.step_settle)  # bench script: the measured motion runs to its end
                # Stopped even after a failed start: a late window closes, and its reply is not counted.
                stopped, stop_failed = self.stop_window()
                problem = problem or stop_failed
                if problem:
                    round_errors.append(f"round {number}: {problem}")
                else:
                    rounds.append(stopped)
                if unreachable_reason(stopped):
                    incomplete = f"{name} round {number}: {unreachable_reason(stopped)}"
                    break
                if undo:
                    errors += replies_errors(undo())
                    time.sleep(self.opts.step_settle)  # bench script: the undo's motion ends before the next round
            if not incomplete:
                self.stress.focus_pane(self.pane)
            owners = sum_owners(rounds)
            errors = round_errors + errors
            results.append({"scenario": name, "rounds": rounds, "failed_rounds": len(round_errors), "errors": errors[:12],
                            "damage": sum(int(r["damage"]) for r in rounds), "owners": owners})
            self.log(f"render-idle-damage: {name}: damage {results[-1]['damage']}, {len(owners)} owners"
                     + (f", {len(round_errors)} failed rounds" if round_errors else "")
                     + (f", errors {errors[:2]}" if errors else ""), flush=True)
            if incomplete:
                self.log(f"render-idle-damage: the motion pass ended early: {incomplete}", flush=True)
                break
        return results, incomplete


def replies_errors(replies):
    """The error texts in an action's reply (or a tuple of replies)."""
    items = replies if isinstance(replies, tuple) else (replies,)
    return [str(r.get("error"))[:160] for r in items if isinstance(r, dict) and r.get("error")]


def run(opts):
    launch = load("bench_launch", "bench_launch.py")
    stress_module = load("perf_stress_session", "perf-stress-session.py")
    os.makedirs(opts.out, exist_ok=True)
    app = display = bench = None
    try:
        if opts.app and opts.vdisplay:
            display = stress_module.start_vdisplay(opts.vdisplay, opts.out, opts.vdisplay_hold)
        if opts.app:
            env = {} if opts.no_activate else {"CMUX_NEXT_NO_ACTIVATE": None}
            app = launch.BenchApp(opts.app, out=opts.out, env=env, window=None,
                                  perf_session="stress" if opts.session == "stress" else "light")
            with open(os.path.join(app.scratch, "ghostty"), "w") as f:
                f.write(GHOSTTY_CONFIG)
            app.launch()
            rpc, socket_path, tag = app.rpc, app.socket, app.tag
            sha = launch.build_sha(app.app)
        else:
            socket_path, tag, sha = opts.socket, None, None
            rpc = lambda method, params=None, timeout=60: launch.rpc_at(socket_path, method, params, timeout)
        bench = Bench(rpc, stress_module, opts)
        bench.check_available()
        stress_summary, busy_stopped = bench.build()
        key_window = bool(bench.main_window().get("key"))
        if not key_window and not opts.no_activate:
            raise ShapeError("render-idle-damage: wrong session shape: the main window is not key, so the focused "
                             "terminal's cursor does not blink (pass --no-activate to measure that on purpose)")
        idle = bench.idle()
        motion, motion_incomplete = bench.motion() if opts.motion else ([], None)
        host = dict(launch.read_host())
        host.update(launch.host_facts())
        report = {
            "schema": SCHEMA, "host": host, "app": {"tag": tag, "sha": sha, "socket": socket_path},
            "conditions": {"session": opts.session, "vdisplay_hz": opts.vdisplay or None, "chromium_tabs": opts.tabs,
                           "idle_s": opts.idle_s, "settle_s": opts.settle, "rounds": opts.rounds, "key_window": key_window,
                           "cursor_blink": key_window, "busy_stopped": busy_stopped, "stress": stress_summary},
            "idle": idle, "motion": motion, "motion_incomplete": motion_incomplete, "queue": owner_queue(idle, motion),
            "pass": verdict(idle),
        }
    except (Unavailable, ShapeError, stress_module.StressShapeError) as error:
        message = str(error)
        print(message if message.startswith("render-idle-damage:") else f"render-idle-damage: wrong session shape: {message}",
              file=sys.stderr, flush=True)
        return 2
    except MeasureError as error:
        print(str(error), file=sys.stderr, flush=True)
        return 3
    finally:
        if bench:
            bench.stress.pages.close()
        if app and not opts.keep:
            app.stop()
        if display and not opts.keep:
            display.terminate()  # the helper this script started, by its process
    path = os.path.join(opts.out, "render-idle-damage.json")
    with open(path, "w") as f:
        json.dump(report, f, indent=1)
    print(table(report["queue"]), flush=True)
    summary = {"json": path, "idle_damage": (idle or {}).get("damage"), "idle_damage_per_s": (idle or {}).get("damage_per_s"),
               "ghostty_idle_frames": ((idle or {}).get("ghostty") or {}).get("frames"), "owners": len(report["queue"]),
               **report["pass"]}
    print("RENDER-IDLE-DAMAGE " + json.dumps(summary), flush=True)
    if opts.fail_on_damage and not all(report["pass"].values()):
        return 1
    return 0


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--app", help="a DEBUG or bench `cmux DEV <tag>.app` to launch (not running)")
    where.add_argument("--socket", help="the debug socket of a running tagged app (no launch)")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="render-idle-damage-"))
    parser.add_argument("--session", choices=["stress", "light"], default="stress")
    parser.add_argument("--tabs", type=int, default=10, help="Chromium tabs in the idle pane")
    parser.add_argument("--idle-s", type=float, default=60)
    parser.add_argument("--settle", type=float, default=15, help="seconds of rest before the idle window")
    parser.add_argument("--rounds", type=int, default=3, help="rounds of each motion scenario")
    parser.add_argument("--step-settle", type=float, default=1.0, help="seconds each motion step and undo get")
    parser.add_argument("--no-motion", dest="motion", action="store_false", help="only the idle pass")
    parser.add_argument("--no-activate", action="store_true",
                        help="keep CMUX_NEXT_NO_ACTIVATE: the window is never key and the cursor does not blink")
    parser.add_argument("--vdisplay", type=float, default=0, help="with --app: a 1920 x 1200 virtual main display at this Hz")
    parser.add_argument("--vdisplay-hold", type=float, default=1800)
    parser.add_argument("--fail-on-damage", action="store_true", help="exit 1 when the idle pass has damage or Ghostty frames")
    parser.add_argument("--keep", action="store_true", help="leave the launched app running")
    return parser.parse_args(argv)


if __name__ == "__main__":
    sys.exit(run(parse()))
