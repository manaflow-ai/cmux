#!/usr/bin/env bash
# chromium_host_baseline.py (task p01-process-005): the per-role budgets sum to the program targets, perf-lead.md
# holds the same budget table, and a canned chromium-host-bench.py --baseline result becomes one section 5 row per
# number and session. No app, no Mac.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you change the budgets or the bench's result.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/../chromium_host_baseline.py"
lead="$here/../../../plans/cmux-next/perf-lead.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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
  "light": {"tabs10": {"chromium_tabs": 10, "settle_s": 35, "wakes": {"app_wakeups_per_s": 61.2, "ledger_per_s": 9.5, "cef_pump_per_s": 8.1,
                                                                    "by_kind_per_s": {"app": 61.2, "cef-renderer": 4.0}}}},
  "stress": {"idle": {"settle_s": 35, "chromium_tabs": null, "wakes": {"app_wakeups_per_s": 140.0, "ledger_per_s": 30.0, "cef_pump_per_s": 22.0}},
             "inproc": {"error": "the probe never loaded: {}"}}},
 "baseline": {
  "census_light": {"terminals": 2, "census": {"roles": {"app": {"processes": 1, "threads": 60, "peak_threads": 64, "rss_mb": 300.0},
                                                         "daemon": {"processes": 1, "threads": 30, "peak_threads": 31, "rss_mb": 40.0},
                                                         "terminal_host": {"processes": 2, "threads": 18, "peak_threads": 18, "rss_mb": 21.0}}}},
  "census_heavy": {"terminals": 172, "census": {"per_hidden_terminal_mb": 6.9,
                                                "roles": {"app": {"processes": 1, "threads": 91, "peak_threads": 95, "rss_mb": 810.0},
                                                          "daemon": {"processes": 1, "threads": 797, "peak_threads": 801, "rss_mb": 295.0},
                                                          "terminal_host": {"processes": 172, "threads": 1548, "peak_threads": 1548, "rss_mb": 1806.0}}}}}}
JSON
python3 -I - "$tool" "$tmp/result.json" > "$tmp/out.json" <<'PY'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("baseline", sys.argv[1])
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)
result = json.load(open(sys.argv[2]))
result["baseline"]["memory_split"] = baseline.memory_split(result["baseline"]["census_light"], result["baseline"]["census_heavy"])
nothing = baseline.memory_split({"terminals": 3, "census": {}}, {"terminals": 3, "census": {}})
missing = baseline.memory_split({"error": "process-model-census.py is not in this checkout"}, {"terminals": 3})
json.dump({"rows": baseline.rows(result, "2026-10-26"), "split": result["baseline"]["memory_split"],
           "nothing": nothing, "missing": missing, "sums": baseline.check_sums()}, sys.stdout)
PY
check() { # <python expression over `out`> <message>
  python3 -I -c "import json, sys; out = json.load(open(sys.argv[1])); sys.exit(0 if ($1) else 1)" "$tmp/out.json" || fail "$2"
}
check 'out["sums"] == []' "a budget group does not sum to its target"
check 'len(out["rows"]) == 13' "not 13 rows"
check 'all("cmux20-bench, macOS 27.0.1, 120 Hz, Debug" in r and "0123456789abcdef0123456789abcdef01234567" in r for r in out["rows"])' \
  "a row lacks the host, macOS, Hz or sha"
check 'any("pump share (light)" in r and "0.09 % of main-thread time" in r and "0.28 %" in r for r in out["rows"])' "pump share row"
check 'any("pump share (STRESS)" in r and "not measured in this run" in r for r in out["rows"])' "an unmeasured number must say so"
check 'any("10 Chromium tabs (light)" in r and "app 61.2/s kernel wakeups" in r and "cef-renderer 4/s" in r for r in out["rows"])' "10-tab wakes row"
check 'any("in process (light)" in r and "key 9.1/12.4/15/18.2 ms (p50/p95/p99/max, n 60)" in r for r in out["rows"])' "key to paint row"
check 'any("key and click to paint, in process (STRESS)" in r and "the probe never loaded" in r for r in out["rows"])' "STRESS error row"
check 'any("stall 9a, in process (light)" in r and "31 long frames, pass False" in r for r in out["rows"])' "stall row"
check 'any("process census (heavy)" in r and "terminal_host 172 proc / 1548 thr" in r for r in out["rows"])' "census heavy row"
# 170 terminals added: terminal_host (1806 - 21) / 170 = 10.5, daemon 255 / 170 = 1.5, app 510 / 170 = 3.0.
check 'out["split"]["per_role_mb"] == {"app": 3.0, "daemon": 1.5, "terminal_host": 10.5} and out["split"]["terminals_added"] == 170' \
  "memory split per role"
check 'any("per-role memory split" in r and "census 6.9 MB" in r and "terminal_host 10.5 MB" in r for r in out["rows"])' "split row"
check '"adds no terminals" in out["nothing"]["error"]' "a heavy session with no more terminals must be refused"
check 'out["missing"]["error"].startswith("census light: process-model-census.py")' "a missing census must name itself"
echo "chromium-host-baseline tests: ok"
