#!/usr/bin/env python3
"""graceful-swap-fleet.py's saves still land: each EDITS anchor is in its file exactly once. When a page drops the
text a save edits (Settings lost its title on 2026-11-23), every film of that series showed nothing and read as a
missed hot swap. Reads EDITS from the source, so the test needs none of the fleet script's imports."""
import ast
import importlib.util
import json
import os
import pathlib
import re
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
SOURCE = open(os.path.join(HERE, "..", "graceful-swap-fleet.py"), encoding="utf-8").read()


def edits():
    block = re.search(r"^EDITS = (\{.*?^\})", SOURCE, re.S | re.M)
    assert block, "graceful-swap-fleet.py has no EDITS block"
    return ast.literal_eval(block.group(1))


class Anchors(unittest.TestCase):
    def test_each_anchor_is_in_its_file_once(self):
        for kind, (rel, plain, marked) in edits().items():
            with self.subTest(kind=kind):
                text = open(os.path.join(ROOT, rel), encoding="utf-8").read()
                self.assertEqual(text.count(plain), 1, f"{kind}: {rel} should hold {plain!r} once")
                self.assertNotIn(marked, text, f"{kind}: {rel} is left with the save's mark")



def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "..", rel))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class InPage(unittest.TestCase):
    """inpage(): the series' saves on the pages' own clock, from the dev server's hot-swap-timing.ndjson."""

    def test_summarizes_this_series_rows_per_page_without_the_warm_run(self):
        fleet = load("gsw_fleet", "graceful-swap-fleet.py")
        fleet.GS = load("gsw", "graceful-swap.py")
        out = pathlib.Path(tempfile.mkdtemp())
        scenario = object.__new__(fleet.Scenario)
        scenario.out, scenario.scratch, scenario.results = out, out / "scratch", {"latency": {}}
        scenario.timing_log.parent.mkdir(parents=True)
        rel = fleet.EDITS["composer"][0]
        rows = [{"file": "/t/" + rel, "page": "cmux-agent://pane/?a", "total": t, "frame": 17} for t in (900, 40, 50, 60)]
        rows.append({"file": "/t/webviews/src/Other.tsx", "page": "cmux-agent://pane/?a", "total": 5})
        scenario.timing_log.write_text('{"file": "/t/%s", "total": 1}\n' % rel + "".join(json.dumps(r) + "\n" for r in rows))
        scenario.inpage("composer", "composer", since=1)
        page = json.loads((out / "latency" / "composer-inpage.json").read_text())["pages"]["cmux-agent://pane/?a"]
        self.assertEqual(page["n"], 3)
        self.assertEqual(page["total"], {"p50_ms": 50.0, "p95_ms": 60.0})
        self.assertEqual(page["frame"]["p95_ms"], 17.0)


class Summary(unittest.TestCase):
    """summary(): a film whose watched region never changed is a missed swap, not a 0 ms one."""

    def test_unchanged_region_is_missed_for_settled_ms(self):
        fleet = load("gsw_fleet", "graceful-swap-fleet.py")
        fleet.GS = load("gsw", "graceful-swap.py")
        out = pathlib.Path(tempfile.mkdtemp())
        scenario = object.__new__(fleet.Scenario)
        scenario.out, scenario.results = out, {"latency": {}}
        # step 8c6948cc's hidden series: two films changed, the rest stood still and read settled_ms 0.
        changed = {"changed_frames": 1, "first_change_ms": 56, "settled_ms": 56}
        still = {"changed_frames": 0, "first_change_ms": None, "settled_ms": 0}
        runs = [{"regions": {"unfocused": dict(changed), "sidebar": {"kept": True}}, "video": {"fps": 9.4}}]
        runs += [{"regions": {"unfocused": dict(still), "sidebar": {"kept": True}}, "video": {"fps": 9.4}} for _ in range(3)]
        scenario.summary("hidden", "hidden", "unfocused", ["sidebar"], runs, sample="settled_ms")
        region = json.loads((out / "latency" / "hidden-hidden.json").read_text())["regions"]["unfocused"]
        self.assertEqual(region["samples_ms"], [56.0])
        self.assertEqual((region["n"], region["missed"]), (1, 3))


if __name__ == "__main__":
    unittest.main()
