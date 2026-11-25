#!/usr/bin/env python3
"""Tests for link-stats.py: python3 scripts/cmux-next/test_link_stats.py"""
import importlib.util
import json
import pathlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("link_stats", HERE / "link-stats.py")
ls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ls)


def line(**over):
    j = {"event": "link_stat", "v": 1, "kind": "phone", "transport": "wireguard", "path": "turn-tls", "reason": "first",
         "pings": 10, "lost": 1, "setupMs": 800, "rttN": 10, "rttP50": 40, "rttP95": 90, "rttMax": 120,
         "ingressColo": "SJC", "country": "US", "continent": "NA", "hubColo": "LAX"}
    j.update(over)
    return j


def event(j, where="source"):
    if where == "source":
        return {"source": j, "$metadata": {"id": "x"}}
    return {"$metadata": {"id": "x", "message": json.dumps(j)}}


class StatOf(unittest.TestCase):
    def test_reads_parsed_source_and_message_text(self):
        self.assertEqual(ls.stat_of(event(line()))["path"], "turn-tls")
        self.assertEqual(ls.stat_of(event(line(), "message"))["rttP50"], 40)

    def test_direct_through_a_mapped_port_is_its_own_path(self):
        self.assertEqual(ls.stat_of(event(line(path="direct", portmapBy="pcp", portmapUsed=True)))["path"], "direct-mapped")
        self.assertEqual(ls.stat_of(event(line(path="direct", portmapBy="pcp", portmapUsed=False)))["path"], "direct")
        self.assertEqual(ls.stat_of(event(line(path="turn", portmapUsed=True)))["path"], "turn")

    def test_skips_other_lines_and_malformed_stats(self):
        self.assertIsNone(ls.stat_of(event({"event": "placement"})))
        self.assertIsNone(ls.stat_of({"$metadata": {"message": "not json"}}))
        for bad in ({"path": "carrier"}, {"transport": "x"}, {"reason": "y"}, {"pings": -1}, {"lost": "a"}, {"pings": True}):
            self.assertIsNone(ls.stat_of(event(line(**bad))), bad)

    def test_clamps_and_cleans(self):
        s = ls.stat_of(event(line(rttP95=1e12, country="united states", hubColo=None)))
        self.assertEqual(s["rttP95"], 600_000)
        self.assertEqual(s["country"], "?")
        self.assertEqual(s["hubColo"], "?")
        # Setup only from a first stat.
        self.assertIsNone(ls.stat_of(event(line(reason="periodic")))["setupMs"])


class Percentile(unittest.TestCase):
    def test_weighted_nearest_rank(self):
        self.assertIsNone(ls.percentile([], 50))
        self.assertEqual(ls.percentile([(10, 1), (20, 1), (30, 1), (40, 1)], 50), 20)
        self.assertEqual(ls.percentile([(10, 1), (1000, 99)], 50), 1000)
        self.assertEqual(ls.percentile([(10, 99), (1000, 1)], 99), 10)
        self.assertEqual(ls.percentile([(10, 99), (1000, 1)], 100), 1000)
        self.assertEqual(ls.percentile([(None, 5), (7, 0), (3, 1)], 50), 3)


class Aggregate(unittest.TestCase):
    def stats(self, n, **over):
        return [ls.stat_of(event(line(**over))) for _ in range(n)]

    def test_overall_row_and_group_numbers(self):
        stats = self.stats(5) + self.stats(5, reason="periodic", rttP50=60, lost=0, pings=10)
        rows = ls.aggregate(stats, 5)
        overall, group = rows
        self.assertEqual((overall["continent"], overall["country"], overall["hubColo"]), ("all", "all", "all"))
        self.assertEqual((group["continent"], group["country"], group["hubColo"]), ("NA", "*", "LAX"))
        self.assertEqual(group["stats"], 10)
        self.assertEqual(group["links"], 5)
        self.assertEqual(group["share"], 1.0)
        self.assertEqual(group["loss"], 0.05)
        self.assertEqual(group["rtt_p50"], 40)
        self.assertEqual(group["rtt_p95"], 60)
        self.assertEqual(group["setup_p50"], 800)

    def test_keystroke_round_trips(self):
        keys = dict(echoN=100, echoP50=45, echoP95=140, echoP99=1900, ackN=100, ackP50=38, ackP95=120, ackP99=1880,
                    spikeCount=3)
        group = ls.aggregate(self.stats(5, **keys) + self.stats(5), 5)[1]
        self.assertEqual((group["keys"], group["echo_p50"], group["echo_tail_p99"], group["ack_p50"]), (500, 45, 1900, 38))
        self.assertEqual(group["spikes_per_1k_keys"], 30.0)
        self.assertIsNone(ls.aggregate(self.stats(5), 5)[1]["spikes_per_1k_keys"])

    def test_share_across_paths(self):
        rows = ls.aggregate(self.stats(6) + self.stats(2, path="direct"), 1)
        share = {r["path"]: r["share"] for r in rows if r["continent"] == "all"}
        self.assertEqual(share, {"turn-tls": 0.75, "direct": 0.25})

    def test_small_groups_fold_and_print_no_row(self):
        stats = self.stats(5, country="US") + self.stats(1, country="NZ", continent="OC")
        rows = ls.aggregate(stats, 5, by_country=True)
        places = [(r["continent"], r["country"]) for r in rows]
        self.assertIn(("NA", "US"), places)
        self.assertNotIn(("OC", "NZ"), places)
        self.assertNotIn(("OC", "*"), places)
        self.assertNotIn("NZ", json.dumps(rows))
        # The overall row still counts the folded link.
        self.assertEqual(rows[0]["links"], 6)

    def test_countries_only_when_asked(self):
        rows = ls.aggregate(self.stats(5), 5)
        self.assertNotIn("US", json.dumps(rows))

    def test_render_is_a_markdown_table(self):
        out = ls.render(ls.aggregate(self.stats(5), 5))
        self.assertTrue(out.startswith("| transport | path |"))
        self.assertIn("10.00%", out)
        self.assertEqual(len(out.splitlines()), 4)


class Main(unittest.TestCase):
    def test_reads_a_saved_result(self):
        import contextlib
        import io
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"result": {"events": {"events": [event(line()) for _ in range(5)]}}}, f)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.assertEqual(ls.main(["--events", f.name, "--json"]), 0)
        pathlib.Path(f.name).unlink()
        head, *rows = [json.loads(x) for x in buf.getvalue().splitlines()]
        self.assertEqual(head["link_stats"], 5)
        self.assertEqual(len(rows), 2)


if __name__ == "__main__":
    unittest.main()
