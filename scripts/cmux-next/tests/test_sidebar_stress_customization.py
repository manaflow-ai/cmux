#!/usr/bin/env python3
"""sidebar-stress-bench.py's customization scenarios (theme_scroll, custom_sections) against a fake app (no app).

What it checks, by counts, never a time:
- the customize manifest contributes exactly N sidebar sections, each with its own render export in main.js, and a
  save changes only the edited section's headline;
- theme_scroll reads each switch window's sidebar counters apart: work the fake app does on a switch shows in that
  window's delta and in the summed `list_reloads`, and the baseline gesture (no switch) shows none;
- the table has one row per scenario the results hold.
Run: python3 -I scripts/cmux-next/tests/test_sidebar_stress_customization.py"""
import importlib.util, json, os, re, sys, tempfile, types, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = tempfile.mkdtemp(prefix="sbstress-custom-test-")
_argv, _modules = sys.argv, {name: sys.modules.get(name) for name in ("bench_idle",)}
sys.argv = ["sidebar-stress-bench.py", "--app", "/nonexistent/cmux.app", "--tag", "unit", "--out", OUT, "--no-trace",
            "--theme-switches", "4", "--custom-sections", "1,10,50"]
sys.modules["bench_idle"] = types.SimpleNamespace(usage=lambda pid: (0, 0, 0))
try:
    spec = importlib.util.spec_from_file_location("sidebar_stress_bench", os.path.join(HERE, "..", "sidebar-stress-bench.py"))
    bench = importlib.util.module_from_spec(spec)
    source, last = open(spec.origin).read().rstrip(), "sys.exit(0 if main() else 1)"
    assert source.endswith(last), "the bench's last line is not its main() call"
    exec(compile(source[: -len(last)], spec.origin, "exec"), bench.__dict__)
finally:
    sys.argv = _argv
    for name, module in _modules.items():
        if module is None:
            sys.modules.pop(name, None)
        else:
            sys.modules[name] = module


class FakeApp:
    """debug.sidebar_perf counters that a theme switch bumps by `reload_per_switch` list reloads."""

    def __init__(self, reload_per_switch):
        self.counts = {k: 0 for k in bench.PERF_KEYS}
        self.reload_per_switch = reload_per_switch
        self.switches = []

    def rpc(self, method, params=None, timeout=60):
        if method == "debug.sidebar_perf":
            return dict(self.counts)
        if method == "settings.set":
            self.switches.append(params["value"])
            self.counts["list_reloads"] += self.reload_per_switch
            self.counts["rebuilds"] += self.reload_per_switch
            return {"ok": True}
        if method == "debug.frames":
            if params.get("action") == "stop":
                return {"running": True, "frames": 3, "intervals_ms": [16.7, 16.7, 33.4], "refresh_ms": 16.7, "max_ms": 33.4}
            return {}
        if method == "debug.mouse":
            return {}
        if method == "debug.sidebar_rows":
            return {"windows": [{"rows": []}]}
        return {}


def run_theme(reload_per_switch):
    app = FakeApp(reload_per_switch)
    with mock.patch.dict(bench.__dict__, {"rpc": app.rpc, "Trace": bench.Trace, "main_thread_profile": lambda p: None}), \
            mock.patch.object(bench.time, "sleep", lambda s: None):
        return app, bench.scenario_theme_scroll(1, 20)


class Customization(unittest.TestCase):
    def test_manifest_has_n_sections_each_rendered(self):
        for n in (1, 10, 50):
            manifest = bench.section_manifest(n)
            sections = manifest["contributes"]["sidebarSections"]
            self.assertEqual(len(sections), n)
            self.assertEqual(len({s["id"] for s in sections}), n)
            self.assertEqual(manifest["id"], "local/customize")
            script = bench.section_script(n, 0)
            self.assertEqual(sorted(re.findall(r"exportsByName\.(render\d+) =", script)), sorted(s["render"] for s in sections))

    def test_save_changes_only_the_edited_headline(self):
        before, after = bench.section_script(10, 0), bench.section_script(10, 3)
        self.assertIn(bench.section_headline(0, 3), after)
        self.assertNotIn(bench.section_headline(0, 3), before)
        changed = [a for a, b in zip(before.splitlines(), after.splitlines()) if a != b]
        self.assertEqual(len(changed), 1)

    def test_theme_switch_work_shows_per_window(self):
        app, out = run_theme(reload_per_switch=1)
        self.assertEqual(len(app.switches), 5)  # 4 switches, then the last theme restored
        self.assertEqual(out["switched"]["summary"]["perf_sum"]["list_reloads"], 4)
        self.assertEqual(out["switched"]["summary"]["perf_max_per_window"]["rebuilds"], 1)
        self.assertEqual(out["baseline"]["summary"]["perf_sum"]["list_reloads"], 0)
        self.assertEqual(len(out["switched"]["windows"]), 4)

    def test_theme_switch_with_no_work_counts_zero(self):
        _, out = run_theme(reload_per_switch=0)
        self.assertEqual(out["switched"]["summary"]["perf_sum"]["list_reloads"], 0)
        self.assertEqual(out["switched"]["summary"]["dropped_slots"], 4)  # one 2-refresh interval per window

    def test_table_rows(self):
        _, theme = run_theme(reload_per_switch=0)
        results = {"sizes": {"20": {"theme_scroll": theme, "switch": {"click_to_idle_ms": bench.percentiles([5, 6, 7])},
                                    "custom_sections": [{"sections": 50, "error": "0 of 50 section views mounted"}]}}}
        names = [r["scenario"] for r in bench.table(results)]
        self.assertEqual(names, ["switch", "theme_scroll.baseline", "theme_scroll.switched", "sections50"])


if __name__ == "__main__":
    unittest.main()
