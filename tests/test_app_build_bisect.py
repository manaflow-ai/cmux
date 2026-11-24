#!/usr/bin/env python3
"""The build bisect (scripts/ci/app_build_bisect.py): feed parsing, the probe order, skips, the build step and the
verdict, with the probe faked."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
bisect_mod = sys.modules.get("app_build_bisect")
if bisect_mod is None:
    spec = importlib.util.spec_from_file_location("app_build_bisect", ROOT / "scripts/ci/app_build_bisect.py")
    bisect_mod = importlib.util.module_from_spec(spec)
    sys.modules["app_build_bisect"] = bisect_mod
    spec.loader.exec_module(bisect_mod)
b = bisect_mod

FEED = """<rss><channel>
<item><title>1.0.0-nightly.4495068035301</title><pubDate>Sat, 21 Nov 2026 13:44:08 -0800</pubDate>
<sparkle:version>4495068035301</sparkle:version>
<enclosure sparkle:deltaFrom="4494208705801" /><enclosure sparkle:deltaFrom="4493799092601" />
<cmux:sourceCommit xmlns:cmux="x">""" + "d" * 40 + """</cmux:sourceCommit></item>
<item><sparkle:version>4494208705801</sparkle:version></item>
</channel></rss>"""


def rng(n: int, built=()) -> list[dict]:
    return [{"sha": f"{i:040x}", "pr": 100 + i, "author": "a", "subject": f"c{i} (#{100 + i})",
             **({"build": str(i)} if i in built else {})} for i in range(n)]


def state(n: int, built=()) -> dict:
    return {"good": {"commit": "f" * 40, "build": "1"}, "bad": {"commit": f"{n - 1:040x}", "build": "2"},
            "range": rng(n, built), "results": {}, "log": []}


class Feed(unittest.TestCase):
    def test_items(self):
        items = b.feed_items(FEED)
        self.assertEqual(items[0]["build"], "4495068035301")
        self.assertEqual(items[0]["commit"], "d" * 40)
        self.assertEqual(items[0]["delta_from"], ["4494208705801", "4493799092601"])
        self.assertIsNone(items[1]["commit"])


class Bisect(unittest.TestCase):
    def run_with(self, st, first_bad, skips=(), build_cmd=None, built_ok=()):
        calls = []

        def fake(host, cmd, timeout):
            calls.append(cmd)
            if cmd.startswith("build "):
                return (0, "") if cmd.split()[1] in built_ok else (1, "")
            sha = cmd.split()[1]
            i = int(sha, 16)
            if sha in skips and sha not in st.get("built", []):
                return 125, ""
            return (1 if i >= first_bad else 0), ""

        with mock.patch.object(b, "run_on", side_effect=fake):
            v = b.bisect(st, "probe {sha}", None, build_cmd, 20, lambda s: None)
        return v, calls

    def test_finds_culprit_in_log_steps(self):
        v, calls = self.run_with(state(40), 23)
        self.assertEqual(v["kind"], "culprit")
        self.assertEqual(v["culprit"]["pr"], 123)
        self.assertLessEqual(len(calls), 7)

    def test_built_commits_first(self):
        st = state(40, built=(5, 30))
        _, calls = self.run_with(st, 23)
        self.assertIn(f"{30:040x}", calls[0] + calls[1])

    def test_skips_leave_a_range(self):
        skips = {f"{i:040x}" for i in range(20, 26)}
        v, _ = self.run_with(state(40), 23, skips=skips)
        self.assertEqual(v["kind"], "range")
        self.assertIn("no published build", v["why"])
        self.assertTrue(all(19 <= int(c["sha"], 16) <= 26 for c in v["candidates"]))

    def test_build_cmd_narrows(self):
        skips = {f"{i:040x}" for i in range(20, 26)}
        v, calls = self.run_with(state(40), 23, skips=skips, build_cmd="build {sha}", built_ok=skips)
        self.assertEqual(v["kind"], "culprit")
        self.assertEqual(int(v["culprit"]["sha"], 16), 23)
        self.assertTrue(any(c.startswith("build ") for c in calls))

    def test_broken_probe_stops(self):
        st = state(10)
        with mock.patch.object(b, "run_on", return_value=(255, "ssh failed")):
            v = b.bisect(st, "probe {sha}", "host", None, 20, lambda s: None)
        self.assertEqual(v["kind"], "range")
        self.assertIn("probe broke", st["stopped"])

    def test_text_names_owner_rule(self):
        v, _ = self.run_with(state(8), 3)
        self.assertIn("#103", b.text(v))
        self.assertIn("reverts it or fixes forward", b.text(v))


spec = importlib.util.spec_from_file_location("app_bisect_pane_params_probe",
                                              ROOT / "scripts/ci/app-bisect-pane-params-probe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

PAGE = """
export function initializeParams() {
  return {
    protocolVersion: 1,
    clientInfo: { name: "x", version: "1" }, // a comment, with a comma
    _meta: { acpmux: { peerRowBatches: true } },
  };
}
await this.request("initialize", initializeParams(), 5);
await this.request("session/new", { cwd, ...extra, _meta: { acpmux: { harness: "claude" } } });
"""


class PaneParamsProbe(unittest.TestCase):
    def test_helper_and_inline_literals(self):
        self.assertEqual(set(probe.sent(PAGE, "initialize")[0]), {"protocolVersion", "clientInfo", "_meta"})
        self.assertEqual(set(probe.sent(PAGE, "session/new")[0]), {"cwd", "_meta"})

    def test_meta_keys(self):
        meta = probe.sent(PAGE, "initialize")[0]["_meta"]
        inner = probe.literal(meta, meta.index("{", meta.index("acpmux")))
        self.assertEqual(set(probe.top_keys(inner)), {"peerRowBatches"})


if __name__ == "__main__":
    unittest.main()
