#!/usr/bin/env python3
"""idle-budget.py's pure parts: process kinds, per-kind sums, the v2 budget check (sessions, sums, ratios,
assertions), the perf cron rows, the session table, energy per kind and tree, power assertions and the
saver/thermal guard; procs.py's counters (interrupt and package-idle wakeups apart, billed energy, GPU time,
the coalition); and the chrome-static reference (Chrome kinds, uBlock Origin parity, the reference browser
refusal, ratio rows and their noise floor; xbench's Chrome switches); and the shipping measurement mode (launch
env, Debug refusal under --gate, the five report fields); the role and App Nap audit (task 106: `ps` priorities, D16's
expected roles, pooled acpmux agents); and bench-typing.py's D8 benches (p14-energy-135: the Chromium composer and
page-scroll plans, the saver launch, the scroll page and its read path, fixture results into p50/p95 and dropped
frames, the D8 verdicts). Runs on any host (libproc loads only to measure)."""

from __future__ import annotations

import contextlib
import fcntl
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import types
import unittest
import unittest.mock
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "perf-bench"))
spec = importlib.util.spec_from_file_location("idle_budget", HERE / "idle-budget.py")
ib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ib)
procs = ib.procs

APP = "/Users/x/DerivedData/cmux-t/Build/Products/Debug/cmux DEV t.app"
CHROME = "/Applications/Chromium.app"
CHROME_HELPERS = f"{CHROME}/Contents/Frameworks/Chromium Framework.framework/Versions/154.0.8037.58/Helpers"


def row(kind, threads, wakeups, cpu=0.0, cpu_mw=0.0, billed_mw=0.0, pid=0):
    return {"pid": pid, "kind": kind, "threads": threads, "threads_ran": 0, "wakeups_per_s": wakeups, "csw_per_s": 0.0, "cpu_pct": cpu,
            "energy_mw_cpu": cpu_mw, "energy_mw_billed": billed_mw}


PMSET = """Assertion status system-wide:
   BackgroundTask                 0
   PreventUserIdleSystemSleep     1
Listed by owning process:
   pid 501(cmux DEV t): [0x0000a1b200018c3d] 00:01:10 PreventUserIdleSystemSleep named: "cmux keep awake"
   pid 88(powerd): [0x0000a1b200018c40] 00:00:05 PreventUserIdleDisplaySleep named: "Powerd - Prevent sleep while display is on"
   pid 120(coreaudiod): [0x0000a1b200018c41] 00:00:30 PreventUserIdleSystemSleep named: "com.apple.audio.context123.preventuseridlesleep"
\tCreated for PID: 777.
\tResources: audio-out builtin-speaker
   pid 900(Google Chrome Helper (Renderer)): [0x0000a1b200018c42] 00:00:01 PreventUserIdleSystemSleep named: "x"
Kernel Assertions: 0x4=USB
   id=500  level=255 0x4=USB mod=1/1/26, 9:00 AM description=com.apple.usb.externaldevice.14100000 owner=AppleUSB
"""


def ends(saver_start, saver_end, thermal_start="nominal", thermal_end="nominal", assertions=(), anim=None,
         assertions_end=None):
    start = {"saver": saver_start, "saver_reason": "setting" if saver_start else None, "thermal": thermal_start,
             "assertions": list(assertions)}
    end = {"saver": saver_end, "saver_reason": "setting" if saver_end else None, "thermal": thermal_end,
           "assertions": list(assertions if assertions_end is None else assertions_end)}
    if anim:
        start["anim"], end["anim"] = anim
    return {"start": start, "end": end}


class IdleBudgetTests(unittest.TestCase):
    def test_kinds(self):
        self.assertEqual(ib.kind(f"{APP}/Contents/MacOS/cmux DEV"), "app")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui server --socket s"), "daemon")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui __holder --socket s"), "holder")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux-tui __terminal-host --owner a@1"), "terminal-host")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/acpmux daemon"), "acpmux")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper (Renderer).app/x --type=renderer"), "cef-renderer")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper (GPU).app/x --type=gpu-process"), "cef-gpu")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper (Renderer).app/x --type=renderer --extension-process"),
                         "cef-extension")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper.app/x --type=utility --utility-sub-type=n"), "cef-utility")
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Helper.app/Contents/MacOS/cmux Helper"), "cef-helper")
        # The Chromium Host is a second executable of the app (Contents/MacOS), not the app.
        self.assertEqual(ib.kind(f"{APP}/Contents/MacOS/cmux Chromium Host --framework=/x/Chromium Embedded Framework.framework"),
                         "cef-host")
        self.assertEqual(ib.kind(f"{APP}/Contents/MacOS/cmux Chromium Host"), "cef-host")
        # Older builds' Chromium Host app in Contents/Frameworks.
        self.assertEqual(ib.kind(f"{APP}/Contents/Frameworks/cmux Chromium Host.app/Contents/MacOS/cmux Chromium Host --x"),
                         "cef-host")
        # A --type process outside a Helper app is not a Chromium helper: the app binary is the app.
        self.assertEqual(ib.kind(f"{APP}/Contents/MacOS/cmux DEV --type=renderer"), "app")
        self.assertEqual(ib.kind("/bin/zsh -l"), "other:zsh")

    def test_every_chromium_kind_has_a_budget_row(self):
        with open(ib.BUDGET_FILE) as handle:
            budget = json.load(handle)
        for name in ("cef-gpu", "cef-renderer", "cef-extension", "cef-utility", "cef-host"):
            self.assertIn(name, budget["kinds"])

    def test_every_process_of_the_tree_has_a_kind(self):
        """p14-energy-104: fixture command lines map to each kind; the tree and the census tell what the command
        cannot."""
        frameworks = f"{APP}/Contents/Frameworks"
        helper = f"{frameworks}/cmux Helper.app/Contents/MacOS/cmux Helper"
        renderer = f"{frameworks}/cmux Helper (Renderer).app/Contents/MacOS/cmux Helper (Renderer)"
        webcontent = ("/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/"
                      "com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent")
        bin_ = f"{APP}/Contents/Resources/bin"
        cua = f"{APP}/Contents/Library/cmux Computer Use.app/Contents/MacOS/cmux-cua-helper"
        watcher = ("/bin/zsh -f -c zmodload zsh/system || exit 0\npid=$1 out=$2 seconds=$3\n"
                   "sysread -i 3 -s 1 byte || exit 0 cmux-crash-watcher 501 /tmp/x/sample.txt 15")
        adapter = f"{APP}/Contents/Resources/MediaRemoteAdapter/mediaremote-adapter.pl"
        framework = f"{frameworks}/MediaRemoteAdapter.framework"
        watch = (f"/bin/sh -c exec 3<&0\nchild= watch=\n\"$0\" \"$@\" </dev/null &\nwait \"$child\" /usr/bin/perl "
                 f"{adapter} {framework} stream --micros --debounce=150")
        table = [
            (501, 1, f"{APP}/Contents/MacOS/cmux DEV"),
            (502, 501, f"{renderer} --type=renderer --extension-process"),
            (503, 501, f"{helper} --type=utility --utility-sub-type=network.mojom.NetworkService"),
            (504, 501, f"{helper} --type=utility --utility-sub-type=storage.mojom.StorageService"),
            (505, 501, f"{helper} --type=utility --utility-sub-type=audio.mojom.AudioService"),
            (506, 501, watcher),
            (507, 1, f"{cua} serve --socket /tmp/s --no-permissions-gate --owner-pid 501"),
            (508, 501, f"{helper} --type=crashpad-handler --database=/tmp/c"),
            (509, 501, f"{APP}/Contents/MacOS/cmux Chromium Host --framework=/x"),
            (510, 1, webcontent),
            (511, 1, webcontent),
            (512, 501, f"{bin_}/cmux-tui server --socket s"),
            (513, 512, f"{bin_}/cmux-tui __terminal-host --owner a@512"),
            (514, 513, "-zsh"),
            (515, 514, "/opt/homebrew/bin/node build.js"),
            (516, 512, f"{bin_}/acpmux daemon"),
            (517, 516, f"{bin_}/acpmux __agent-host --session s1"),
            (518, 517, "/Users/x/.local/bin/claude --acp"),
            (519, 1, "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/"
                     "Contents/MacOS/com.apple.WebKit.GPU"),
            # The holder model (CMUX_TUI_TERMINAL_HOST_MODEL=holder): the built-in holder and the standalone one
            # (argv[0] cmux-holder, no `__holder`), each with a shell and its job.
            (530, 1, f"{bin_}/cmux-tui-host __holder --socket h1 --owner a@512"),
            (531, 530, "-zsh"),
            (532, 531, "/usr/bin/make -j8"),
            (533, 1, "cmux-holder --socket h2 --owner a@512"),
            (534, 533, "/bin/bash -l"),
            (535, 534, "/usr/bin/git status"),
            # The Now Playing stream: the watch shell, its `{ while read }` subshell (the same argv) and the adapter.
            (540, 501, watch),
            (541, 540, watch),
            (542, 540, f"/usr/bin/perl {adapter} {framework} stream --micros --debounce=150"),
            # The app's one-shot tools, and what they run.
            (550, 501, "gh api --include -X GET /notifications"),
            (551, 501, "/usr/bin/git -C /Users/x/repo status --porcelain"),
            (552, 551, "/Library/Developer/CommandLineTools/usr/libexec/git-core/git-remote-https origin"),
            (553, 501, "/opt/homebrew/bin/rg --json needle /Users/x/repo"),
            (554, 501, f"{bin_}/cmux-diff-sidecar rpc --root /tmp/r --cmux {bin_}/cmux --process-group-ready"),
            (555, 554, f"{bin_}/cmux __diff --resource-scheme page"),
            # A foreign executable the app runs and no rule names.
            (560, 501, "/usr/local/libexec/mystery-agent --serve"),
        ]
        census = {"pages": [{"page": "cmux.home", "engine": "webkit", "state": "visible", "webkit_pid": 510},
                            {"page": "cmux.agent", "engine": "chromium", "webkit_pid": None}],
                  "spares": [{"spare": "cef_window", "webkit_pid": None}]}
        window = ib.WindowKinds(table, census)
        got = {pid: window(cmd, pid) for pid, _ppid, cmd in table}
        self.assertEqual(got, {
            501: "app", 502: "cef-extension", 503: "cef-network", 504: "cef-storage", 505: "cef-audio",
            506: "crash-watcher", 507: "cua-helper", 508: "crashpad", 509: "cef-host", 510: "webkit-app-page",
            511: "webkit-browser-tab", 512: "daemon", 513: "terminal-host", 514: "terminal-job", 515: "terminal-job",
            516: "acpmux", 517: "acpmux", 518: "agent-harness", 519: "webkit-gpu",
            530: "holder", 531: "terminal-job", 532: "terminal-job", 533: "holder", 534: "terminal-job",
            535: "terminal-job", 540: "now-playing", 541: "now-playing", 542: "now-playing",
            550: "app-tool", 551: "app-tool", 552: "app-tool", 553: "app-tool", 554: "app-tool", 555: "app-tool",
            560: "other:mystery-agent"})
        # Every kind but the foreign executable has a budget row.
        budget = ib.load_budget(ib.BUDGET_FILE)
        self.assertEqual({k for k in got.values() if k not in budget["kinds"]}, {"other:mystery-agent"})
        # A build with no census (no debug.webui) cannot split WebKit: unsplit, not a guess.
        self.assertIsNone(ib.webkit_app_pages({}))
        self.assertEqual(ib.WindowKinds(table, {})(webcontent, 510), "webkit-webcontent")
        self.assertEqual(ib.kind(webcontent), "webkit-webcontent")
        # The command alone still names what it can.
        self.assertEqual(ib.kind(watcher), "crash-watcher")
        self.assertEqual(ib.kind(f"{cua} serve --socket /tmp/s"), "cua-helper")
        self.assertEqual(ib.kind("cmux-holder --socket h2 --owner a@512"), "holder")
        self.assertEqual(ib.kind("/opt/homebrew/bin/node build.js"), "other:node")
        self.assertEqual(ib.kind("/Applications/Other App.app/Contents/Resources/bin/thing --x"), "other:thing")
        # The tree is the app's set alone: a bench started in a cmux terminal does not make the app a terminal job.
        app_only = [(501, 901, f"{APP}/Contents/MacOS/cmux DEV")]
        self.assertEqual(ib.WindowKinds(app_only)(app_only[0][2], 501), "app")

    def test_the_set_and_its_tree_come_from_one_ps_read(self):
        """process_set's rows are the `ps` read it walked: a job that exits before a later read keeps its kind."""
        bin_ = f"{APP}/Contents/Resources/bin"
        table = [(501, 1, f"{APP}/Contents/MacOS/cmux DEV"), (512, 501, f"{bin_}/cmux-tui server --socket s"),
                 (513, 1, f"{bin_}/cmux-tui __terminal-host --owner a@512"), (514, 513, "-zsh"),
                 (515, 514, "/usr/bin/git status"), (900, 1, "/usr/sbin/sshd"), (901, 900, "-zsh")]
        reads = []

        def process_table():
            reads.append(1)
            return table

        instance = procs.Instance(APP + "/", 501)
        with unittest.mock.patch.object(procs, "process_table", process_table), \
                unittest.mock.patch.object(procs, "_darwin", return_value=types.SimpleNamespace(responsible=None)):
            found = ib.process_set(instance)
        self.assertEqual(len(reads), 1)
        self.assertEqual(sorted(found), [501, 512, 513, 514, 515])
        self.assertEqual(sorted(found.rows), sorted(r for r in table if r[0] in found))
        classify = ib.WindowKinds(found.rows)
        self.assertEqual(classify(found[515], 515), "terminal-job")

    def test_holders_join_the_set_by_their_owner(self):
        table = [(501, 1, f"{APP}/Contents/MacOS/cmux DEV"),
                 (512, 501, f"{APP}/Contents/Resources/bin/cmux-tui server --socket s"),
                 (533, 1, "cmux-holder --socket h2 --owner a@512"),
                 (534, 533, "-zsh"),
                 (535, 1, "cmux-holder --socket h3 --owner a@9999")]
        instance = procs.Instance(APP + "/", 501)
        with unittest.mock.patch.object(procs, "process_table", return_value=table), \
                unittest.mock.patch.object(procs, "_darwin", return_value=types.SimpleNamespace(responsible=None)):
            found = ib.process_set(instance)
        self.assertEqual(sorted(found), [501, 512, 533, 534])

    def test_hidden_pages_mark_their_rows(self):
        """A row is hidden when every page its process runs is hidden: debug.webui pages and spares, and in a tab
        session every browser tab but the shown one (WebKit tabs all, behind a shown Chromium tab)."""
        census = {"pages": [{"page": "cmux.home", "state": "visible", "webkit_pid": 10, "renderer_pids": []},
                            {"page": "cmux.agent", "state": "hidden", "webkit_pid": 11, "renderer_pids": [20]},
                            {"page": "cmux.notes", "state": "hidden", "webkit_pid": None, "renderer_pids": [21]},
                            {"page": "cmux.files", "state": "visible", "webkit_pid": None, "renderer_pids": [21]}],
                  "spares": [{"spare": "cef_window", "renderer_pids": [22], "webkit_pid": None},
                             {"spare": "new_tab", "state": None, "webkit_pid": 12.0}],
                  "browser_tabs": [{"tab": "t1", "renderer_pids": [30]}, {"tab": "t2", "renderer_pids": [31]}]}
        # 21 runs a visible page too: not hidden. Browser tabs have no state without the session's shown tab.
        self.assertEqual(ib.hidden_pids(census), {11, 20, 12, 22})
        shown = {"engine": "chromium", "tabs": ["t2"]}
        self.assertEqual(ib.hidden_pids(census, shown), {11, 20, 12, 22, 30})
        window = ib.WindowKinds([], census, shown)
        self.assertTrue(window.hidden(99, "webkit-browser-tab"))
        self.assertFalse(window.hidden(31, "cef-renderer"))
        self.assertFalse(ib.WindowKinds([], census).hidden(99, "webkit-browser-tab"))
        self.assertFalse(ib.WindowKinds([], census, {"engine": "webkit", "tabs": []}).hidden(99, "webkit-browser-tab"))
        # A hidden WebKit browser tab at 1.0/s is over tabs-static's 0.5 per hidden process; a shown one is not judged.
        budget = ib.load_budget(ib.BUDGET_FILE)
        tab = {**row("webkit-browser-tab", 10, 1.0), "hidden": True}
        over = ("webkit-browser-tab", "hidden_wakeups_max", 1.0, 0.5)
        self.assertIn(over, ib.over_budget("tabs-static", ib.aggregate({"processes": [tab]}), budget))
        tab["hidden"] = False
        self.assertNotIn(over, ib.over_budget("tabs-static", ib.aggregate({"processes": [tab]}), budget))

    def test_an_unclassified_child_is_an_over_with_kind_other(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        kinds = ib.aggregate({"processes": [row("app", 30, 0.1), row("other:mystery-agent", 1, 0.0)],
                              "main_wakes_per_s": 0})
        over = ("other:mystery-agent", "kind", "other", "classified")
        for session in ("light", "tabs-static", "stress", "busy-hidden"):
            self.assertIn(over, ib.over_budget(session, kinds, budget))
        self.assertEqual(ib.over_line("light", over),
                         "IDLE-BUDGET-OVER light other:mystery-agent kind other != classified")
        # A reference browser's kinds are Chrome's own (chrome_kind), never judged.
        self.assertEqual(ib.over_budget("chrome-static", kinds, budget), [])
        self.assertEqual(ib.exit_code(True, [("light", *over)], []), 1)
        self.assertEqual(ib.exit_code(False, [("light", *over)], []), 0)

    def test_every_cef_kind_is_judged(self):
        """No cef-* kind goes unjudged: each has task 104's number or a ratio_to_chrome row against Chrome; none has
        an explicit null wakeup limit. cef-gpu's absolute 1.0/s is D4's goal: reported, never an over."""
        budget = ib.load_budget(ib.BUDGET_FILE)
        fields = ("wakeups_per_s", "wakeups_max")
        cef = [name for name in budget["kinds"] if name.startswith("cef-")]
        self.assertEqual(set(cef), {"cef-host", "cef-gpu", "cef-renderer", "cef-extension", "cef-network",
                                    "cef-storage", "cef-audio", "cef-utility", "cef-helper"})
        against_chrome = {part for rule in budget["ratio_to_chrome"] if rule["field"] == "wakeups_per_s"
                          for part in rule["of"].split("+")}
        for name in cef:
            limits = budget["kinds"][name]
            self.assertFalse(any(f in limits and limits[f] is None for f in fields), name)
            numbered = any(isinstance(limits.get(f), (int, float)) for f in fields)
            self.assertTrue(numbered or name in against_chrome, name)
        for own in budget["sessions"].values():
            for name, limits in (own.get("kinds") or {}).items():
                if name.startswith("cef-"):
                    self.assertFalse(any(f in limits and limits[f] is None for f in fields), name)
        # The plan's numbers, and nothing invented beside them.
        self.assertEqual(ib.limit_for(budget, "light", "cef-extension", "wakeups_max"), 0.1)
        self.assertEqual(ib.limit_for(budget, "light", "cef-network", "wakeups_per_s"), 0.2)
        for name in ("crash-watcher", "cua-helper"):
            self.assertEqual(ib.limit_for(budget, "light", name, "wakeups_max"), 0)
        for name in ("cef-host", "cef-gpu", "cef-renderer", "cef-storage", "cef-audio", "cef-utility", "cef-helper"):
            for field in fields:
                self.assertIsNone(ib.limit_for(budget, "light", name, field), (name, field))
        # D4: cef-gpu at 3/s in tabs-static is no over (its check is the ratio), and its goal reports it unmet.
        kinds = ib.aggregate({"processes": [row("cef-gpu", 10, 3.0)]})
        self.assertEqual(ib.over_budget("tabs-static", kinds, budget), [])
        self.assertEqual(ib.goal_rows(budget, "tabs-static", kinds),
                         [{"of": "cef-gpu", "field": "wakeups_per_s", "max": 1.0, "value": 3.0, "met": False}])
        self.assertEqual(ib.goal_rows(budget, "light", kinds), [])
        # A terminal's jobs are the person's and the app's tools are reported: never judged.
        self.assertEqual(ib.over_budget("light", {"terminal-job": {"wakeups_max": 9.0, "disk_bytes_per_s": 9.0},
                                                  "app-tool": {"wakeups_max": 9.0, "disk_bytes_per_s": 9.0}}, budget), [])

    def test_the_cua_helper_joins_the_set_by_its_owner_pid(self):
        cua = "/Applications/cmux.app/Contents/Library/cmux Computer Use.app/Contents/MacOS/cmux-cua-helper"
        table = [(501, 1, f"{APP}/Contents/MacOS/cmux DEV"),
                 (600, 1, f"{cua} serve --socket /tmp/s --owner-pid 501"),
                 (601, 1, f"{cua} serve --socket /tmp/t --owner-pid 5010"),
                 (602, 1, f"{cua} serve --socket /tmp/u")]
        instance = procs.Instance(APP + "/", 501)
        with unittest.mock.patch.object(procs, "process_table", return_value=table), \
                unittest.mock.patch.object(procs, "_darwin", return_value=types.SimpleNamespace(responsible=None)):
            self.assertEqual(sorted(instance.pids()), [501, 600])
        self.assertEqual(procs.kind_of(f"{cua} serve --socket /tmp/s"), "cua-helper")
        self.assertEqual(procs.kind_of("/bin/zsh -f -c x cmux-crash-watcher 501 /tmp/s 15"), "crash-watcher")

    def test_aggregate_sums_and_maxes_per_kind(self):
        kinds = ib.aggregate({"processes": [row("terminal-host", 3, 0.0), row("terminal-host", 5, 0.5), row("app", 40, 2.0)],
                              "main_wakes_per_s": 1.5})
        self.assertEqual(kinds["terminal-host"]["n"], 2)
        self.assertEqual(kinds["terminal-host"]["threads"], 8)
        self.assertEqual(kinds["terminal-host"]["threads_max"], 5)
        self.assertEqual(kinds["terminal-host"]["wakeups_max"], 0.5)
        self.assertEqual(kinds["app"]["main_wakes_per_s"], 1.5)

    def test_over_budget_names_each_value_over_its_limit(self):
        budget = {"kinds": {"app": {"main_wakes_per_s": 0, "wakeups_per_s": 1.0, "threads_max": None},
                            "holder": {"wakeups_max": {"light": 0, "stress": 1}}}}
        kinds = {"app": {"main_wakes_per_s": 0.2, "wakeups_per_s": 0.9, "threads_max": 99},
                 "holder": {"wakeups_max": 0.5}}
        self.assertEqual(ib.over_budget("light", kinds, budget), [("app", "main_wakes_per_s", 0.2, 0), ("holder", "wakeups_max", 0.5, 0)])
        self.assertEqual(ib.over_budget("stress", kinds, budget), [("app", "main_wakes_per_s", 0.2, 0)])

    def test_cron_rows(self):
        report = {"sessions": {"light": {"kinds": {"app": {"wakeups_per_s": 0.4, "threads_max": 30, "main_wakes_per_s": 0}}}}}
        rows = ib.cron_rows(report, {"kinds": {"app": {"wakeups_per_s": 1.0}}})
        self.assertEqual(rows["idle_budget.light.app.wakeups_per_s"],
                         {"p50": 0.4, "p95": 0.4, "p99": 0.4, "unit": "/s", "budget": 1.0, "floor": 0.5})
        self.assertEqual(rows["idle_budget.light.app.threads_max"]["unit"], "threads")
        self.assertIsNone(rows["idle_budget.light.app.threads_max"]["budget"])

    def test_checked_in_budget_parses(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        self.assertEqual(budget["version"], 2)
        self.assertEqual(budget["kinds"]["app"]["main_wakes_per_s"], 0)
        self.assertIn("energy_mw_billed", budget["kinds"]["app"])
        self.assertIn("gpu_ms_per_s", budget["kinds"]["app"])


def rusage_words(pkg_idle=0, interrupt=0, energy=0, billed=0, serviced=0, user=0, system=0, footprint=0):
    """An rusage_info_v6 as proc_pid_rusage fills it (64 words), with the words procs reads."""
    words = [0] * 64
    words[2], words[3], words[4], words[5], words[9] = user, system, pkg_idle, interrupt, footprint
    words[33], words[34], words[42] = billed, serviced, energy
    return words


class CountersTests(unittest.TestCase):
    """procs.py's counters as Chrome defines them (base/process/process_metrics_apple.mm,
    components/power_metrics/resource_coalition_mac.mm)."""

    def test_interrupt_and_package_idle_wakeups_are_reported_apart(self):
        first = procs.usage_from_words(rusage_words(), 1, 1)
        last = procs.usage_from_words(rusage_words(pkg_idle=4, interrupt=10), 1, 1)
        got = procs.rates(first, last, 1.0)
        self.assertEqual(got["wakeups_per_s"], 10)  # not 14: package-idle wakeups are a subset
        self.assertEqual(got["pkg_idle_wakeups_per_s"], 4)

    def test_billed_energy_adds_billed_and_takes_off_serviced(self):
        first = procs.usage_from_words(rusage_words(energy=1_000_000, billed=500_000, serviced=0), 1, 1)
        last = procs.usage_from_words(rusage_words(energy=11_000_000, billed=6_500_000, serviced=2_000_000), 1, 1)
        got = procs.rates(first, last, 2.0)
        self.assertEqual(got["energy_mw_cpu"], 5.0)
        self.assertEqual(got["energy_mw_billed"], 7.0)  # (10 + 6 - 2) mJ over 2 s

    def test_cpu_time_uses_the_timebase(self):
        last = procs.usage_from_words(rusage_words(user=375, system=125), 125, 3)
        self.assertEqual(last.cpu_ns, 500 * 125 // 3)
        self.assertEqual(procs.rates(None, last, 1.0)["cpu_pct"], 100 * (500 * 125 // 3) / 1e9)

    def test_gpu_time_per_pid_from_the_registry(self):
        registry = [{"IORegistryEntryChildren": [
            {"IOUserClientCreator": "pid 42, cmux", "AppUsage": [{"accumulatedGPUTime": 3_000_000},
                                                                  {"accumulatedGPUTime": 1_000_000}]},
            {"IOUserClientCreator": "pid 42, cmux", "AppUsage": [{"accumulatedGPUTime": 2_000_000}]},
            {"IOUserClientCreator": "pid 7, WindowServer", "AppUsage": [{"accumulatedGPUTime": 9}]},
            {"IOUserClientCreator": "pid 8, idle"}]}]
        self.assertEqual(procs.gpu_ns_from_registry(registry), {42: 6_000_000, 7: 9})
        self.assertEqual(procs.gpu_ms_per_s({42: 1_000_000}, {42: 6_000_000}, 42, 2.0), 2.5)
        self.assertEqual(procs.gpu_ms_per_s({}, {}, 42, 2.0), 0)
        self.assertIsNone(procs.gpu_ms_per_s(None, {42: 1}, 42, 2.0))

    def test_coalition_rates(self):
        def words(energy, to_me, to_others, gpu_ns, cpu_ticks, interrupt, idle):
            w = [0] * procs._CRU_WORDS
            w[3], w[4], w[5], w[8], w[11], w[20], w[21] = cpu_ticks, interrupt, idle, gpu_ns, energy, to_me, to_others
            return w
        first = procs.coalition_from_words(words(0, 0, 0, 0, 0, 0, 0), 125, 3)
        last = procs.coalition_from_words(words(4_000_000, 3_000_000, 1_000_000, 8_000_000, 24_000_000, 20, 6), 125, 3)
        self.assertEqual(last.gpu_ns, 8_000_000)  # ns already, not timebase ticks
        self.assertEqual(last.cpu_ns, 1_000_000_000)
        got = procs.coalition_rates(first, last, 2.0)
        self.assertEqual(got, {"energy_mw_cpu": 2.0, "energy_mw_billed": 3.0, "gpu_ms_per_s": 4.0, "cpu_pct": 50.0,
                               "wakeups_per_s": 10.0, "pkg_idle_wakeups_per_s": 3.0})

    def test_a_coalition_read_failure_is_null_not_zero(self):
        last = procs.coalition_from_words([0] * procs._CRU_WORDS, 1, 1)
        self.assertIsNone(procs.coalition_rates(None, last, 1.0))
        self.assertIsNone(procs.coalition_rates(last, None, 1.0))
        self.assertEqual(ib.coalition_line(None), "app coalition: not readable")

    def test_report_has_cpu_and_billed_energy_and_gpu_per_kind(self):
        first = procs.usage_from_words(rusage_words(), 1, 1)
        last = procs.usage_from_words(rusage_words(pkg_idle=4, interrupt=10, energy=3_000_000, billed=1_000_000,
                                                   footprint=int(procs.MB)), 1, 1)
        app = ib.process_row(1, f"{APP}/Contents/MacOS/cmux DEV", first, last, 1.0, gpu=1.5, threads_now=30, csw=12, ran=[])
        daemon = ib.process_row(2, f"{APP}/Contents/Resources/bin/cmux-tui server", first, last, 1.0, gpu=None,
                                threads_now=4, csw=0, ran=[])
        started = ib.process_row(3, f"{APP}/Contents/MacOS/cmux DEV", None, last, 1.0, gpu=0.5, threads_now=1, csw=0, ran=[])
        self.assertEqual((app["wakeups_per_s"], app["pkg_idle_wakeups_per_s"]), (10, 4))
        self.assertTrue(started["partial"])
        self.assertFalse(app["partial"])
        kinds = ib.aggregate({"processes": [app, daemon, started]})
        self.assertEqual(kinds["app"]["energy_mw_cpu"], 6.0)
        self.assertEqual(kinds["app"]["energy_mw_billed"], 8.0)
        self.assertEqual(kinds["app"]["gpu_ms_per_s"], 2.0)
        self.assertEqual(kinds["app"]["wakeups_per_s"], 20)
        self.assertEqual(kinds["app"]["pkg_idle_wakeups_per_s"], 8)
        self.assertIsNone(kinds["daemon"]["gpu_ms_per_s"])  # no registry read: unknown, not 0
        self.assertIn("billed mW", ib.table("light", kinds, []))

    def test_cron_rows_carry_billed_energy_and_gpu(self):
        report = {"sessions": {"light": {"kinds": {"app": {"energy_mw_billed": 3.5, "gpu_ms_per_s": None}}}}}
        rows = ib.cron_rows(report, {"kinds": {"app": {"energy_mw_billed": None}}})
        self.assertEqual(rows["idle_budget.light.app.energy_mw_billed"]["unit"], "mW")
        self.assertNotIn("idle_budget.light.app.gpu_ms_per_s", rows)

    def test_instance_window_totals(self):
        rows = [{"kind": "main", "threads": 3, "mw": 1.0, "energy_mw_cpu": 1.0, "energy_mw_billed": 2.0,
                 "gpu_ms_per_s": 0.5, "wakeups_per_s": 10.0, "pkg_idle_wakeups_per_s": 4.0},
                {"kind": "gpu", "threads": 5, "mw": 2.0, "energy_mw_cpu": 2.0, "energy_mw_billed": 2.0,
                 "gpu_ms_per_s": None, "wakeups_per_s": 1.0, "pkg_idle_wakeups_per_s": 0.0}]
        got = procs.window_totals(rows)
        self.assertEqual((got["wakeups_per_s"], got["pkg_idle_wakeups_per_s"]), (11.0, 4.0))
        self.assertEqual(got["energy_mw_billed"], 4.0)
        self.assertIsNone(got["gpu_ms_per_s"])
        self.assertEqual(got["kinds"]["main"]["gpu_ms_per_s"], 0.5)
        self.assertEqual((got["threads"], got["processes"]), (8, 2))
        self.assertEqual(list(got["kinds"]), ["gpu", "main"])  # by CPU energy

    def test_xbench_records_companion_rows_from_the_same_window(self):
        sys.path.insert(0, str(HERE.parent / "perf-bench"))
        import xbench
        rows = xbench.window_rows({"power-idle-visible": "mw", "idle-cpu-20": "cpu_pct", "idle-wakeups-20": "wakeups_per_s"})
        self.assertEqual(rows["power-idle-visible-billed"], "energy_mw_billed")
        self.assertEqual(rows["power-idle-visible-gpu"], "gpu_ms_per_s")
        self.assertEqual(rows["idle-wakeups-20-pkg-idle"], "pkg_idle_wakeups_per_s")
        self.assertNotIn("idle-cpu-20-billed", rows)
        self.assertEqual(xbench.ROW_INFO["power-idle-visible-gpu"][1], "ms/s")
        self.assertEqual(xbench.fmt(2.25, "ms/s"), "2.2 ms/s")
        self.assertIn("ms/s", xbench.FLOORS)

    # -- v2 (p14-energy-002) ------------------------------------------------------------------------------

    def test_v2_kinds(self):
        frameworks = f"{APP}/Contents/Frameworks"
        host = f"{frameworks}/cmux DEV t Chromium Host.app/Contents/MacOS/cmux DEV t Chromium Host"
        self.assertEqual(ib.kind(host), "cef-host")
        self.assertEqual(ib.kind(f"{host} --remote-debugging-port=0"), "cef-host")
        helper = f"{frameworks}/cmux Helper.app/Contents/MacOS/cmux Helper"
        self.assertEqual(ib.kind(f"{helper} --type=renderer --extension-process"), "cef-extension")
        self.assertEqual(ib.kind(f"{helper} --type=utility --utility-sub-type=network.mojom.NetworkService"), "cef-network")
        self.assertEqual(ib.kind(f"{helper} --type=utility --utility-sub-type=storage.mojom.StorageService"), "cef-storage")
        self.assertEqual(ib.kind(f"{helper} --type=utility --utility-sub-type=audio.mojom.AudioService"), "cef-audio")
        self.assertEqual(ib.kind(f"{helper} --type=utility --utility-sub-type=data_decoder.mojom.DataDecoderService"),
                         "cef-utility")
        self.assertEqual(ib.kind(f"{helper} --type=crashpad-handler --database=x"), "crashpad")
        self.assertEqual(ib.kind(f"{APP}/Contents/MacOS/cmux DEV"), "app")

    def test_app_plus_daemon_sum_is_an_over(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        kinds = {"app": {"wakeups_per_s": 0.7, "main_wakes_per_s": 0.2}, "daemon": {"wakeups_per_s": 0.4}}
        overs = ib.over_budget("tabs-static", kinds, budget)
        self.assertIn(("app+daemon", "wakeups_per_s", 1.1, 1.0), overs)
        self.assertEqual(ib.over_line("tabs-static", ("app+daemon", "wakeups_per_s", 1.1, 1.0)),
                         "IDLE-BUDGET-OVER tabs-static app+daemon wakeups_per_s 1.1 > 1.0")
        # Each alone is within its own kind limit: only the sum is over.
        self.assertEqual([o for o in overs if o[0] in ("app", "daemon")], [])
        rows = ib.cron_rows({"sessions": {"tabs-static": {"kinds": kinds}}}, budget)
        self.assertEqual(rows["idle_budget.tabs-static.app+daemon.wakeups_per_s"]["p50"], 1.1)
        self.assertEqual(rows["idle_budget.tabs-static.app+daemon.wakeups_per_s"]["budget"], 1.0)
        self.assertIn("idle_budget.tabs-static.tree.wakeups_per_s", rows)

    def test_v1_file_still_loads_and_judges(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "v1.json"
            path.write_text(json.dumps({"kinds": {"app": {"main_wakes_per_s": 0, "wakeups_per_s": 1.0},
                                                  "holder": {"wakeups_max": {"light": 0}}}}))
            budget = ib.load_budget(str(path))
        self.assertEqual(budget["version"], 1)
        self.assertEqual(budget["sessions"], {})
        kinds = {"app": {"main_wakes_per_s": 0.2, "wakeups_per_s": 1.5}, "holder": {"wakeups_max": 0.5}}
        self.assertEqual(ib.over_budget("light", kinds, budget),
                         [("app", "main_wakes_per_s", 0.2, 0), ("app", "wakeups_per_s", 1.5, 1.0),
                          ("holder", "wakeups_max", 0.5, 0)])
        rows = ib.cron_rows({"sessions": {"light": {"kinds": kinds}}}, budget)
        self.assertEqual(rows["idle_budget.light.app.wakeups_per_s"]["budget"], 1.0)

    def test_d2_to_d7_sessions_and_numbers(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        sessions = budget["sessions"]

        def limit(session, name, field):
            return ib.limit_for(budget, session, name, field)

        # D2: light-webkit keeps the owner's zeros and tightens; light takes D4's Chromium limits.
        self.assertEqual(limit("light-webkit", "app", "main_wakes_per_s"), 0)
        self.assertEqual(limit("light-webkit", "holder", "wakeups_max"), 0)
        self.assertEqual(limit("light-webkit", "terminal-host", "wakeups_max"), 0)
        self.assertEqual(limit("light-webkit", "app", "wakeups_per_s"), 0.5)
        self.assertEqual(limit("light-webkit", "daemon", "wakeups_per_s"), 0.2)
        self.assertEqual(limit("light-webkit", "acpmux", "wakeups_max"), 0.1)
        self.assertEqual(sessions["light-webkit"]["sums"]["tree"], {"energy_mw_cpu": 1.0})  # D2: tree CPU energy
        self.assertEqual(limit("light", "app", "wakeups_per_s"), 1.0)
        self.assertEqual(limit("light", "app", "main_wakes_per_s"), 0.5)
        # D3: hidden, minimized, occluded, each no higher than light on the same run, and napped.
        for name in ("light-hidden", "minimized", "occluded"):
            self.assertEqual(limit(name, "app", "wakeups_per_s"), 0.3)
            self.assertEqual(limit(name, "app", "main_wakes_per_s"), 0.1)
            self.assertEqual(limit(name, "app", "role"), "napped")
            self.assertEqual({(r["to"], r["max_ratio"]) for r in sessions[name]["relative"]}, {("light", 1.0)})
        # D4 tabs-static.
        self.assertEqual(sessions["tabs-static"]["sums"]["app+daemon"]["wakeups_per_s"], 1.0)
        self.assertEqual(limit("tabs-static", "app", "main_wakes_per_s"), 0.5)
        self.assertEqual(limit("tabs-static", "cef-renderer", "hidden_wakeups_max"), 0.1)
        self.assertEqual(limit("tabs-static", "cef-extension", "wakeups_max"), 0.1)
        self.assertEqual(limit("tabs-static", "cef-network", "wakeups_per_s"), 0.2)
        self.assertEqual(limit("tabs-static", "webkit-browser-tab", "hidden_wakeups_max"), 0.5)
        # D5 stress-static.
        self.assertEqual(sessions["stress-static"]["sums"]["app+daemon"]["wakeups_per_s"], 1.0)
        self.assertEqual(limit("stress-static", "app", "main_wakes_per_s"), 0.5)
        # D6 Chrome ratios.
        chrome = {f"{r['of']}/{r['vs']}.{r['field']}": r["max_ratio"] for r in budget["ratio_to_chrome"]}
        xbench = {(r["browser"], r["row"]): r.get("max_ratio", r.get("max")) for r in budget["xbench"]}
        self.assertEqual(xbench[("cmux-chromium", "idle-wakeups-20")], 0.5)
        self.assertEqual(xbench[("cmux-chromium", "idle-wakeups-1")], 0.5)
        self.assertEqual(xbench[("cmux-chromium", "power-idle-visible")], 1.0)
        self.assertEqual(xbench[("cmux-chromium", "power-idle-hidden")], 1.0)
        self.assertEqual(xbench[("cmux-terminal", "idle-wakeups-home")], 1.0)
        self.assertEqual(chrome["cef-host/browser.wakeups_per_s"], 1.0)
        self.assertEqual(chrome["cef-gpu/gpu.wakeups_per_s"], 1.0)
        # D7 energy saver.
        for name, reason in (("energy-saver", "setting"), ("energy-saver-auto", "battery")):
            self.assertEqual(sessions[name]["limits"]["page_raf_per_s"], 31)
            self.assertEqual(sessions[name]["expect"], {"saver": True, "saver_reason": reason})
            self.assertEqual(sessions[name]["relative"],
                             [{"to": "tabs-static", "of": "tree", "field": "wakeups_per_s", "max_ratio": 0.6}])
        self.assertEqual(sessions["energy-saver-auto"]["simulate"], {"on_battery": True, "percent": 15})

    def test_assertion_with_keep_awake_off_is_an_over(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        held = [{"pid": 4242, "type": "PreventUserIdleSystemSleep", "name": "cmux keep awake"}]
        off = {"sessions.keepAwake": "off", "phone.keepAwake": "off"}
        over = ("assertions", "held", 1, 0)
        self.assertEqual(ib.over_budget("light", {}, budget, facts={"assertions": held, "settings": off}), [over])
        self.assertEqual(ib.over_budget("light", {}, budget, facts={"assertions": held}), [over])
        self.assertEqual(ib.over_budget("light", {}, budget, facts={"assertions": [], "settings": off}), [])
        # The shipping default (pluggedIn) with no agent at work: the assertion is a leak, and the run did not
        # have the settings the session asked for (off).
        shipping = {"sessions.keepAwake": "pluggedIn", "phone.keepAwake": "pluggedIn"}
        overs = ib.over_budget("light", {}, budget, facts={"assertions": held, "settings": shipping})
        self.assertIn(over, overs)
        self.assertIn(("session", "sessions.keepAwake", "pluggedIn", "off"), overs)
        self.assertIn(("session", "phone.keepAwake", "pluggedIn", "off"), overs)
        # Only a session that itself turns keep-awake on may hold one; busy and reference sessions are not judged.
        asks = {"sessions": {"keep-awake": {"settings": {"sessions.keepAwake": "always"}}},
                "assertions_allowed_when": budget["assertions_allowed_when"]}
        self.assertEqual(ib.over_budget("keep-awake", {}, asks,
                                        facts={"assertions": held, "settings": {"sessions.keepAwake": "always"}}), [])
        for name in ("agent-working-visible", "busy-hidden", "chrome-static"):
            self.assertEqual(ib.over_budget(name, {}, budget, facts={"assertions": held, "settings": shipping}), [])
        # STRESS has no agent at work: judged.
        self.assertIn(over, ib.over_budget("stress", {}, budget, facts={"assertions": held}))

    def test_every_session_runs_with_keep_awake_off(self):
        for session in ib.SESSIONS:
            config = ib.session_config(session)
            self.assertEqual((config["sessions"]["keepAwake"], config["phone"]["keepAwake"]), ("off", "off"))
            self.assertEqual(config["appearance"], {"backgroundOpacity": 1})
        self.assertEqual(ib.session_config("light-webkit")["browser"], {"defaultEngine": "webkit"})

    def test_relative_and_chrome_ratios(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        light = {"app": {"wakeups_per_s": 0.2, "main_wakes_per_s": 0.05}}
        hidden = {"app": {"wakeups_per_s": 0.25, "main_wakes_per_s": 0.0}}
        # light-hidden measured before light: judged all the same once both are measured.
        overs, notes = ib.cross_overs(budget, {"light-hidden": hidden, "light": light})
        self.assertEqual(overs, [("light-hidden", ("app", "wakeups_per_s/light", 1.25, 1.0))])
        self.assertEqual(notes, [])
        overs, notes = ib.cross_overs(budget, {"light-hidden": hidden})
        self.assertEqual(overs, [])
        self.assertIn("light-hidden app wakeups_per_s/light: not judged: reference session light not measured", notes)
        # 40/s vs Chrome's 63.5/s at 0.5 (task 004's fixture) and a Chromium Host above Chrome's browser process,
        # with tabs-static measured before chrome-static (task 004's --sessions tabs-static,chrome-static).
        cmux = {"app": {"wakeups_per_s": 26.7, "main_wakes_per_s": 0.4, "energy_mw_billed": 5.0},
                "daemon": {"wakeups_per_s": 0.0, "energy_mw_billed": 1.0},
                "cef-gpu": {"wakeups_per_s": 6.0, "energy_mw_billed": 2.0},
                "cef-host": {"wakeups_per_s": 4.0, "energy_mw_billed": 1.0},
                "cef-renderer": {"wakeups_per_s": 3.0, "energy_mw_billed": 0.0},
                "cef-network": {"wakeups_per_s": 0.2, "energy_mw_billed": 0.0},
                "cef-storage": {"wakeups_per_s": 0.1, "energy_mw_billed": 0.0},
                "cef-helper": {"wakeups_per_s": 0.0, "energy_mw_billed": 0.0}}
        chrome = {"browser": {"wakeups_per_s": 3.5, "energy_mw_billed": 20.0},
                  "gpu": {"wakeups_per_s": 57.0, "energy_mw_billed": 20.0},
                  "renderer": {"wakeups_per_s": 2.0, "energy_mw_billed": 1.0},
                  "utility": {"wakeups_per_s": 1.0, "energy_mw_billed": 1.0},
                  "other": {"wakeups_per_s": 0.0, "energy_mw_billed": 0.0}}
        overs, notes = ib.cross_overs(budget, {"tabs-static": cmux, "chrome-static": chrome})
        got = [over for session, over in overs if session == "tabs-static"]
        self.assertIn(("tree", "wakeups_per_s/chrome:tree", 0.63, 0.5), got)
        self.assertIn(("cef-host", "wakeups_per_s/chrome:browser", 1.143, 1.0), got)
        # The cef-* kinds with no number of their own are judged against Chrome's same role.
        self.assertIn(("cef-renderer", "wakeups_per_s/chrome:renderer", 1.5, 1.0), got)
        self.assertNotIn("cef-network+cef-storage+cef-audio+cef-utility", [o[0] for o in got])
        self.assertNotIn("cef-helper", [o[0] for o in got])
        self.assertNotIn("cef-gpu", [o[0] for o in got])
        self.assertEqual(notes, [])
        # Without chrome-static, every ratio_to_chrome row says it was not judged.
        _, notes = ib.cross_overs(budget, {"tabs-static": cmux})
        self.assertEqual(len([n for n in notes if "chrome-static not measured" in n]), len(budget["ratio_to_chrome"]))
        # A partial tree is no value: an unknown part makes the ratio not judged, not a pass.
        partial = {**cmux, "cef-gpu": {"wakeups_per_s": 6.0, "energy_mw_billed": None}}
        overs, notes = ib.cross_overs(budget, {"tabs-static": partial, "chrome-static": chrome})
        self.assertNotIn("energy_mw_billed/chrome:tree", [o[1] for _, o in overs])
        self.assertIn("tabs-static tree energy_mw_billed/chrome:tree: not judged: tree energy_mw_billed unknown", notes)

    def test_a_sum_with_an_unknown_part_is_no_value(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        kinds = {"app": {"energy_mw_cpu": 0.6, "wakeups_per_s": 0.1, "main_wakes_per_s": 0},
                 "cef-gpu": {"energy_mw_cpu": None, "wakeups_per_s": 0.1}}
        self.assertIsNone(ib.selector_value(kinds, "tree", "energy_mw_cpu"))
        self.assertTrue(ib.unknown_sum(kinds, "tree", "energy_mw_cpu"))
        self.assertEqual(ib.over_budget("light-webkit", kinds, budget), [])
        self.assertEqual(ib.sum_notes("light-webkit", kinds, budget), ["light-webkit tree energy_mw_cpu: not judged: unknown"])
        # A kind that lacks a field another kind carries is unknown too; a kind that did not run is skipped.
        self.assertIsNone(ib.selector_value({"app": {"x": 1.0}, "daemon": {}}, "tree", "x"))
        self.assertEqual(ib.selector_value({"app": {"x": 1.0}}, "app+daemon", "x"), 1.0)
        self.assertIsNone(ib.selector_value({}, "app+daemon", "x"))
        known = {"app": {"energy_mw_cpu": 0.6}, "daemon": {"energy_mw_cpu": 0.5}}
        self.assertEqual(ib.over_budget("light-webkit", known, budget), [("tree", "energy_mw_cpu", 1.1, 1.0)])
        rows = ib.cron_rows({"sessions": {"light-webkit": {"kinds": known}}}, budget)
        self.assertEqual(rows["idle_budget.light-webkit.tree.energy_mw_cpu"]["budget"], 1.0)
        self.assertEqual(rows["idle_budget.light-webkit.tree.energy_mw_cpu"]["unit"], "mW")

    def test_disk_and_log_reported_by_some_processes_only_are_unknown(self):
        processes = [{**row("daemon", 4, 0.0), "disk_bytes_per_s": 0.0}, row("daemon", 4, 0.0),
                     {**row("app", 30, 0.0), "disk_bytes_per_s": 0.0, "log_lines": 0}, row("holder", 2, 0.0)]
        kinds = ib.aggregate({"processes": processes})
        self.assertIsNone(kinds["daemon"]["disk_bytes_per_s"])
        self.assertEqual((kinds["app"]["disk_bytes_per_s"], kinds["app"]["log_lines"]), (0.0, 0))
        self.assertNotIn("disk_bytes_per_s", kinds["holder"])

    def test_stress_keeps_the_v1_limits_outside_its_busy_pages(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        kinds = {"holder": {"wakeups_max": 0.5}, "terminal-host": {"wakeups_max": 0.0},
                 "daemon": {"wakeups_per_s": 1.5}, "app": {"wakeups_per_s": 0.5, "main_wakes_per_s": 0},
                 "cef-renderer": {"wakeups_max": 60.0, "disk_bytes_per_s": 4096.0},
                 "webkit-webcontent": {"disk_bytes_per_s": 10.0}}
        self.assertEqual(ib.over_budget("stress", kinds, budget),
                         [("daemon", "wakeups_per_s", 1.5, 1.0), ("holder", "wakeups_max", 0.5, 0)])
        self.assertEqual(ib.limit_for(budget, "stress", "app", "main_wakes_per_s"), 0)
        self.assertEqual(ib.limit_for(budget, "stress", "terminal-host", "wakeups_max"), 0)
        self.assertIsNone(ib.limit_for(budget, "stress", "cef-renderer", "disk_bytes_per_s"))
        rows = ib.cron_rows({"sessions": {"stress": {"kinds": kinds}}}, budget)
        self.assertEqual(rows["idle_budget.stress.holder.wakeups_max"]["budget"], 0)
        self.assertEqual(rows["idle_budget.stress.daemon.wakeups_per_s"]["budget"], 1.0)

    def test_xbench_rows(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        result = {"rows": {"idle-wakeups-20": {"cmux-chromium": {"median": 40.0}, "chrome": {"median": 63.5}},
                           "idle-wakeups-1": {"cmux-chromium": {"median": 20.0}, "chrome": {"median": 44.8}},
                           "power-idle-visible": {"cmux-chromium": {"median": 90.0}, "chrome": {"median": 100.0}},
                           "idle-wakeups-home": {"cmux-terminal": {"median": 8.6}}}}
        overs, notes = ib.xbench_overs(budget, result)
        self.assertEqual(overs, [("cmux-chromium", "idle-wakeups-20/chrome", 0.63, 0.5),
                                 ("cmux-terminal", "idle-wakeups-home", 8.6, 1.0)])
        self.assertEqual(notes, ["xbench cmux-chromium power-idle-hidden: not judged: not measured"])
        self.assertEqual(ib.over_line("xbench", overs[1]),
                         "IDLE-BUDGET-OVER xbench cmux-terminal idle-wakeups-home 8.6 > 1.0")

    def test_session_limits_expectations_roles_and_busy_sessions(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        facts = {"page_raf_per_s": 60.0, "saver": True, "saver_reason": "setting"}
        self.assertEqual(ib.over_budget("energy-saver", {}, budget, facts=facts),
                         [("session", "page_raf_per_s", 60.0, 31)])
        self.assertEqual(ib.over_budget("energy-saver-auto", {}, budget, facts={**facts, "page_raf_per_s": 30}),
                         [("session", "saver_reason", "setting", "battery")])
        self.assertEqual(ib.over_line("x", ("session", "saver_reason", "setting", "battery")),
                         "IDLE-BUDGET-OVER x session saver_reason setting != battery")
        # A budget role is judged per process (role_audit), not per kind.
        napped = {"app": {"wakeups_per_s": 0.1, "main_wakes_per_s": 0.0, "roles": ["default"]}}
        self.assertEqual(ib.over_budget("minimized", napped, budget), [])
        self.assertEqual(ib.role_audit("minimized", [{"pid": 7, "kind": "app", "role": "default"}], budget),
                         ([{"kind": "app", "pids": [7], "observed": "default", "expected": "napped"}], []))
        # Idle sessions write nothing: all_kinds applies to every kind; busy and reference sessions take only
        # their own limits.
        self.assertEqual(ib.over_budget("light", {"cef-helper": {"disk_bytes_per_s": 12.0}}, budget),
                         [("cef-helper", "disk_bytes_per_s", 12.0, 0)])
        busy = {"app": {"wakeups_per_s": 1.5, "main_wakes_per_s": 30.0, "disk_bytes_per_s": 100.0}}
        self.assertEqual(ib.over_budget("busy-hidden", busy, budget), [])
        self.assertEqual(ib.over_budget("chrome-static", busy, budget), [])

    def test_aggregate_hidden_max_roles_and_energy(self):
        processes = [{**row("cef-renderer", 10, 0.05), "hidden": True, "energy_mw_billed": 0.25, "role": "best-effort"},
                     {**row("cef-renderer", 12, 3.0), "energy_mw_billed": 1.0, "role": "foreground"},
                     {**row("cef-renderer", 11, 0.3), "hidden": True, "role": "best-effort"}]
        entry = ib.aggregate({"processes": processes})["cef-renderer"]
        self.assertEqual(entry["hidden_wakeups_max"], 0.3)
        self.assertEqual(entry["wakeups_max"], 3.0)
        self.assertEqual(entry["energy_mw_billed"], 1.25)
        self.assertEqual(entry["roles"], ["best-effort", "foreground"])

    def test_allowed_periodic_fits_wakeup_audit_limits(self):
        entries = ib.load_budget(ib.BUDGET_FILE)["allowed_periodic"]
        self.assertLessEqual(len(entries), 6)
        for entry in entries:
            self.assertTrue(entry["owner"] and entry["why"])
            self.assertGreaterEqual(entry["period_s"], 15)


class SessionTableTests(unittest.TestCase):
    def test_tab_sessions_shape(self):
        tabs = ib.SESSIONS["tabs-static"]["tabs"]
        self.assertEqual((tabs["webkit_hidden"], tabs["chromium_hidden"], tabs["shown"]), (5, 10, "static"))
        self.assertEqual(ib.SESSIONS["tabs-static"]["config"]["browser"]["freezeHiddenTabs"], ib.FREEZE_HIDDEN_TABS_S)
        saver = ib.SESSIONS["energy-saver"]
        self.assertEqual(saver["config"]["energy"], {"saver": "always"})
        self.assertEqual(saver["tabs"]["shown"], "anim")
        self.assertEqual((saver["tabs"]["webkit_hidden"], saver["tabs"]["chromium_hidden"]), (5, 10))
        self.assertTrue(saver["saver"] and saver["anim"])
        self.assertTrue(ib.SESSIONS["minimized"]["minimize"])
        for name, entry in ib.SESSIONS.items():
            self.assertEqual(bool(entry.get("saver")), name == "energy-saver", name)

    def test_tab_sessions_settle_past_the_hidden_tab_freeze(self):
        for name in ("tabs-static", "energy-saver"):
            self.assertGreater(ib.settle_seconds(name, 5), ib.FREEZE_HIDDEN_TABS_S, name)
            self.assertEqual(ib.settle_seconds(name, 120), 120)
        self.assertEqual(ib.settle_seconds("light", 5), 5)

    def test_unknown_session_refused_before_any_launch(self):
        with self.assertRaises(SystemExit) as raised:
            ib.parse_sessions("light,tabs-statik")
        self.assertIn("unknown session tabs-statik", str(raised.exception))
        self.assertEqual(ib.parse_sessions("tabs-static,energy-saver,minimized"), ["tabs-static", "energy-saver", "minimized"])
        self.assertEqual(ib.parse_sessions("all"), list(ib.SESSIONS))

    def test_tab_plan_hides_every_tab_behind_the_shown_one(self):
        with ib.IdlePages() as pages:
            plan = ib.tab_plan(pages, ib.SESSIONS["energy-saver"]["tabs"])
            static = ib.tab_plan(pages, ib.SESSIONS["tabs-static"]["tabs"])
        self.assertEqual([engine for engine, _, _ in plan], ["webkit"] * 5 + ["chromium"] * 11)
        self.assertEqual(plan[0][1:], (pages.origin + ib.PROBE_PATH + "-w0", "w0"))
        self.assertEqual(plan[-1][1:], (pages.origin + ib.ANIM_PATH, "anim"))
        self.assertEqual(static[-1][1:], (pages.origin + ib.PROBE_PATH + "-shown", "shown"))
        self.assertEqual(ib.plan_keys(ib.TABS_STATIC)[-1], ("chromium", "shown"))
        self.assertEqual(len({key for _, _, key in plan}), len(plan))

    def test_idle_pages_serve_the_shared_static_page_and_the_animated_page(self):
        import urllib.request
        with ib.IdlePages() as pages:
            static = urllib.request.urlopen(pages.url("static", "c3"), timeout=5).read().decode()
            anim = urllib.request.urlopen(pages.origin + ib.ANIM_PATH, timeout=5).read().decode()
            urllib.request.urlopen(urllib.request.Request(pages.origin + "/loaded/anim", method="POST"), timeout=5).read()
            self.assertTrue(pages.wait_loaded("anim", 5))
            self.assertFalse(pages.wait_loaded("c3", 0))
        self.assertEqual(static, ib.tab_pages.TabPages.body(pages, "/static-c3").decode())
        self.assertNotIn("requestAnimationFrame", static)
        self.assertIn("requestAnimationFrame", anim)
        self.assertIn("__rafCount", anim)
        self.assertIn("/loaded/anim", anim)
        self.assertIn(ib.ANIM_READ_PATH, anim)
        self.assertIn(ib.ANIM_COUNT_PATH, anim)

    def test_read_anim_answers_the_held_read_and_returns_the_posted_count(self):
        """The page's read path, played by a thread as the page's script does it: a held GET, then the POST."""
        import threading
        import urllib.request
        with ib.IdlePages() as pages:
            def page():
                urllib.request.urlopen(pages.origin + ib.ANIM_READ_PATH, timeout=10).read()
                urllib.request.urlopen(urllib.request.Request(
                    pages.origin + ib.ANIM_COUNT_PATH + "/1800/61000.25/visible", method="POST"), timeout=5).read()
            held = threading.Thread(target=page)
            held.start()
            got = pages.read_anim(5)  # answered whether the GET arrived before or after this ask
            held.join(5)
            self.assertEqual(got, {"count": 1800, "t_ms": 61000.25, "visibility": "visible"})
            self.assertIn("error", pages.read_anim(0.2))  # no page asks again: an error, not a hang
            again = threading.Thread(target=page)
            again.start()  # the late GET answers the read that timed out at once
            again.join(5)
            self.assertFalse(again.is_alive())
        self.assertIn("error", ib.parse_anim_count(ib.ANIM_COUNT_PATH + "/x/1/visible"))

    def test_the_anim_page_needs_no_devtools(self):
        source = (HERE / "idle-budget.py").read_text()
        self.assertNotIn("CMUX_NEXT_CEF_EXTRA_SWITCHES", source)
        self.assertNotIn("remote-debugging-port", source)


class FakeApp:
    """An app whose control socket records each method in `calls`, shared with the fake usage reads."""

    def __init__(self, calls):
        self.calls = calls

    def rpc(self, method, params=None, timeout=30):
        self.calls.append(method)
        if method == "debug.hangs":
            return {"main_wakes": 10 * sum(1 for c in self.calls if c == "debug.hangs")}
        if method == "debug.energy":
            return {"policy": {"isSaver": True, "reason": "setting"}}
        return {}


class MeasureOrderTests(unittest.TestCase):
    def test_window_end_reads_sit_outside_every_counter_bracket(self):
        calls = []
        app = FakeApp(calls)
        instance = type("Instance", (), {"pid": 1, "harness": {}})()
        saved = (ib.process_set, ib.threads, procs.usage, procs.overhead, procs.gpu_ns_by_pid, procs.coalition_of,
                 procs.coalition_id, procs.thermal_state, procs.power_assertions, ib.time.sleep)
        ib.process_set = lambda _instance: ib.ProcessSet({1: f"{APP}/Contents/MacOS/cmux DEV"},
                                                         [(1, 0, f"{APP}/Contents/MacOS/cmux DEV")])
        ib.threads = lambda _pid: {}
        procs.usage = lambda pid: calls.append("usage" if pid == 1 else f"usage {pid}") or procs.usage_from_words(
            rusage_words(), 1, 1)
        procs.overhead = lambda _pid: (0, 30, 0, 0, 0)
        procs.gpu_ns_by_pid = lambda: {}
        procs.coalition_of = lambda _pid: None
        procs.coalition_id = lambda _pid: 7
        procs.thermal_state = lambda: "nominal"
        procs.power_assertions = lambda _pids: calls.append("pmset") or []
        ib.time.sleep = lambda seconds: calls.append(f"sleep {seconds:g}")
        roles_saved = (procs.priorities, procs.process_table, ib.acpmux_homes)
        procs.priorities = lambda _pids: calls.append("roles") or {1: {"base": 4, "nice": 0, "darwinbg": True}}
        procs.process_table = lambda: calls.append("ps") or []
        ib.acpmux_homes = lambda _env: []
        d15 = ib.D15Readers(windowserver=lambda: calls.append("windowserver") or (157, 10, "rusage", len(calls)),
                            start_network=lambda seconds, workdir: calls.append(f"nettop start {seconds:g}") or "nettop",
                            network_pid=lambda started: 77,
                            finish_network=lambda started, start, end: calls.append(f"nettop finish {started}") or {},
                            read_log=lambda pids, start, end: calls.append("log show") or None)
        try:
            result = ib.measure(app, instance, 60, read_anim=lambda: calls.append("anim") or {"count": 0, "t_ms": 0},
                                d15=d15)
        finally:
            (ib.process_set, ib.threads, procs.usage, procs.overhead, procs.gpu_ns_by_pid, procs.coalition_of,
             procs.coalition_id, procs.thermal_state, procs.power_assertions, ib.time.sleep) = saved
            (procs.priorities, procs.process_table, ib.acpmux_homes) = roles_saved
        probes = {"debug.energy", "pmset", "anim"}
        counters = [i for i, c in enumerate(calls) if c in ("debug.hangs", "debug.wakeups", "debug.cef", "debug.layers", "usage")]
        start_probes = [i for i, c in enumerate(calls) if c in probes and i < counters[0]]
        end_probes = [i for i, c in enumerate(calls) if c in probes and i > counters[-1]]
        self.assertEqual(len(start_probes) + len(end_probes), sum(1 for c in calls if c in probes))
        self.assertEqual((len(start_probes), len(end_probes)), (3, 3))
        # nettop starts, then a quiet gap (its start-up and the start reads' aftermath) before the counters
        self.assertEqual(calls[start_probes[-1] + 1:start_probes[-1] + 3],
                         [f"nettop start {60 + ib.NETTOP_LEAD_S:g}", f"sleep {ib.QUIET_GAP_S:g}"])
        # debug.webui runs on the app's main actor: the census the kinds need is read after every counter.
        self.assertGreater(calls.index("debug.webui"), counters[-1])
        self.assertEqual(calls.count("debug.webui"), 1)
        self.assertEqual([(r["kind"], r["hidden"]) for r in result["processes"]], [("app", False)])
        self.assertEqual(result["ends"]["start"]["saver"], True)
        self.assertIn("anim", result["ends"]["end"])
        # The roles are read once, after every counter and end read.
        self.assertEqual(calls.count("roles"), 1)
        self.assertGreater(calls.index("roles"), max(counters + end_probes))
        self.assertEqual((result["processes"][0]["role"], result["processes"][0]["pooled"]), ("darwinbg", False))
        # The pooled agents come from the set's own `ps` rows: no second `ps` read in the window.
        self.assertNotIn("ps", calls)
        # D15: WindowServer is read outside the process counters; nettop starts before every bracket (no exec or
        # start-up of it inside one), samples its lead plus the window and ends after the last read; its own usage
        # is read right at the window's two ends (its coalition share is taken out); `log show` reads logd after.
        usage = [i for i, c in enumerate(calls) if c == "usage"]
        window = calls.index("sleep 60")
        servers = [i for i, c in enumerate(calls) if c == "windowserver"]
        self.assertEqual(len(servers), 2)
        self.assertTrue(servers[0] < usage[0] and servers[1] > usage[-1])
        started = calls.index(f"nettop start {60 + ib.NETTOP_LEAD_S:g}")
        self.assertLess(started, calls.index(f"sleep {ib.QUIET_GAP_S:g}"))
        self.assertTrue(started < usage[0] < window < usage[-1] < calls.index("nettop finish nettop"))
        self.assertEqual([i for i, c in enumerate(calls) if c == "usage 77"], [window - 1, window + 1])
        self.assertGreater(calls.index("log show"), usage[-1])
        self.assertEqual(result["readers"], {"network": True, "log": False})
        self.assertEqual([r["network_bytes"] for r in result["processes"]], [0])
        self.assertEqual([r["log_lines"] for r in result["processes"]], [None])
        self.assertEqual(result["windowserver"]["source"], "rusage")

    def test_nettop_runs_before_the_power_window_and_leaves_the_coalition(self):
        """nettop exists before PowerWindow lists the coalition's outside members, and the coalition rates lose its
        share: a reader started inside the bracket (after prepare) fails here."""
        calls, ticks = [], {"coalition": 0, 77: 0}

        class FakeWindow:
            def __init__(self, *_args):
                pass

            def prepare(self):
                calls.append("prepare")

            def begin(self):
                calls.append("begin")

            def end(self):
                calls.append("end")

            def finish(self):
                return None

        def coalition(_pid):
            ticks["coalition"] += 1
            wakeups = 0 if ticks["coalition"] == 1 else 600  # 10/s over the 60 s window, nettop's 1/s of it
            return procs.CoalitionUsage(0, 0, 0, 0, 0, wakeups, 0)

        def usage(pid):
            if pid == 77:
                ticks[77] += 1
                return procs.usage_from_words(rusage_words(interrupt=0 if ticks[77] == 1 else 60), 1, 1)
            return procs.usage_from_words(rusage_words(), 1, 1)

        d15 = ib.D15Readers(windowserver=lambda: (157, 10, "rusage", 0.0),
                            start_network=lambda seconds, workdir: calls.append("nettop start") or "nettop",
                            network_pid=lambda started: 77, finish_network=lambda started, start, end: {},
                            read_log=lambda pids, start, end: {})
        clock = iter(range(0, 1000, 60))
        with contextlib.ExitStack() as stack:
            for target, name, value in (
                    (ib, "process_set", lambda _instance: ib.ProcessSet({1: f"{APP}/Contents/MacOS/cmux DEV"},
                                                                        [(1, 0, f"{APP}/Contents/MacOS/cmux DEV")])),
                    (ib, "threads", lambda _pid: {}), (ib, "frame_sources", lambda _app: None),
                    (ib.power_attribution, "PowerWindow", FakeWindow), (procs, "usage", usage),
                    (procs, "overhead", lambda _pid: (0, 30, 0, 0, 0)), (procs, "gpu_ns_by_pid", lambda: {}),
                    (procs, "coalition_of", coalition), (procs, "coalition_id", lambda _pid: 7),
                    (procs, "thermal_state", lambda: "nominal"), (procs, "power_assertions", lambda _pids: []),
                    (procs, "priorities", lambda _pids: {}), (ib, "acpmux_homes", lambda _env: []),
                    (ib.time, "sleep", lambda _seconds: None), (ib.time, "monotonic", lambda: next(clock))):
                stack.enter_context(unittest.mock.patch.object(target, name, value))
            result = ib.measure(FakeApp([]), type("Instance", (), {"pid": 1, "harness": {}})(), 60, attribute=True, d15=d15)
        self.assertEqual(calls, ["nettop start", "prepare", "begin", "end"])
        self.assertEqual(result["coalition"]["wakeups_per_s"], 9.0)

    def test_a_reader_outside_the_app_coalition_is_not_subtracted(self):
        coalition = {"energy_mw_cpu": 1.0, "energy_mw_billed": 1.0, "cpu_pct": 0.5, "wakeups_per_s": 4.0,
                     "pkg_idle_wakeups_per_s": 1.0, "gpu_ms_per_s": 0.0}
        nettop = procs.usage_from_words(rusage_words(interrupt=60), 1, 1)
        self.assertEqual(ib.coalition_without(coalition, procs.Usage(), nettop, 60)["wakeups_per_s"], 3.0)
        self.assertIsNone(ib.coalition_without(coalition, procs.Usage(), None, 60))  # gone: unknown, not the app's
        with unittest.mock.patch.object(procs, "coalition_id", lambda pid: {1: 7, 77: 8}.get(pid)):
            self.assertFalse(ib.same_coalition(77, 1))
            self.assertTrue(ib.same_coalition(1, 1))


# The role reads of one window (procs.priorities' seams): each task's base priority (proc_pidinfo PROC_PIDTASKINFO
# pti_priority) and its darwinbg bit and nice (PROC_PIDTBSDINFO). The app, daemon, terminal host and three renderers
# at the default 31 (not lowered), the spare renderer 603 darwin background at 4, the extension process suppressed at
# 28; 999 is not of the set and 700 is gone (neither read answers).
TASK_BASE = {501: 31, 502: 31, 503: 31, 601: 31, 602: 31, 605: 31, 603: 4, 604: 28, 999: 20}
BSD_STATE = {501: (False, 0), 502: (False, 0), 503: (False, 0), 601: (False, 0), 602: (False, 0), 605: (False, 0),
             603: (True, 0), 604: (False, 0), 999: (False, 0)}


def role_priorities(pids, base=None, bsd=None):
    base, bsd = {**TASK_BASE, **(base or {})}, {**BSD_STATE, **(bsd or {})}
    return procs.priorities(pids, task_priority_of=base.get, bsd_state_of=bsd.get)


def role_rows(kinds, hidden=None, shown=None, base=None):
    """Rows of `kinds` ({pid: kind}) with their roles from the fixture reads and the census's `hidden` / `shown`."""
    rows = [{"pid": pid, "kind": kind} for pid, kind in kinds.items()]
    for row_ in rows:
        if hidden and row_["pid"] in hidden:
            row_["hidden"] = hidden[row_["pid"]]
        if shown and row_["pid"] in shown:
            row_["shown"] = shown[row_["pid"]]
    return ib.with_roles(rows, role_priorities(kinds, base), pooled=set())


def census_rows_of(kinds, census, shown_tab=None, base=None):
    """Rows marked as measure() marks them: WindowKinds' `hidden` and `shown` from a debug.webui census."""
    window = ib.WindowKinds([], census, shown_tab)
    rows = [{"pid": pid, "kind": kind, "hidden": window.hidden(pid, kind), "shown": window.shown(pid, kind)}
            for pid, kind in kinds.items()]
    return ib.with_roles(rows, role_priorities(kinds, base), pooled=set())


TABS_KINDS = {501: "app", 502: "daemon", 503: "terminal-host", 601: "cef-renderer", 602: "cef-renderer",
              605: "cef-renderer", 603: "cef-renderer", 604: "cef-extension"}
# tabs-static as debug.webui reports it: Home visible in Chromium (601), the shown browser tab t1 (602), the hidden
# tab t2 (605) and a spare (603).
TABS_CENSUS = {"pages": [{"page": "cmux.home", "state": "visible", "webkit_pid": None, "renderer_pids": [601]}],
               "spares": [{"spare": "cef_window", "renderer_pids": [603], "webkit_pid": None}],
               "browser_tabs": [{"tab": "t1", "renderer_pids": [602]}, {"tab": "t2", "renderer_pids": [605]}]}
TABS_SHOWN = {"engine": "chromium", "tabs": ["t1"]}


class ReshowApp:
    """An app for reshow_tab: tab.focus selects its target (unless `selects` is false), browser.page.tabs reports
    the selection and debug.webui answers `browser_tabs` (the census after the switch); `selects` None refuses the
    switch."""

    def __init__(self, browser_tabs, selects=True):
        self.browser_tabs, self.selects, self.focused, self.selected = browser_tabs, selects, [], "t1"

    def rpc(self, method, params=None, timeout=30):
        params = params or {}
        if method == "action.run" and params.get("action") == "tab.focus":
            self.focused.append(params["target"])
            if self.selects is None:
                return {"error": {"code": "refused", "message": "no such tab"}}
            if self.selects:
                self.selected = params["target"].removeprefix("tab:")
            return {"ok": True}
        if method == "browser.page.tabs":
            return {"tabs": [{"id": tab["tab"], "selected": tab["tab"] == self.selected} for tab in self.browser_tabs]}
        if method == "debug.webui":
            return {"pages": [], "spares": [], "browser_tabs": self.browser_tabs}
        return {}


class RoleAuditTests(unittest.TestCase):
    """Task 106: each task's role from its base priority and darwinbg bit, checked against D16."""

    def test_fixture_reads_give_a_role_per_process(self):
        priority = role_priorities(list(TABS_KINDS) + [700])
        self.assertEqual(sorted(priority), sorted(TABS_KINDS))  # 999 is not asked for; 700 is gone
        self.assertEqual(priority[603], {"base": 4, "darwinbg": True, "nice": 0})
        roles = {row_["pid"]: row_["role"] for row_ in role_rows(TABS_KINDS)}
        self.assertEqual(roles, {501: "default", 502: "default", 503: "default", 601: "default", 602: "default",
                                 605: "default", 603: "darwinbg", 604: "suppressed"})
        self.assertIsNone(ib.observed_role(None))
        self.assertIsNone(ib.observed_role({"base": None, "darwinbg": False}))
        self.assertEqual(ib.observed_role({"base": None, "darwinbg": True}), "darwinbg")
        # One unread half is None, the other still counts.
        self.assertEqual(procs.priorities([1], task_priority_of=lambda _pid: 28, bsd_state_of=lambda _pid: None),
                         {1: {"base": 28, "darwinbg": None, "nice": None}})

    def test_the_task_base_priority_decides_not_the_busiest_thread(self):
        """`ps -o pri` would print 97 for a napped app with one realtime thread (CVDisplayLink, audio) and 20 for a
        daemon whose threads all idle at utility QoS: the task's base priority is what the role sets."""
        napped_with_realtime_thread = {"base": 4, "darwinbg": False, "nice": 0}
        self.assertEqual(ib.observed_role(napped_with_realtime_thread), "suppressed")
        self.assertEqual(ib.observed_role({"base": 28, "darwinbg": False, "nice": 0}), "suppressed")
        utility_qos_daemon = {"base": 31, "darwinbg": False, "nice": 0}
        self.assertEqual(ib.observed_role(utility_qos_daemon), "default")
        budget = ib.load_budget(ib.BUDGET_FILE)
        app = role_rows({501: "app"}, base={501: 4})
        self.assertEqual(ib.role_audit("minimized", app, budget), ([], []))
        daemons = role_rows({502: "daemon", 503: "terminal-host"})
        self.assertEqual(ib.role_audit("light", daemons, budget), ([], []))

    def test_hidden_renderer_at_foreground_priority_is_flagged(self):
        """With 104's census: in tabs-static Home's visible renderer and the shown tab's are judged not-background
        and pass at the default priority (energy-saver does not judge them); the hidden tab's renderer at the default
        priority is the one mismatch."""
        budget = ib.load_budget(ib.BUDGET_FILE)
        rows = census_rows_of(TABS_KINDS, TABS_CENSUS, TABS_SHOWN)
        for session in ("tabs-static", "energy-saver"):
            mismatches, notes = ib.role_audit(session, rows, budget)
            self.assertEqual(mismatches, [{"kind": "cef-renderer", "pids": [605], "observed": "default",
                                           "expected": "best-effort"}])
            self.assertEqual(notes, [])
        self.assertEqual(ib.role_over_line("tabs-static", mismatches[0]),
                         "IDLE-BUDGET-OVER tabs-static cef-renderer role owner=role pids=605 observed=default "
                         "expected=best-effort")
        # Suppressed, the hidden tab passes.
        fixed = census_rows_of(TABS_KINDS, TABS_CENSUS, TABS_SHOWN, base={605: 4})
        self.assertEqual(ib.role_audit("tabs-static", fixed, budget), ([], []))

    def test_a_shown_renderer_left_at_best_effort_is_flagged(self):
        """Task 107, steady state: in tabs-static (judge_shown_renderers) the shown tab's and Home's renderers are
        foreground (Chrome's kUserBlocking); backgrounded, each is a mismatch. The other shown sessions do not judge
        a shown renderer (nobody measured them for it), and with no window shown every renderer is best-effort."""
        budget = ib.load_budget(ib.BUDGET_FILE)
        backgrounded = census_rows_of(TABS_KINDS, TABS_CENSUS, TABS_SHOWN, base={605: 4, 601: 4, 602: 28})
        mismatches, notes = ib.role_audit("tabs-static", backgrounded, budget)
        self.assertEqual(mismatches, [
            {"kind": "cef-renderer", "pids": [601], "observed": "suppressed", "expected": "not-background"},
            {"kind": "cef-renderer", "pids": [602], "observed": "suppressed", "expected": "not-background"}])
        self.assertEqual(notes, [])
        self.assertEqual(ib.role_over_line("tabs-static", mismatches[1]),
                         "IDLE-BUDGET-OVER tabs-static cef-renderer role owner=role pids=602 observed=suppressed "
                         "expected=not-background")
        for session in ("energy-saver", "light"):
            self.assertEqual(ib.role_audit(session, backgrounded, budget), ([], []), session)
        self.assertTrue(ib.SESSIONS["tabs-static"]["judge_shown_renderers"])
        self.assertEqual([name for name, spec in ib.SESSIONS.items() if spec.get("judge_shown_renderers")],
                         ["tabs-static"])
        self.assertEqual([m["pids"] for m in ib.role_audit("minimized", backgrounded, budget)[0]
                          if m["kind"] == "cef-renderer"], [])

    def reshow(self, after_reads, after_tabs=None, selects=True, rows=None, wait_s=1.0):
        """reshow_tab on tabs-static's window rows (t2's renderer 605 best-effort, t1's 602 foreground) with
        `after_reads`: the priority reads after the switch, in order (the last repeats)."""
        rows = rows if rows is not None else census_rows_of(TABS_KINDS, TABS_CENSUS, TABS_SHOWN, base={605: 4})
        app = ReshowApp(after_tabs if after_tabs is not None else TABS_CENSUS["browser_tabs"], selects)
        now, reads = [0.0], list(after_reads)

        def read(pids):
            reading = reads.pop(0) if len(reads) > 1 else reads[0]
            return {pid: {"base": reading[pid], "darwinbg": False, "nice": 0} for pid in pids if pid in reading}

        def sleep(seconds):
            now[0] += seconds

        record = ib.reshow_tab(app, rows, ib.census_tab_pids(TABS_CENSUS), TABS_SHOWN, read_priorities=read,
                               clock=lambda: now[0], sleep=sleep, wait_s=wait_s)
        return record, app

    def test_reshow_shows_the_hidden_tab_and_reads_its_return(self):
        """Task 107, the transition: t2 was hidden and best-effort; shown through tab.focus, its renderer comes back
        to the default priority and t1's goes to best-effort. The first read after the switch has not changed yet
        (Chromium sets it on its launcher thread), the second has."""
        record, app = self.reshow([{605: 4, 602: 31}, {605: 31, 602: 4}])
        self.assertEqual(app.focused, ["tab:t2"])
        self.assertEqual((record["tab"], record["previous"], record["selected"]), ("t2", ["t1"], True))
        self.assertEqual(record["before"], [{"pid": 605, "of": "tab", "role": "suppressed"},
                                            {"pid": 602, "of": "previous", "role": "default"}])
        self.assertEqual([(item["pid"], item["of"], item["priority"]["base"]) for item in record["after"]],
                         [(605, "tab", 31), (602, "previous", 4)])
        self.assertEqual(ib.reshow_audit("tabs-static", record), ([], []))
        self.assertEqual(json.loads(json.dumps(record)), record)  # the report's JSON keeps it as is

    def test_a_renderer_that_does_not_come_back_is_an_over(self):
        """CEF lowering a renderer on hide but not raising it on show: after RESHOW_WAIT_S t2's renderer is still
        best-effort and t1's still foreground, two reshow overs (and the window's own read passed)."""
        record, _app = self.reshow([{605: 4, 602: 31}], wait_s=1.0)
        self.assertGreaterEqual(record["waited_s"], 1.0)
        mismatches, notes = ib.reshow_audit("tabs-static", record)
        self.assertEqual(mismatches, [
            {"kind": "cef-renderer", "pids": [605], "observed": "suppressed", "expected": "not-background",
             "phase": "reshow"},
            {"kind": "cef-renderer", "pids": [602], "observed": "default", "expected": "best-effort",
             "phase": "reshow"}])
        self.assertEqual(notes, [])
        self.assertEqual(ib.role_over_line("tabs-static", mismatches[0]),
                         "IDLE-BUDGET-OVER tabs-static cef-renderer role owner=role pids=605 observed=suppressed "
                         "expected=not-background phase=reshow")
        window = census_rows_of(TABS_KINDS, TABS_CENSUS, TABS_SHOWN, base={605: 4})
        rows = [{**row(r["kind"], 10, 0.0), **r} for r in window]
        entry = ib.summarize("tabs-static", {"processes": rows, "ends": ends(False, False), "reshow": record},
                             ib.load_budget(ib.BUDGET_FILE))
        self.assertEqual(entry["role_mismatches"], mismatches)
        self.assertIn(["cef-renderer", "role", "suppressed", "not-background"], entry["over"])

    def test_a_reshow_that_cannot_run_or_measure_a_return_says_so(self):
        # No hidden tab was read best-effort: nothing to show, a note (the window's read already flagged 605).
        record, app = self.reshow([{}], rows=census_rows_of(TABS_KINDS, TABS_CENSUS, TABS_SHOWN))
        self.assertEqual(app.focused, [])
        self.assertEqual(ib.reshow_audit("tabs-static", record),
                         ([], ["tabs-static cef-renderer reshow: not judged: no hidden Chromium tab was read "
                               "best-effort at the window's end"]))
        self.assertEqual(ib.reshow_candidate([], {}, TABS_SHOWN)[2], "no census browser_tabs or no shown tab")
        # The selection never landed.
        record, _app = self.reshow([{605: 31, 602: 4}], selects=False)
        self.assertEqual(ib.reshow_audit("tabs-static", record)[1],
                         [f"tabs-static cef-renderer reshow: not judged: tab t2 was not reported selected in "
                          f"{ib.RESHOW_WAIT_S:g} s"])
        # The app refused the switch: the window stays measured, only the reshow is skipped.
        record, _app = self.reshow([{}], selects=None)
        self.assertEqual(ib.reshow_audit("tabs-static", record)[1],
                         ["tabs-static cef-renderer reshow: not judged: tab.focus refused: "
                          "{'code': 'refused', 'message': 'no such tab'}"])
        # The tab came back in a new renderer (discarded while hidden): judged, but no return is measured.
        moved = [{"tab": "t1", "renderer_pids": [602]}, {"tab": "t2", "renderer_pids": [606]}]
        record, _app = self.reshow([{606: 31, 602: 4}], after_tabs=moved)
        self.assertEqual(ib.reshow_audit("tabs-static", record),
                         ([], ["tabs-static cef-renderer reshow: not judged: tab t2 runs a new renderer after the "
                               "switch (pids before=605 after=606): its return is not measured"]))
        # A renderer gone before its read.
        record, _app = self.reshow([{605: 31}])
        self.assertEqual(ib.reshow_audit("tabs-static", record),
                         ([], ["tabs-static cef-renderer reshow: not judged: unread pids=602"]))
        self.assertEqual(ib.reshow_audit("light", None), ([], []))
        self.assertEqual([name for name, spec in ib.SESSIONS.items() if spec.get("reshow")], ["tabs-static"])

    def test_a_build_without_a_census_judges_no_renderer_of_a_shown_session(self):
        """No debug.webui: every renderer is of unknown visibility. A shown session reports them not judged (no false
        over for Home's or the shown tab's renderer); with no window shown each is still best-effort."""
        budget = ib.load_budget(ib.BUDGET_FILE)
        rows = census_rows_of(TABS_KINDS, {}, TABS_SHOWN)
        self.assertEqual([(r["hidden"], r["shown"]) for r in rows if r["kind"] == "cef-renderer"], [(False, False)] * 4)
        mismatches, notes = ib.role_audit("tabs-static", rows, budget)
        self.assertEqual(mismatches, [])
        self.assertEqual(notes, ["tabs-static cef-renderer role: not judged: visibility unknown pids=601,602,603,605"])
        mismatches, _notes = ib.role_audit("minimized", rows, budget)
        self.assertEqual([(m["kind"], m["pids"]) for m in mismatches if m["kind"] == "cef-renderer"],
                         [("cef-renderer", [601]), ("cef-renderer", [602]), ("cef-renderer", [605])])

    def test_minimized_app_must_nap_and_every_renderer_is_best_effort(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        mismatches, _notes = ib.role_audit("minimized", role_rows(TABS_KINDS), budget)
        self.assertEqual([(m["kind"], m["pids"], m["observed"], m["expected"]) for m in mismatches],
                         [("app", [501], "default", "napped"),
                          ("cef-renderer", [601], "default", "best-effort"),
                          ("cef-renderer", [602], "default", "best-effort"),
                          ("cef-renderer", [605], "default", "best-effort")])
        napped = role_rows({501: "app", 502: "daemon", 603: "cef-renderer"}, base={501: 28})
        self.assertEqual(ib.role_audit("minimized", napped, budget), ([], []))

    def test_the_chromium_host_naps_while_no_window_shows(self):
        """Task 128: the host holds its App Nap activity only while a page shows, so with no window shown it is
        napped like the app; while a window shows it is not judged (a hidden-page-only host is not in the census)."""
        budget = ib.load_budget(ib.BUDGET_FILE)
        awake = role_rows({501: "app", 509: "cef-host"}, base={501: 28, 509: 31})
        mismatches, _notes = ib.role_audit("minimized", awake, budget)
        self.assertEqual([(m["kind"], m["pids"], m["observed"], m["expected"]) for m in mismatches],
                         [("cef-host", [509], "default", "napped")])
        napped = role_rows({501: "app", 509: "cef-host"}, base={501: 28, 509: 28})
        self.assertEqual(ib.role_audit("light-hidden", napped, budget), ([], []))
        self.assertEqual(ib.role_audit("tabs-static", awake, budget)[0], [])

    def test_an_unread_role_is_not_judged_and_says_so(self):
        """A process whose role could not be read (gone at the window's end, the read failed) is a not-judged note,
        never a silent pass."""
        budget = ib.load_budget(ib.BUDGET_FILE)
        rows = ib.with_roles([{"pid": 501, "kind": "app"}, {"pid": 502, "kind": "daemon"}], {}, pooled=set())
        self.assertEqual(ib.role_audit("minimized", rows, budget), ([], ["minimized app role: not judged: unread pids=501"]))
        entry = ib.summarize("minimized", {"processes": [{**row("app", 30, 0.1), "pid": 501, "role": None}],
                                           "ends": ends(False, False)}, budget)
        self.assertIn("minimized app role: not judged: unread pids=501", entry["not_judged"])
        self.assertFalse([o for o in entry["over"] if o[1] == "role"])

    def test_daemon_and_terminal_host_never_background_while_a_terminal_shows(self):
        rows = role_rows({502: "daemon", 603: "terminal-host"})
        budget = ib.load_budget(ib.BUDGET_FILE)
        self.assertEqual(ib.role_audit("light", rows, budget)[0],
                         [{"kind": "terminal-host", "pids": [603], "observed": "darwinbg", "expected": "not-background"}])
        self.assertEqual(ib.role_audit("minimized", rows, budget), ([], []))

    def test_pooled_agents_are_darwin_background(self):
        rows = role_rows({502: "acpmux", 603: "acpmux"})
        for row_ in rows:
            row_["pooled"] = True
        self.assertEqual(ib.role_audit("light", rows, ib.load_budget(ib.BUDGET_FILE))[0],
                         [{"kind": "acpmux", "pids": [502], "observed": "default", "expected": "background"}])

    def test_busy_and_reference_sessions_are_not_judged(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        rows = role_rows({601: "cef-renderer", 602: "cef-renderer"}, hidden={601: True, 602: True})
        self.assertEqual(ib.role_audit("stress", rows, budget), ([], []))
        self.assertEqual(ib.role_audit("chrome-static", rows, budget), ([], []))

    def test_an_explicit_null_role_is_not_judged(self):
        """`"role": null` means measured, not judged (limit_for's contract), not D16's default."""
        rows = role_rows({501: "app"})  # the app at the default priority while minimized
        own = {"kinds": {}, "sessions": {"minimized": {"kinds": {"app": {"role": None}}}}}
        self.assertEqual(ib.role_audit("minimized", rows, own), ([], []))
        per_session = {"kinds": {"app": {"role": {"minimized": None}}}}
        self.assertEqual(ib.role_audit("minimized", rows, per_session), ([], []))
        self.assertEqual(ib.role_audit("minimized", rows, {"kinds": {}})[0][0]["expected"], "napped")
        renderers = census_rows_of({601: "cef-renderer"}, {}, None)
        self.assertEqual(ib.role_audit("tabs-static", renderers, {"kinds": {"cef-renderer": {"role": None}}}), ([], []))
        self.assertEqual(ib.role_budget_errors(own), [])

    def test_budget_role_overrides_and_unknown_roles(self):
        budget = {"kinds": {}, "sessions": {"minimized": {"kinds": {"app": {"role": "not-background"}}}}}
        rows = role_rows({501: "app"})
        self.assertEqual(ib.role_audit("minimized", rows, budget), ([], []))
        rows[0]["role"] = "suppressed"
        self.assertEqual(ib.role_audit("minimized", rows, budget)[0],
                         [{"kind": "app", "pids": [501], "observed": "suppressed", "expected": "not-background"}])
        self.assertEqual(ib.role_budget_errors(ib.load_budget(ib.BUDGET_FILE)), [])
        typo = {"kinds": {"app": {"role": {"light": "naped"}}}, "sessions": {"x": {"kinds": {"daemon": {"role": "bg"}}}}}
        self.assertEqual(len(ib.role_budget_errors(typo)), 2)
        self.assertEqual(len(ib.role_budget_errors({"kinds": {"app": {"role": "foreground"}}})), 1)
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "budget.json")
            with open(path, "w") as handle:
                json.dump(typo, handle)
            with self.assertRaises(SystemExit) as raised:
                ib.main(["--budget", path, "--app", APP])
        self.assertIn("kinds.app.role.light", str(raised.exception))

    def test_summarize_counts_role_mismatches_as_overs(self):
        rows = [{**row("app", 30, 0.1), "pid": 501, "role": "default"}]
        result = {"processes": rows, "ends": ends(False, False)}
        entry = ib.summarize("minimized", result, ib.load_budget(ib.BUDGET_FILE))
        self.assertIn(["app", "role", "default", "napped"], entry["over"])
        self.assertEqual(entry["role_mismatches"][0]["pids"], [501])

    def test_pool_pids_trusts_only_live_hosts(self):
        with tempfile.TemporaryDirectory() as home:
            pool = os.path.join(home, "hosts", "pool")
            os.makedirs(pool)
            records = {"live": {"session_id": "s1", "start_nonce": "ab12", "host_pid": 70},
                       "stale": {"session_id": "s2", "start_nonce": "cd34", "host_pid": 80},
                       "bad": {"session_id": "../x", "start_nonce": "ab", "host_pid": 90}}
            for name, record in records.items():
                with open(os.path.join(pool, f"{name}.json"), "w") as handle:
                    json.dump(record, handle)
            for record in records.values():
                open(os.path.join(pool, f"{os.path.basename(record['session_id'])}.{record['start_nonce']}.live"), "w").close()
            table = [(70, 1, "/x/bin/acpmux __agent-host s1"), (71, 70, "claude"), (72, 71, "node"),
                     (80, 1, "/x/bin/acpmux __agent-host s2"), (90, 1, "/x/bin/acpmux __agent-host x"), (5, 1, "zsh")]
            held = os.open(os.path.join(pool, "s1.ab12.live"), os.O_RDONLY)
            try:
                fcntl.flock(held, fcntl.LOCK_EX)
                # flock locks belong to the open file: another open of it from this process is refused too.
                self.assertTrue(ib.live_lock_held(os.path.join(pool, "s1.ab12.live")))
                self.assertFalse(ib.live_lock_held(os.path.join(pool, "s2.cd34.live")))
                found = ib.pool_pids({70, 71, 72, 80, 90, 5}, table, [home, os.path.join(home, "missing")])
            finally:
                os.close(held)
        self.assertEqual(found, {70, 71, 72})

    def test_acpmux_homes_resolve_as_the_app_does(self):
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, ".acpmux", "builds", "k1"))
            os.makedirs(os.path.join(home, ".cmux", "chief", "c1", "acpmux"))
            homes = ib.acpmux_homes({"ACPMUX_HOME": "/e/acp", "CMUX_NEXT_CHIEF_HOME": "/chief"}, user_home=home)
        self.assertEqual(homes, [os.path.join(home, ".acpmux"), os.path.join(home, ".acpmux", "builds", "k1"),
                                 "/e/acp", "/chief/acpmux", os.path.join(home, ".cmux", "chief", "c1", "acpmux")])
        self.assertEqual(ib.acpmux_homes({"CMUX_NEXT_ACPMUX_ROOT": "/r"}, user_home="/nohome")[0], "/r")

    def test_table_shows_roles(self):
        kinds = ib.aggregate({"processes": [{**row("app", 30, 0.1), **r} for r in role_rows({501: "app"})]})
        text = ib.table("minimized", kinds, [("app", "role", "default", "napped")])
        self.assertIn("| roles |", text)
        self.assertTrue(text.rstrip().endswith("| **default** |"))


class EnergyTests(unittest.TestCase):
    def test_energy_sums_per_kind_and_tree(self):
        kinds = ib.aggregate({"processes": [row("cef-renderer", 10, 0.1, cpu_mw=1.25, billed_mw=1.5),
                                            row("cef-renderer", 10, 0.0, cpu_mw=0.75, billed_mw=0.5),
                                            row("app", 40, 0.5, cpu_mw=8.0, billed_mw=9.0),
                                            row("daemon", 9, 0.2, cpu_mw=0.5, billed_mw=0.5)]})
        summary = ib.energy_summary(kinds)
        self.assertEqual(summary["per_kind"], {"cef-renderer": {"cpu": 2.0, "billed": 2.0}, "app": {"cpu": 8.0, "billed": 9.0},
                                               "daemon": {"cpu": 0.5, "billed": 0.5}})
        self.assertEqual(summary["tree"], {"cpu": 10.5, "billed": 11.5})

    def test_energy_from_fixture_rusage_to_mw(self):
        """rusage words (ri_energy_nj, ri_billed_energy, ri_serviced_energy) through process_row, aggregate and
        energy_summary over a 2 s window."""
        zero = procs.usage_from_words(rusage_words(), 1, 1)
        def process(pid, cmd, energy, billed, serviced):
            last = procs.usage_from_words(rusage_words(energy=energy, billed=billed, serviced=serviced), 1, 1)
            return ib.process_row(pid, cmd, zero, last, 2.0, gpu=0.0, threads_now=4, csw=0, ran=[])
        rows = [process(1, f"{APP}/Contents/MacOS/cmux DEV", 8_000_000, 3_000_000, 1_000_000),
                process(2, f"{APP}/Contents/Frameworks/cmux Helper (Renderer).app/x --type=renderer", 2_500_000, 0, 500_000),
                process(3, f"{APP}/Contents/Frameworks/cmux Helper (Renderer).app/x --type=renderer", 1_500_000, 1_000_000, 0)]
        self.assertEqual((rows[0]["energy_mw_cpu"], rows[0]["energy_mw_billed"]), (4.0, 5.0))  # (8 + 3 - 1) mJ / 2 s
        summary = ib.energy_summary(ib.aggregate({"processes": rows}))
        self.assertEqual(summary["per_kind"], {"app": {"cpu": 4.0, "billed": 5.0},
                                               "cef-renderer": {"cpu": 2.0, "billed": 2.25}})  # 1.0 + 1.25
        self.assertEqual(summary["tree"], {"cpu": 6.0, "billed": 7.25})


class PowerAssertionTests(unittest.TestCase):
    def test_assertions_of_the_pid_set(self):
        found = procs.power_assertions({501, 777, 900}, PMSET)
        self.assertEqual([(a["pid"], a.get("created_for")) for a in found], [(501, None), (120, 777), (900, None)])
        self.assertEqual(found[0]["type"], "PreventUserIdleSystemSleep")
        self.assertEqual(found[0]["name"], "cmux keep awake")
        self.assertEqual(found[0]["process"], "cmux DEV t")
        self.assertEqual((found[0]["id"], found[0]["age"]), ("0x0000a1b200018c3d", "00:01:10"))
        self.assertNotIn("held", found[0])
        self.assertEqual(found[2]["process"], "Google Chrome Helper (Renderer)")
        self.assertEqual(procs.power_assertions({4242}, PMSET), [])

    def test_an_assertion_read_at_both_ends_is_listed_once(self):
        start = procs.power_assertions({501}, PMSET)
        end = procs.power_assertions({501}, PMSET.replace("00:01:10", "00:02:10"))
        self.assertNotEqual(start[0]["line"], end[0]["line"])  # only the age differs
        got = ib.window_assertions(start, end)
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0]["age"], "00:02:10")  # the latest read
        other = procs.power_assertions({501}, PMSET.replace("0x0000a1b200018c3d", "0x0000a1b200018c99"))
        self.assertEqual(len(ib.window_assertions(start, other)), 2)  # a new assertion with the same name counts


class SaverAndThermalTests(unittest.TestCase):
    def test_saver_state_from_debug_energy(self):
        self.assertEqual(ib.saver_state({"policy": {"isSaver": True, "reason": "setting"}}), (True, "setting"))
        self.assertEqual(ib.saver_state({"policy": {"isSaver": True}, "inputs": {"reason": "battery"}}), (True, "battery"))
        self.assertEqual(ib.saver_state({"policy": {"isSaver": False}}), (False, None))
        self.assertEqual(ib.saver_state({}), (None, None))

    def test_saver_mismatch(self):
        self.assertIsNone(ib.saver_mismatch(True, [True, True]))
        self.assertIn("asked energy saver on", ib.saver_mismatch(True, [True, False]))
        self.assertIn("asked energy saver on", ib.saver_mismatch(True, [None, None]))  # no debug.energy: not proven
        self.assertIsNone(ib.saver_mismatch(False, [False, None]))
        self.assertIn("asked energy saver off", ib.saver_mismatch(False, [False, True]))

    def test_gate_refuses_a_saver_mismatch(self):
        result = {"processes": [row("app", 40, 0.2)], "ends": ends(False, False)}
        entry = ib.summarize("energy-saver", result, {"kinds": {}})
        self.assertTrue(entry["saver"]["asked"])
        self.assertEqual(entry["saver"]["observed"], [False, False])
        self.assertIsNotNone(entry["saver"]["mismatch"])
        self.assertEqual(entry["over"], [])
        self.assertEqual(ib.exit_code(True, [], ["energy-saver"]), 1)
        self.assertEqual(ib.exit_code(False, [], ["energy-saver"]), 0)
        self.assertEqual(ib.exit_code(True, [], []), 0)
        matched = ib.summarize("energy-saver", {"processes": [], "ends": ends(True, True)}, {"kinds": {}})
        self.assertIsNone(matched["saver"]["mismatch"])
        self.assertEqual(matched["saver"]["reason"], "setting")

    def test_thermal_serious_marks_the_rows(self):
        self.assertEqual(ib.worst_thermal(["fair", "serious"]), "serious")
        self.assertEqual(ib.worst_thermal([None, "nominal"]), "nominal")
        self.assertIsNone(ib.worst_thermal([None, None]))
        hot = ib.summarize("light", {"processes": [row("app", 40, 0.2)], "ends": ends(False, False, "fair", "serious")},
                           {"kinds": {}})
        self.assertEqual(hot["thermal"], {"start": "fair", "end": "serious", "worst": "serious", "marked": True})
        self.assertTrue(hot["kinds"]["app"]["thermal_marked"])
        cool = ib.summarize("light", {"processes": [row("app", 40, 0.2)], "ends": ends(False, False, "fair", "fair")},
                            {"kinds": {}})
        self.assertFalse(cool["thermal"]["marked"])
        self.assertNotIn("thermal_marked", cool["kinds"]["app"])

    def test_report_entry_has_assertions_energy_saver_thermal(self):
        held = procs.power_assertions({501}, PMSET)
        later = procs.power_assertions({501}, PMSET.replace("00:01:10", "00:02:11"))
        result = {"processes": [row("app", 40, 0.2, cpu_mw=4.0, billed_mw=5.0), row("daemon", 9, 0.1, cpu_mw=1.0, billed_mw=1.0)],
                  "ends": ends(False, False, assertions=held, assertions_end=later)}
        entry = ib.summarize("tabs-static", result, {"kinds": {}})
        for key in ("assertions", "energy_mw", "saver", "thermal"):
            self.assertIn(key, entry)
        self.assertEqual(len(entry["assertions"]), 1)  # the same assertion at both ends is listed once
        self.assertEqual(entry["energy_mw"]["per_kind"]["app"], {"cpu": 4.0, "billed": 5.0})
        self.assertEqual(entry["energy_mw"]["tree"], {"cpu": 5.0, "billed": 6.0})
        self.assertNotIn("anim", entry)
        text = ib.table("tabs-static", entry["kinds"], [], entry)
        self.assertIn("energy 5.0 mW CPU, 6.0 mW billed (tree)", text)
        self.assertIn("1 power assertion(s)", text)

    def test_animated_page_rate(self):
        reads = ({"count": 100, "t_ms": 1000, "visibility": "visible"}, {"count": 1900, "t_ms": 61000, "visibility": "visible"})
        entry = ib.summarize("energy-saver", {"processes": [], "ends": ends(True, True, anim=reads)}, {"kinds": {}})
        self.assertEqual(entry["anim"]["raf_per_s"], 30.0)
        self.assertEqual(entry["anim"]["visibility"], ["visible", "visible"])
        self.assertEqual(ib.refusals({**entry, **SHIPPING_RAN}), [])

    def test_gate_refuses_energy_saver_without_a_raf_rate(self):
        unread = ({"error": "the page posted no rAF count in 10 s"}, {"count": 1, "t_ms": 2})
        entry = ib.summarize("energy-saver", {"processes": [], "ends": ends(True, True, anim=unread)}, {"kinds": {}})
        self.assertEqual([what for what, _ in ib.refusals({**entry, **SHIPPING_RAN})], ["anim"])
        light = ib.summarize("light", {"processes": [], "ends": ends(False, False)}, {"kinds": {}})
        self.assertEqual(ib.refusals({**light, **SHIPPING_RAN}), [])
        self.assertIn("error", ib.anim_rate({"error": "no target"}, {"count": 1, "t_ms": 2}))

    def test_window_facts_reach_the_v2_session_rows(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        fast = ({"count": 0, "t_ms": 0, "visibility": "visible"}, {"count": 3600, "t_ms": 60000, "visibility": "visible"})
        entry = ib.summarize("energy-saver", {"processes": [], "ends": ends(True, True, anim=fast)}, budget)
        self.assertEqual(ib.window_facts(entry)["page_raf_per_s"], 60.0)
        self.assertIn(["session", "page_raf_per_s", 60.0, 31], entry["over"])
        capped = ({"count": 0, "t_ms": 0, "visibility": "visible"}, {"count": 1800, "t_ms": 60000, "visibility": "visible"})
        ok = ib.summarize("energy-saver", {"processes": [], "ends": ends(True, True, anim=capped)}, budget)
        self.assertEqual(ok["over"], [])
        off = ib.summarize("energy-saver", {"processes": [], "ends": ends(False, False, anim=capped)}, budget)
        self.assertIn(["session", "saver", False, True], off["over"])
        unknown = ib.summarize("energy-saver", {"processes": [], "ends": ends(None, None, anim=capped)}, budget)
        self.assertNotIn("saver", ib.window_facts(unknown))  # no debug.energy: refused (saver mismatch), not an over
        held = procs.power_assertions({501}, PMSET)
        light = ib.summarize("light", {"processes": [], "ends": ends(False, False, assertions=held)}, budget)
        self.assertIn(["assertions", "held", 1, 0], light["over"])


def ratio_rule(of, vs, field, max_ratio, session="tabs-static"):
    return {"session": session, "of": of, "vs": vs, "field": field, "max_ratio": max_ratio}


def chrome_entry(kinds, running=True, chrome_version="1.75.0", cmux_version="1.75.0", shape=None):
    """A measured chrome-static session entry (run_chrome_static's block plus its kinds)."""
    return {"exit": 0, "kinds": kinds, "over": [],
            "chrome": {"app": CHROME, "version": "154.0.8037.58",
                       "ublock": {"cmux_version": cmux_version, "chrome_version": chrome_version, "running": running},
                       "unequal": list(shape or [])}}


# A tabs-static cmux tree with uBlock Origin's extension renderer, and a Chrome tree with its own.
CMUX_KINDS = {"app": {"n": 1, "wakeups_per_s": 10.0}, "cef-renderer": {"n": 11, "wakeups_per_s": 28.0},
              "cef-extension": {"n": 1, "wakeups_per_s": 2.0}}
CHROME_KINDS = {"browser": {"n": 1, "wakeups_per_s": 20.0}, "renderer": {"n": 16, "wakeups_per_s": 41.5},
                "extension": {"n": 1, "wakeups_per_s": 2.0}}
TREE_RULE = {"ratio_to_chrome": [ratio_rule("tree", "tree", "wakeups_per_s", 0.5)]}


class ChromeReferenceTests(unittest.TestCase):
    """The chrome-static reference (p14-energy-004): a Chromium that runs MV2, tabs-static's pages, uBlock Origin."""

    def judge(self, sessions, budget, asked=True):
        report = {"sessions": sessions}
        overs, notes, refused = ib.judge_across(report, budget, asked)
        return report, overs, notes, refused

    def test_chrome_kinds(self):
        self.assertEqual(ib.chrome_kind(f"{CHROME}/Contents/MacOS/Chromium --user-data-dir=/p/data"), "browser")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Chromium Helper (Renderer).app/Contents/MacOS/"
                                        "Chromium Helper (Renderer) --type=renderer --renderer-client-id=7"), "renderer")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Chromium Helper (Renderer).app/Contents/MacOS/"
                                        "Chromium Helper (Renderer) --type=renderer --extension-process"), "extension")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Chromium Helper (GPU).app/Contents/MacOS/"
                                        "Chromium Helper (GPU) --type=gpu-process"), "gpu")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Chromium Helper.app/Contents/MacOS/Chromium Helper "
                                        "--type=utility --utility-sub-type=network.mojom.NetworkService"), "utility")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/chrome_crashpad_handler --monitor-self"), "crashpad")
        self.assertEqual(ib.chrome_kind(f"{CHROME_HELPERS}/Chromium Helper.app/Contents/MacOS/Chromium Helper "
                                        "--type=ppapi"), "other")

    def test_forty_against_sixty_three_and_a_half_at_half_is_over(self):
        # The acceptance case: cmux's tree 40/s against Chrome's 63.5/s at max_ratio 0.5, both running uBlock Origin;
        # tabs-static measured before chrome-static, judged all the same.
        report, overs, notes, refused = self.judge(
            {"tabs-static": {"kinds": CMUX_KINDS, "over": []}, ib.CHROME_SESSION: chrome_entry(CHROME_KINDS)}, TREE_RULE)
        self.assertEqual(overs, [("tabs-static", ("tree", "wakeups_per_s/chrome:tree", 0.63, 0.5))])
        self.assertEqual((notes, refused), ([], []))
        row = report["ratio_to_chrome"][0]
        self.assertEqual((row["cmux_value"], row["chrome_value"], row["verdict"]), (40.0, 63.5, "over"))
        self.assertEqual(report["sessions"]["tabs-static"]["over"], [["tree", "wakeups_per_s/chrome:tree", 0.63, 0.5]])
        self.assertTrue(report["chrome"]["parity"]["tabs-static"]["equal"])
        self.assertEqual(report["chrome"]["kinds"], CHROME_KINDS)
        self.assertIn("**over**", ib.ratio_table(report["ratio_to_chrome"]))
        # Below the ratio: no over.
        quiet = {**CMUX_KINDS, "cef-renderer": {"n": 11, "wakeups_per_s": 19.0}}
        _, overs, _, _ = self.judge({"tabs-static": {"kinds": quiet, "over": []},
                                     ib.CHROME_SESSION: chrome_entry(CHROME_KINDS)}, TREE_RULE)
        self.assertEqual(overs, [])

    def test_the_budget_file_rows_are_judged_once(self):
        # The budget's own ratio_to_chrome rows go through one path: one over per row, not one per judge.
        budget = ib.load_budget(ib.BUDGET_FILE)
        chrome = {**CHROME_KINDS, "gpu": {"n": 1, "wakeups_per_s": 4.0}}
        cmux = {**CMUX_KINDS, "cef-gpu": {"n": 1, "wakeups_per_s": 6.0}, "cef-host": {"n": 1, "wakeups_per_s": 1.0}}
        _, overs, _, _ = self.judge({ib.CHROME_SESSION: chrome_entry(chrome), "tabs-static": {"kinds": cmux, "over": []}},
                                    budget)
        fields = [over[1] for _, over in overs]
        self.assertEqual(len(fields), len(set(fields)))
        self.assertIn("wakeups_per_s/chrome:gpu", fields)

    def test_without_ublock_in_chrome_ratios_are_unequal_not_judged_and_refused(self):
        report, overs, notes, refused = self.judge(
            {"tabs-static": {"kinds": CMUX_KINDS, "over": []},
             ib.CHROME_SESSION: chrome_entry(CHROME_KINDS, chrome_version=None, running=False)}, TREE_RULE)
        self.assertEqual(overs, [])
        row = report["ratio_to_chrome"][0]
        self.assertEqual(row["verdict"], "not judged")
        self.assertEqual(row["unequal"], ["no uBlock Origin was loaded into Chrome"])
        self.assertIn("tabs-static tree wakeups_per_s/chrome:tree: not judged: unequal: no uBlock Origin was loaded "
                      "into Chrome", notes)
        self.assertEqual(refused, ["tabs-static: no uBlock Origin was loaded into Chrome"])
        self.assertIn("unequal: no uBlock Origin was loaded into Chrome", ib.ratio_table(report["ratio_to_chrome"]))

    def test_parity_comes_from_the_measured_sessions(self):
        # uBlock Origin bundled but not run in the cmux session (built-in ad blocker off, a person's own copy
        # found): no cef-extension process, so unequal although the bundle has the folder.
        no_ext = {name: values for name, values in CMUX_KINDS.items() if name != "cef-extension"}
        report, overs, _, refused = self.judge({"tabs-static": {"kinds": no_ext, "over": []},
                                                ib.CHROME_SESSION: chrome_entry(CHROME_KINDS)}, TREE_RULE)
        self.assertEqual(overs, [])
        self.assertEqual(report["ratio_to_chrome"][0]["unequal"],
                         ["uBlock Origin 1.75.0 did not run in the cmux session (no cef-extension process)"])
        self.assertTrue(refused)
        # Chrome listed uBlock Origin's target but measured no extension renderer: not running either.
        no_chrome_ext = {name: values for name, values in CHROME_KINDS.items() if name != "extension"}
        report, _, _, _ = self.judge({"tabs-static": {"kinds": CMUX_KINDS, "over": []},
                                      ib.CHROME_SESSION: chrome_entry(no_chrome_ext)}, TREE_RULE)
        self.assertEqual(report["ratio_to_chrome"][0]["unequal"],
                         ["uBlock Origin 1.75.0 did not run in Chrome (no extension target or process)"])

    def test_ublock_parity_needs_the_same_version_running(self):
        self.assertTrue(ib.ublock_parity("1.75.0", True, "1.75.0", True)["equal"])
        self.assertEqual(ib.ublock_parity("1.75.0", True, "1.75.0", False)["unequal"],
                         ["uBlock Origin 1.75.0 did not run in Chrome (no extension target or process)"])
        self.assertEqual(ib.ublock_parity("1.75.0", True, "1.74.0", True)["unequal"],
                         ["uBlock Origin 1.74.0 in Chrome, 1.75.0 in cmux"])
        self.assertIn("the cmux app bundles no uBlock Origin", ib.ublock_parity(None, False, "1.75.0", True)["unequal"])

    def test_a_reference_that_cannot_run_mv2_is_refused(self):
        mv2 = {"manifest_version": 2, "version": "1.75.0"}
        self.assertIn("ignores --load-extension", ib.reference_refusal("com.google.Chrome", "155.0.7400.12", mv2))
        self.assertIn("ignores --load-extension", ib.reference_refusal("com.google.Chrome.canary", "137.0.1.0", mv2))
        self.assertIsNone(ib.reference_refusal("com.google.Chrome", "136.0.7103.2", mv2))
        self.assertIn("no Manifest V2", ib.reference_refusal(ib.CHROME_FOR_TESTING_ID, "154.0.8037.92", mv2))
        self.assertIsNone(ib.reference_refusal(ib.CHROME_FOR_TESTING_ID, "154.0.8037.92", {"manifest_version": 3}))
        # ungoogled-chromium (org.chromium.Chromium) may: whether uBlock Origin started is checked in the run.
        self.assertIsNone(ib.reference_refusal("org.chromium.Chromium", "154.0.8037.58", mv2))

    def test_a_failed_chrome_static_is_refused_only_when_asked(self):
        failed = {"exit": 1, "error": "RuntimeError: chrome-static: branded Google Chrome 155 ignores --load-extension"}
        _, overs, notes, refused = self.judge({"tabs-static": {"kinds": CMUX_KINDS, "over": []},
                                               ib.CHROME_SESSION: failed}, TREE_RULE)
        self.assertEqual(overs, [])
        self.assertEqual(notes, ["tabs-static tree wakeups_per_s/chrome:tree: not judged: reference session "
                                 "chrome-static not measured"])
        self.assertEqual(len(refused), 1)
        self.assertIn("branded Google Chrome 155", refused[0])
        _, _, _, refused = self.judge({"tabs-static": {"kinds": CMUX_KINDS, "over": []}}, TREE_RULE, asked=False)
        self.assertEqual(refused, [])

    def test_chrome_pages_out_of_shape_are_unequal(self):
        # tabs-static's own plan: 5 hidden WebKit and 10 hidden Chromium pages, then the shown one.
        pages = ib.IdlePages()
        try:
            keys = [key for _engine, _url, key in ib.tab_plan(pages, ib.TABS_STATIC)]
        finally:
            pages.close()
        self.assertEqual((len(keys), keys[-1]), (16, "shown"))
        good = {key: "visible" if key == "shown" else "hidden" for key in keys}
        self.assertEqual(ib.chrome_shape_unequal(16, good, keys), [])
        self.assertEqual(ib.chrome_shape_unequal(17, good, keys), ["Chrome had 17 page targets, tabs-static has 16"])
        behind = {**good, "shown": "hidden"}
        self.assertEqual(ib.chrome_shape_unequal(16, behind, keys),
                         ["Chrome's tab visibility is not 1 shown, 15 hidden: shown=hidden"])
        self.assertEqual(ib.chrome_shape_unequal(16, {}, keys[:1]),
                         ["Chrome had 16 page targets, tabs-static has 1",
                          "Chrome's tab visibility is not 1 shown, 0 hidden: w0=None"])
        reason = ib.chrome_shape_unequal(16, behind, keys)[0]
        report, overs, _, refused = self.judge({"tabs-static": {"kinds": CMUX_KINDS, "over": []},
                                                ib.CHROME_SESSION: chrome_entry(CHROME_KINDS, shape=[reason])}, TREE_RULE)
        self.assertEqual(overs, [])
        self.assertEqual(report["ratio_to_chrome"][0]["unequal"], [reason])
        self.assertEqual(refused, [f"tabs-static: {reason}"])

    def test_chrome_at_zero_counts_as_the_floor(self):
        # Chrome's GPU process at 0 wakeups and cmux's at 1 in a minute is noise: the floor (0.5/s), no over.
        budget = {"ratio_to_chrome": [ratio_rule("cef-gpu", "gpu", "wakeups_per_s", 1.0),
                                      ratio_rule("cef-host", "browser", "wakeups_per_s", 1.0)]}
        chrome = {**CHROME_KINDS, "gpu": {"n": 1, "wakeups_per_s": 0.0}}
        cmux = {**CMUX_KINDS, "cef-gpu": {"n": 1, "wakeups_per_s": 0.017}}
        report, overs, notes, _ = self.judge({"tabs-static": {"kinds": cmux, "over": []},
                                              ib.CHROME_SESSION: chrome_entry(chrome)}, budget)
        self.assertEqual(overs, [])
        gpu, host = report["ratio_to_chrome"]
        self.assertEqual((gpu["ratio"], gpu["floor"], gpu["verdict"]), (0.034, 0.5, "ok"))
        self.assertEqual(host["verdict"], "not judged")
        self.assertIn("tabs-static cef-host wakeups_per_s/chrome:browser: not judged: cmux ran no cef-host", notes)
        # cmux at 3/s against the floor is over, and the printed field says the floor was the reference.
        cmux["cef-gpu"] = {"n": 1, "wakeups_per_s": 3.0}
        _, overs, _, _ = self.judge({"tabs-static": {"kinds": cmux, "over": []},
                                     ib.CHROME_SESSION: chrome_entry(chrome)}, budget)
        self.assertEqual(overs, [("tabs-static", ("cef-gpu", "wakeups_per_s/chrome:gpu:floor", 6.0, 1.0))])
        self.assertEqual(ib.over_line("tabs-static", overs[0][1]),
                         "IDLE-BUDGET-OVER tabs-static cef-gpu wakeups_per_s/chrome:gpu:floor 6.0 > 1.0")
        # A field with no floor and a reference of 0 judges nothing (ratio_over's rule).
        self.assertEqual(ib.ratio_of(2.0, 0.0), (None, None))
        self.assertEqual(ib.ratio_over("a", "x", {"a": {"x": 2.0}}, "b", {"b": {"x": 0.0}}, 1.0, "/c"), [])

    def test_template_key_follows_the_browser_and_ublock(self):
        base = ib.template_key("/A/Chromium.app", "154.0", "/u", "1.75.0")
        self.assertEqual(base, ib.template_key("/A/Chromium.app", "154.0", "/u", "1.75.0"))
        self.assertNotEqual(base, ib.template_key("/A/Chromium.app", "155.0", "/u", "1.75.0"))
        self.assertNotEqual(base, ib.template_key("/A/Chromium.app", "154.0", "/u", "1.76.0"))
        self.assertNotEqual(base, ib.template_key("/A/Chromium.app", "154.0", None, None))

    def test_a_template_build_that_fails_leaves_no_template(self):
        class Failing:
            def launch(self, profile, url):
                Path(profile, "data").mkdir()

            def ready(self):
                raise RuntimeError("no DevTools endpoint")

            def quit(self):
                pass

        with tempfile.TemporaryDirectory() as folder:
            template = str(Path(folder, "template-k"))
            with self.assertRaises(RuntimeError):
                ib.build_template(Failing(), template, 0)
            self.assertEqual(list(Path(folder).iterdir()), [])

    def test_chrome_static_settles_as_long_as_the_tab_sessions(self):
        self.assertEqual(ib.settle_seconds(ib.CHROME_SESSION, 10), ib.FREEZE_HIDDEN_TABS_S + ib.FREEZE_GRACE_S)
        self.assertEqual(ib.settle_seconds(ib.CHROME_SESSION, 90), 90)
        self.assertEqual(ib.settle_seconds("light", 10), 10)

    def test_manifest_version(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertIsNone(ib.manifest_version(folder))
            Path(folder, "manifest.json").write_text(json.dumps({"version": "1.75.0", "manifest_version": 2}))
            self.assertEqual(ib.manifest_version(folder), "1.75.0")
            self.assertEqual(ib.read_manifest(folder)["manifest_version"], 2)

    def test_chrome_rows_count_like_cmux_rows(self):
        cmd = f"{CHROME}/Contents/MacOS/Chromium"
        start = procs.usage_from_words(rusage_words(interrupt=10, energy=1_000_000_000), 1, 1)
        end = procs.usage_from_words(rusage_words(interrupt=30, energy=3_000_000_000, billed=500_000_000), 1, 1)
        born = procs.usage_from_words(rusage_words(interrupt=4, energy=2_000_000_000), 1, 1)
        first = {7: (cmd, start, (0, 30, 0, 0, 100), {})}
        last = {7: (cmd, end, (0, 31, 0, 0, 140), {1: (2_000, "CrBrowserMain")}),
                8: (cmd, born, (0, 5, 0, 0, 2), {})}
        rows = ib.process_rows(first, last, 2.0, {7: 0}, {7: 4_000_000}, ib.chrome_kind)
        self.assertEqual([(r["pid"], r["kind"], r["energy_mw_cpu"], r["energy_mw_billed"], r["wakeups_per_s"], r["partial"])
                          for r in rows], [(7, "browser", 1000.0, 1250.0, 10.0, False), (8, "browser", 1000.0, 1000.0, 2.0, True)])
        self.assertEqual((rows[0]["gpu_ms_per_s"], rows[0]["csw_per_s"], rows[0]["threads_ran"]), (2.0, 20.0, 1))
        browser = ib.aggregate({"processes": rows})["browser"]
        self.assertEqual((browser["n"], browser["energy_mw_billed"], browser["wakeups_per_s"]), (2, 2250.0, 12.0))


class XbenchChromeSwitchTests(unittest.TestCase):
    def test_extensions_load_with_one_disable_features(self):
        import xbench
        browser = xbench.ChromiumBrowser("chrome", CHROME, None, None, extensions=["/tmp/ubo"])
        switches = browser.switches()
        self.assertIn("--load-extension=/tmp/ubo", switches)
        self.assertEqual([s for s in switches if s.startswith("--disable-features=")], ["--disable-features=ChromeWhatsNewUI"])
        plain = xbench.ChromiumBrowser("chrome", CHROME, None, None).switches()
        self.assertEqual([s for s in plain if s.startswith("--disable-features=")], ["--disable-features=ChromeWhatsNewUI"])
        self.assertFalse(any(s.startswith("--load-extension") for s in plain))



def bundle(folder, debug, ident="com.cmuxterm.app.debug.t"):
    """A `cmux DEV t.app` with an empty main executable and an Info.plist naming `ident`; `debug` adds Xcode's
    `.debug.dylib` beside the executable."""
    import plistlib
    macos = os.path.join(folder, "cmux DEV t.app", "Contents", "MacOS")
    os.makedirs(macos)
    open(os.path.join(macos, "cmux DEV"), "wb").close()
    if debug:
        open(os.path.join(macos, "cmux DEV.debug.dylib"), "wb").close()
    contents = os.path.dirname(macos)
    if ident:
        with open(os.path.join(contents, "Info.plist"), "wb") as handle:
            plistlib.dump({"CFBundleIdentifier": ident}, handle)
    return os.path.dirname(contents)


def fake_tool(folder, name, code=0, stderr=""):
    """An executable that appends its arguments (one line, tab-separated) to `<folder>/<name>.calls` and exits `code`."""
    path = os.path.join(folder, name)
    calls = path + ".calls"
    with open(path, "w") as handle:
        handle.write(f"#!/bin/sh\nprintf '%s\\t' \"$@\" >> '{calls}'\necho >> '{calls}'\n")
        if stderr:
            handle.write(f"echo '{stderr}' >&2\n")
        handle.write(f"exit {code}\n")
    os.chmod(path, 0o755)
    return path, calls


SHIPPING_KEYS = {"CMUX_NEXT_BENCH_SHIPPING_DRAW": "1", "CMUX_NEXT_DEV_SENTRY": "1", "CMUX_NEXT_DEV_HANG_REPORTS": "1",
                 "CMUX_NEXT_ISOLATED_LAUNCH": "1"}
# debug.shipping_mode of a bench-hooks launch in the shipping configuration.
MODE_SENDING = {"draws_when_occluded": False, "pages_render_when_covered": False, "sentry_should_start": True,
                "hang_reports": {"available": True, "setting": True, "decision": "send", "enabled": True}}
# The shipping fields of a session that ran the shipping configuration (no shipping refusal).
SHIPPING_RAN = {"activated": {"activated": True, "error": ""}, "sentry_started": True,
                "hang_reports": {"available": True, "setting": True, "decision": "send", "enabled": True, "on": True}}


class ShippingModeTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="idle-budget-test-")
        self.addCleanup(shutil.rmtree, self.folder, True)

    def bench_app(self, **kwargs):
        import bench_launch
        return bench_launch.BenchApp(bundle(self.folder, debug=False), out=os.path.join(self.folder, "out"),
                                     teardown=False, **kwargs)

    def test_launch_env_holds_the_keys_and_drops_no_activate(self):
        env = ib.launch_env()
        for key, value in SHIPPING_KEYS.items():
            self.assertEqual(env[key], value)
        self.assertIn("CMUX_NEXT_NO_ACTIVATE", env)
        self.assertIsNone(env["CMUX_NEXT_NO_ACTIVATE"])  # None removes BASE_ENV's value
        self.assertNotIn("CMUX_NEXT_BENCH_SHIPPING_DRAW", ib.launch_env(shipping_draw=False))
        self.assertEqual(ib.launch_env(shipping_draw=False)["CMUX_NEXT_ISOLATED_LAUNCH"], "1")

    def test_the_app_is_started_isolated_at_the_fixed_window_frame(self):
        """No CMUX_NEXT_NO_ACTIVATE, so the app may activate; CMUX_NEXT_ISOLATED_LAUNCH keeps TestWindowPlacement
        (the same frame on every host) and the other isolation guards (LaunchIsolation.isolated)."""
        env = self.bench_app(env=ib.launch_env()).environment()
        for key, value in SHIPPING_KEYS.items():
            self.assertEqual(env.get(key), value)
        self.assertNotIn("CMUX_NEXT_NO_ACTIVATE", env)
        self.assertEqual(env["CMUX_NEXT_SOCKET_MODE"], "automation")  # the bench still reaches the socket
        self.assertEqual(env["CMUX_NEXT_TEST_WINDOW_FRAME"], "40,40,1440,900")
        self.assertEqual(env["CMUX_NEXT_TEST_WINDOW_SCREEN"], "0")

    def test_every_session_asks_for_hang_reports(self):
        for session in ib.SESSIONS:
            self.assertEqual(ib.session_config(session)["diagnostics"], {"hangReports": True}, session)

    def test_activate_refuses_a_no_activate_launch(self):
        app = self.bench_app()
        app.process = types.SimpleNamespace(poll=lambda: None)
        app.launched_env = app.environment()
        result = app.activate()
        self.assertFalse(result["activated"])
        self.assertIn("CMUX_NEXT_NO_ACTIVATE=1", result["error"])

    def launched(self, replies):
        """A shipping-mode BenchApp that 'runs', whose debug.window_list answers `replies` in turn (the last one
        repeats)."""
        app = self.bench_app(env=ib.launch_env())
        app.process = types.SimpleNamespace(poll=lambda: None)
        app.launched_env = app.environment()
        calls = []

        def rpc(method, params=None, timeout=60):
            calls.append(method)
            return replies[min(len(calls), len(replies)) - 1]
        app.rpc = rpc
        return app, calls

    def test_activate_sees_a_key_window(self):
        osascript, osascript_calls = fake_tool(self.folder, "osascript")
        app, calls = self.launched([{"windows": [{"key": False}]}, {"windows": [{"key": False}, {"key": True}]}])
        with unittest.mock.patch.dict(os.environ, {"BENCH_LAUNCH_OSASCRIPT": osascript}):
            result = app.activate(timeout=5)
        self.assertEqual(result, {"activated": True, "error": ""})
        self.assertEqual(calls, ["debug.window_list", "debug.window_list"])
        with open(osascript_calls) as handle:
            self.assertIn('tell application id "com.cmuxterm.app.debug.t" to activate', handle.read())

    def test_activate_reports_osascript_failure(self):
        osascript, _ = fake_tool(self.folder, "osascript", code=1, stderr="execution error: not allowed")
        app, calls = self.launched([{"windows": [{"key": True}]}])
        with unittest.mock.patch.dict(os.environ, {"BENCH_LAUNCH_OSASCRIPT": osascript}):
            result = app.activate(timeout=5)
        self.assertFalse(result["activated"])
        self.assertIn("osascript exit 1", result["error"])
        self.assertIn("not allowed", result["error"])
        self.assertEqual(calls, [])  # no window poll after a failed activate

    def test_activate_times_out_without_a_key_window(self):
        osascript, _ = fake_tool(self.folder, "osascript")
        app, calls = self.launched([{"windows": [{"key": False}]}])
        with unittest.mock.patch.dict(os.environ, {"BENCH_LAUNCH_OSASCRIPT": osascript}):
            result = app.activate(timeout=0.3)
        self.assertFalse(result["activated"])
        self.assertIn("no window of the app is key 0.3 s after activate", result["error"])
        self.assertGreaterEqual(len(calls), 2)

    def test_hang_report_consent_is_written_into_the_tag_domain_only(self):
        import bench_launch
        defaults, defaults_calls = fake_tool(self.folder, "defaults")
        with unittest.mock.patch.dict(os.environ, {"BENCH_LAUNCH_DEFAULTS": defaults}):
            app = bundle(self.folder, debug=False)
            self.assertEqual(bench_launch.seed_hang_report_consent(app, now=0), "")
            with open(defaults_calls) as handle:
                self.assertEqual(handle.read().split("\t")[:5], ["write", "com.cmuxterm.app.debug.t",
                                                                 "cmux.next.hangReports.consentedAt", "-date",
                                                                 "1970-01-01 00:00:00 +0000"])
            shutil.rmtree(app)
            user = bundle(self.folder, debug=False, ident="com.cmuxterm.app")
            self.assertIn("not a tagged DEV bundle id", bench_launch.seed_hang_report_consent(user))
        failing, _ = fake_tool(self.folder, "defaults-fails", code=1, stderr="Could not write domain")
        with unittest.mock.patch.dict(os.environ, {"BENCH_LAUNCH_DEFAULTS": failing}):
            shutil.rmtree(user)
            self.assertIn("defaults exit 1", bench_launch.seed_hang_report_consent(bundle(self.folder, debug=False)))

    def test_build_config_reads_the_binary_bench_app_launches(self):
        import bench_launch
        app = bundle(self.folder, debug=False)
        self.assertEqual(bench_launch.main_binary(app), self.bench_app_at(app).binary)
        self.assertEqual(ib.bundle_build_config(app), "release")

    def bench_app_at(self, app):
        import bench_launch
        return bench_launch.BenchApp(app, out=os.path.join(self.folder, "out"), teardown=False)

    def test_gate_on_a_debug_bundle_exits_non_zero_with_the_reason(self):
        app = bundle(self.folder, debug=True)
        self.assertEqual(ib.bundle_build_config(app), "debug")
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as raised:
            ib.main(["--app", app, "--gate", "--out", os.path.join(self.folder, "out")])
        self.assertNotEqual(raised.exception.code, 0)
        self.assertIn("IDLE-BUDGET-REFUSED build_config=debug", out.getvalue())
        self.assertIn("refuses a Debug build", out.getvalue())
        self.assertFalse(os.path.exists(os.path.join(self.folder, "out")))  # refused before any launch or output

    def test_shipping_draw_off_is_refused_where_it_changes_nothing(self):
        """Only a Debug automation launch draws occluded windows: on a Release or bench-hooks build `--shipping-draw
        off` would measure the same draw twice."""
        app = bundle(self.folder, debug=False)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as raised:
            ib.main(["--app", app, "--shipping-draw", "off", "--out", os.path.join(self.folder, "out")])
        self.assertEqual(raised.exception.code, 2)
        self.assertIn("--shipping-draw off has no effect on a release build", out.getvalue())
        self.assertIsNotNone(ib.gate_refusal("bench-hooks", False, "off"))
        self.assertIsNone(ib.gate_refusal("debug", False, "off"))

    def test_gate_accepts_release_and_bench_hooks_and_no_gate_accepts_debug(self):
        self.assertIsNone(ib.gate_refusal("release", True))
        self.assertIsNone(ib.gate_refusal("bench-hooks", True))
        self.assertIsNone(ib.gate_refusal("debug", False))

    def test_the_five_fields_come_from_the_app(self):
        import bench_launch
        env = {**bench_launch.BASE_ENV, **{k: v for k, v in ib.launch_env().items() if v is not None}}
        env.pop("CMUX_NEXT_NO_ACTIVATE", None)
        fields = ib.shipping_fields("bench-hooks", env, ["main", "SentryCrash Exception Handler (Primary)"],
                                    MODE_SENDING, {"activated": True, "error": ""})
        self.assertEqual(tuple(fields), ib.SHIPPING_FIELDS)
        self.assertEqual(set(ib.SHIPPING_FIELDS),
                         {"build_config", "sentry_started", "hang_reports", "draws_when_occluded", "activated"})
        self.assertEqual(fields["build_config"], "bench-hooks")
        self.assertTrue(fields["sentry_started"])
        self.assertEqual(fields["hang_reports"],
                         {"available": True, "setting": True, "decision": "send", "enabled": True, "on": True})
        self.assertEqual(fields["draws_when_occluded"], {"windows": False, "pages": False, "predicted": False})
        self.assertTrue(fields["activated"]["activated"])
        self.assertIsNone(ib.draw_mismatch(fields))
        self.assertEqual(ib.shipping_refusals(fields), [])

    def test_an_app_that_did_not_answer_records_unknown_and_hang_reports_off(self):
        quiet = ib.shipping_fields("debug", {}, ["main"], {}, {"activated": False, "error": "x"})
        self.assertFalse(quiet["sentry_started"])
        self.assertEqual(quiet["hang_reports"],
                         {"available": None, "setting": None, "decision": None, "enabled": None, "on": False})
        self.assertEqual(quiet["draws_when_occluded"], {"windows": None, "pages": None, "predicted": False})
        self.assertIsNone(ib.draw_mismatch(quiet))

    def test_the_app_answer_wins_and_a_mismatch_is_named(self):
        automation = {"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation"}
        fields = ib.shipping_fields("debug", automation, [], {**MODE_SENDING, "pages_render_when_covered": False},
                                    {"activated": True, "error": ""})
        self.assertEqual(fields["draws_when_occluded"], {"windows": False, "pages": False, "predicted": True})
        self.assertIn("the launch env predicts True", ib.draw_mismatch(fields))

    def test_predicted_draw_follows_window_draw_policy(self):
        automation = {"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation"}
        self.assertTrue(ib.predicted_draws_when_occluded("debug", automation))
        self.assertFalse(ib.predicted_draws_when_occluded("debug", {**automation, "CMUX_NEXT_BENCH_SHIPPING_DRAW": "1"}))
        self.assertFalse(ib.predicted_draws_when_occluded("bench-hooks", automation))
        self.assertFalse(ib.predicted_draws_when_occluded("release", automation))
        self.assertFalse(ib.predicted_draws_when_occluded("debug", {}))

    def test_gate_refuses_a_session_not_activated(self):
        entry = {**SHIPPING_RAN, "activated": {"activated": False, "error": "no window of the app is key 10 s after activate"}}
        self.assertEqual(ib.shipping_refusals(entry),
                         [("activated", "the app was not activated: no window of the app is key 10 s after activate")])

    def test_gate_refuses_a_session_without_sentry(self):
        self.assertEqual([what for what, _ in ib.shipping_refusals({**SHIPPING_RAN, "sentry_started": False})],
                         ["sentry"])

    def test_gate_refuses_a_session_without_hang_reports(self):
        for hang in ({"available": True, "setting": True, "decision": "confirm", "enabled": False, "on": False},
                     {"available": False, "setting": True, "decision": None, "enabled": False, "on": False},
                     {"available": True, "setting": False, "decision": "invite", "enabled": False, "on": False}):
            reasons = ib.shipping_refusals({**SHIPPING_RAN, "hang_reports": hang})
            self.assertEqual([what for what, _ in reasons], ["hang_reports"], hang)
            self.assertIn(json.dumps(hang["decision"]), reasons[0][1])

    def test_gate_refuses_a_session_with_no_shipping_record(self):
        self.assertEqual([what for what, _ in ib.refusals({"saver": {"mismatch": None}})],
                         ["activated", "sentry", "hang_reports"])


typing_spec = importlib.util.spec_from_file_location("bench_typing", HERE / "bench-typing.py")
bt = importlib.util.module_from_spec(typing_spec)
typing_spec.loader.exec_module(bt)


def frames_path(wheels, moved, *runs, after=None):
    """The scroll page's post of `runs` (lists of rAF times), with after-frame times 2 ms after each by default."""
    def enc(lists):
        return ";".join(",".join(f"{t:.2f}" for t in times) for times in lists) or "-"
    after = [[t + 2 for t in times] for times in runs] if after is None else after
    return ib.SCROLL_FRAMES_PATH + f"/{wheels}/{moved}/{enc(runs)}/{enc(after)}"


def gesture(events=240, px=24.0, **counts):
    """One gesture's counts as ScrollRun.gesture returns them, sent on time."""
    return {"events": events, "failed": 0, "late": 0, "max_late_ms": 0, "max_gap_ms": 8.4,
            "delta_px": (events - 1) * px, **counts}


def steady(count, start=0.0):
    return [round(start + i * 1000 / 120, 2) for i in range(count)]


class D8BenchTests(unittest.TestCase):
    """bench-typing.py's Chromium composer typing and page scroll, saver on and off (p14-energy-135)."""

    def test_saver_launch_turns_the_feature_on_in_both_states(self):
        self.assertEqual(ib.saver_launch(True), ({"energy": {"saver": "always"}}, {"CMUX_ENABLE_FEATURES": "energySaver"}))
        self.assertEqual(ib.saver_launch(False), ({"energy": {"saver": "off"}}, {"CMUX_ENABLE_FEATURES": "energySaver"}))

    def test_the_energy_saver_session_launches_with_the_feature_on(self):
        base = {"CMUX_NEXT_ISOLATED_LAUNCH": "1"}
        self.assertEqual(ib.session_env("energy-saver", base), {**base, "CMUX_ENABLE_FEATURES": "energySaver"})
        for session in ib.SESSIONS:
            if session != "energy-saver":
                self.assertEqual(ib.session_env(session, base), base, session)

    def test_dry_run_prints_both_surfaces_with_the_saver_on_and_off(self):
        out = io.StringIO()
        with tempfile.TemporaryDirectory() as folder, contextlib.redirect_stdout(out):
            code = bt.main(["--app", APP, "--surface", "agent-composer-chromium,chromium-page-scroll",
                            "--energy-saver", "off,on", "--dry-run", "--out", folder])
        self.assertEqual(code, 0)
        rows = [json.loads(line.removeprefix("BENCH-TYPING-PLAN ")) for line in out.getvalue().splitlines()]
        self.assertEqual([(r["surface"], r["energy_saver"]) for r in rows],
                         [("agent-composer-chromium", "off"), ("agent-composer-chromium", "on"),
                          ("chromium-page-scroll", "off"), ("chromium-page-scroll", "on")])
        for row in rows:
            self.assertEqual(row["config"]["browser"], {"defaultEngine": "chromium"})
            self.assertEqual(row["config"]["energy"], {"saver": "always" if row["energy_saver"] == "on" else "off"})
            self.assertEqual(row["env"]["CMUX_ENABLE_FEATURES"], "energySaver")
            self.assertEqual(row["env"].get("CMUX_NEXT_AGENT_PANE_MOCK"), "1" if row["surface"] == "agent-composer-chromium" else None)
            self.assertTrue(row["out"].endswith(f"{row['surface']}-saver-{row['energy_saver']}"))
            # Each printed command is one launch of that combination.
            again = bt.parse_args(bt.shlex.split(row["command"])[2:])
            self.assertEqual((again.surfaces, again.savers, again.out), ([row["surface"]], [row["energy_saver"]], row["out"]))
            self.assertTrue(again.launched)

    def test_a_single_run_with_no_saver_asks_nothing(self):
        args = bt.parse_args(["--tag", "t"])
        self.assertEqual((args.surface, args.energy_saver), ("terminal", None))
        self.assertEqual(bt.launch_config("terminal", None), ({"appearance": {"backgroundOpacity": 1}}, {}))
        self.assertIsNone(bt.saver_block(None, [], None))

    def test_options_that_do_not_fit_the_surface_are_refused(self):
        for argv in (["--tag", "t", "--surface", "agent-composer-chromium", "--flood", "2"],
                     ["--tag", "t", "--surface", "chromium-page-scroll", "--stress"],
                     ["--tag", "t", "--energy-saver", "maybe"],
                     ["--tag", "t", "--surface", "chromium-page-scroll", "--scroll-seconds", "0"],
                     ["--csv", "x.csv", "--analyze-only", "--energy-saver", "on"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                bt.parse_args(argv)

    def test_composer_fixture_parses_into_p50_and_p95(self):
        stats = {"keys": 118, "to_frame": {"p50_ms": 7.1, "p95_ms": 9.4, "max_ms": 15.2},
                 "to_paint": {"p50_ms": 8.0, "p95_ms": 10.9, "max_ms": 17.0}}
        got = bt.composer_result(stats, sent=120, failed=1)
        self.assertEqual(got["key_to_frame_ms"], {"n": 118, "p50": 7.1, "p95": 9.4, "max": 15.2})
        self.assertEqual(got["key_to_paint_ms"]["p95"], 10.9)
        self.assertEqual((got["timed"], got["untimed"], got["failed_keys"]), (118, 1, 1))
        self.assertNotIn("error", got)
        empty = bt.composer_result({"keys": 0, "to_frame": {"p50_ms": 0, "p95_ms": 0, "max_ms": 0}}, sent=120)
        self.assertIsNone(empty["key_to_frame_ms"])
        self.assertIn("error", bt.composer_result({"error": "no agent pane"}, sent=120))

    def test_composer_series_records_every_key(self):
        raw = {"keys": 3, "samples": [{"to_frame_ms": 6.1, "to_paint_ms": 7.0}, {"to_frame_ms": 7.2, "to_paint_ms": 8.1},
                                      {"to_frame_ms": 8.3, "to_paint_ms": 9.2}]}
        self.assertEqual(bt.composer_series(raw), {"key_to_frame_ms": [6.1, 7.2, 8.3], "key_to_paint_ms": [7.0, 8.1, 9.2]})
        self.assertEqual(bt.composer_series({"keys": 3}), {"key_to_frame_ms": [], "key_to_paint_ms": []})
        self.assertEqual(bt.composer_series(None), {"key_to_frame_ms": [], "key_to_paint_ms": []})

    def test_scroll_fixture_counts_dropped_frames_at_120_hz(self):
        period = 1000 / 120
        # One frame late by two refreshes: two dropped.
        janky = steady(100) + [round((i + 2) * period, 2) for i in range(100, 239)]
        reads = [ib.parse_scroll_frames(frames_path(240, 5736, steady(240))),
                 ib.parse_scroll_frames(frames_path(239, 5712, janky))]
        got = bt.scroll_result(reads, 120.0, gestures=[gesture(), gesture()])
        self.assertEqual([s["dropped_frames"] for s in got["scrolls"]], [0, 2])
        self.assertEqual(got["dropped_frames"], 2)
        self.assertEqual(got["frames"], 479)
        self.assertEqual((got["wheels_sent"], got["wheels_received"], got["scrolled_px"]), (480, 479, 11448))
        self.assertAlmostEqual(got["frame_interval_ms"]["p50"], period, delta=0.02)
        self.assertAlmostEqual(got["frame_interval_ms"]["max"], 3 * period, delta=0.02)
        self.assertAlmostEqual(got["after_frame_interval_ms"]["p50"], period, delta=0.02)
        self.assertAlmostEqual(got["fps"], 119.2, delta=0.5)
        self.assertEqual(got["nominal_ms"], 8.333)
        self.assertNotIn("error", got)
        # The same frames judged at 60 Hz drop nothing: the refresh rate sets what a drop is.
        self.assertEqual(bt.frame_drops([period * 2] * 10, 1000 / 60), 0)

    def test_a_pause_in_the_input_is_no_dropped_frame(self):
        # The page stopped its loop after the quiet time and started a new run at the next wheel event, 100 ms later:
        # the gap between the runs is no interval, so no frame dropped (one record of both runs counted 11).
        first = steady(120)
        second = steady(120, start=first[-1] + 100)
        got = bt.scroll_result([ib.parse_scroll_frames(frames_path(240, 5736, first, second))], 120.0,
                               gestures=[gesture()])
        self.assertEqual(got["scrolls"][0]["runs"], 2)
        self.assertEqual(got["dropped_frames"], 0)
        self.assertEqual(len(got["intervals_ms"]), 238)
        self.assertAlmostEqual(got["fps"], 120.0, delta=0.5)
        self.assertNotIn("error", got)
        self.assertEqual(bt.frame_drops(bt.run_intervals([first + second]), 1000 / 120), 11)
        self.assertEqual(bt.run_intervals([[0, 8, 16], [116, 124]]), [8, 8, 8])

    def test_a_scroll_the_bench_did_not_drive_steadily_is_an_error(self):
        moved = ib.parse_scroll_frames(frames_path(240, 5736, steady(240)))
        cases = {
            "wheel events failed": (moved, gesture(failed=3)),
            "ms apart: the input paused": (moved, gesture(max_gap_ms=104.0, late=1, max_late_ms=96.0)),
            "received 12 of 240": (ib.parse_scroll_frames(frames_path(12, 288, steady(12))), gesture()),
            "did not move": (ib.parse_scroll_frames(frames_path(240, 0, steady(240))), gesture()),
            "moved 900 px of 5736": (ib.parse_scroll_frames(frames_path(240, 900, steady(240))), gesture()),
        }
        for reason, (read, sent) in cases.items():
            got = bt.scroll_result([read], 120.0, gestures=[sent])
            self.assertIn(reason, got.get("error", ""), reason)
            self.assertIn("scroll 1: ", got["error"])
        # A late send inside the quiet time keeps the run whole: no refusal.
        on_time = gesture(late=4, max_late_ms=6.0, max_gap_ms=14.3)
        self.assertNotIn("error", bt.scroll_result([moved], 120.0, gestures=[on_time]))

    def test_a_scroll_with_no_frames_or_no_read_is_an_error(self):
        none = bt.scroll_result([ib.parse_scroll_frames(frames_path(0, 0))], 120.0)
        self.assertIn("did not move", none["error"])
        self.assertIsNone(none["dropped_frames"])
        self.assertIn("no wheel event reached it", bt.scroll_result([], 120.0)["error"])
        unread = bt.scroll_result([{"error": "the page posted no scroll frames in 10 s"}], 120.0)
        self.assertIn("posted no scroll frames", unread["error"])
        self.assertIn("error", ib.parse_scroll_frames(ib.SCROLL_FRAMES_PATH + "/x/0/-/-"))
        self.assertIn("error", ib.parse_scroll_frames(ib.SCROLL_FRAMES_PATH + "/3/0/0,8.33"))

    def test_the_scroll_page_records_runs_only_while_input_is_active(self):
        import urllib.request
        with ib.IdlePages() as pages:
            page = urllib.request.urlopen(pages.origin + ib.SCROLL_PATH, timeout=5).read().decode()
        self.assertIn("addEventListener('wheel'", page)
        self.assertIn("{passive:true}", page)
        self.assertIn(f"performance.now()-last>{ib.SCROLL_QUIET_MS}", page)
        self.assertIn("runs.push(run)", page)  # a loop that starts again starts a new run
        self.assertIn("new MessageChannel()", page)  # the after-frame time
        self.assertIn("scrollTo(0,0)", page)  # every gesture has the page's height to scroll
        self.assertIn(f"i<{ib.SCROLL_ROWS}", page)
        for path in (ib.SCROLL_READ_PATH, ib.SCROLL_FRAMES_PATH, "/loaded/scroll"):
            self.assertIn(path, page)
        self.assertNotIn("setInterval", page)

    def test_a_gesture_that_scrolls_past_the_page_is_refused(self):
        events = bt.gesture_events(2.0, 120.0)
        self.assertEqual(events, 240)
        self.assertLessEqual(events * 24.0, ib.SCROLL_PAGE_PX - bt.WINDOW[3])
        self.assertGreater(bt.gesture_events(2.0, 240.0) * 100.0, ib.SCROLL_PAGE_PX - bt.WINDOW[3])

    def test_a_gesture_moves_the_pointer_only_on_its_first_event(self):
        sent = []

        class App:
            def rpc(self, method, params, timeout):
                sent.append(params)
                return {"delivered_to": "RenderWidgetHostViewCocoa"}
        run = bt.ScrollRun.__new__(bt.ScrollRun)
        run.app, run.args = App(), types.SimpleNamespace(scroll_seconds=0.05, scroll_px=24.0)
        got = run.gesture(120.0)
        self.assertEqual([p["phase"] for p in sent], ["began"] + ["changed"] * 4 + ["ended"])
        self.assertNotIn("hover", sent[0])
        self.assertTrue(all(p["hover"] is False for p in sent[1:]))
        self.assertEqual((got["events"], got["failed"], got["delta_px"]), (6, 0, 120.0))
        self.assertLess(got["max_gap_ms"], 60)

    def test_read_scroll_answers_the_held_read_and_returns_the_posted_frames(self):
        import threading
        import urllib.request
        with ib.IdlePages() as pages:
            def page():
                urllib.request.urlopen(pages.origin + ib.SCROLL_READ_PATH, timeout=10).read()
                urllib.request.urlopen(urllib.request.Request(
                    pages.origin + frames_path(3, 72, [0, 8.33], [120, 128.33]), method="POST"), timeout=5).read()
            held = threading.Thread(target=page)
            held.start()
            got = pages.read_scroll(5)
            held.join(5)
            self.assertEqual(got, {"wheels": 3, "scrolled_px": 72, "runs_ms": [[0.0, 8.33], [120.0, 128.33]],
                                   "post_runs_ms": [[2.0, 10.33], [122.0, 130.33]]})
            self.assertIn("posted no scroll frames", pages.read_scroll(0.2)["error"])
            self.assertIn("error", pages.read_anim(0.2))  # the two read paths are apart

    def test_d8_verdicts(self):
        def typed(p95, mismatch=None, timed=120, failed=0):
            return {"sent": 120, "timed": timed, "failed_keys": failed, "saver": {"mismatch": mismatch},
                    "key_to_frame_ms": {"n": timed, "p50": 6.0, "p95": p95, "max": 12.0}}

        def terminal(p95, n=120, failed=0):
            return {"phases": {"single": {"keys": 120, "failed_keys": failed,
                                          "stats": {"key_to_frame_ms": {"n": n, "p95": p95}}}}}

        def scrolled(dropped, fps=119.6, hz=120.0, source=bt.HZ_FROM_DISPLAY):
            return {"dropped_frames": dropped, "fps": fps, "hz": hz, "hz_source": source}
        verdicts = bt.d8_verdicts({
            ("agent-composer-chromium", "off"): typed(9.0), ("agent-composer-chromium", "on"): typed(9.4),
            ("chromium-page-scroll", "off"): scrolled(0), ("chromium-page-scroll", "on"): scrolled(3),
            ("terminal", "off"): terminal(4.0), ("terminal", "on"): terminal(4.6)})
        self.assertEqual(verdicts["agent-composer-chromium"]["verdict"], "pass")
        self.assertEqual(verdicts["agent-composer-chromium"]["delta_ms"], 0.4)
        self.assertEqual(verdicts["chromium-page-scroll"]["verdict"], "fail")
        self.assertEqual(verdicts["terminal"]["verdict"], "fail")

        def scroll(on):
            return bt.d8_verdicts({("chromium-page-scroll", "off"): scrolled(0),
                                   ("chromium-page-scroll", "on"): on})["chromium-page-scroll"]
        self.assertEqual(scroll(scrolled(0))["verdict"], "pass")
        self.assertEqual(scroll(scrolled(0, fps=100.0))["verdict"], "fail")  # no drop counted, but not 120 Hz
        for unscored, reason in ((scrolled(0, hz=60.0, source=bt.HZ_FROM_FLAG), "60 Hz"),
                                 (scrolled(0, source=bt.HZ_ASSUMED), "assumed"),
                                 ({**scrolled(0), "error": "scroll 1: two wheel events were sent 104 ms apart"},
                                  "104 ms apart")):
            got = scroll(unscored)
            self.assertEqual(got["verdict"], "unscored", reason)
            self.assertTrue(any(reason in why for why in got["why"]), got["why"])

        def composer(on):
            return bt.d8_verdicts({("agent-composer-chromium", "off"): typed(9.0),
                                   ("agent-composer-chromium", "on"): on})["agent-composer-chromium"]
        refused = composer(typed(9.0, "asked energy saver on, debug.energy reported [False, False]"))
        self.assertEqual(refused["verdict"], "unscored")
        self.assertIn("saver on: asked energy saver on", refused["why"][0])
        self.assertIn("40 of 120 keys timed", composer(typed(9.0, timed=40))["why"][0])
        self.assertIn("2 keys failed", composer(typed(9.0, timed=118, failed=2))["why"][0])
        short = bt.d8_verdicts({("terminal", "off"): terminal(4.0), ("terminal", "on"): terminal(4.1, n=60)})
        self.assertEqual(short["terminal"]["verdict"], "unscored")
        self.assertIn("60 of 120 keys timed", short["terminal"]["why"][0])
        failed = bt.d8_verdicts({("chromium-page-scroll", "off"): {"error": "launch failed"},
                                 ("chromium-page-scroll", "on"): scrolled(0)})
        self.assertEqual(failed["chromium-page-scroll"]["verdict"], "unscored")
        self.assertEqual(bt.d8_verdicts({("chromium-page-scroll", "on"): scrolled(0)}), {})

    def test_saver_block_needs_both_ends_to_show_the_asked_state(self):
        self.assertIsNone(bt.saver_block("on", [True, True], "setting")["mismatch"])
        self.assertIn("asked energy saver on", bt.saver_block("on", [True, None], None)["mismatch"])
        self.assertIn("asked energy saver on", bt.saver_block("on", [], None)["mismatch"])
        self.assertIn("asked energy saver off", bt.saver_block("off", [False, True], "setting")["mismatch"])
        self.assertIsNone(bt.saver_block("off", [False, False], None)["mismatch"])


# ---------------------------------------------------------------------------------------------------------
# D15: disk, network, log and WindowServer (task p14-energy-105)

# `nettop -x -n -d -L 3 -s 1`: sample 0 (totals so far) and two window samples. The app has a TLS flow and a
# listening socket; the daemon only a loopback flow; mDNSResponder is not in the set.
NETTOP = """time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
12:00:00.000000,cmux DEV t.501,,,90000,80000,0,0,0,,,,,,,,,,,,
12:00:00.000000,tcp4 192.168.1.20:50001<->17.253.4.125:443,en0,Established,90000,80000,0,0,0,20.0 ms,131072,131072,BE,-,cubic,,,,,,
12:00:00.000000,cmux-tui.502,,,5000,5000,0,0,0,,,,,,,,,,,,
12:00:00.000000,tcp4 127.0.0.1:50002<->127.0.0.1:9222,lo0,Established,5000,5000,0,0,0,,,,,,,,,,,,
time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
12:00:01.000000,cmux DEV t.501,,,120,80,0,0,0,,,,,,,,,,,,
12:00:01.000000,tcp4 192.168.1.20:50001<->17.253.4.125:443,en0,Established,120,80,0,0,0,20.0 ms,131072,131072,BE,-,cubic,,,,,,
12:00:01.000000,tcp4 *:7000<->*:*,lo0,Listen,0,0,0,0,0,,,,,,,,,,,,
12:00:01.000000,cmux-tui.502,,,0,0,0,0,0,,,,,,,,,,,,
12:00:01.000000,tcp4 127.0.0.1:50002<->127.0.0.1:9222,lo0,Established,0,0,0,0,0,,,,,,,,,,,,
12:00:01.000000,mDNSResponder.300,,,64,64,0,0,0,,,,,,,,,,,,
time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
12:00:02.000000,cmux DEV t.501,,,0,0,0,0,0,,,,,,,,,,,,
12:00:02.000000,tcp4 192.168.1.20:50001<->17.253.4.125:443,en0,Established,0,0,0,0,0,20.0 ms,131072,131072,BE,-,cubic,,,,,,
12:00:02.000000,tcp4 *:7000<->*:*,lo0,Listen,0,0,0,0,0,,,,,,,,,,,,
12:00:02.000000,cmux-tui.502,,,0,0,0,0,0,,,,,,,,,,,,
12:00:02.000000,tcp4 127.0.0.1:50002<->127.0.0.1:9222,lo0,Established,0,0,0,0,0,,,,,,,,,,,,
"""

# `log show --style ndjson --info --debug`: two app lines in the window (one subsystem, one with none), one daemon
# line, one app line before the window, a line of a pid outside the set and log's closing summary object.
LOG = "\n".join(json.dumps(event) for event in [
    {"timestamp": "2026-10-25 12:00:00.500000+0000", "processID": 501, "subsystem": "com.cmuxterm.next", "category": "pump",
     "eventMessage": "tick"},
    {"timestamp": "2026-10-25 12:00:01.250000+0000", "processID": 501, "subsystem": "com.cmuxterm.next", "category": "pump",
     "eventMessage": "tick"},
    {"timestamp": "2026-10-25 12:00:01.500000+0000", "processID": 501, "subsystem": "", "category": "",
     "senderImagePath": "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", "eventMessage": "x"},
    {"timestamp": "2026-10-25 12:00:01.700000+0000", "processID": 502, "subsystem": "", "category": "",
     "senderImagePath": "/x/cmux-tui", "eventMessage": "y"},
    {"timestamp": "2026-10-25 12:00:01.800000+0000", "processID": 999, "subsystem": "com.apple.x", "category": "y"},
]) + "\n{\"count\":5,\"finished\":1}\n"
WINDOW_START = procs.datetime.datetime(2026, 10, 25, 12, 0, 1, tzinfo=procs.datetime.timezone.utc).timestamp()
WINDOW_END = WINDOW_START + 2
# nettop's `time` is the local time of day: the window around NETTOP's two delta samples (12:00:01, 12:00:02).
NETTOP_HEADER = NETTOP.split("\n", 1)[0] + "\n"
NET_START = procs.datetime.datetime(2026, 10, 25, 12, 0, 0, 500000).timestamp()
NET_END = procs.datetime.datetime(2026, 10, 25, 12, 0, 2, 200000).timestamp()

TOP = """Processes: 512 total, 3 running, 509 sleeping, 2401 threads
PID    IDLEW
157    48211+
"""

D15_PROCESSES = {501: f"{APP}/Contents/MacOS/cmux DEV", 502: f"{APP}/Contents/Resources/bin/cmux-tui server --socket s"}


def d15_snapshots(app_disk=0):
    """Two snapshots (procs.Usage, overhead (disk, threads, mach, syscalls, csw), threads) of the app and the daemon,
    the app writing `app_disk` bytes in between."""
    usage = procs.usage_from_words(rusage_words(), 1, 1)
    first = {pid: (cmd, usage, (1_000_000, 10, 0, 0, 0), {}) for pid, cmd in D15_PROCESSES.items()}
    last = {pid: (cmd, usage, (1_000_000 + (app_disk if pid == 501 else 0), 10, 0, 0, 0), {})
            for pid, cmd in D15_PROCESSES.items()}
    return first, last


class D15ParserTests(unittest.TestCase):
    def test_nettop_counts_the_window_samples_per_pid(self):
        net = procs.parse_nettop(NETTOP)
        self.assertEqual(net[501]["bytes"], 200)
        self.assertEqual(net[501]["connections"], 1)
        self.assertEqual(net[501]["remotes"], ["tcp4 17.253.4.125:443"])
        self.assertEqual(net[502], {"bytes": 0, "loopback_bytes": 0, "connections": 1, "remotes": ["tcp4 127.0.0.1:9222"],
                                    "remote_bytes": {}})
        self.assertEqual(procs.parse_nettop(NETTOP, NET_START, NET_END), net)  # the window covers both samples
        self.assertEqual(net[300]["bytes"], 128)

    def test_nettop_counts_loopback_bytes_and_skips_the_totals_sample(self):
        text = NETTOP.replace("12:00:01.000000,cmux-tui.502,,,0,0", "12:00:01.000000,cmux-tui.502,,,300,0")
        text = text.replace("12:00:01.000000,tcp4 127.0.0.1:50002<->127.0.0.1:9222,lo0,Established,0,0",
                            "12:00:01.000000,tcp4 127.0.0.1:50002<->127.0.0.1:9222,lo0,Established,300,0")
        net = procs.parse_nettop(text)
        self.assertEqual(net[502]["bytes"], 300)  # not the 10000 of sample 0
        self.assertEqual(net[502]["loopback_bytes"], 300)
        self.assertEqual(net[501]["loopback_bytes"], 0)

    def test_nettop_that_did_not_sample_the_window_is_not_measured(self):
        self.assertIsNone(procs.parse_nettop(""))
        sample0 = NETTOP.split("time,", 2)
        self.assertIsNone(procs.parse_nettop("time," + sample0[1]))  # one sample: the totals only
        header_once = NETTOP.split("\n", 1)[0] + "\n" + "\n".join(
            line for line in NETTOP.splitlines()[1:] if not line.startswith("time,"))
        self.assertIsNone(procs.parse_nettop(header_once))
        self.assertIsNone(procs.parse_nettop(header_once, NET_START, NET_END))

    def test_nettop_counts_only_the_samples_stamped_inside_the_window(self):
        late = NETTOP + NETTOP_HEADER + "12:00:03.000000,cmux DEV t.501,,,999,0,0,0,0,,,,,,,,,,,,\n" + \
            "12:00:03.000000,tcp4 127.0.0.1:50003<->127.0.0.1:8123,lo0,Established,999,0,0,0,0,,,,,,,,,,,,\n"
        self.assertEqual(procs.parse_nettop(late)[501]["bytes"], 1199)  # no window: every sample
        net = procs.parse_nettop(late, NET_START, NET_END)
        self.assertEqual(net[501]["bytes"], 200)  # the bench's end reads at 12:00:03 are not the app's
        self.assertEqual(net[501]["loopback_bytes"], 0)
        self.assertEqual(net[501]["remote_bytes"], {"tcp4 17.253.4.125:443": 200})
        self.assertEqual(net[501]["connections"], 1)  # open at the window's last sample (12:00:02)

    def test_nettop_samples_that_do_not_cover_the_window_are_not_measured(self):
        self.assertIsNone(procs.parse_nettop(NETTOP, NET_START, NET_END + 3))  # nettop stopped 3 s early
        self.assertIsNone(procs.parse_nettop(NETTOP, NET_START - 1, NET_END))  # its totals came after the start
        self.assertIsNotNone(procs.parse_nettop(NETTOP, NET_START, NET_END + 1))  # within one sample of the end

    def test_finish_nettop_of_a_header_once_csv_is_a_failed_reader(self):
        folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, folder)
        path = os.path.join(folder, "nettop.csv")
        with open(path, "w") as handle:
            handle.write(NETTOP.split("\n", 1)[0] + "\n" + "\n".join(
                line for line in NETTOP.splitlines()[1:] if not line.startswith("time,")))
        done = types.SimpleNamespace(wait=lambda timeout=None: 0, returncode=0, kill=lambda: None)
        self.assertIsNone(ib.finish_nettop(ib.NettopRun(done, path, 0.0), NET_START, NET_END))
        first, last = d15_snapshots()
        rows = ib.process_rows(first, last, 60.0, None, None, ib.kind, network=ib.NOT_MEASURED, logs={})
        entry = ib.summarize("light", {"processes": rows, "ends": ends(False, False),
                                       "readers": {"network": False, "log": True}}, D15BudgetTests.BUDGET)
        self.assertEqual(entry["over"], [])
        self.assertIn("light app network_bytes: not judged: unknown", entry["not_judged"])

    def test_remote_matches_the_whole_host_or_end(self):
        self.assertTrue(procs.remote_matches("17.253.4.125:443", "tcp4 17.253.4.125:443"))
        self.assertTrue(procs.remote_matches("17.253.4.125", "tcp4 17.253.4.125:443"))
        self.assertTrue(procs.remote_matches("tcp4 17.253.4.125:443", "tcp4 17.253.4.125:443"))
        self.assertTrue(procs.remote_matches("2606:4700::1", "tcp6 2606:4700::1.443"))
        for allowed, end in (("1.1.1.1:443", "tcp4 11.1.1.1:443"), ("17.253.4.12", "tcp4 17.253.4.125:443"),
                             ("10.0.0.1", "tcp4 10.0.0.10:443"), ("17.0.0.1:443", "tcp4 117.0.0.1:443"),
                             ("17.253.4.125:80", "tcp4 17.253.4.125:443")):
            self.assertFalse(procs.remote_matches(allowed, end), (allowed, end))

    def test_nettop_command_covers_the_window(self):
        command = procs.nettop_command(60)
        self.assertEqual(command[0], "/usr/bin/nettop")
        self.assertEqual(command[command.index("-L") + 1], "61")
        self.assertIn("-x", command)
        self.assertIn("-d", command)

    def test_log_counts_lines_of_the_set_inside_the_window(self):
        logs = procs.parse_log(LOG, {501, 502}, WINDOW_START, WINDOW_END)
        self.assertEqual(logs[501], {"lines": 2, "owners": {"com.cmuxterm.next:pump": 1, "AppKit": 1}})
        self.assertEqual(logs[502], {"lines": 1, "owners": {"cmux-tui": 1}})
        self.assertNotIn(999, logs)
        self.assertEqual(procs.parse_log(LOG, {501})[501]["lines"], 3)  # no window: every line

    def test_log_command_names_every_pid(self):
        command = procs.log_command({502, 501}, WINDOW_START + 0.4, WINDOW_END + 0.2)
        self.assertEqual(command[command.index("--predicate") + 1], "processID == 501 OR processID == 502")
        self.assertIn("ndjson", command)
        self.assertIn("--debug", command)

    def test_top_idlew(self):
        self.assertEqual(procs.parse_top_idlew(TOP, 157), 48211)
        self.assertIsNone(procs.parse_top_idlew(TOP, 158))


class D15BudgetTests(unittest.TestCase):
    BUDGET = {"all_kinds": {"disk_bytes_per_s": 0, "log_lines": 0, "network_bytes": 0},
              "kinds": {"app": {"wakeups_per_s": 1.0}}}

    def kinds(self, network=None, logs=None, app_disk=0):
        first, last = d15_snapshots(app_disk)
        rows = ib.process_rows(first, last, 60.0, None, None, ib.kind, network=network, logs=logs)
        return ib.aggregate({"processes": rows})

    def measured(self, app_disk=0):
        return self.kinds(procs.parse_nettop(NETTOP), procs.parse_log(LOG, {501, 502}, WINDOW_START, WINDOW_END),
                          app_disk)

    def test_checked_in_budget_has_the_d15_zeros(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        self.assertEqual(budget["all_kinds"], {"disk_bytes_per_s": 0, "log_lines": 0, "network_bytes": 0})
        for name in ("light", "tabs-static", "signed-in", "minimized"):
            for field in ib.D15_FIELDS:
                self.assertEqual(ib.limit_for(budget, name, "app", field), 0, (name, field))
        for rule in budget["allowed_periodic"]:
            self.assertGreaterEqual(rule["period_s"], 15)
            if "metrics" in rule:  # a D15 excuse names its kind and only D15 fields
                self.assertTrue(rule["kind"])
                self.assertLessEqual(set(rule["metrics"]), set(ib.D15_FIELDS))

    def test_rows_and_kinds_carry_disk_network_and_log(self):
        kinds = self.measured(app_disk=6000)
        self.assertEqual(kinds["app"]["disk_bytes"], 6000)
        self.assertEqual(kinds["app"]["disk_bytes_per_s"], 100.0)
        self.assertEqual(kinds["app"]["disk_writers"], [501])
        self.assertEqual(kinds["app"]["network_bytes"], 200)
        self.assertEqual(kinds["app"]["connections"], 1)
        self.assertEqual(kinds["app"]["log_lines"], 2)
        self.assertEqual(kinds["daemon"]["disk_bytes_per_s"], 0)
        self.assertEqual(kinds["daemon"]["network_bytes"], 0)
        self.assertEqual(kinds["daemon"]["network_loopback_bytes"], 0)
        self.assertEqual(kinds["daemon"]["log_lines"], 1)
        self.assertNotIn("disk_writers", kinds["daemon"])

    def test_4kb_written_by_the_app_prints_an_over(self):
        kinds = self.kinds({}, {}, app_disk=4096)
        overs = ib.over_budget("light", kinds, self.BUDGET)
        self.assertEqual(overs, [("app", "disk_bytes_per_s", round(4096 / 60, 3), 0)])
        self.assertEqual(ib.over_line("light", overs[0], kinds),
                         f"IDLE-BUDGET-OVER light app disk_bytes_per_s {round(4096 / 60, 3)} > 0 pids=501")

    def test_4kb_written_by_the_app_is_an_over_against_the_checked_in_budget(self):
        kinds = self.kinds({}, {}, app_disk=4096)
        overs = ib.over_budget("light", kinds, ib.load_budget(ib.BUDGET_FILE))
        self.assertIn(("app", "disk_bytes_per_s", round(4096 / 60, 3), 0), overs)

    def test_quiet_processes_are_in_budget(self):
        self.assertEqual(ib.over_budget("light", self.kinds({}, {}), self.BUDGET), [])

    def test_a_failed_reader_is_not_measured_not_a_pass_or_an_over(self):
        kinds = self.kinds(ib.NOT_MEASURED, ib.NOT_MEASURED)
        self.assertIsNone(kinds["app"]["network_bytes"])
        self.assertIsNone(kinds["app"]["log_lines"])
        self.assertEqual(kinds["app"]["disk_bytes_per_s"], 0)  # disk comes from rusage, not a reader
        self.assertEqual(ib.over_budget("light", kinds, self.BUDGET), [])
        self.assertEqual(ib.kind_notes("light", kinds, self.BUDGET),
                         ["light app log_lines: not judged: unknown", "light app network_bytes: not judged: unknown",
                          "light daemon log_lines: not judged: unknown", "light daemon network_bytes: not judged: unknown"])

    def test_a_run_that_does_not_read_network_or_log_has_no_such_fields(self):
        kinds = self.kinds()
        self.assertNotIn("network_bytes", kinds["app"])
        self.assertNotIn("log_lines", kinds["app"])
        self.assertEqual(ib.kind_notes("light", kinds, self.BUDGET), [])

    def test_summarize_lists_the_failed_readers(self):
        first, last = d15_snapshots()
        rows = ib.process_rows(first, last, 60.0, None, None, ib.kind, network=ib.NOT_MEASURED, logs={})
        entry = ib.summarize("light", {"processes": rows, "ends": ends(False, False),
                                       "readers": {"network": False, "log": True}}, self.BUDGET)
        self.assertEqual(entry["readers_failed"], ["network"])
        self.assertIn("light app network_bytes: not judged: unknown", entry["not_judged"])

    def test_log_and_network_overs_name_their_owners(self):
        kinds = self.measured()
        lines = [ib.over_line("light", over, kinds) for over in ib.over_budget("light", kinds, self.BUDGET)]
        self.assertIn("IDLE-BUDGET-OVER light app network_bytes 200 > 0 remotes=tcp4 17.253.4.125:443", lines)
        self.assertIn("IDLE-BUDGET-OVER light app log_lines 2 > 0 owners=com.cmuxterm.next:pump=1,AppKit=1", lines)
        self.assertIn("IDLE-BUDGET-OVER light daemon log_lines 1 > 0 owners=cmux-tui=1", lines)

    def test_allowed_periodic_excuses_only_its_kind_metric_and_remote(self):
        kinds = self.kinds(procs.parse_nettop(NETTOP), {})
        rule = {"owner": "DeviceHubSocket.ping", "period_s": 30, "why": "keepalive", "kind": "app",
                "metrics": ["network_bytes"], "remote": "17.253.4.125:443"}
        self.assertEqual(ib.over_budget("light", kinds, {**self.BUDGET, "allowed_periodic": [rule]}), [])
        for other in ({**rule, "remote": "1.1.1.1:443"}, {**rule, "kind": "daemon"}, {**rule, "metrics": ["log_lines"]},
                      {"owner": "DeviceHubSocket.ping", "period_s": 30, "why": "a wakeup owner only"}):
            self.assertEqual([o[:2] for o in ib.over_budget("light", kinds, {**self.BUDGET, "allowed_periodic": [other]})],
                             [("app", "network_bytes")], other)
        # an excuse covers D15 metrics only, never a wakeup limit
        self.assertFalse(ib.periodic_excuse({"allowed_periodic": [{**rule, "metrics": ["wakeups_per_s"]}]}, "app",
                                            "wakeups_per_s", kinds["app"]))

    def test_a_remote_excuse_matches_the_whole_end_not_a_substring(self):
        text = NETTOP.replace("17.253.4.125:443", "11.1.1.1:443")
        kinds = self.kinds(procs.parse_nettop(text), {})
        rule = {"owner": "x", "period_s": 30, "why": "y", "kind": "app", "metrics": ["network_bytes"],
                "remote": "1.1.1.1:443"}
        self.assertEqual([o[:2] for o in ib.over_budget("light", kinds, {**self.BUDGET, "allowed_periodic": [rule]})],
                         [("app", "network_bytes")])

    def test_a_remote_excuse_survives_an_idle_open_connection_elsewhere(self):
        text = NETTOP.replace(  # a second, zero-byte flow of the app open to the bench's tab server at the end
            "12:00:02.000000,tcp4 *:7000<->*:*,lo0,Listen,0,0",
            "12:00:02.000000,tcp4 127.0.0.1:50009<->127.0.0.1:8123,lo0,Established,0,0")
        kinds = self.kinds(procs.parse_nettop(text), {})
        self.assertEqual(kinds["app"]["connections"], 2)
        self.assertEqual(kinds["app"]["remotes"], ["tcp4 17.253.4.125:443", "tcp4 127.0.0.1:8123"])
        rule = {"owner": "x", "period_s": 30, "why": "y", "kind": "app", "metrics": ["network_bytes"],
                "remote": "17.253.4.125:443"}
        self.assertEqual(ib.over_budget("light", kinds, {**self.BUDGET, "allowed_periodic": [rule]}), [])

    def test_a_remote_excuse_leaves_bytes_to_other_ends_an_over(self):
        text = NETTOP.replace(
            "12:00:02.000000,cmux DEV t.501,,,0,0", "12:00:02.000000,cmux DEV t.501,,,50,0").replace(
            "12:00:02.000000,tcp4 *:7000<->*:*,lo0,Listen,0,0",
            "12:00:02.000000,tcp4 192.168.1.20:50010<->8.8.8.8:443,en0,Established,50,0")
        kinds = self.kinds(procs.parse_nettop(text), {})
        rule = {"owner": "x", "period_s": 30, "why": "y", "kind": "app", "metrics": ["network_bytes"],
                "remote": "17.253.4.125"}
        self.assertEqual(ib.over_budget("light", kinds, {**self.BUDGET, "allowed_periodic": [rule]}),
                         [("app", "network_bytes", 250, 0)])

    def test_a_remote_excuses_no_disk_or_log_value(self):
        kinds = self.kinds(procs.parse_nettop(NETTOP), procs.parse_log(LOG, {501, 502}, WINDOW_START, WINDOW_END))
        rule = {"owner": "x", "period_s": 30, "why": "y", "kind": "app", "metrics": ["log_lines"],
                "remote": "17.253.4.125:443"}
        self.assertFalse(ib.periodic_excuse({"allowed_periodic": [rule]}, "app", "log_lines", kinds["app"]))

    def test_a_process_that_exits_in_the_window_keeps_its_network_and_log(self):
        first, last = d15_snapshots()
        helper = f"{APP}/Contents/Frameworks/cmux Helper.app/Contents/MacOS/cmux Helper --type=utility"
        first = {**first, 503: (helper, first[501][1], first[501][2], {})}
        network = {**procs.parse_nettop(NETTOP), 503: {"bytes": 4096, "loopback_bytes": 0, "connections": 0,
                                                       "remotes": ["tcp4 1.2.3.4:443"],
                                                       "remote_bytes": {"tcp4 1.2.3.4:443": 4096}}}
        logs = {503: {"lines": 3, "owners": {"com.x:y": 3}}}
        rows = ib.process_rows(first, last, 60.0, None, None, ib.kind, network=network, logs=logs)
        exited = ib.exited_rows(first, last, ib.kind, network=network, logs=logs)
        self.assertEqual([(r["pid"], r["exited"], r["disk_bytes"]) for r in exited], [(503, True, None)])
        kinds = ib.aggregate({"processes": rows, "exited": exited})
        name = ib.kind(helper)
        self.assertEqual(kinds[name]["exited"], [503])
        self.assertEqual(kinds[name]["n"], 0)
        self.assertEqual(kinds[name]["network_bytes"], 4096)
        self.assertEqual(kinds[name]["log_lines"], 3)
        self.assertIsNone(kinds[name]["disk_bytes_per_s"])  # its rusage left with it: unknown, not 0
        overs = ib.over_budget("light", kinds, self.BUDGET)
        self.assertIn((name, "network_bytes", 4096, 0), overs)
        self.assertIn((name, "log_lines", 3, 0), overs)
        self.assertIn(f"light {name} disk_bytes_per_s: not judged: unknown", ib.kind_notes("light", kinds, self.BUDGET))

    def test_busy_and_reference_sessions_do_not_take_the_d15_zeros(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        kinds = self.kinds({}, {}, app_disk=4096)
        self.assertEqual(ib.over_budget("busy-hidden", kinds, budget), [])
        self.assertEqual(ib.over_budget("chrome-static", kinds, budget), [])

    def test_cron_rows_have_the_d15_units(self):
        report = {"sessions": {"light": {"kinds": {"app": {"disk_bytes_per_s": 68.267, "network_bytes": 0, "log_lines": None}}}}}
        rows = ib.cron_rows(report, self.BUDGET)
        self.assertEqual(rows["idle_budget.light.app.disk_bytes_per_s"],
                         {"p50": 68.267, "p95": 68.267, "p99": 68.267, "unit": "B/s", "budget": 0,
                          "floor": 0.5})
        self.assertEqual(rows["idle_budget.light.app.network_bytes"]["unit"], "bytes")
        self.assertNotIn("idle_budget.light.app.log_lines", rows)

    def test_table_has_the_d15_columns(self):
        kinds = self.kinds({}, ib.NOT_MEASURED, app_disk=4096)
        text = ib.table("light", kinds, ib.over_budget("light", kinds, self.BUDGET))
        self.assertIn("| disk B/s | net bytes (conns) | log lines |", text)
        self.assertIn(f"| **{round(4096 / 60, 3)}** | 0 (0) | - |", text)


class WindowServerTests(unittest.TestCase):
    TABLE = [(1, 0, "/sbin/launchd"), (157, 1, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer -daemon")]

    def test_reading_prefers_rusage_then_top(self):
        root = lambda pid: procs.Usage(interrupt_wakeups=900)  # noqa: E731
        clock = lambda: 5.0  # noqa: E731
        self.assertEqual(ib.windowserver_reading(self.TABLE, root, lambda pid: 1, clock), (157, 900, "rusage", 5.0))
        self.assertEqual(ib.windowserver_reading(self.TABLE, lambda pid: None, lambda pid: 48211, clock),
                         (157, 48211, "top-idlew", 5.0))
        self.assertEqual(ib.windowserver_reading(self.TABLE, lambda pid: None, lambda pid: None, clock),
                         (157, None, "unreadable", 5.0))
        self.assertEqual(ib.windowserver_reading(self.TABLE[:1], root, None, clock), (None, None, "not-found", 5.0))

    def test_rate_and_delta_against_the_hidden_reference(self):
        rate = ib.windowserver_rate((157, 1000, "rusage", 10.0), (157, 1600, "rusage", 70.0))
        self.assertEqual(rate, 10.0)
        self.assertEqual(ib.windowserver_report(rate, 7.5, "rusage"),
                         {"source": "rusage", "wakeups_per_s": 10.0, "hidden_reference_per_s": 7.5, "reference": "hidden",
                          "delta_per_s": 2.5})

    def test_no_rate_across_a_restart_or_a_source_change(self):
        self.assertIsNone(ib.windowserver_rate((157, 1000, "rusage", 0.0), (158, 1600, "rusage", 60.0)))
        self.assertIsNone(ib.windowserver_rate((157, 1000, "rusage", 0.0), (157, 1600, "top-idlew", 60.0)))
        self.assertIsNone(ib.windowserver_report(None, 7.5, "unreadable")["delta_per_s"])

    def test_a_hidden_session_is_its_own_reference_and_zero_seconds_takes_none(self):
        server = ib.windowserver_report(4.0, None, "rusage")
        self.assertEqual(ib.windowserver_with_reference(None, server, {"hide": True}, 60, {}),
                         {"source": "rusage", "wakeups_per_s": 4.0, "hidden_reference_per_s": 4.0, "reference": "self",
                          "delta_per_s": 0.0})
        self.assertEqual(ib.windowserver_with_reference(None, server, {}, 0, {})["reference"], "none")

    def test_a_hide_that_is_not_confirmed_takes_no_reference(self):
        class HideApp:
            def __init__(self, hide_reply, windows):
                self.hide_reply, self.windows, self.calls = hide_reply, windows, []

            def rpc(self, method, params=None, timeout=30):
                self.calls.append(method)
                return self.hide_reply if method == "action.run" else {"windows": self.windows}

        server = ib.windowserver_report(4.0, None, "rusage")
        shown = [{"kind": "main", "visible": True}]
        hidden = [{"kind": "main", "visible": False}]
        readings = iter([(157, 100, "rusage", 0.0), (157, 160, "rusage", 60.0)])
        with unittest.mock.patch.object(ib.time, "sleep", lambda _seconds: None), \
                unittest.mock.patch.object(ib, "windowserver_reading", lambda: next(readings)):
            for reply, windows in (({"error": {"code": "unknown_action"}}, hidden), ({}, shown), ({}, None)):
                app, entry = HideApp(reply, windows), {}
                report = ib.windowserver_with_reference(app, server, {}, 60, entry)
                self.assertEqual((report["reference"], report["hidden_reference_per_s"], report["delta_per_s"]),
                                 ("hide-failed", None, None), (reply, windows))
                self.assertEqual(entry["windowserver_hide"], reply)
            confirmed = ib.windowserver_with_reference(HideApp({}, hidden), server, {}, 60, {})
        self.assertEqual((confirmed["reference"], confirmed["hidden_reference_per_s"], confirmed["delta_per_s"]),
                         ("hidden", 1.0, 3.0))

    def test_windowserver_is_reported_never_judged(self):
        budget = {"all_kinds": {"disk_bytes_per_s": 0}, "kinds": {"windowserver": {"wakeups_per_s": 0}}}
        entry = ib.summarize("light", {"processes": [], "ends": ends(False, False),
                                       "windowserver": ib.windowserver_report(40.0, 1.0, "rusage")}, budget)
        self.assertEqual(entry["over"], [])
        self.assertEqual(entry["windowserver"]["delta_per_s"], 39.0)
        self.assertIn("WindowServer (rusage, reported): 40.0/s, 1.0/s with cmux hidden (hidden), delta 39.0/s",
                      ib.table("light", {}, [], entry))


# A JS event loop on a virtual clock that runs a probe page's script (PageVisibilityTests): setTimeout clamps to 4 ms
# and, while the page is hidden and `align` is set, fires on the next multiple of `align` ms as Chrome's hidden-page
# wake alignment does; requestAnimationFrame fires every 16 ms only while visible; `steps` change visibilityState and
# dispatch visibilitychange. Prints the POSTed paths with their times.
PROBE_HARNESS = r"""
const script = require('fs').readFileSync(0, 'utf8');
const cfg = JSON.parse(process.argv[1]);
let now = 0, seq = 0;
const timers = [], posts = [], listeners = [];
let rafs = [];
global.document = {visibilityState: 'visible', addEventListener: (type, f) => listeners.push(f)};
global.performance = {now: () => now};
global.fetch = (path) => { posts.push([now, path]); return {then() {}}; };
global.setTimeout = (f, delay) => {
  let at = now + Math.max(delay || 0, 4);
  if (document.visibilityState === 'hidden' && cfg.align) at = Math.ceil(at / cfg.align) * cfg.align;
  timers.push({at, f, seq: seq++});
};
global.requestAnimationFrame = (f) => rafs.push(f);
eval(script);
const steps = cfg.steps.slice();
while (true) {
  const timer = timers.length ? timers.reduce((a, b) => (a.at < b.at || (a.at === b.at && a.seq < b.seq)) ? a : b) : null;
  const frame = rafs.length && document.visibilityState === 'visible' ? Math.floor(now / 16 + 1) * 16 : Infinity;
  const step = steps.length ? steps[0].at : Infinity;
  const next = Math.min(timer ? timer.at : Infinity, frame, step);
  if (next === Infinity || next > cfg.end) break;
  now = next;
  if (step === next) {
    document.visibilityState = steps.shift().visibility;
    listeners.forEach(f => f());
  } else if (timer && timer.at === next) {
    timers.splice(timers.indexOf(timer), 1);
    timer.f();
  } else {
    const due = rafs; rafs = [];
    due.forEach(f => f(now));
  }
}
console.log(JSON.stringify(posts));
"""


class PageVisibilityTests(unittest.TestCase):
    """D17 (task 048): the probe page's posts, their parser, and the per-tab visibility report."""

    def run_page(self, steps, end, align=1000):
        node = shutil.which("node")
        if node is None:
            self.skipTest("no node to run the probe page's script")
        import re
        import subprocess
        page = ib.probe_page("c3")
        script = re.search(r"<script>(.*)</script>", page, re.S).group(1)
        done = subprocess.run([node, "-e", PROBE_HARNESS, json.dumps({"steps": steps, "end": end, "align": align})],
                              input=script, capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout)

    def probes(self, posts):
        return [ib.parse_probe(path) for _, path in posts if path.startswith(ib.PROBE_REPORT_PATH + "/")]

    def test_a_visible_page_posts_its_load_and_state_and_runs_no_probe(self):
        posts = self.run_page([], 60000)
        self.assertEqual([path for _, path in posts], ["/loaded/c3", "/vis/c3/visible"])

    def test_a_hidden_page_is_probed_after_the_delay_and_before_the_freeze_grace(self):
        posts = self.run_page([{"at": 1000, "visibility": "hidden"}], 60000)
        self.assertIn("/vis/c3/hidden", [path for _, path in posts])
        probes = self.probes(posts)
        self.assertEqual(len(probes), 1)
        key, probe = probes[0]
        self.assertEqual(key, "c3")
        self.assertEqual((probe["state_start"], probe["state_end"], probe["intact"]), ("hidden", "hidden", True))
        self.assertEqual(probe["raf"], 0, "a hidden page runs no rAF")
        self.assertLessEqual(probe["timer_wakes_per_s"], ib.HIDDEN_TIMER_WAKES_MAX)
        self.assertGreaterEqual(probe["hidden_ms"], ib.PROBE_DELAY_MS)
        report_at = next(t for t, path in posts if path.startswith(ib.PROBE_REPORT_PATH))
        self.assertLess(report_at - 1000, ib.FREEZE_HIDDEN_TABS_S * 1000, "the probe ends before the freeze")

    def test_unthrottled_timers_of_a_hidden_page_show_in_its_probe(self):
        _, probe = self.probes(self.run_page([{"at": 1000, "visibility": "hidden"}], 60000, align=0))[0]
        self.assertGreater(probe["timer_wakes_per_s"], 100)

    def test_a_page_shown_again_before_its_probe_runs_none(self):
        posts = self.run_page([{"at": 1000, "visibility": "hidden"}, {"at": 5000, "visibility": "visible"}], 60000)
        self.assertEqual(self.probes(posts), [])
        self.assertEqual([path for _, path in posts][-1], "/vis/c3/visible")

    def test_a_page_shown_during_its_probe_reports_it_not_intact(self):
        start = 1000 + ib.PROBE_DELAY_MS
        posts = self.run_page([{"at": 1000, "visibility": "hidden"}, {"at": start + 1500, "visibility": "visible"}],
                              60000)
        _, probe = self.probes(posts)[0]
        self.assertFalse(probe["intact"])
        self.assertIsNone(ib.hidden_probe([probe]))

    def test_the_probe_parser(self):
        key, probe = ib.parse_probe(ib.PROBE_REPORT_PATH + "/c1/hidden/hidden/0/5/4000/4100/11050/1")
        self.assertEqual(key, "c1")
        self.assertEqual(probe, {"state_start": "hidden", "state_end": "hidden", "raf": 0, "raf_per_s": 0.0,
                                 "timer_fires": 5, "timer_wakes_per_s": 1.0, "probe_ms": 4100, "hidden_ms": 11050,
                                 "intact": True})
        self.assertIsNone(ib.parse_probe(ib.PROBE_REPORT_PATH + "/c1/hidden/hidden/0/1/0/4000/11000/1")[1][
            "timer_wakes_per_s"])
        self.assertIsNone(ib.parse_probe(ib.PROBE_REPORT_PATH + "/c1/hidden")[0])

    def test_the_pages_server_serves_probe_pages_and_keeps_their_posts(self):
        import urllib.request
        with ib.IdlePages() as pages:
            body = urllib.request.urlopen(pages.probe_url("c3"), timeout=5).read().decode()
            for path in ("/vis/c3/hidden", ib.PROBE_REPORT_PATH + "/c3/hidden/hidden/0/4/3000/4000/11000/1",
                         ib.PROBE_REPORT_PATH + "/bad"):
                urllib.request.urlopen(urllib.request.Request(pages.origin + path, method="POST"), timeout=5).read()
            states, probes = pages.page_states()
        self.assertEqual(body, ib.probe_page("c3"))
        self.assertIn("/loaded/'+k", body)
        self.assertEqual(states, {"c3": "hidden"})
        self.assertEqual([p["timer_wakes_per_s"] for p in probes["c3"]], [1.0])
        self.assertEqual(len(pages.probe_errors), 1)

    def hidden(self, raf=0, wakes=1.0):
        return {"state_start": "hidden", "state_end": "hidden", "raf": raf, "raf_per_s": raf / 4, "timer_fires": 4,
                "timer_wakes_per_s": wakes, "probe_ms": 4000, "hidden_ms": 11000, "intact": True}

    def test_tabs_static_wants_every_tab_but_the_shown_one_hidden(self):
        tabs = ib.TABS_STATIC
        keys = [key for _, key in ib.plan_keys(tabs)]
        states = {key: "visible" if key == "shown" else "hidden" for key in keys}
        probes = {key: [self.hidden()] for key in keys if key != "shown"}
        report = ib.visibility_report(ib.SESSIONS["tabs-static"], tabs, states, states, probes)
        self.assertEqual((report["met"], report["wrong"], report["unknown"]), (True, {}, {}))
        self.assertEqual(len(report["tabs"]), 16)
        self.assertEqual(report["tabs"]["shown"]["expected"], "visible")
        # A hidden Chromium tab that reports visible, one that runs rAF, one over the timer limit: each is wrong.
        bad = ib.visibility_report(ib.SESSIONS["tabs-static"], tabs, {**states, "c0": "visible"},
                                   {**states, "c0": "visible"},
                                   {**probes, "c1": [self.hidden(raf=40)], "c2": [self.hidden(wakes=4.0)]})
        self.assertFalse(bad["met"])
        self.assertEqual(sorted(bad["wrong"]), ["c0", "c1", "c2"])
        self.assertIn("visibilityState visible at the window start, expected hidden", bad["wrong"]["c0"])
        self.assertEqual(bad["wrong"]["c1"], ["10.0 rAF/s while hidden"])
        self.assertEqual(bad["wrong"]["c2"], ["4.0 timer wakes/s while hidden > 1"])
        # WebKit tabs are reported, never judged.
        webkit = ib.visibility_report(ib.SESSIONS["tabs-static"], tabs, {**states, "w0": "visible"}, states, probes)
        self.assertTrue(webkit["met"])
        self.assertTrue(webkit["tabs"]["w0"]["problems"])

    def test_the_shown_tab_of_a_hidden_minimized_or_covered_window_must_be_hidden(self):
        for spec in (ib.SESSIONS["light-hidden"], ib.SESSIONS["minimized"], {"cover": True}):
            visible = ib.visibility_report(spec, ib.ONE_TAB, {"shown": "visible"}, {"shown": "visible"}, {})
            self.assertFalse(visible["met"], spec)
            hidden = ib.visibility_report(spec, ib.ONE_TAB, {"shown": "hidden"}, {"shown": "hidden"},
                                          {"shown": [self.hidden()]})
            self.assertTrue(hidden["met"], spec)
        shown = ib.visibility_report(ib.SESSIONS["light"], ib.ONE_TAB, {"shown": "visible"}, {"shown": "visible"}, {})
        self.assertTrue(shown["met"])

    def test_a_tab_with_no_report_or_no_hidden_probe_is_unknown_not_met(self):
        spec = ib.SESSIONS["light-hidden"]
        none = ib.visibility_report(spec, ib.ONE_TAB, {}, {}, {})
        self.assertIsNone(none["met"])
        self.assertEqual(none["unknown"]["shown"], ["no visibilityState by the window start",
                                                    "no visibilityState by the window end"])
        unprobed = ib.visibility_report(spec, ib.ONE_TAB, {"shown": "hidden"}, {"shown": "hidden"}, {})
        self.assertIsNone(unprobed["met"])
        self.assertEqual(unprobed["unknown"]["shown"], ["no hidden probe"])

    def test_the_animated_tab_is_left_to_its_own_rate(self):
        tabs = ib.SESSIONS["energy-saver"]["tabs"]
        report = ib.visibility_report(ib.SESSIONS["energy-saver"], tabs, {}, {}, {})
        self.assertNotIn("anim", report["tabs"])
        self.assertEqual(report["tabs"]["c9"]["expected"], "hidden")

    def test_the_visibility_tab_goes_only_to_the_light_sessions_when_asked(self):
        self.assertIsNone(ib.session_tabs("light-hidden"))
        self.assertIs(ib.session_tabs("light-hidden", True), ib.ONE_TAB)
        self.assertIs(ib.session_tabs("minimized", True), ib.ONE_TAB)
        self.assertIsNone(ib.session_tabs("stress", True))
        self.assertIs(ib.session_tabs("tabs-static", True), ib.TABS_STATIC)
        self.assertEqual(ib.settle_seconds("light-hidden", 10, ib.ONE_TAB), ib.VISIBILITY_SETTLE_S)
        self.assertEqual(ib.settle_seconds("light-hidden", 10), 10)
        self.assertGreater(ib.VISIBILITY_SETTLE_S * 1000, ib.PROBE_DELAY_MS + ib.PROBE_MS)
        self.assertLess(ib.PROBE_DELAY_MS + ib.PROBE_MS, ib.FREEZE_HIDDEN_TABS_S * 1000)

    def test_the_visibility_line_names_states_and_probe_rates(self):
        report = ib.visibility_report(ib.SESSIONS["light-hidden"], ib.ONE_TAB, {"shown": "hidden"},
                                      {"shown": "hidden"}, {"shown": [self.hidden()]})
        self.assertEqual(json.loads(ib.visibility_line(report)),
                         {"met": True, "wrong": {}, "unknown": {}, "tabs": {"shown": ["hidden", "hidden", 0.0, 1.0]}})


FIVE = ("signed-in", "home", "occluded", "app-quit", "external-churn")


class FiveSessionsTests(unittest.TestCase):
    """p14-energy-102: signed-in, home, occluded, app-quit, external-churn (their table, budget rows and fixtures)."""

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="idle-budget-102-")
        self.addCleanup(shutil.rmtree, self.folder, True)

    # The table.

    def test_the_five_sessions_and_what_each_builds(self):
        self.assertEqual(ib.parse_sessions(",".join(FIVE)), list(FIVE))
        self.assertTrue(ib.SESSIONS["occluded"]["cover"])
        self.assertTrue(ib.SESSIONS["home"]["home"])
        self.assertTrue(ib.SESSIONS["signed-in"]["sign_in"])
        self.assertTrue(ib.SESSIONS["app-quit"]["quit"])
        churn = ib.SESSIONS["external-churn"]
        self.assertTrue(churn["churn"] and churn["hide"])
        for name in FIVE:
            self.assertFalse(ib.SESSIONS[name].get("tabs") or ib.SESSIONS[name].get("saver"), name)
            self.assertEqual(ib.settle_seconds(name, 60), 60)
        self.assertEqual((ib.CHURN_WRITES_PER_S, ib.HISTORY_PERIOD_S), (10, 5))

    def test_unknown_session_refused(self):
        for text in ("signed-out", "home,app-quitt", "occlude"):
            with self.assertRaises(SystemExit) as raised:
                ib.parse_sessions(text)
            self.assertIn("unknown session", str(raised.exception))
            self.assertIn("external-churn", str(raised.exception))  # the list names the new sessions

    def test_signed_in_turns_phone_access_and_the_feed_on_and_keeps_keep_awake_off(self):
        config = ib.session_config("signed-in")
        self.assertEqual(config["phone"], {"keepAwake": "off", "allowConnections": True})
        self.assertEqual(config["sessions"], {"keepAwake": "off"})
        self.assertEqual(config["feed"], {"github": {"enabled": True}})
        self.assertEqual(ib.BASE_CONFIG["phone"], {"keepAwake": "off"})  # the merge changes no shared config
        self.assertEqual(ib.merged({"a": {"b": 1, "c": 2}}, {"a": {"c": 3}, "d": 4}), {"a": {"b": 1, "c": 3}, "d": 4})

    # The budget rows (D13, D6 home, D3 occluded).

    def test_budget_rows_of_the_five(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        sessions = budget["sessions"]
        self.assertEqual(sessions["signed-in"]["sums"]["app+daemon"], {"wakeups_per_s": 1.0})
        self.assertEqual(sessions["app-quit"]["sums"]["tree"], {"wakeups_per_s": 0.1})
        self.assertEqual(ib.limit_for(budget, "external-churn", "app", "wakeups_per_s"), 1.0)
        self.assertEqual(sessions["home"]["sums"]["tree"], {"wakeups_per_s": 1.0})
        self.assertEqual(ib.limit_for(budget, "occluded", "app", "wakeups_per_s"), 0.3)
        self.assertEqual(ib.limit_for(budget, "occluded", "app", "main_wakes_per_s"), 0.1)
        for name in FIVE:
            self.assertIn(name, sessions, name)
            self.assertFalse(ib.busy_kind(sessions[name], "app"), name)  # every one is an idle session, judged

    def test_signed_in_app_plus_daemon_over(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        kinds = {"app": ib.aggregate({"processes": [row("app", 30, 0.7)]})["app"],
                 "daemon": ib.aggregate({"processes": [row("daemon", 8, 0.4)]})["daemon"]}
        overs = ib.over_budget("signed-in", kinds, budget)
        self.assertIn(("app+daemon", "wakeups_per_s", 1.1, 1.0), overs)

    def test_app_quit_judges_the_tree_without_an_app(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        rows = [row("daemon", 8, 0.06), row("holder", 2, 0.0), row("terminal-host", 3, 0.05), row("acpmux", 4, 0.0)]
        kinds = ib.aggregate({"processes": rows})
        self.assertNotIn("app", kinds)
        self.assertIn(("tree", "wakeups_per_s", 0.11, 0.1), ib.over_budget("app-quit", kinds, budget))
        quiet = ib.aggregate({"processes": [row("daemon", 8, 0.05), row("holder", 2, 0.0)]})
        self.assertEqual(ib.over_budget("app-quit", quiet, budget), [])

    def test_external_churn_judges_the_app(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        kinds = ib.aggregate({"processes": [row("app", 30, 1.4), row("daemon", 8, 0.2)]})
        self.assertIn(("app", "wakeups_per_s", 1.4, 1.0), ib.over_budget("external-churn", kinds, budget))

    # signed-in: the account, never a secret.

    def credentials(self, text, mode=0o600):
        path = os.path.join(self.folder, "dev.env")
        with open(path, "w") as handle:
            handle.write(text)
        os.chmod(path, mode)
        return path

    def test_sign_in_env_names_the_file_and_the_account_never_the_password(self):
        import bench_launch
        path = self.credentials("CMUX_DOGFOOD_STACK_EMAIL=me@x.dev\nexport CMUX_UITEST_STACK_EMAIL='agent@x.dev'\n"
                                "CMUX_UITEST_STACK_PASSWORD=hunter2-secret\n")
        env = bench_launch.agent_sign_in_env(path)
        self.assertEqual(env, {"CMUX_AUTH_CREDENTIALS_FILE": path, "CMUX_DEV_AUTH_ACCOUNT": "agent@x.dev",
                               "CMUX_DEV_AUTH_PROFILE": "agent"})
        self.assertNotIn("hunter2-secret", json.dumps(env))

    def test_sign_in_env_refuses_a_file_the_app_would_not_read(self):
        import bench_launch
        with self.assertRaises(bench_launch.CredentialsError) as shared:
            bench_launch.agent_sign_in_env(self.credentials("CMUX_UITEST_STACK_EMAIL=a@x.dev\n", mode=0o644))
        self.assertIn("0600", str(shared.exception))
        with self.assertRaises(bench_launch.CredentialsError) as empty:
            bench_launch.agent_sign_in_env(self.credentials("CMUX_DOGFOOD_STACK_EMAIL=me@x.dev\n"))
        self.assertIn("CMUX_UITEST_STACK_EMAIL", str(empty.exception))
        with self.assertRaises(bench_launch.CredentialsError):
            bench_launch.agent_sign_in_env(os.path.join(self.folder, "missing.env"))

    BOTH_PAIRS = ("CMUX_DOGFOOD_STACK_EMAIL=me@x.dev\nCMUX_DOGFOOD_STACK_PASSWORD=mine\n"
                  "CMUX_UITEST_STACK_EMAIL=agent@x.dev\nCMUX_UITEST_STACK_PASSWORD=theirs\n")

    def test_the_fleet_secrets_file_with_both_pairs_is_left_to_the_apps_own_lookup(self):
        """The fleet layout holds the dogfood and the agent pair in one file. Named by CMUX_AUTH_CREDENTIALS_FILE the
        app takes the dogfood pair first and refuses it as another account; found by its ambient lookup, the agent
        profile and the declared account pick the agent pair (DogfoodCredentials.decide)."""
        import bench_launch
        home = os.path.join(self.folder, "home")
        os.makedirs(os.path.join(home, ".secrets"))
        path = os.path.join(home, ".secrets", "cmuxterm-dev.env")
        with open(path, "w") as handle:
            handle.write(self.BOTH_PAIRS)
        os.chmod(path, 0o600)
        with unittest.mock.patch.dict(os.environ, {"HOME": home}):
            env = bench_launch.agent_sign_in_env()
            self.assertEqual(env, bench_launch.agent_sign_in_env(path))
        self.assertEqual(env, {"CMUX_DEV_AUTH_ACCOUNT": "agent@x.dev", "CMUX_DEV_AUTH_PROFILE": "agent"})
        self.assertNotIn("theirs", json.dumps(env))

    def test_another_file_with_the_dogfood_pair_is_refused(self):
        import bench_launch
        with self.assertRaises(bench_launch.CredentialsError) as raised:
            bench_launch.agent_sign_in_env(self.credentials(self.BOTH_PAIRS))
        self.assertIn("CMUX_DOGFOOD_STACK_EMAIL", str(raised.exception))
        self.assertNotIn("mine", str(raised.exception))
        commented = self.credentials("# CMUX_DOGFOOD_STACK_PASSWORD=x\nCMUX_UITEST_STACK_EMAIL=\"agent@x.dev\"\n")
        self.assertEqual(bench_launch.agent_sign_in_env(commented)["CMUX_DEV_AUTH_ACCOUNT"], "agent@x.dev")

    # Signed in, then signed out: no session after it restores the account.

    def auth_app(self, signed_in, end_session_signs_out=True):
        """An app whose auth.status follows debug.cloud.end_session; `log` lists every call and the stop."""
        state = {"signed_in": signed_in}
        log = []

        def rpc(method, params=None, timeout=30):
            log.append(method)
            if method == "debug.cloud.end_session" and end_session_signs_out:
                state["signed_in"] = False
            if method == "auth.status":
                return {"signed_in": state["signed_in"], "restoring": False, "email": "agent@x.dev", "backend": "b"}
            return {"ended": True}
        process = types.SimpleNamespace(poll=lambda: None if "stop" not in log else 0, pid=7)
        return types.SimpleNamespace(rpc=rpc, process=process, stop=lambda: log.append("stop")), log

    def test_a_signed_in_session_signs_out_before_the_app_stops(self):
        app, log = self.auth_app(signed_in=True)
        rig = ib.SessionRig("signed-in", "debug")
        rig.account = "agent@x.dev"
        rig.after_launch(app)
        self.assertTrue(rig.shape["signed_in"])
        with unittest.mock.patch.object(ib.time, "sleep", lambda _s: None):
            self.assertEqual(rig.teardown(app), [])
        self.assertEqual(log[-3:], ["debug.cloud.end_session", "auth.status", "stop"])
        self.assertEqual(rig.shape["sign_out"], {"signed_out": True, "error": ""})

    def test_a_sign_out_that_does_not_end_is_reported_and_the_app_still_stops(self):
        app, log = self.auth_app(signed_in=True, end_session_signs_out=False)
        rig = ib.SessionRig("signed-in", "debug")
        rig.account = "agent@x.dev"
        with unittest.mock.patch.object(ib, "SIGN_OUT_WAIT_S", 0):
            errors = rig.teardown(app)
        self.assertEqual(log[-1], "stop")
        self.assertEqual(len(errors), 1)
        self.assertIn("sign-out: still signed in", errors[0])

    def test_every_other_session_runs_signed_out(self):
        app, log = self.auth_app(signed_in=False)
        rig = ib.SessionRig("light", "release")
        rig.after_launch(app)
        self.assertEqual((rig.shape["signed_in"], log), (False, ["auth.status"]))
        self.assertEqual(rig.teardown(app), [])
        self.assertEqual(log, ["auth.status", "stop"])  # no sign-out of a session that never signed in

    def test_a_restored_sign_in_is_ended_before_an_unsigned_session(self):
        app, log = self.auth_app(signed_in=True)
        rig = ib.SessionRig("light-hidden", "release")
        with unittest.mock.patch.object(ib.time, "sleep", lambda _s: None):
            rig.after_launch(app)
        self.assertEqual(rig.shape["left_signed_in"], {"signed_out": True, "error": ""})
        self.assertFalse(rig.shape["signed_in"])
        stuck, _log = self.auth_app(signed_in=True, end_session_signs_out=False)
        with unittest.mock.patch.object(ib.time, "sleep", lambda _s: None), \
                unittest.mock.patch.object(ib, "sign_out", lambda app: {"signed_out": False, "error": "still signed in"}), \
                self.assertRaises(ib.SessionShapeError) as raised:
            ib.SessionRig("light", "release").after_launch(stuck)
        self.assertIn("did not sign out: still signed in", str(raised.exception))

    # signed-in-display-sleep (D13: signed-in app <= light-hidden with the display asleep).

    def test_display_sleep_session_sleeps_the_display_and_wakes_it_at_the_teardown(self):
        commands = []
        run = lambda argv, **kw: commands.append(argv[0]) or types.SimpleNamespace(returncode=0, stderr="")
        app = types.SimpleNamespace(rpc=lambda *a, **k: {"windows": [{"kind": "main", "occluded": True, "key": True}]},
                                    process=types.SimpleNamespace(poll=lambda: 0), stop=lambda: commands.append("stop"))
        rig = ib.SessionRig("signed-in-display-sleep", "debug", run=run)
        rig.after_activate(app)
        self.assertEqual(commands, ["pmset"])
        self.assertTrue(rig.shape["display_sleep"]["main"][0]["occluded"])
        self.assertEqual(rig.teardown(app), [])
        self.assertEqual(commands, ["pmset", "stop", "caffeinate"])  # the app stops first, then the display wakes
        failing = lambda argv, **kw: types.SimpleNamespace(returncode=1, stderr="not allowed")
        with self.assertRaises(ib.SessionShapeError) as raised:
            ib.SessionRig("signed-in-display-sleep", "debug", run=failing).after_activate(app)
        self.assertIn("pmset exit 1: not allowed", str(raised.exception))

    def test_display_sleep_row_is_relative_to_light_hidden(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        self.assertEqual(ib.session_budget(budget, "signed-in-display-sleep")["relative"],
                         [{"to": "light-hidden", "of": "app", "field": "wakeups_per_s", "max_ratio": 1.0}])
        self.assertEqual(ib.session_config("signed-in-display-sleep"), ib.session_config("signed-in"))
        asleep = ib.aggregate({"processes": [row("app", 30, 0.6)]})
        hidden = ib.aggregate({"processes": [row("app", 30, 0.5)]})
        overs, notes = ib.cross_overs(budget, {"signed-in-display-sleep": asleep, "light-hidden": hidden})
        self.assertEqual([n for n in notes if n.startswith("signed-in-display-sleep")], [])  # light-hidden's own vs light
        self.assertEqual([session for session, _over in overs], ["signed-in-display-sleep"])
        quiet = ib.aggregate({"processes": [row("app", 30, 0.4)]})
        self.assertEqual(ib.cross_overs(budget, {"signed-in-display-sleep": quiet, "light-hidden": hidden})[0], [])
        _overs, alone = ib.cross_overs(budget, {"signed-in-display-sleep": quiet})
        self.assertIn("reference session light-hidden not measured", alone[0])

    def test_signed_in_rows_on_a_debug_build_are_reported_not_judged(self):
        entry = {"over": [["app+daemon", "wakeups_per_s", 1.1, 1.0]], "not_judged": []}
        notes = ib.unjudged_on_debug("signed-in", entry, "debug")
        self.assertEqual(entry["over"], [])
        self.assertEqual(entry["not_judged"], notes)
        self.assertIn("app+daemon wakeups_per_s: 1.1 over 1.0 on a Debug build", notes[1])
        kept = {"over": [["app", "wakeups_per_s", 2.0, 1.0]], "not_judged": []}
        self.assertEqual(ib.unjudged_on_debug("light", kept, "debug"), [])
        self.assertEqual(kept["over"], [["app", "wakeups_per_s", 2.0, 1.0]])  # other sessions keep their judgement

    def test_signed_in_needs_a_debug_build(self):
        self.assertIsNone(ib.sign_in_refusal("debug"))
        for config in ("release", "bench-hooks"):
            self.assertIn("Debug build only", ib.sign_in_refusal(config))
            with self.assertRaises(ib.SessionShapeError):
                ib.SessionRig("signed-in", config).env({"A": "1"})
        path = self.credentials("CMUX_UITEST_STACK_EMAIL=agent@x.dev\nCMUX_UITEST_STACK_PASSWORD=p\n")
        rig = ib.SessionRig("signed-in", "debug", credentials=path)
        env = rig.env({"A": "1"})
        self.assertEqual((env["A"], env["CMUX_AUTH_CREDENTIALS_FILE"], rig.account), ("1", path, "agent@x.dev"))
        self.assertEqual(ib.SessionRig("home", "release").env({"A": "1"}), {"A": "1"})  # no account elsewhere

    def test_auth_status_keeps_no_email(self):
        reply = {"signed_in": True, "restoring": False, "email": "Agent@X.dev", "user_id": "u1", "backend": "https://b"}
        state = ib.signed_in_state(reply, "agent@x.dev")
        self.assertEqual(state, {"signed_in": True, "restoring": False, "account_matches": True, "backend": "https://b"})
        self.assertNotIn("x.dev", json.dumps(state).replace("https://b", ""))
        self.assertFalse(ib.signed_in_state({"signed_in": True, "email": "other@x.dev"}, "agent@x.dev")["account_matches"])
        self.assertFalse(ib.signed_in_state({"error": "x"}, "agent@x.dev")["signed_in"])

    def test_wait_signed_in(self):
        replies = iter([{"signed_in": False, "restoring": True}, {"signed_in": True, "restoring": True, "email": "a@x"},
                        {"signed_in": True, "restoring": False, "email": "a@x"}])
        app = types.SimpleNamespace(rpc=lambda method, params=None, timeout=30: next(replies))
        with unittest.mock.patch.object(ib.time, "sleep", lambda _s: None):
            self.assertTrue(ib.wait_signed_in(app, "a@x", seconds=5)["signed_in"])
            other = types.SimpleNamespace(rpc=lambda *a, **k: {"signed_in": True, "restoring": False, "email": "b@x"})
            with self.assertRaises(ib.SessionShapeError) as wrong:
                ib.wait_signed_in(other, "a@x", seconds=5)
            self.assertNotIn("b@x", str(wrong.exception))
            out = types.SimpleNamespace(rpc=lambda *a, **k: {"signed_in": False, "restoring": False})
            with self.assertRaises(ib.SessionShapeError):
                ib.wait_signed_in(out, "a@x", seconds=0)

    # occluded and home.

    def test_wait_occluded_needs_every_main_window_occluded(self):
        states = iter([{"windows": [{"kind": "main", "occluded": False}]},
                       {"windows": [{"kind": "main", "occluded": True}, {"kind": "panel", "occluded": False}]}])
        app = types.SimpleNamespace(rpc=lambda method, params=None, timeout=10: next(states))
        with unittest.mock.patch.object(ib.time, "sleep", lambda _s: None):
            self.assertEqual(ib.wait_occluded(app, 5)["main"][0]["occluded"], True)
            still = types.SimpleNamespace(rpc=lambda *a, **k: {"windows": [{"kind": "main", "occluded": False}]})
            with self.assertRaises(ib.SessionShapeError):
                ib.wait_occluded(still, 0)

    def test_start_cover_reads_the_helper_line_and_ends_a_silent_helper(self):
        helper = os.path.join(self.folder, "benchhelper")
        with open(helper, "w") as handle:
            handle.write('#!/bin/sh\n[ "$1" = cover ] || exit 2\necho "covering 1920x1080"\nexec sleep 60\n')
        os.chmod(helper, 0o755)
        cover = ib.start_cover(helper, seconds=5)
        self.assertIsNone(cover.poll())
        ib.stop_process(cover)
        self.assertIsNotNone(cover.poll())
        silent = os.path.join(self.folder, "silent")
        with open(silent, "w") as handle:
            handle.write("#!/bin/sh\necho 'no display' >&2\nexit 2\n")
        os.chmod(silent, 0o755)
        with self.assertRaises(ib.SessionShapeError) as raised:
            ib.start_cover(silent, seconds=5)
        self.assertIn("no display", str(raised.exception))

    def test_home_runs_after_the_activation(self):
        calls = []
        app = types.SimpleNamespace(rpc=lambda method, params=None, timeout=30: calls.append((method, params)) or {})
        ib.SessionRig("home", "release").after_activate(app)
        self.assertEqual(calls, [("action.run", {"action": "home.show", "args": {}, "focus": False, "origin": "script"})])

    def fake_helper(self):
        helper = os.path.join(self.folder, "benchhelper")
        with open(helper, "w") as handle:
            handle.write('#!/bin/sh\n[ "$1" = cover ] || exit 2\necho "covering 1920x1080"\nexec sleep 60\n')
        os.chmod(helper, 0o755)
        return helper

    def test_the_cover_waits_until_the_app_is_occluded_and_no_longer_active(self):
        """Another app's window in front: occluded alone (cmux still key under the cover) is not the shape."""
        replies = iter([{"windows": [{"kind": "main", "occluded": True, "key": True}]},
                        {"windows": [{"kind": "main", "occluded": True, "key": False}]}])
        methods = []
        app = types.SimpleNamespace(rpc=lambda method, params=None, timeout=10: methods.append(method) or next(replies))
        rig = ib.SessionRig("occluded", "release")
        rig.helper = self.fake_helper()
        with unittest.mock.patch.object(ib.time, "sleep", lambda _s: None):
            rig.after_activate(app)
        self.addCleanup(ib.stop_process, rig.cover)
        self.assertIsNone(rig.cover.poll())  # the cover runs through the settle and the window
        self.assertEqual(methods, ["debug.window_list", "debug.window_list"])
        self.assertEqual(rig.shape["cover"], {"main": [{"key": False, "visible": None, "occluded": True,
                                                        "miniaturized": None, "alpha": None}], "any_key": False})
        self.assertEqual(rig.teardown(None), [])
        self.assertIsNotNone(rig.cover.poll())  # the teardown ends it

    def test_an_app_that_stays_active_under_the_cover_is_refused(self):
        still_key = types.SimpleNamespace(rpc=lambda *a, **k: {"windows": [{"kind": "main", "occluded": True, "key": True}]})
        with self.assertRaises(ib.SessionShapeError) as raised:
            ib.wait_occluded(still_key, 0, inactive=True)
        self.assertIn("occluded and inactive", str(raised.exception))
        unknown = types.SimpleNamespace(rpc=lambda *a, **k: {"error": "no such method"})
        with self.assertRaises(ib.SessionShapeError):
            ib.wait_occluded(unknown, 0, inactive=True)
        self.assertEqual(ib.wait_occluded(still_key, 0)["any_key"], True)  # occluded alone: minimized's, display sleep's

    # app-quit.

    def test_quit_keeps_the_sessions_and_waits_for_the_exit(self):
        import bench_launch
        app = bench_launch.BenchApp(bundle(self.folder, debug=False), out=os.path.join(self.folder, "out"),
                                    teardown=False)
        sent = []
        app.rpc = lambda method, params=None, timeout=60: sent.append((method, params)) or {"error": "closed"}
        app.process = types.SimpleNamespace(poll=lambda: None, wait=lambda timeout: 0)
        result = app.quit_keep_sessions()
        self.assertTrue(result["quit"])
        self.assertEqual(sent[0][1]["action"], "quitKeepSessions")

        def hangs(timeout):
            raise ib.subprocess.TimeoutExpired("cmux DEV", timeout)
        app.process = types.SimpleNamespace(poll=lambda: None, wait=hangs)
        late = app.quit_keep_sessions(timeout=1)
        self.assertFalse(late["quit"])
        self.assertIn("still runs 1 s after quitKeepSessions", late["error"])
        app.process = types.SimpleNamespace(poll=lambda: 0)
        self.assertEqual(app.quit_keep_sessions()["error"], "the app is not running")

    def test_app_quit_reads_no_socket_after_the_quit_and_stops_after_the_window(self):
        """main()'s app-quit: quitKeepSessions after the settle, QUIT_SETTLE_S, the window over QuitTree with no app
        (measure(None)), no window_state or sample read, then app.stop (which ends the daemons) last."""
        events = []
        teardown = types.SimpleNamespace(processes=lambda: [(11, "/x/cmux DEV t.app/Contents/Resources/bin/cmux-tui server")])

        class FakeBench:
            def __init__(self, app, out, env, config, **_results):
                self.app, self.tag, self.teardown, self.launched_env = app, "t", teardown, {}
                self.process = types.SimpleNamespace(pid=10, poll=lambda: 0 if "quit" in events else None)
                events.append("new")

            def launch(self):
                events.append("launch")

            def rpc(self, method, params=None, timeout=30):
                events.append(("rpc-after-quit" if "quit" in events else "rpc", method))
                return {"signed_in": False, "restoring": False} if method == "auth.status" else {}

            def activate(self):
                return {"activated": True, "error": ""}

            def quit_keep_sessions(self):
                events.append("quit")
                return {"quit": True, "seconds": 0.5, "error": ""}

            def stop(self):
                events.append("stop")

        def measure(app, instance, seconds, read_anim=None, attribute=False, shown_tab=None, workdir=None,
                    ledger_limit=20, hidden_hosts=()):
            events.append(("measure", app, type(instance).__name__))
            return {"seconds": seconds, "ends": {}, "processes": [{**row("daemon", 8, 0.05), "ran": []}],
                    "windowserver": ib.windowserver_report(None, None, None)}

        import bench_launch
        app_path = bundle(self.folder, debug=False)
        sleeps = []
        with unittest.mock.patch.object(bench_launch, "BenchApp", FakeBench), \
                unittest.mock.patch.object(bench_launch, "seed_hang_report_consent", lambda _app: ""), \
                unittest.mock.patch.multiple(ib, measure=measure, fresh_session=lambda _app: {}, threads=lambda _pid: {},
                                             host_facts=lambda: {"host": "h", "macos": "26"},
                                             run_sample=lambda *a: events.append("sample")), \
                unittest.mock.patch.object(ib.procs, "Instance", lambda app, pid: types.SimpleNamespace(pid=pid)), \
                unittest.mock.patch.object(ib.time, "sleep", sleeps.append), \
                contextlib.redirect_stdout(io.StringIO()) as out, self.assertRaises(SystemExit) as raised:
            ib.main(["--app", app_path, "--sessions", "app-quit", "--out", os.path.join(self.folder, "out")])
        self.assertEqual(raised.exception.code, 0)
        quit_at = events.index("quit")
        self.assertEqual([e for e in events[quit_at:] if isinstance(e, tuple) and e[0] == "rpc-after-quit"], [])
        self.assertEqual(events[quit_at + 1:], [("measure", None, "QuitTree"), "stop"])
        self.assertIn(ib.QUIT_SETTLE_S, sleeps)
        self.assertIn('IDLE-BUDGET-SHAPE app-quit {"signed_in": false, "quit": {"quit": true', out.getvalue())
        with open(os.path.join(self.folder, "out", "idle-budget.json")) as handle:
            report = json.load(handle)
        self.assertEqual(report["session_exits"], {"app-quit": 0})
        self.assertNotIn("window_state", report["sessions"]["app-quit"]["result"])

    def test_quit_tree_is_the_tags_processes(self):
        teardown = types.SimpleNamespace(processes=lambda: [(11, "/x/cmux DEV t.app/Contents/Resources/bin/cmux-tui server"),
                                                            (12, "/tmp/host __terminal-host --owner b:t@11")])
        tree = ib.QuitTree(teardown, 10)
        self.assertEqual(tree.pid, 10)
        self.assertEqual(sorted(tree.pids()), [11, 12])

    def test_measure_without_the_app_reads_no_socket(self):
        calls = []
        instance = type("Instance", (), {"pid": 1, "harness": {}})()
        saved = (ib.process_set, ib.threads, procs.usage, procs.overhead, procs.gpu_ns_by_pid, procs.coalition_of,
                 procs.thermal_state, procs.power_assertions, ib.time.sleep, ib.read_rpc, procs.priorities)
        server = "/x/cmux DEV t.app/Contents/Resources/bin/cmux-tui server"
        ib.process_set = lambda _instance: ib.ProcessSet({2: server}, [(2, 1, server)])
        procs.priorities = lambda _pids: {}
        ib.threads = lambda _pid: {}
        procs.usage = lambda _pid: procs.usage_from_words(rusage_words(), 1, 1)
        procs.overhead = lambda _pid: (0, 8, 0, 0, 0)
        procs.gpu_ns_by_pid = lambda: {}
        procs.coalition_of = lambda _pid: None
        procs.thermal_state = lambda: "nominal"
        procs.power_assertions = lambda _pids: []
        ib.time.sleep = lambda _seconds: None
        ib.read_rpc = lambda *args, **kwargs: calls.append(args[1]) or {}
        try:
            result = ib.measure(None, instance, 60, d15=ib.D15Readers(
                windowserver=lambda: (157, 10, "rusage", 0.0), start_network=lambda seconds, workdir: None,
                network_pid=lambda started: None, finish_network=lambda started, start, end: None,
                read_log=lambda pids, start, end: None))
        finally:
            (ib.process_set, ib.threads, procs.usage, procs.overhead, procs.gpu_ns_by_pid, procs.coalition_of,
             procs.thermal_state, procs.power_assertions, ib.time.sleep, ib.read_rpc, procs.priorities) = saved
        self.assertEqual(calls, [])
        self.assertEqual([r["kind"] for r in result["processes"]], ["daemon"])
        self.assertIsNone(result["ends"]["start"]["saver"])
        self.assertNotIn("main_wakes_per_s", result)

    # external-churn.

    def test_chrome_history_fixture_reads_as_chromium_history(self):
        import sqlite3
        path = ib.make_chrome_history(os.path.join(self.folder, "History"), visits=3, now=1_700_000_000)
        ib.append_chrome_visit(path, 7, now=1_700_000_100)
        with sqlite3.connect(path) as db:  # ChromiumHistoryReader's query
            rows = db.execute("SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND "
                              "visit_count > 0 ORDER BY last_visit_time DESC").fetchall()
        self.assertEqual(rows[0], ("https://example.com/churn/7", "Churn 7", 1, ib.chrome_time(1_700_000_100)))
        self.assertEqual(len(rows), 4)
        self.assertEqual(ib.chrome_time(0), 11644473600 * 1_000_000)
        self.assertFalse(os.path.exists(path + "-journal"))  # the commit made and removed it

    def test_keep_in_sync_store_is_one_synced_chrome_source(self):
        history = os.path.join(self.folder, "Chrome", "Default", "History")
        files = ib.keep_in_sync_store(history, now=1_700_000_000)
        record = files["sources.json"][0]
        self.assertEqual(record["syncedHistoryFile"], Path(history).resolve().as_uri())
        self.assertEqual((record["browser"], record["profileDirectory"]), ("chrome", "Default"))
        self.assertEqual(record["proposedProfileID"], record["targetProfileID"])
        self.assertRegex(record["targetProfileID"], r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
        # ImportedDataStore.batchFile: <target profile>/<source key, other than letters, digits and - as _>.json
        batch = files[f"{record['targetProfileID']}/chrome_Default.json"]
        self.assertEqual((batch["source"], batch["kinds"], batch["history"], batch["importedAt"]),
                         (record, ["history"], [], 1_700_000_000))

    def test_seeded_store_restores_the_tags_store(self):
        store = os.path.join(self.folder, "BrowserImport")
        os.makedirs(store)
        with open(os.path.join(store, "sources.json"), "w") as handle:
            handle.write("[]")
        seeded = ib.SeededStore(store, {"sources.json": [{"a": 1}], "p/b.json": {"b": 2}}).write()
        with open(os.path.join(store, "p", "b.json")) as handle:
            self.assertEqual(json.load(handle), {"b": 2})
        seeded.restore()
        with open(os.path.join(store, "sources.json")) as handle:
            self.assertEqual(handle.read(), "[]")
        self.assertFalse(os.path.exists(store + ".bench-prev"))
        os.makedirs(store + ".bench-prev")
        with self.assertRaises(ib.SessionShapeError):
            ib.SeededStore(store, {}).write()
        fresh = os.path.join(self.folder, "fresh", "BrowserImport")
        ib.SeededStore(fresh, {"sources.json": []}).write().restore()
        self.assertFalse(os.path.exists(fresh))

    def test_a_restore_that_cannot_move_the_store_back_reports_and_keeps_it_aside(self):
        store = os.path.join(self.folder, "BrowserImport")
        os.makedirs(store)
        seeded = ib.SeededStore(store, {"sources.json": []}).write()
        with unittest.mock.patch.object(ib.os, "rename", side_effect=OSError(16, "Resource busy")):
            problem = seeded.restore()
        self.assertIn("the earlier store stays at", problem)
        self.assertTrue(os.path.isdir(store + ".bench-prev"))

    def test_the_app_stops_before_the_churn_fixtures_go(self):
        """The app's Keep in Sync watch reads the History file and writes the import store: both stay until it ended.
        A failing step does not skip the later ones."""
        store = os.path.join(self.folder, "BrowserImport")
        os.makedirs(store)
        rig = ib.SessionRig("external-churn", "release")
        rig.scratch = os.path.join(self.folder, "scratch")
        os.makedirs(rig.scratch)
        rig.store = ib.SeededStore(store, {"sources.json": []}).write()
        seen = []

        def stop():
            seen.append((os.path.isdir(rig.scratch), os.path.exists(store + ".bench-prev")))
            raise RuntimeError("debug.quit timed out")
        app = types.SimpleNamespace(process=types.SimpleNamespace(poll=lambda: None), stop=stop)
        errors = rig.teardown(app)
        self.assertEqual(seen, [(True, True)])  # the fixtures were still there while the app stopped
        self.assertEqual(errors, ["app: RuntimeError: debug.quit timed out"])
        self.assertFalse(os.path.exists(rig.scratch))
        self.assertFalse(os.path.exists(store + ".bench-prev"))  # restored anyway

    def test_import_store_only_of_a_tagged_bundle(self):
        tagged = bundle(os.path.join(self.folder, "a"), debug=False)
        mine = bundle(os.path.join(self.folder, "b"), debug=False, ident="com.cmuxterm.app")
        self.assertTrue(ib.import_store_dir(tagged).endswith("Application Support/com.cmuxterm.app.debug.t/BrowserImport"))
        self.assertIsNone(ib.import_store_dir(mine))

    def test_churn_writes_ten_a_second_and_a_history_visit_every_five_seconds(self):
        project = ib.make_project(os.path.join(self.folder, "project"))
        self.assertTrue(os.path.isdir(os.path.join(project, ".git")))
        history = ib.make_chrome_history(os.path.join(self.folder, "History"), visits=1)
        churn = ib.ExternalChurn(project, history)
        for n in range(101):
            churn.step(n)
        with open(os.path.join(project, "churn.log")) as handle:
            self.assertEqual(len(handle.read().splitlines()), 101)
        self.assertEqual((churn.writes, churn.visits), (101, 3))  # writes 0, 50 and 100: one per 5 s at 10/s
        running = ib.ExternalChurn(project, history, writes_per_s=200).start()
        self.assertTrue(running.thread.is_alive())
        counts = running.stop()
        self.assertFalse(running.thread.is_alive())
        self.assertIsNone(counts["error"])
        self.assertGreaterEqual(counts["writes"], 1)


ACPMUX = f"{APP}/Contents/Resources/bin/acpmux"
FAKE = "/usr/bin/python3 /tmp/agent-idle/fake_agent.py"


def agent_table():
    """A process table with two agent hosts, a chat's (its harness runs a tool) and a pooled entry's (the multicall
    spelling), plus a python that is no harness."""
    return [(1, 0, f"{APP}/Contents/MacOS/cmux DEV"),
            (10, 1, f"{ACPMUX} daemon run"),
            (20, 1, f"{ACPMUX} __agent-host"),
            (21, 20, FAKE),
            (22, 21, "/bin/zsh -c make"),
            (30, 1, f"{APP}/Contents/Resources/bin/cmux acp __agent-host"),
            (31, 30, "/usr/local/bin/node /x/claude-agent-acp"),
            (40, 1, "/usr/bin/python3 /tmp/other.py")]


class AgentHarnessKindTests(unittest.TestCase):
    """p14-energy-103: every process under an acpmux agent host, pooled ones included, is agent-harness."""

    def test_kind_under_an_agent_host_is_agent_harness(self):
        self.assertEqual(ib.kind(FAKE, under_agent_host=True), "agent-harness")
        self.assertEqual(ib.kind("/bin/zsh -c make", under_agent_host=True), "agent-harness")
        self.assertEqual(ib.kind(FAKE), "other:python3")
        # The host is acpmux code, in both spellings (the acpmux binary, the cmux multicall binary).
        self.assertEqual(ib.kind(f"{ACPMUX} __agent-host"), "acpmux")
        self.assertEqual(ib.kind(f"{APP}/Contents/Resources/bin/cmux acp __agent-host"), "acpmux")
        self.assertFalse(procs.is_agent_host(f"{ACPMUX} daemon run --note __agent-hostile"))

    def test_harness_pids_are_every_descendant_of_a_host(self):
        self.assertEqual(procs.agent_harness_pids(agent_table()), {21: 20, 22: 20, 31: 30})
        # A host under a host is its own: its harness is the inner host's.
        nested = [(20, 1, f"{ACPMUX} __agent-host"), (21, 20, f"{ACPMUX} __agent-host"), (22, 21, FAKE)]
        self.assertEqual(procs.agent_harness_pids(nested), {22: 21})

    def test_process_set_names_the_harness_of_its_own_table(self):
        # process_set's instance read and its table are the one source: the harness map is the instance's.
        darwin = types.SimpleNamespace(responsible=None)
        with unittest.mock.patch.object(procs, "process_table", agent_table), \
                unittest.mock.patch.object(procs, "_darwin", lambda: darwin):
            instance = procs.Instance(APP, 1)
            found = ib.process_set(instance)
        self.assertEqual(instance.harness, {21: 20, 22: 20, 31: 30})
        self.assertTrue(set(instance.harness) <= set(found))
        self.assertFalse(hasattr(ib, "agent_harness"))  # one walk: procs.agent_harness_pids through Instance.pids

    def test_instance_counts_harnesses_of_its_hosts(self):
        darwin = types.SimpleNamespace(responsible=None)
        table = agent_table() + [(50, 0, "/opt/acpmux __agent-host"), (51, 50, FAKE)]
        with unittest.mock.patch.object(procs, "process_table", lambda: table), \
                unittest.mock.patch.object(procs, "_darwin", lambda: darwin):
            instance = procs.Instance(APP, 1)
            pids = instance.pids()
        self.assertTrue({20, 21, 22, 30, 31} <= set(pids))
        self.assertNotIn(51, pids)  # another app's host and its harness
        self.assertEqual(instance.harness, {21: 20, 22: 20, 31: 30})
        self.assertEqual(instance.kind(21, FAKE), "agent-harness")
        self.assertEqual(instance.kind(40, "/usr/bin/python3 /tmp/other.py"), procs.kind_of("/usr/bin/python3 /tmp/other.py"))
        self.assertNotEqual(procs.kind_of(FAKE), "agent-harness")  # the kind comes from the tree, not the command

    def test_rows_mark_the_hidden_chats_harness(self):
        zero = procs.usage_from_words(rusage_words(), 1, 1)
        woke = procs.usage_from_words(rusage_words(interrupt=6), 1, 1)

        def snap(usage):
            return {pid: (cmd, usage, (0, 4, 0, 0, 0), {}) for pid, _ppid, cmd in agent_table()}

        rows = ib.process_rows(snap(zero), snap(woke), 2.0, {}, {}, ib.kind, harness={21: 20, 22: 20, 31: 30},
                               hidden_hosts=(20,))
        by_pid = {r["pid"]: r for r in rows}
        self.assertEqual({pid: by_pid[pid]["kind"] for pid in (20, 21, 22, 30, 31, 40)},
                         {20: "acpmux", 21: "agent-harness", 22: "agent-harness", 30: "acpmux", 31: "agent-harness",
                          40: "other:python3"})
        self.assertEqual([pid for pid, r in sorted(by_pid.items()) if r.get("hidden")], [21, 22])
        self.assertEqual((by_pid[21]["agent_host"], by_pid[31]["agent_host"]), (20, 30))
        kinds = ib.aggregate({"processes": rows})
        self.assertEqual(kinds["agent-harness"]["n"], 3)
        self.assertEqual(kinds["agent-harness"]["hidden_wakeups_max"], 3.0)

    def test_measure_classifies_the_harness_of_the_last_read(self):
        calls = []
        commands = {pid: cmd for pid, _ppid, cmd in agent_table()}
        instance = type("Instance", (), {"pid": 1, "harness": {}})()
        # The first read saw a harness 21 under host 20 that exits; the last read's table has 31 under 30, and
        # names 77, which is not in its set: the map is the last read's, filtered to its pids.
        reads = [({**commands, 23: FAKE}, {21: 20, 22: 20, 23: 20}), (commands, {21: 20, 22: 20, 31: 30, 77: 30})]

        def process_set(read_instance):
            got, read_instance.harness = reads.pop(0) if len(reads) > 1 else reads[0]
            return ib.ProcessSet(got, [row for row in agent_table() if row[0] in got])

        d15 = ib.D15Readers(windowserver=lambda: (157, 10, "rusage", 0.0),
                            start_network=lambda seconds, workdir: "nettop", network_pid=lambda started: None,
                            finish_network=lambda started, start, end: {}, read_log=lambda pids, start, end: {})

        patches = [unittest.mock.patch.object(ib, "process_set", process_set),
                   unittest.mock.patch.object(ib, "threads", lambda _pid: {}),
                   unittest.mock.patch.object(procs, "usage", lambda _pid: procs.usage_from_words(rusage_words(), 1, 1)),
                   unittest.mock.patch.object(procs, "overhead", lambda _pid: (0, 4, 0, 0, 0)),
                   unittest.mock.patch.object(procs, "gpu_ns_by_pid", lambda: {}),
                   unittest.mock.patch.object(procs, "coalition_of", lambda _pid: None),
                   unittest.mock.patch.object(procs, "thermal_state", lambda: "nominal"),
                   unittest.mock.patch.object(procs, "power_assertions", lambda _pids: []),
                   unittest.mock.patch.object(procs, "process_table", lambda: calls.append("ps") or agent_table()),
                   unittest.mock.patch.object(procs, "priorities", lambda _pids: {}),
                   unittest.mock.patch.object(ib, "acpmux_homes", lambda _env: []),
                   unittest.mock.patch.object(ib.time, "sleep", lambda seconds: calls.append("sleep"))]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        result = ib.measure(FakeApp([]), instance, 60, hidden_hosts=(30,), d15=d15)
        self.assertEqual(calls, ["sleep", "sleep"])  # no second ps read: the harness is the last process_set's
        kinds = {r["pid"]: (r["kind"], r.get("hidden", False)) for r in result["processes"]}
        self.assertEqual(kinds[31], ("agent-harness", True))
        self.assertEqual(kinds[21], ("agent-harness", False))
        self.assertNotIn(23, kinds)
        self.assertNotIn(77, kinds)


class AgentSessionTests(unittest.TestCase):
    """The agent-idle, agent-working-visible and busy-hidden sessions and their D14 rows."""

    def test_the_three_sessions_and_their_rows_exist(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        for name in ("agent-idle", "agent-working-visible", "busy-hidden"):
            self.assertIn(name, ib.SESSIONS)
            self.assertIn(name, budget["sessions"])
        self.assertEqual(ib.SESSIONS["agent-idle"]["agents"], {"visible": True, "hidden": True, "pool": 1})
        self.assertEqual(ib.SESSIONS["agent-working-visible"]["agents"], {"visible": True, "working": True, "engine": "cef"})
        self.assertEqual(ib.SESSIONS["busy-hidden"]["busy_terminal"], 0.1)
        # agent-idle settles past the hidden harness's freeze (p14-energy-117).
        self.assertGreater(ib.settle_seconds("agent-idle", 60), ib.HARNESS_FREEZE_S)
        self.assertEqual(ib.settle_seconds("busy-hidden", 60), 60)
        self.assertIn("agent-harness", budget["kinds"])

    def test_unknown_agent_session_refused(self):
        with self.assertRaises(SystemExit) as raised:
            ib.parse_sessions("agent-idle,agent-idel")
        self.assertIn("unknown session agent-idel", str(raised.exception))
        self.assertEqual(ib.parse_sessions("agent-idle,agent-working-visible,busy-hidden"),
                         ["agent-idle", "agent-working-visible", "busy-hidden"])

    def test_d14_budgets(self):
        budget = ib.load_budget(ib.BUDGET_FILE)
        idle = {"app": {"wakeups_per_s": 0.4}, "daemon": {"wakeups_per_s": 0.2}, "acpmux": {"wakeups_per_s": 0.3},
                "agent-harness": {"wakeups_per_s": 9.0, "hidden_wakeups_max": 4.0}}
        # The hidden harness is reported, not judged, until p14-energy-117 freezes it.
        self.assertEqual(ib.over_budget("agent-idle", idle, budget), [])
        self.assertIsNone(ib.limit_for(budget, "agent-idle", "agent-harness", "hidden_wakeups_max"))
        # ... and the gap shows: an IDLE-BUDGET-NOT-JUDGED note with the value and the task that turns it on.
        notes = ib.deferred_notes("agent-idle", idle, budget)
        self.assertEqual(len(notes), 1)
        self.assertTrue(notes[0].startswith("agent-idle agent-harness hidden_wakeups_max: not judged: 4.0 measured;"))
        self.assertIn("p14-energy-117", notes[0])
        self.assertIn("not measured", ib.deferred_notes("agent-idle", {}, budget)[0])
        self.assertEqual(ib.deferred_notes("stress-static", {}, budget), [])  # a null with no reason stays quiet
        loud ={**idle, "acpmux": {"wakeups_per_s": 0.6}}
        self.assertIn(("app+daemon+acpmux", "wakeups_per_s", 1.2, 1.0), ib.over_budget("agent-idle", loud, budget))
        working = {"app": {"wakeups_per_s": 20.0}, "cef-renderer": {"wakeups_per_s": 10.0},
                   "cef-gpu": {"wakeups_per_s": 6.0}, "daemon": {"wakeups_per_s": 50.0}}
        self.assertEqual(ib.over_budget("agent-working-visible", working, budget),
                         [("app+cef-renderer+cef-gpu", "wakeups_per_s", 36.0, 35)])
        # Busy: only the session's own rows judge (the daemon's 50/s carries the printing terminal).
        busy = {"app": {"wakeups_per_s": 2.5, "main_wakes_per_s": 3.0}, "daemon": {"wakeups_per_s": 50.0}}
        self.assertEqual(ib.over_budget("busy-hidden", busy, budget), [("app", "wakeups_per_s", 2.5, 2.0)])

    def test_agent_home_config_and_records(self):
        with tempfile.TemporaryDirectory() as folder:
            home = ib.AgentHome(folder, "agent-idle")
            self.assertEqual(home.env(), {"ACPMUX_HOME": home.home, "ACPMUX_SOCKET": home.socket})
            self.assertLess(len(home.socket), 104)
            home.write()
            with open(os.path.join(home.home, "config.json")) as handle:
                config = json.load(handle)
            self.assertEqual(config, ib.agent_config(sys.executable, os.path.join(folder, "fake_agent.py")))
            self.assertEqual(config["defaultHarness"], ib.AGENT_HARNESS_ID)
            self.assertEqual(config["pool"], {"idleMinutes": ib.POOL_IDLE_MINUTES})
            self.assertTrue(os.path.isfile(os.path.join(folder, "fake_agent.py")))
            self.assertTrue(os.path.isdir(home.cwd) and os.path.isdir(home.pool_cwd))
            self.assertEqual(home.pool_host_pids(), [])
            os.makedirs(os.path.join(home.home, "hosts", "pool"))
            with open(os.path.join(home.home, "hosts", "s1.json"), "w") as handle:
                json.dump({"session_id": "s1", "host_pid": 4242}, handle)
            with open(os.path.join(home.home, "hosts", "pool", "pool-1.json"), "w") as handle:
                json.dump({"host_pid": 4343}, handle)
            with open(os.path.join(home.home, "hosts", "pool", "pool-2.json.tmp-9"), "w") as handle:
                json.dump({"host_pid": 9}, handle)
            self.assertEqual(home.host_pid("s1"), 4242)
            self.assertIsNone(home.host_pid("s2"))
            self.assertEqual(home.pool_host_pids(), [4343])

    def test_pool_ready_counts_only_ready_entries_in_its_folder(self):
        with tempfile.TemporaryDirectory() as folder:
            home = ib.AgentHome(folder, "agent-idle")
            entries = [{"cwd": home.pool_cwd, "state": "ready", "roles": ["hinted"]},
                       {"cwd": home.pool_cwd + "/", "state": "warming"},
                       {"cwd": home.cwd, "state": "ready"}]  # the agent page's own prewarm hint
            home.call = lambda method, params=None, timeout=10: {"pool": {"entries": entries}}
            self.assertEqual(home.pool_ready(home.pool_cwd), [entries[0]])
            home.call = lambda method, params=None, timeout=10: {"error": "closed"}
            self.assertEqual(home.pool_ready(home.pool_cwd), [])

    def test_trust_reports_a_refusal(self):
        home = ib.AgentHome("/tmp/x", "agent-idle")
        home.call = lambda method, params=None, timeout=10: {}
        self.assertIsNone(home.trust("/tmp/x/agent-work"))
        home.call = lambda method, params=None, timeout=10: {"error": {"code": -32601, "message": "no method"}}
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            self.assertEqual(home.trust("/w"), {"cwd": "/w", "error": {"code": -32601, "message": "no method"}})
        self.assertTrue(printed.getvalue().startswith("AGENT-SESSION-TRUST-REFUSED "))

    def test_gate_blocks_until_release(self):
        with tempfile.TemporaryDirectory() as folder:
            home = ib.AgentHome(folder, "agent-working-visible")
            path = home.gate()
            home.release()  # no reader yet: nothing to end, no error
            got = []

            def read():
                with open(path) as gate:
                    got.append(gate.readline())

            reader = ib.threading.Thread(target=read)
            reader.start()
            for _ in range(500):  # the reader opens the FIFO at some point; release reaches it once it has
                home.release()
                reader.join(0.01)
                if got:
                    break
            reader.join(5)
            self.assertEqual(got, ["go\n"])

    def test_chat_session_and_turn_done(self):
        self.assertEqual(ib.chat_session({"result": json.dumps({"sessionId": "s1"})}), "s1")
        self.assertEqual(ib.chat_session({"result": {"sessionId": "s2"}}), "s2")
        self.assertEqual(ib.chat_session({"sessionId": "s3"}), "s3")
        self.assertIsNone(ib.chat_session({"error": "no agent tab"}))
        self.assertIsNone(ib.chat_session({"result": "not json"}))
        self.assertTrue(ib.turn_done({"status": "ready", "lastTurn": {"endedAt": 5}}))
        # idle is SessionStatus::Idle, "No child process": the harness exited, nothing would be measured.
        self.assertFalse(ib.turn_done({"status": "idle", "lastTurn": {"endedAt": 5}}))
        self.assertFalse(ib.turn_done({"status": "running", "lastTurn": {"endedAt": 5}}))
        self.assertFalse(ib.turn_done({"status": "ready"}))


def fake_wait(predicate, seconds, step=0.25):
    """perf-stress-session.py's bounded poll with no sleep: up to 20 tries, an exception is no value."""
    for _ in range(20):
        try:
            value = predicate()
        except Exception:  # noqa: BLE001 - as the real poll: the state may not answer yet
            value = None
        if value:
            return value
    return None


class FakeWorld:
    """The app, its agent pages and its acpmux as the session builders see them: perf-stress-session.py's Stress
    (workspaces, panes, tabs, show), debug.agent_pane per pane, and acpmux's replies (AgentHome.call), with the
    host records acpmux writes. Every verb is recorded in `log`."""

    def __init__(self, home, engine="cef", trust_error=None, prewarm=None, finished_status="ready", new_chat=None,
                 send_error=None, write_hidden_record=True):
        self.home, self.engine, self.log = home, engine, []
        self.trust_error, self.prewarm = trust_error, prewarm or {"accepted": True}
        self.finished_status, self.new_chat, self.send_error = finished_status, new_chat, send_error
        self.write_hidden_record = write_hidden_record
        self.workspaces = {"w1": [{"id": "p1", "tabs": [{"id": "t1", "selected": True}]}]}
        self.focused = self.showing = "w1"
        self.sessions, self.pool = {}, []
        self.next_pid = 5000
        world = self

        class Stress:
            def __init__(self, rpc):
                self.rpc, self.refusals = rpc, []

            def action(self, name, args=None, target=None, focus=True, timeout=120, settle=0.0):
                world.log.append(("action", name, target))
                return {}

            def focused_workspace(self):
                return world.focused

            def workspace(self, workspace_id):
                panes = world.workspaces.get(workspace_id)
                return None if panes is None else {"id": workspace_id, "panes": panes}

            @staticmethod
            def panes(workspace):
                return (workspace or {}).get("panes") or []

            def new_workspace(self):
                made = f"w{len(world.workspaces) + 1}"
                world.workspaces[made] = [{"id": f"p{len(world.workspaces) + 1}", "tabs": [{"id": "tx", "selected": True}]}]
                world.log.append(("new_workspace", made))
                return made

            def show(self, workspace):
                world.log.append(("show", workspace))
                world.showing = workspace

            def window_showing(self, workspace, topology=None):
                return {"workspace": workspace} if world.showing == workspace else None

            def send(self, tab_id, text):
                world.log.append(("send", tab_id, text))

        self.module = types.SimpleNamespace(Stress=Stress, wait=fake_wait)
        home.call = self.acpmux

    def pid(self):
        self.next_pid += 1
        return self.next_pid

    def record(self, path, pid):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as handle:
            json.dump({"host_pid": pid}, handle)

    # The app's control socket.
    def rpc(self, method, params=None, timeout=30):
        params = params or {}
        if method != "debug.agent_pane":
            return {}
        action, pane = params["action"], params["pane"]
        self.log.append(("page", action, pane))
        session = f"s-{pane}"
        if action == "chat_state":
            return {"pane": pane, "sessionId": session if session in self.sessions else None}
        if action == "engine":
            return {"pane": pane, "engine": self.engine}
        if action == "new_chat":
            return self.new_chat or {"pane": pane, "sessionId": None}
        if action == "send_prompt":
            if self.send_error:
                return {"pane": pane, "error": self.send_error}
            gated = params["text"].startswith("gate: ")
            self.sessions[session] = {"sessionId": session, "status": "running" if gated else self.finished_status,
                                      "lastTurn": None if gated else {"endedAt": 1}}
            if self.write_hidden_record or pane == "p1":
                self.record(os.path.join(self.home.home, "hosts", f"{session}.json"), self.pid())
            return {"pane": pane, "sent": True, "turnEnded": not gated, "sessionId": session}
        return {"error": f"unknown action {action}"}

    # acpmux's socket (AgentHome.call).
    def acpmux(self, method, params=None, timeout=10):
        self.log.append(("acpmux", method))
        if method == "_acpmux/status":
            return {"pool": {"entries": list(self.pool)}}
        if method == "_acpmux/sessions":
            return {"sessions": list(self.sessions.values())}
        if method == "acp.trust.set":
            return {"error": self.trust_error} if self.trust_error else {}
        if method == "_acpmux/prewarm":
            if self.prewarm.get("accepted"):
                self.pool.append({"cwd": params["cwd"], "state": "ready"})
                self.record(os.path.join(self.home.home, "hosts", "pool", "pool-1.json"), self.pid())
            return self.prewarm
        return {"error": "unknown"}


class AgentSessionBuildTests(unittest.TestCase):
    """build_agents, open_agent_chat, build_busy_hidden and main's session wiring against FakeWorld."""

    def setUp(self):
        folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, folder, ignore_errors=True)
        self.home = ib.AgentHome(folder, "agent-idle")
        os.makedirs(self.home.home)
        self.out = io.StringIO()
        patch = unittest.mock.patch("sys.stdout", self.out)
        patch.start()
        self.addCleanup(patch.stop)

    def build(self, plan, **world):
        self.world = FakeWorld(self.home, **world)
        return ib.build_agents(self.world, self.home, plan, self.world.module)

    def page_verbs(self, verb):
        return [entry for entry in self.world.log if entry[:2] == ("page", verb)]

    def test_agent_idle_builds_a_hidden_chat_a_visible_chat_and_a_pool_entry(self):
        built = self.build(ib.SESSIONS["agent-idle"]["agents"])
        hidden, visible = built["chats"]
        self.assertEqual((hidden["workspace"], hidden["visible"], visible["workspace"], visible["visible"]),
                         ("w2", False, "w1", True))
        self.assertEqual(built["hidden_hosts"], [hidden["host_pid"]])
        # The hidden workspace showed for its chat, then the launch workspace showed again over it.
        self.assertEqual([e for e in self.world.log if e[0] == "show"], [("show", "w2"), ("show", "w1")])
        self.assertEqual(self.world.showing, "w1")
        self.assertEqual((built["pool_entries"], len(built["pool_hosts"])), (1, 1))
        self.assertEqual(built["plan"], ib.SESSIONS["agent-idle"]["agents"])
        self.assertEqual(built["trust"], [])
        # One new chat and one prompt per chat: the user verbs never repeat.
        self.assertEqual(len(self.page_verbs("new_chat")), 2)
        self.assertEqual(len(self.page_verbs("send_prompt")), 2)
        self.assertIn("AGENT-SESSION ", self.out.getvalue())

    def test_working_chat_runs_its_gated_turn_on_cef(self):
        built = self.build(ib.SESSIONS["agent-working-visible"]["agents"])
        (chat,) = built["chats"]
        self.assertEqual((chat["working"], chat["engine"]), (True, "cef"))
        self.assertEqual(self.world.sessions[chat["session"]]["status"], "running")
        self.assertEqual(len(self.home.gates), 1)
        self.assertEqual(built["pool_hosts"], [])

    def test_a_webkit_chat_is_refused_where_the_session_sums_cef(self):
        with self.assertRaisesRegex(ib.SessionShapeError, "shows on webkit:own-host, the session measures cef"):
            self.build(ib.SESSIONS["agent-working-visible"]["agents"], engine="webkit:own-host")
        # agent-idle names no engine: a WebKit chat is recorded, not refused.
        built = self.build({"visible": True}, engine="webkit:agentChat")
        self.assertEqual(built["chats"][0]["engine"], "webkit:agentChat")

    def test_a_refused_send_is_sent_once_then_refused(self):
        with self.assertRaisesRegex(ib.SessionShapeError, "send_prompt refused"):
            self.build({"visible": True}, send_error="timed out")
        self.assertEqual(len(self.page_verbs("send_prompt")), 1)
        with self.assertRaisesRegex(ib.SessionShapeError, "new_chat refused"):
            self.build({"visible": True}, new_chat={"error": "timed out"})
        self.assertEqual(len(self.page_verbs("new_chat")), 1)
        self.assertEqual(self.page_verbs("send_prompt"), [])

    def test_a_pending_start_is_refused_with_the_trust_refusal(self):
        with self.assertRaisesRegex(ib.SessionShapeError, "waits on a question .*no method"):
            self.build({"visible": True}, new_chat={"sessionId": None, "pending": True}, trust_error="no method")
        self.assertIn("AGENT-SESSION-TRUST-REFUSED", self.out.getvalue())

    def test_a_trust_refusal_is_reported(self):
        built = self.build({"visible": True}, trust_error="no method")
        self.assertEqual(built["trust"], [{"cwd": self.home.cwd, "error": "no method"}])

    def test_a_harness_that_exited_is_no_finished_turn(self):
        with self.assertRaisesRegex(ib.SessionShapeError, "its turn did not finish"):
            self.build({"visible": True}, finished_status="idle")

    def test_a_hidden_chat_with_no_host_record_is_refused(self):
        with self.assertRaisesRegex(ib.SessionShapeError, "has no agent host record"):
            self.build({"hidden": True}, write_hidden_record=False)

    def test_a_refused_prewarm_is_refused(self):
        with self.assertRaisesRegex(ib.SessionShapeError, "prewarm .* refused: .*the session pool is off"):
            self.build({"pool": 1}, prewarm={"accepted": False, "reason": "the session pool is off"})

    def test_a_pool_entry_the_page_hinted_does_not_count(self):
        self.world = FakeWorld(self.home)
        answer = self.world.acpmux

        def acpmux(method, params=None, timeout=10):
            if method != "_acpmux/prewarm":
                return answer(method, params, timeout)
            # A newer hint from the agent page superseded the bench's: the ready entry is in the page's folder.
            self.world.pool.append({"cwd": self.home.cwd, "state": "ready"})
            return {"accepted": True, "superseded": True}

        self.home.call = acpmux
        with self.assertRaisesRegex(ib.SessionShapeError, "1 ready pooled entries in .* wanted, 0"):
            ib.build_agents(self.world, self.home, {"pool": 1}, self.world.module)

    def test_busy_hidden_prints_in_the_launch_terminal_then_hides_it(self):
        self.world = FakeWorld(self.home)
        built = ib.build_busy_hidden(self.world, 0.1, self.world.module)
        self.assertEqual(built, {"printing_workspace": "w1", "printing_tab": "t1", "period_s": 0.1,
                                 "shown_workspace": "w2"})
        self.assertIn(("send", "t1", "while :; do echo idle-budget-tick; sleep 0.1; done\n"), self.world.log)
        self.assertEqual(self.world.showing, "w2")

    def test_busy_hidden_refuses_a_workspace_with_no_terminal(self):
        self.world = FakeWorld(self.home)
        self.world.workspaces["w1"] = [{"id": "p1", "tabs": []}]
        with self.assertRaisesRegex(ib.SessionShapeError, "has no terminal tab"):
            ib.build_busy_hidden(self.world, 0.1, self.world.module)


class AgentRefusalTests(unittest.TestCase):
    """A window that did not measure the harnesses the session built is refused, not passed."""

    AGENTS = {"plan": {"visible": True, "hidden": True, "pool": 1}, "hidden_hosts": [20], "pool_hosts": [30]}

    def rows(self, *hosts):
        return [{"kind": "agent-harness", "agent_host": host} for host in hosts] + [{"kind": "acpmux"}]

    def test_both_harnesses_measured(self):
        self.assertEqual(ib.agent_refusals(self.AGENTS, self.rows(20, 30)), [])

    def test_the_hidden_harness_exited(self):
        self.assertEqual(ib.agent_refusals(self.AGENTS, self.rows(30)),
                         [("agents", "no agent-harness row under the hidden chat's host [20]")])

    def test_an_empty_hidden_set_is_refused(self):
        agents = {**self.AGENTS, "hidden_hosts": []}
        self.assertEqual(ib.agent_refusals(agents, self.rows(20, 30)),
                         [("agents", "no agent-harness row under the hidden chat's host []")])

    def test_the_pooled_harness_is_gone(self):
        self.assertEqual(ib.agent_refusals(self.AGENTS, self.rows(20)),
                         [("agents", "no agent-harness row under a pooled host [30]")])

    def test_sessions_without_agents_or_without_a_hidden_chat(self):
        self.assertEqual(ib.agent_refusals(None, []), [])
        working = {"plan": {"visible": True, "working": True}, "hidden_hosts": [], "pool_hosts": []}
        self.assertEqual(ib.agent_refusals(working, []), [])

    def test_refusals_reads_the_window_rows(self):
        entry = {"saver": {"mismatch": None}, "agents": self.AGENTS, "result": {"processes": self.rows(30)}}
        with unittest.mock.patch.object(ib, "shipping_refusals", lambda _entry: []):
            self.assertEqual([what for what, _why in ib.refusals(entry)], ["agents"])


class SessionWiringTests(unittest.TestCase):
    """main's session wiring: the agent home's env reaches the app, its config is written before the launch, and
    the gated turns end before the app stops."""

    class App:
        def __init__(self, path, out, env, config, log_name=None, perf_session=None, run=None):
            self.path, self.out, self.env, self.config = path, out, env, config
            self.log_name, self.perf_session, self.run = log_name, perf_session, run
            self.log = []

        def launch(self):
            self.log.append("launch")

        def stop(self):
            self.log.append("stop")

    def test_an_agent_session_launches_with_its_acpmux_home(self):
        with tempfile.TemporaryDirectory() as out:
            app, agents = ib.session_app(self.App, "/A.app", out, "agent-idle", {"CMUX_X": "1"})
            self.assertIsInstance(agents, ib.AgentHome)
            self.assertEqual(app.env, {"CMUX_X": "1", **agents.env()})
            self.assertEqual(agents.folder, os.path.join(out, "agent-idle"))
            self.assertEqual(app.out, out)  # result-v1 files: the lab reads --out only
            self.assertEqual(app.log_name, os.path.join("agent-idle", "app.log"))
            self.assertTrue(os.path.isdir(os.path.join(out, "agent-idle")))
            app, agents = ib.session_app(self.App, "/A.app", out, "busy-hidden", {"CMUX_X": "1"})
            self.assertIsNone(agents)
            self.assertEqual(app.env, {"CMUX_X": "1"})

    def test_start_writes_the_home_before_the_launch_then_builds(self):
        log = []
        app = self.App("/A.app", "/o", {}, {})
        app.launch = lambda: log.append("launch")
        agents = types.SimpleNamespace(write=lambda: log.append("write"))
        entry = {}
        with unittest.mock.patch.object(ib, "build_agents", lambda *a: log.append("agents") or {"built": 1}), \
                unittest.mock.patch.object(ib, "build_busy_hidden", lambda *a: log.append("busy") or {"busy": 1}):
            ib.start_session(app, agents, ib.SESSIONS["agent-idle"], entry)
            self.assertEqual(log, ["write", "launch", "agents"])
            self.assertEqual(entry, {"agents": {"built": 1}})
            log.clear()
            ib.start_session(app, None, ib.SESSIONS["busy-hidden"], entry)
            self.assertEqual(log, ["launch", "busy"])

    def test_stop_releases_the_gates_before_the_app_stops(self):
        log = []
        app = types.SimpleNamespace(stop=lambda: log.append("stop"))
        ib.stop_session(app, types.SimpleNamespace(release=lambda: log.append("release")))
        self.assertEqual(log, ["release", "stop"])

        def broken():
            raise OSError("gate")

        log.clear()
        with self.assertRaises(OSError):
            ib.stop_session(app, types.SimpleNamespace(release=broken))
        self.assertEqual(log, ["stop"])  # the app stops whatever the release did
        log.clear()
        ib.stop_session(app, None)
        self.assertEqual(log, ["stop"])

    def test_main_uses_the_session_wiring(self):
        source = Path(HERE / "idle-budget.py").read_text()
        main = source[source.index("def main(argv=None):"):]
        self.assertIn("session_app(BenchApp, opts.app, out, session, rig.env(env), runs)", main)
        self.assertIn("start_session(app, agents, spec, entry)", main)
        self.assertIn("stop_session(app, agents)", main)
        self.assertLess(main.index("start_session("), main.index("settle_seconds("))

    def test_main_goes_on_after_a_session_app_that_raises_and_records_stress_in_one_run(self):
        """A session whose app was never built (session_app raised) is reported failed and records nothing; the
        loop goes on. Each later session's app records into --out as its story's perf session (stress for a STRESS
        session), and the sessions of one story share one run."""
        made, records = [], []

        class FakeBench:
            def __init__(self, path, out, env, config, log_name=None, perf_session=None, run=None):
                self.app, self.out, self.log_name, self.perf_session, self.run = path, out, log_name, perf_session, run
                self.process = None
                made.append(self)

            def record(self, story, metric, unit, samples, better, engine):
                records.append((story, metric, self.perf_session, self.run.id, list(samples), self.out))
                return os.path.join(self.out, f"{story}.ndjson")

            def stop(self):
                pass

        real_session_app = ib.session_app

        def session_app(app_class, app_path, out, session, env, runs=None):
            if session == "light":
                raise RuntimeError("no launch")
            return real_session_app(FakeBench, app_path, out, session, env, runs)

        def start_session(app, agents, spec, entry):
            raise ib.SessionShapeError("refused after the launch")

        import bench_launch
        with tempfile.TemporaryDirectory() as folder:
            app_path = bundle(folder, debug=False)
            out = os.path.join(folder, "out")
            with unittest.mock.patch.object(bench_launch, "seed_hang_report_consent", lambda _app: ""), \
                    unittest.mock.patch.multiple(ib, session_app=session_app, start_session=start_session,
                                                 fresh_session=lambda _app: {}, host_facts=lambda: {"host": "h", "macos": "26"}), \
                    contextlib.redirect_stdout(io.StringIO()) as printed, self.assertRaises(SystemExit):
                ib.main(["--app", app_path, "--sessions", "stress,light,stress-static", "--out", out])
            with open(os.path.join(out, "idle-budget.json")) as handle:
                report = json.load(handle)
        self.assertEqual(report["session_exits"], {"stress": 1, "light": 1, "stress-static": 1})
        self.assertIn("IDLE-BUDGET-SESSION-FAILED light exit=1 RuntimeError: no launch", printed.getvalue())
        self.assertNotIn("results_v1", report["sessions"]["light"])
        self.assertEqual([app.perf_session for app in made], ["stress", "stress"])
        self.assertEqual([app.out for app in made], [out, out])
        self.assertEqual([app.log_name for app in made], [os.path.join("stress", "app.log"),
                                                         os.path.join("stress-static", "app.log")])
        self.assertIs(made[0].run, made[1].run)
        self.assertEqual(sorted((story, metric, session, samples) for story, metric, session, _run, samples, _out
                                in records),
                         [("idle-budget-stress", "idle_budget.stress-static.failed", "stress", [1]),
                          ("idle-budget-stress", "idle_budget.stress.failed", "stress", [1])])
        self.assertEqual({run for *_head, run, _samples, _out in records}, {made[0].run.id})

    def test_a_results_writer_that_raises_does_not_abort(self):
        app = types.SimpleNamespace(perf_session="stress", run=None,
                                    record=lambda *a, **k: (_ for _ in ()).throw(OSError("disk full")))
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            result = ib.record_session(app, "stress", {}, {}, failed=True)
        self.assertEqual(result, {"error": "OSError: disk full"})
        self.assertIn("IDLE-BUDGET-RESULTS-FAILED stress: OSError: disk full", printed.getvalue())


if __name__ == "__main__":
    unittest.main()
