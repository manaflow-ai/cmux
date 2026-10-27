#!/usr/bin/env python3
"""Tab and workspace switch benchmark for a tagged cmux-next build
(plans/cmux-next/tab-lifecycle.md).

Launches the tagged app through bench_launch.BenchApp (the bench env, no
activation, test window on the last screen, scratch config, a fresh saved
session, the tag teardown), builds a workload, then drives
selection changes at key-repeat speed through the app's own socket
(`debug.key` delivers Ctrl-Tab to this app only; `action.run` switches
workspaces). No system input is synthesized.

Workload: one pane with --tabs mixed tabs (every other one a Chromium page
on a local static file, the rest terminals), plus --workspaces extra
workspaces with one terminal each (one of them with a Chromium tab).

Scenarios (each --seconds long, one selection change every --interval ms):
  tab-repeat       Ctrl-Tab held: next tab across all mixed tabs
  tab-mixed        alternate one terminal and one Chromium tab (both directions)
  tab-back-forth   Ctrl-Tab then Ctrl-Shift-Tab (the user's repro of the
                   disappearing page)
  workspace-repeat next workspace, wrapping

Per scenario: display frame intervals (`debug.frames`), main-thread stalls
(`debug.hangs`), app physical footprint before/after, and the content
invariant sampled after every change and once after the scenario settles:
the selected tab of every visible pane shows its content, and for a
Chromium tab its page window is visible over the pane (`debug.surfaces`
`content_visible` when the build has it; else `debug.cef` child windows).

Each scenario's raw per-frame samples go to the out folder as
cmux-perf-result/v1 through BenchApp.record (story --story):
  switch_repeat.<scenario>.frame_interval  ms between displayed frames
  switch_repeat.<scenario>.main_busy       main-thread busy ms per frame
  switch_repeat.<scenario>.stalls          main-thread stalls (count)
The frame percentiles (p50, p95, p99) are the app's own `debug.frames`.

Usage:
  scripts/cmux-next/bench-tab-switch.sh <tag> [--app PATH] [--tabs 20]
      [--workspaces 6] [--seconds 10] [--interval 33] [--scenarios ...]
      [--label NAME] [--out DIR] [--keep-running] [--story tab-switch-repeat]
      [--session light]

Writes artifacts/cmux-next-bench/<sha>-tabswitch-<label>.json.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_idle import Client, usage, wait_for_socket  # noqa: E402
from bench_frames import split_raw_frames  # noqa: E402
from bench_launch import BenchApp, PERF_LAB, RecordError, load_by_path  # noqa: E402

perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))

COLORS = ["#c0392b", "#27ae60", "#2980b9", "#8e44ad", "#d35400", "#16a085", "#2c3e50", "#f39c12", "#7f8c8d", "#e84393"]


def page_html(index: int) -> str:
    color = COLORS[index % len(COLORS)]
    return (f"<!doctype html><title>page {index}</title><body style='margin:0;background:{color};color:white;"
            f"font:48px -apple-system'><p style='padding:40px'>page {index}</p></body>")


def refused(response):
    if not isinstance(response, dict):
        return "no response"
    if response.get("ok") is False or "error" in response:
        return response.get("error") or "refused"
    return None


def result(response):
    return (response or {}).get("result") or {}


class Bench:
    def __init__(self, control: Client, app_pid: int, args):
        self.control = control
        self.app_pid = app_pid
        self.args = args
        self.lag_samples = 0
        self.samples = {}  # scenario -> {series: raw samples}, for result-v1 (the report keeps the summaries)

    # -- workload -------------------------------------------------------

    def surfaces(self):
        return result(self.control.call("debug.surfaces", timeout=10))

    def visible_panes(self):
        rows = []
        for window in self.surfaces().get("windows", []):
            rows += [p for p in window.get("panes", []) if p.get("visible")]
        return rows

    def topology(self):
        return result(self.control.call("snapshot.get", timeout=10)).get("topology") or {}

    def focused_pane_tabs(self):
        topology = self.topology()
        pane_id = (topology.get("focus") or {}).get("pane")
        for workspace in topology.get("workspaces", []):
            for screen in workspace.get("screens", []):
                for pane in screen.get("panes", []):
                    if pane.get("id") == pane_id:
                        return pane.get("tabs", [])
        return []

    def wait_tabs(self, count, limit_s=60):
        deadline = time.monotonic() + limit_s
        while time.monotonic() < deadline:
            if len(self.focused_pane_tabs()) >= count:
                return True
            time.sleep(0.2)  # test script: waiting for the daemon to add the tab
        return False

    def action_retry(self, name, limit_s=15, **args):
        """`action.run`, retried while the app reports no focused pane yet
        (a workspace switch or close settles focus a moment later)."""
        deadline = time.monotonic() + limit_s
        while True:
            response = self.control.action(name, timeout=90, **args)
            reason = refused(response)
            if reason is None or "No pane is focused" not in str(reason) or time.monotonic() > deadline:
                return response
            time.sleep(0.25)  # test script: waiting for focus to settle

    def build_workload(self, scratch):
        tabs, workspaces = self.args.tabs, self.args.workspaces
        # A fresh workspace; the tagged daemon keeps earlier runs' workspaces.
        for reason in [refused(self.control.action("workspace new", timeout=30)),
                       refused(self.control.action("palette.closeOtherWorkspaces", timeout=30, confirm=True))]:
            if reason:
                raise SystemExit(f"bench-tab-switch: could not reset workspaces: {reason}")
        time.sleep(1)  # test script: let the close settle
        if not self.wait_tabs(1):
            raise SystemExit("bench-tab-switch: the fresh workspace has no tab")
        home = (self.topology().get("focus") or {}).get("workspace")
        for index in range(1, tabs):
            if index % 2 == 1:
                path = os.path.join(scratch, f"page{index}.html")
                with open(path, "w") as handle:
                    handle.write(page_html(index))
                reason = refused(self.action_retry("openBrowser.chromium", url="file://" + path))
            else:
                reason = refused(self.action_retry("newSurface"))
            if reason or not self.wait_tabs(index + 1):
                raise SystemExit(f"bench-tab-switch: could not create tab {index}: {reason or 'timeout'}")
        for index in range(workspaces):
            reason = refused(self.control.action("workspace new", timeout=30))
            if reason:
                raise SystemExit(f"bench-tab-switch: could not create workspace {index}: {reason}")
            time.sleep(0.5)  # test script: the new workspace's terminal attaches
            if index == 1:
                path = os.path.join(scratch, f"ws{index}.html")
                with open(path, "w") as handle:
                    handle.write(page_html(index + 3))
                self.control.action("openBrowser.chromium", timeout=90, url="file://" + path)
                self.wait_tabs(2)
        # Back to the first workspace, then visit every tab once so each
        # Chromium page exists (warm) before the measured runs.
        order = [w.get("id") for w in self.topology().get("workspaces", [])]
        self.home_index = order.index(home) + 1 if home in order else 1
        self.control.action("selectWorkspaceByNumber", timeout=10, index=self.home_index)
        time.sleep(1)  # test script: let the switch settle
        if len(self.focused_pane_tabs()) != tabs:
            raise SystemExit(f"bench-tab-switch: first workspace has {len(self.focused_pane_tabs())} tabs, want {tabs}")
        for _ in range(tabs):
            self.key("tab", ["control"])
            time.sleep(0.4)  # test script: slow warm-up visit, one tab at a time
        time.sleep(2)  # test script: pages finish loading

    # -- input ----------------------------------------------------------

    def key(self, name, modifiers):
        return self.control.call("debug.key", {"key": name, "modifiers": modifiers}, timeout=10)

    def next_workspace(self):
        return self.control.action("nextSidebarTab", timeout=10)

    # -- measurement ----------------------------------------------------

    def invariant(self):
        """Violations of: the selected tab of every visible pane shows its
        content, and a Chromium page is visible over it."""
        violations = []
        surfaces = self.surfaces()
        has_content_visible = False
        for window in surfaces.get("windows", []):
            for pane in window.get("panes", []):
                if not pane.get("visible") or pane.get("selected_tab") is None:
                    continue
                lagging = pane.get("shown_tab") not in (None, pane.get("selected_tab")) and pane.get("content_visible", False)
                if pane.get("blank") and lagging:
                    # The previous tab still shows, drawn, until the next
                    # display frame presents the new selection (per-frame
                    # coalescing): not a blank frame. Counted apart.
                    self.lag_samples += 1
                elif pane.get("blank"):
                    violations.append(f"blank pane {pane['pane']} selected={pane.get('selected_tab')} shown={pane.get('shown_tab')}")
                if "content_visible" in pane:
                    has_content_visible = True
                    if not pane["content_visible"]:
                        violations.append(f"hidden content in pane {pane['pane']} tab={pane.get('selected_tab')} kind={pane.get('kind')}")
        if not has_content_visible:
            # Older builds: the Chromium child windows over each shown page.
            cef = result(self.control.call("debug.cef", timeout=10))
            for page in cef.get("devtools", []):
                children = [c for c in page.get("child_windows", []) if not c.get("devtools")]
                if not any(c.get("visible") for c in children):
                    violations.append(f"chromium page not visible pane={page.get('pane')} tab={page.get('tab')}")
        return violations

    def run(self, name, step):
        control = self.control
        hangs_before = result(control.call("debug.hangs", {"limit": 0}, timeout=10))
        before = usage(self.app_pid)
        control.call("debug.frames", {"action": "start"}, timeout=10)
        changes, sampled, violations, transient = 0, 0, [], []
        self.lag_samples = 0
        deadline = time.monotonic() + self.args.seconds
        interval = self.args.interval / 1000.0
        next_at = time.monotonic()
        while time.monotonic() < deadline:
            step(changes)
            changes += 1
            if self.args.sample_every and changes % self.args.sample_every == 0:
                sampled += 1
                transient += self.invariant()
            next_at += interval
            delay = next_at - time.monotonic()
            if delay > 0:
                time.sleep(delay)  # test script: key-repeat pacing
        frames, raw = split_raw_frames(result(control.call("debug.frames", {"action": "stop", "raw": True}, timeout=10)))
        time.sleep(self.args.settle)  # test script: let the final selection settle
        violations = self.invariant()
        after = usage(self.app_pid)
        hangs_after = result(control.call("debug.hangs", {"limit": 64}, timeout=10))
        stalls = (hangs_after.get("count") or 0) - (hangs_before.get("count") or 0)
        row = {
            "changes": changes,
            "frames": frames,
            "stalls": stalls,
            "worst_stalls": sorted(
                ({"duration_ms": round(h.get("duration_ms", 0), 1), "cpu_ms": round(h.get("cpu_ms", 0), 1),
                  "frames": [f for f in h.get("frames", []) if "CmuxNext" in f or "Ghostty" in f or "cef" in f.lower()][:8]}
                 for h in (hangs_after.get("records") or [])[-max(stalls, 0):] if stalls > 0),
                key=lambda h: -h["duration_ms"])[:5],
            "footprint_mb_before": round(before[2] / 1048576, 1) if before else None,
            "footprint_mb_after": round(after[2] / 1048576, 1) if after else None,
            "cpu_s": round((after[0] - before[0]) / 1e9, 2) if before and after else None,
            "invariant_samples": sampled,
            "transient_violations": transient[:20],
            "transient_violation_count": len(transient),
            "lagging_samples": self.lag_samples,
            "settled_violations": violations,
        }
        self.samples[name] = {"frame_interval": raw["intervals_ms"], "main_busy": raw["main_ms"], "stalls": [max(stalls, 0)]}
        print(f"== {name}: {changes} changes, frames p50 {frames.get('p50_ms', 0):.1f} p99 {frames.get('p99_ms', 0):.1f} "
              f"max {frames.get('max_ms', 0):.1f} ms, missed {frames.get('missed')}, stalls {stalls}, "
              f"footprint {row['footprint_mb_before']} -> {row['footprint_mb_after']} MB, "
              f"transient {len(transient)}/{sampled} (lagging one frame {self.lag_samples}), settled {len(violations)}")
        for violation in violations:
            print(f"   SETTLED {violation}")
        return row


def record(bench_app, story, samples_by_scenario):
    """Writes each scenario's samples (Bench.samples) as result-v1 (BenchApp.record); returns {metric: path or
    "not recorded: why"}."""
    units = {"frame_interval": "ms", "main_busy": "ms", "stalls": "count"}
    written = {}
    for name, series_samples in samples_by_scenario.items():
        for series, samples in series_samples.items():
            metric = f"switch_repeat.{name}.{series}"
            if not samples:
                written[metric] = "not recorded: no samples"
                continue
            try:
                written[metric] = str(bench_app.record(story, metric, units[series], samples, better="lower",
                                                       engine="chromium"))
            except (RecordError, perf_result.ResultError) as error:
                written[metric] = f"not recorded: {error}"
            print(f"bench-tab-switch: result-v1 {metric}: {written[metric]}")
    return written


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--app")
    parser.add_argument("--repo-root", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "../..")))
    parser.add_argument("--sha", default="unknown")
    parser.add_argument("--tabs", type=int, default=20)
    parser.add_argument("--workspaces", type=int, default=6)
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--interval", type=float, default=33, help="ms between changes (macOS fast key repeat is ~33 ms)")
    parser.add_argument("--settle", type=float, default=1.0)
    parser.add_argument("--sample-every", type=int, default=5, help="check the invariant every N changes (0 = never)")
    parser.add_argument("--scenarios", default="tab-repeat,tab-mixed,tab-back-forth,workspace-repeat")
    parser.add_argument("--out")
    parser.add_argument("--label", default="run")
    parser.add_argument("--keep-running", action="store_true")
    parser.add_argument("--story", default="tab-switch-repeat", help="result-v1 story of the recorded series")
    parser.add_argument("--session", choices=["light", "stress"], default="light", help="result-v1 session")
    args = parser.parse_args()

    tag = args.tag
    bundle = args.app or os.path.expanduser(f"~/Library/Developer/Xcode/DerivedData/cmux-{tag}/Build/Products/Debug/cmux DEV {tag}.app")
    if not os.path.isdir(bundle):
        raise SystemExit(f"bench-tab-switch: no app at {bundle}")
    scratch = tempfile.mkdtemp(prefix=f"bench-tabswitch-{tag}-")
    out_dir = args.out or os.path.join(args.repo_root, "artifacts/cmux-next-bench")
    os.makedirs(out_dir, exist_ok=True)
    # BenchApp refuses a running app of the tag (tag-in-use) and says why a launch does not come up.
    bench_app = BenchApp(bundle, out=out_dir, config={}, window=None, screen="last",
                         log_name=f"{args.sha}-tabswitch-{args.label}-app.log", perf_session=args.session)
    report = {"tag": tag, "sha": args.sha, "label": args.label, "args": vars(args), "scenarios": {}}
    try:
        bench_app.launch(timeout=120)
        app = bench_app.process
        print(f"bench-tab-switch: app pid {app.pid}")
        control = wait_for_socket(bench_app.socket)
        identity = result(control.call("system.identify"))
        app_pid = identity.get("pid", app.pid)
        bench = Bench(control, app_pid, args)
        time.sleep(3)  # test script: first terminal attaches
        bench.build_workload(scratch)
        report["setup_surfaces"] = bench.surfaces()
        report["cef"] = result(control.call("debug.cef", timeout=10))
        tabs = args.tabs
        scenarios = {
            "tab-repeat": lambda i: bench.key("tab", ["control"]),
            # Tab 0 is a terminal, tab 1 a Chromium page: toggle between them.
            "tab-mixed": lambda i: bench.key("tab", ["control"] if i % 2 == 0 else ["control", "shift"]),
            "tab-back-forth": lambda i: bench.key("tab", ["control"] if i % 2 == 0 else ["control", "shift"]),
            "workspace-repeat": lambda i: bench.next_workspace(),
        }
        for name in args.scenarios.split(","):
            if name in ("tab-mixed", "tab-back-forth"):
                control.action("selectSurfaceByNumber", timeout=10, index=1 if name == "tab-mixed" else 2)
                time.sleep(0.5)  # test script: settle the starting tab
            if name == "workspace-repeat":
                pass
            report["scenarios"][name] = bench.run(name, scenarios[name])
        _ = tabs
        report["results"] = record(bench_app, args.story, bench.samples)
    finally:
        if not args.keep_running:
            bench_app.stop()  # debug.quit, then the tag's daemons and terminals (tag_teardown.py)
            report["teardown"] = "bench_launch"  # as bench_idle.py: tag_teardown logs its own counts
    out = os.path.join(out_dir, f"{args.sha}-tabswitch-{args.label}.json")
    with open(out, "w") as handle:
        json.dump(report, handle, indent=2)
    print(f"bench-tab-switch: wrote {out}")


if __name__ == "__main__":
    main()
