#!/usr/bin/env bash
# chromium_host_baseline.py and chromium-host-bench.py --baseline: the per-role budgets sum to
# the program targets, perf-lead.md holds the same budget table, a canned bench result becomes one section 5 row per
# number and session, and the bench's own baseline steps (census argv, per-kind wake rates, the 10-tab idle
# scenarios, the probe's tab binding) run against a fake app socket and a fake census tool. No app, no Mac.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change the budgets, the bench or its result.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/../chromium_host_baseline.py"
bench="$here/../chromium-host-bench.py"
lead="$here/../../../plans/cmux-next/perf-lead.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

python3 -I -m py_compile "$tool" "$bench" || fail "a module does not compile"

# 1. The budgets sum to their targets and perf-lead.md has the table --budgets prints.
python3 -I "$tool" --check "$lead" || fail "perf-lead.md budget table or the budget sums are wrong"
python3 -I "$tool" --budgets | grep -q '| holder | PTY master' || fail "--budgets prints no holder row"

# 2. A changed budget in perf-lead.md is refused.
sed 's/| 0.6 MB |/| 0.7 MB |/' "$lead" > "$tmp/perf-lead.md"
cmp -s "$lead" "$tmp/perf-lead.md" && fail "the fixture edit did not change the budget table"
if python3 -I "$tool" --check "$tmp/perf-lead.md" 2>"$tmp/err"; then fail "--check passed a changed budget table"; fi
grep -q 'is not the one --budgets prints' "$tmp/err" || fail "--check did not say why: $(cat "$tmp/err")"

# 3. Rows from a canned result: every number has a light and a STRESS (or heavy) row with host, macOS, Hz and sha.
cat > "$tmp/result.json" <<'JSON'
{"build": "Debug", "refresh_hz": 120.0,
 "host": {"name": "cmux20-bench", "macos": "27.0.1", "sha": "0123456789abcdef0123456789abcdef01234567"},
 "modes": {
  "inproc": {"key_to_paint_ms": {"n": 60, "p50": 9.1, "p95": 12.4, "p99": 15.0, "max": 18.2},
             "click_to_paint_ms": {"n": 60, "p50": 8.0, "p95": 11.0, "p99": 14.0, "max": 16.0},
             "stall": {"stall_ms": 50, "every_ms": 100, "stalls": 30, "raf_ms": {"n": 300, "p50": 8.33, "p95": 50.1, "p99": 58.0, "max": 60.2},
                       "long_frames": 31, "pass": false},
             "pump_share": {"light": {"idle": {"share": 0.0009, "wakes": {"cef_pump_per_s": 3.3, "ledger_per_s": 3.7}},
                                      "scroll": {"share": 0.0028, "wakes": {"cef_pump_per_s": 31.4, "ledger_per_s": 31.6}}}}}},
 "sessions": {
  "light": {"tabs10": {"chromium_tabs": 10, "browser_tabs": 10, "settle_s": 35, "scenarios": {
              "app_visible": {"wakes": {"app_wakeups_per_s": 61.2, "ledger_per_s": 9.5, "cef_pump_per_s": 8.1,
                                        "by_kind_per_s": {"app": 61.2, "cef-renderer": 4.0}}},
              "workspace_hidden": {"wakes": {"app_wakeups_per_s": 30.0, "ledger_per_s": 4.0, "cef_pump_per_s": 3.0}},
              "app_hidden": {"error": "showHideAllWindows: refused"}}}},
  "stress": {"idle": {"settle_s": 35, "browser_tabs": 62, "scenarios": {
               "app_visible": {"wakes": {"app_wakeups_per_s": 140.0, "ledger_per_s": 30.0, "cef_pump_per_s": 22.0}},
               "workspace_hidden": {"wakes": {"app_wakeups_per_s": 90.0, "ledger_per_s": 20.0, "cef_pump_per_s": 15.0}},
               "app_hidden": {"wakes": {"app_wakeups_per_s": 70.0, "ledger_per_s": 12.0, "cef_pump_per_s": 11.0}}}},
             "inproc": {"error": "the probe never loaded: {}"},
             "helper": {"key_to_paint_ms": {"n": 60, "p50": 10.0, "p95": 13.5, "p99": 16.0, "max": 20.0},
                        "stall": {"stall_ms": 50, "every_ms": 100, "stalls": 30, "raf_ms": {"n": 400, "p50": 8.33, "p95": 8.5, "p99": 9.0, "max": 9.9},
                                  "long_frames": 0, "pass": true}}}},
 "baseline": {
  "census_light": {"census": {"session": {"terminals": 3, "hidden_terminals": 2},
                              "roles": {"app": {"processes": 1, "threads": 60, "peak_threads": 64, "rss_mb": 300.0, "unique_mb": 290.0},
                                        "daemon": {"processes": 1, "threads": 30, "peak_threads": 31, "rss_mb": 40.0, "unique_mb": 31.0},
                                        "terminal_host": {"processes": 2, "threads": 18, "peak_threads": 18, "rss_mb": 21.0, "unique_mb": 16.0}}}},
  "census_heavy": {"census": {"session": {"terminals": 174, "hidden_terminals": 172}, "per_hidden_terminal_mb": 15.0,
                              "per_hidden_terminal_basis": "all roles, growth over the baseline (2 hidden terminals)",
                              "totals": {"unique_mb": 2890.0},
                              "roles": {"app": {"processes": 1, "threads": 91, "peak_threads": 95, "rss_mb": 810.0, "private_mb": 790.0, "unique_mb": 800.0},
                                        "daemon": {"processes": 1, "threads": 797, "peak_threads": 801, "rss_mb": 295.0, "private_mb": 285.0, "unique_mb": 370.0},
                                        "terminal_host": {"processes": 172, "threads": 1548, "peak_threads": 1548, "rss_mb": 1806.0, "private_mb": 1715.0, "unique_mb": 1800.0}}}}}}
JSON
# The census of the session just before the heavy one (the heavy census's --baseline).
cat > "$tmp/before.json" <<'JSON'
{"census": {"session": {"terminals": 4, "hidden_terminals": 2}, "totals": {"unique_mb": 340.0},
            "roles": {"app": {"processes": 1, "rss_mb": 300.0, "private_mb": 280.0},
                      "daemon": {"processes": 1, "rss_mb": 40.0, "private_mb": 30.0},
                      "terminal_host": {"processes": 2, "rss_mb": 21.0, "private_mb": 15.0},
                      "holder": {"processes": 0, "rss_mb": 0.0, "private_mb": null}}}}
JSON
python3 -I - "$tool" "$tmp/result.json" "$tmp/before.json" > "$tmp/out.json" <<'PY'
import copy, importlib.util, json, sys
spec = importlib.util.spec_from_file_location("baseline", sys.argv[1])
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)
result = json.load(open(sys.argv[2]))
before = json.load(open(sys.argv[3]))
heavy = result["baseline"]["census_heavy"]
result["baseline"]["memory_split"] = baseline.memory_split(before, heavy)
# Without the census's region walk (no private memory): RSS growth, labelled as such.
rss_only = copy.deepcopy(heavy)
for role in rss_only["census"]["roles"].values():
    role.pop("private_mb")
same = {"census": {"session": {"hidden_terminals": 3}}}
json.dump({"rows": baseline.rows(result, "2026-10-26"), "split": result["baseline"]["memory_split"],
           "rss": baseline.memory_split(before, rss_only),
           "nothing": baseline.memory_split(same, same),
           "uncounted": baseline.memory_split({"census": {}}, heavy),
           "missing": baseline.memory_split({"error": "process-model-census.py is not in this checkout"}, heavy),
           "sums": baseline.check_sums()}, sys.stdout)
PY
check() { # <file> <python expression over `out`> <message>
  python3 -I -c "import json, sys; out = json.load(open(sys.argv[1])); sys.exit(0 if ($2) else 1)" "$1" || fail "$3"
}
c3() { check "$tmp/out.json" "$@"; }
c3 'out["sums"] == []' "a budget group does not sum to its target"
c3 'len(out["rows"]) == 15' "not 15 rows"
c3 'all("cmux20-bench, macOS 27.0.1, 120 Hz, Debug" in r and "0123456789abcdef0123456789abcdef01234567" in r for r in out["rows"])' \
  "a row lacks the host, macOS, Hz or sha"
c3 'any("pump share (light)" in r and "0.09 % of main-thread time" in r and "0.28 %" in r for r in out["rows"])' "pump share row"
c3 'any("pump share (STRESS)" in r and "not measured in this run" in r for r in out["rows"])' "an unmeasured number must say so"
c3 'any("10 Chromium tabs (light)" in r and "10 Chromium tabs, 35 s settle" in r and "app visible: app 61.2/s kernel wakeups" in r
        and "cef-renderer 4/s" in r and "workspace hidden: app 30/s" in r and "app hidden: showHideAllWindows: refused" in r
        and "main thread" in r for r in out["rows"])' "10-tab wakes row, three scenarios"
c3 'any("idle wakes, the STRESS tab mix (STRESS)" in r and "62 browser tabs (Chromium and WebKit" in r and "None" not in r
        and "app hidden: app 70/s" in r for r in out["rows"])' "STRESS idle row: its tab count, three scenarios, no None"
c3 'not any("10 Chromium tabs (STRESS)" in r for r in out["rows"])' "the STRESS idle row must not claim 10 Chromium tabs"
c3 'any("in process (light)" in r and "key 9.1/12.4/15/18.2 ms (p50/p95/p99/max, n 60)" in r for r in out["rows"])' "key to paint row"
c3 'any("key and click to paint, in process (STRESS)" in r and "the probe never loaded" in r for r in out["rows"])' "STRESS error row"
c3 'any("key and click to paint, Chromium Host (STRESS)" in r and "key 10/13.5/16/20 ms" in r for r in out["rows"])' "host STRESS key row"
c3 'any("stall 9a, Chromium Host (STRESS)" in r and "0 long frames, pass True" in r for r in out["rows"])' "host STRESS stall row"
c3 'any("stall 9a, in process (light)" in r and "31 long frames, pass False" in r for r in out["rows"])' "stall row"
c3 'any("process census (heavy)" in r and "174 terminals (172 hidden)" in r and "terminal_host 172 proc / 1548 thr" in r
        and "1800 MB unique" in r for r in out["rows"])' "census heavy row"
# 170 hidden terminals added: app (790 - 280) / 170 = 3.0, daemon 255 / 170 = 1.5, terminal_host 1700 / 170 = 10.0;
# shared: (2890 - 2790) - (340 - 325) = 85, / 170 = 0.5. The parts sum to the unique growth, 2550 / 170 = 15.
c3 'out["split"]["per_role_mb"] == {"app": 3.0, "daemon": 1.5, "terminal_host": 10.0} and out["split"]["terminals_added"] == 170' \
  "memory split per role (private growth)"
c3 'out["split"]["shared_once_mb"] == 0.5 and out["split"]["basis"].startswith("private memory per role")' "shared mappings counted once"
c3 'abs(sum(out["split"]["per_role_mb"].values()) + out["split"]["shared_once_mb"] - 15.0) < 1e-9' "the split must sum to the unique growth"
c3 'any("per-role memory split" in r and "private memory per role, shared mappings counted once" in r and "terminal_host 10 MB" in r
        and "counted once, 0.5 MB" in r and "Census per hidden terminal 15 MB (all roles" in r
        and "does not split the ring" in r for r in out["rows"])' "split row"
c3 'out["rss"]["basis"].startswith("RSS growth") and out["rss"]["shared_once_mb"] is None
    and out["rss"]["per_role_mb"]["terminal_host"] == round((1806 - 21) / 170, 3)' "the RSS fallback must say so"
c3 '"adds no hidden terminals" in out["nothing"]["error"]' "a heavy session with no more hidden terminals must be refused"
c3 '"no hidden terminal count" in out["uncounted"]["error"]' "a census with no session counts must be refused"
c3 'out["missing"]["error"].startswith("census before heavy: process-model-census.py")' "a missing census must name itself"

# 4. The bench's baseline steps against a fake app socket and a fake census tool.
cat > "$tmp/fake-census.py" <<'PY'
import json, sys
argv = sys.argv[1:]
with open(sys.argv[0] + ".argv", "a") as log:
    log.write(json.dumps(argv) + "\n")
if "--session" in argv and argv[argv.index("--session") + 1] == "broken":
    print("process-model-census: no running app for tag t1", file=sys.stderr)
    sys.exit(2)
out = argv[argv.index("--out") + 1]
json.dump({"census": 1, "session": {"terminals": 5, "hidden_terminals": 4}, "roles": {}}, open(out, "w"))
PY
python3 -I - "$bench" "$tmp" > "$tmp/bench.json" <<'PY'
import importlib.util, json, os, sys, types
bench_path, tmp = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("chromium_host_bench", bench_path)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
bench.opts = bench.parse(["--app", f"{tmp}/cmux DEV t1.app", "--out", f"{tmp}/bench-out", "--baseline", "--stress"])
os.makedirs(bench.opts.out, exist_ok=True)
bench.opts.idle_settle_seconds = 0
bench.opts.pump_seconds = 0.01
out = {}

# census(): the running app by tag and socket, never --app; its own JSON.
bench.CENSUS_TOOL = f"{tmp}/fake-census.py"
app = types.SimpleNamespace(tag="t1", socket="/tmp/cmux-debug-t1.sock")
out["census_heavy"] = bench.census(app, "heavy", session="heavy", baseline=f"{tmp}/before.json")
out["census_plain"] = bench.census(app, "before-heavy")
out["census_broken"] = bench.census(app, "broken", session="broken")
out["census_argv"] = [json.loads(line) for line in open(f"{tmp}/fake-census.py.argv")]

# wake_rates(): per process kind, over the processes alive at both samples.
before = {"app_wakeups": 100, "app_cpu_ms": 0.0, "ledger": 10, "cef_pump": 5,
          "by_pid": {1: ("app", 100), 2: ("cef-renderer", 10), 3: ("daemon", 5), 5: ("cef-renderer", 0)}}
after = {"app_wakeups": 200, "app_cpu_ms": 100.0, "ledger": 30, "cef_pump": 15,
         "by_pid": {1: ("app", 200), 2: ("cef-renderer", 30), 4: ("daemon", 50), 5: ("cef-renderer", 10)}}
out["rates"] = bench.wake_rates(before, after, 10.0)


class FakeApp:
    """A topology of workspaces > one screen > one pane > tabs, with the actions the baseline sends."""
    def __init__(self):
        self.workspaces = {"w1": [{"id": "t-term", "kind": "terminal"}, {"id": "t-probe", "kind": "browser"}]}
        self.focused = "t-probe"
        self.queries = {"t-probe": "?probe=light"}
        self.calls, self.evals, self.hidden, self.wakes, self.serial = [], [], [], 0, 0
        self.pending, self.lag = None, 0  # focus reaches a new tab one eval late, as a slow open does

    def topology(self):
        return {"workspaces": [{"id": w, "screens": [{"panes": [{"tabs": [dict(t) for t in tabs]}]}]}
                               for w, tabs in self.workspaces.items()]}

    def __call__(self, method, params=None, timeout=None):
        params = params or {}
        self.calls.append((method, params))
        if method == "snapshot.get":
            return {"topology": self.topology()}
        if method == "debug.wakeups":
            self.wakes += 100
            return {"processes": [{"kind": "app", "pid": 1, "wakeups": self.wakes, "cpu_ms": 0.0},
                                  {"kind": "cef-renderer", "pid": 2, "wakeups": self.wakes // 10}],
                    "ledger": [{"owner": "CEFMessagePump", "count": self.wakes // 50}]}
        if method == "browser.page.eval":
            if not params.get("tab") and self.pending:
                if self.lag:
                    self.lag -= 1
                else:
                    self.focused, self.pending = self.pending, None
            tab = params.get("tab") or self.focused
            self.evals.append((params.get("tab"), params["script"]))
            script = params["script"]
            if "location.search ===" in script:
                return {"tab": tab, "value": f"'{self.queries.get(tab)}'" in script}
            return {"tab": tab, "value": "probe {}" if script == "document.title" else None}
        if method != "action.run":
            return {}
        name = params["action"]
        self.serial += 1
        if name == "openBrowser.chromium":
            tab = f"t-new{self.serial}"
            self.workspaces["w1"].append({"id": tab, "kind": "browser"})
            url = params["args"]["url"]
            self.queries[tab] = url[url.index("?"):] if "?" in url else ""
            self.pending, self.lag = tab, 1
        elif name == "closeTab":
            for tabs in self.workspaces.values():
                tabs[:] = [t for t in tabs if f"tab:{t['id']}" != params["target"]]
        elif name == "newTab":
            self.workspaces[f"w-new{self.serial}"] = [{"id": f"t-ws{self.serial}", "kind": "terminal"}]
        elif name == "closeWorkspace":
            self.workspaces.pop(params["target"].split(":", 1)[1], None)
        elif name == "showHideAllWindows":
            self.hidden.append(params["args"]["hidden"])
        return {"ok": True}


fake = FakeApp()
out["tabs10"] = bench.tabs10_wakes(fake, "file:///probe.html")
out["after_tabs10"] = fake.topology()
out["hidden_calls"] = fake.hidden

# open_inproc_probe(): binds every eval to the tab it opened, not the light probe tab that answered first.
probe = FakeApp()
page, click_point, tab = bench.open_inproc_probe(probe, "file:///probe.html", "stress")
probe.evals.clear()
page("document.title")
click_point("b")
out["probe_tab"] = tab
out["probe_evals"] = [t for t, _ in probe.evals]
json.dump(out, sys.stdout)
PY
c4() { check "$tmp/bench.json" "$@"; }
c4 'all("--app" not in argv and argv[argv.index("--tag") + 1] == "t1" and argv[argv.index("--socket") + 1] == "/tmp/cmux-debug-t1.sock"
        for argv in out["census_argv"])' "the census must target the running app by tag and socket, never --app"
c4 'out["census_argv"][0][out["census_argv"][0].index("--session") + 1] == "heavy"
    and out["census_argv"][0][out["census_argv"][0].index("--baseline") + 1].endswith("/before.json")' "heavy census: --session heavy --baseline"
c4 '"--session" not in out["census_argv"][1] and "--baseline" not in out["census_argv"][1]' "the before-heavy census must not build a session"
c4 'out["census_heavy"]["census"]["session"]["hidden_terminals"] == 4 and out["census_heavy"]["path"].endswith("census-heavy.json")' \
  "census() must return the census's own JSON and its path"
c4 'out["census_broken"]["error"].startswith("census broken exit 2: process-model-census: no running app")' "a failed census must say why"
c4 'out["rates"]["by_kind_per_s"] == {"app": 10.0, "cef-renderer": 3.0}' "per-kind rates over the processes alive at both samples"
c4 'out["rates"]["app_wakeups_per_s"] == 10.0 and out["rates"]["cef_pump_share_of_ledger"] == 0.5' "app and pump rates"
c4 'out["tabs10"]["chromium_tabs"] == 10 and out["tabs10"]["browser_tabs"] == 10
    and all("wakes" in out["tabs10"]["scenarios"][k] for k in ("app_visible", "workspace_hidden", "app_hidden"))' \
  "10-tab idle: three scenarios measured"
c4 'out["tabs10"]["scenarios"]["app_visible"]["wakes"]["by_kind_per_s"]["cef-renderer"] > 0' "10-tab idle: per-kind wakes"
c4 'out["hidden_calls"] == [True, False]' "the app is hidden for its scenario and shown after"
c4 '[w["id"] for w in out["after_tabs10"]["workspaces"]] == ["w1"]
    and [t["id"] for t in out["after_tabs10"]["workspaces"][0]["screens"][0]["panes"][0]["tabs"]] == ["t-term", "t-probe"]' \
  "the 9 extra tabs and the hidden-workspace scenario's workspace are closed after"
c4 'out["probe_tab"].startswith("t-new") and out["probe_evals"] and all(t == out["probe_tab"] for t in out["probe_evals"])' \
  "every eval after open_inproc_probe must go to the tab it opened"

# 5. Tabs in the host: only --modes profiles or tcc moves Chromium tabs to the host, in a
# launch without the in-process rows; an in-process row of a launch whose tabs run in the host says not_run.
python3 -I - "$bench" "$tmp" > "$tmp/host-tabs.json" <<'PY'
import contextlib, importlib.util, io, json, sys
bench_path, tmp = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("chromium_host_bench", bench_path)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
out = {"default": bench.launch_tunables("inproc,helper".split(","))["values"],
       "profiles": bench.launch_tunables("helper,profiles".split(","))["values"],
       "tcc": bench.launch_tunables("tcc,helper".split(","))["values"], "refused": []}
for extra in (["--modes", "inproc,profiles"], ["--modes", "profiles", "--baseline"], ["--modes", "profiles", "--stress"],
              ["--modes", "inproc,tcc"]):
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            bench.parse(["--app", f"{tmp}/cmux DEV t1.app", "--out", f"{tmp}/o", *extra])
    except SystemExit:
        out["refused"].append(extra)
bench.parse(["--app", f"{tmp}/cmux DEV t1.app", "--out", f"{tmp}/o", "--modes", "helper,profiles"])
calls = []
def host_rpc(method, params=None, timeout=None):
    calls.append(method)
    return {"backend": "host"} if method == "debug.cef" else {}
out["inproc_tab"] = bench.run_inproc(host_rpc, "file:///probe.html")
out["inproc_row"] = bench.RESULT["modes"]["inproc"]
out["tabs10"] = bench.tabs10_wakes(host_rpc, "file:///probe.html")
out["calls"] = calls
json.dump(out, sys.stdout)
PY
c5() { check "$tmp/host-tabs.json" "$@"; }
c5 'out["default"]["browserHost.tabs"] is False and out["default"]["browserHost.helper"] is True' \
  "the default run must keep Chromium tabs in process"
c5 'out["profiles"]["browserHost.tabs"] is True' "--modes profiles must move Chromium tabs to the host"
c5 'out["tcc"]["browserHost.tabs"] is True' "--modes tcc must move Chromium tabs to the host (its rows need backend host)"
c5 'len(out["refused"]) == 4' "profiles with inproc, --baseline or --stress, and tcc with inproc, must be refused: $(cat "$tmp/host-tabs.json")"
c5 'out["inproc_tab"] is None and "Chromium Host" in out["inproc_row"]["not_run"]' "inproc in host mode must say not_run"
c5 '"Chromium Host" in out["tabs10"]["not_run"]' "tabs10 in host mode must say not_run"
c5 'set(out["calls"]) == {"debug.cef"}' "a not_run row must open no tab"
echo "chromium-host-baseline tests: ok"
