"""cmux-bench core: schema, ledger (plain and git), selectors, compare verdicts, the CLI end to end."""
from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

# tests/git_fixture_env.py turns off git's background maintenance in temp repos.
_git_fixture_spec = importlib.util.spec_from_file_location(
    "git_fixture_env", BENCH_DIR.parents[1] / "tests" / "git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

from benchlib import compare as cmp  # noqa: E402
from benchlib import schema  # noqa: E402
from benchlib.bench import Bench, Context, parse_build  # noqa: E402
from benchlib.ledger import Ledger  # noqa: E402
from benchlib.registry import load_all  # noqa: E402


class Fake(Bench):
    name = "fake"
    summary = "test bench"
    units = "ms"
    owner = "test"
    hosts = ("anywhere",)
    harness = "scripts/bench/tests/test_core.py"


def make_run(build: dict, values: dict[str, float], ts: str, host: str = "cmux20-bench") -> list[dict]:
    ctx = Context(bench=Fake(), build=build, host_role="anywhere", timestamp=ts,
                  host={"name": host, "role": "anywhere", "os": "macOS 27.0", "chip": "Apple M6"})
    for metric, value in values.items():
        ctx.row(metric, unit="ms", samples=[value, value * 1.1, value * 0.9])
    return ctx.rows


def nightly(v: str, sha: str = "a" * 40) -> dict:
    return {"channel": "nightly", "version": v, "sha": sha}


class SchemaTests(unittest.TestCase):
    def test_row_from_samples_has_median_and_percentiles(self):
        rows = make_run(nightly("1"), {"launch": 100.0}, "2026-11-16T00:00:00Z")
        r = rows[0]
        self.assertEqual(r["value"], 100.0)
        self.assertEqual(r["n"], 3)
        self.assertAlmostEqual(r["p95"], 109.0)
        self.assertEqual(r["schema"], "cmux-bench/v1")

    def test_validate_rejects_bad_unit_and_missing_build(self):
        r = make_run(nightly("1"), {"x": 1.0}, "2026-11-16T00:00:00Z")[0]
        with self.assertRaises(schema.SchemaError):
            schema.validate({**r, "unit": "furlongs"})
        with self.assertRaises(schema.SchemaError):
            schema.validate({**r, "build": {}})
        with self.assertRaises(schema.SchemaError):
            schema.validate({**r, "value": float("nan")})

    def test_parse_build(self):
        self.assertEqual(parse_build("DEV")["channel"], "DEV")
        self.assertEqual(parse_build("f" * 40), {"channel": "sha", "version": None, "sha": "f" * 40})
        self.assertTrue(parse_build(None).get("pending"))


class LedgerAndCompareTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ledger = Ledger(root=Path(self.tmp.name) / "plain", remote=None)
        self.ledger.append(make_run(nightly("100"), {"launch": 400, "frame": 50}, "2026-11-14T00:00:00Z"))
        self.ledger.append(make_run(nightly("100"), {"launch": 410, "frame": 50}, "2026-11-14T01:00:00Z"))
        self.ledger.append(make_run(nightly("101", "b" * 40), {"launch": 500, "frame": 52}, "2026-11-15T00:00:00Z"))
        self.ledger.append(make_run({"channel": "sha", "version": None, "sha": "c" * 40},
                                    {"launch": 300, "frame": 49}, "2026-11-16T00:00:00Z"))

    def tearDown(self):
        self.tmp.cleanup()

    def test_runs_are_grouped_and_ordered(self):
        runs = self.ledger.runs()
        self.assertEqual(len(runs), 4)
        self.assertEqual([len(r["rows"]) for r in runs], [2, 2, 2, 2])
        self.assertLess(runs[0]["timestamp"], runs[-1]["timestamp"])

    def test_selectors(self):
        runs = self.ledger.runs()
        self.assertEqual(cmp.resolve("fake@latest", runs)["build"]["sha"], "c" * 40)
        self.assertEqual(cmp.resolve("fake@latest~1", runs)["build"]["version"], "101")
        self.assertEqual(cmp.resolve("fake@nightly", runs)["build"]["version"], "101")
        prev = cmp.resolve("fake@nightly~1", runs)
        self.assertEqual(prev["build"]["version"], "100")
        self.assertEqual(prev["timestamp"], "2026-11-14T01:00:00Z", "the newest run of that NIGHTLY")
        self.assertEqual(cmp.resolve("sha:bbbb", runs, "fake")["build"]["version"], "101")
        self.assertEqual(cmp.resolve("version:100", runs, "fake")["timestamp"], "2026-11-14T01:00:00Z")
        self.assertEqual(cmp.resolve(runs[0]["run_id"][:30], runs)["run_id"], runs[0]["run_id"])
        with self.assertRaises(cmp.SelectorError):
            cmp.resolve("fake@nightly~5", runs)
        with self.assertRaises(cmp.SelectorError):
            cmp.resolve("2026", runs)  # ambiguous prefix
        with self.assertRaises(cmp.SelectorError):
            cmp.resolve("latest", runs)  # needs a bench

    def test_compare_verdicts_threshold_and_floor(self):
        runs = self.ledger.runs()
        res = cmp.compare(cmp.resolve("fake@nightly~1", runs), cmp.resolve("fake@nightly", runs))
        by = {r["metric"]: r for r in res["rows"]}
        self.assertEqual(by["launch"]["verdict"], "regressed")  # 410 -> 500, +22%
        self.assertEqual(by["frame"]["verdict"], "same")  # +4%, and 2 ms is under the 5 ms floor
        self.assertEqual(len(res["regressions"]), 1)
        better = cmp.compare(cmp.resolve("fake@nightly", runs), cmp.resolve("fake@latest", runs))
        self.assertEqual({r["metric"]: r["verdict"] for r in better["rows"]}["launch"], "improved")
        # A per-metric threshold and floor change the call.
        loose = cmp.compare(cmp.resolve("fake@nightly~1", runs), cmp.resolve("fake@nightly", runs),
                            thresholds={"launch": 50.0})
        self.assertEqual(loose["regressions"], [])
        tight = cmp.compare(cmp.resolve("fake@nightly~1", runs), cmp.resolve("fake@nightly", runs),
                            thresholds={"frame": 1.0}, floors={"frame": 0.5})
        self.assertEqual({r["metric"] for r in tight["regressions"]}, {"launch", "frame"})
        self.assertIn("regression", cmp.render(res))
        self.assertIn("| launch |", cmp.render_markdown(res))

    def test_higher_is_better(self):
        a = make_run(nightly("1"), {}, "2026-11-14T00:00:00Z")
        ctx = Context(bench=Fake(), build=nightly("1"), host_role="anywhere", timestamp="2026-11-14T00:00:00Z")
        ctx.row("fps", 60, "fps", better="higher")
        ctx2 = Context(bench=Fake(), build=nightly("2"), host_role="anywhere", timestamp="2026-11-15T00:00:00Z")
        ctx2.row("fps", 40, "fps", better="higher")
        self.assertEqual(a, [])
        res = cmp.compare({"run_id": ctx.run_id, "bench": "fake", "build": ctx.build, "host": ctx.host,
                           "harness": {"version": "fake@1"}, "timestamp": ctx.timestamp, "rows": ctx.rows},
                          {"run_id": ctx2.run_id, "bench": "fake", "build": ctx2.build, "host": ctx2.host,
                           "harness": {"version": "fake@1"}, "timestamp": ctx2.timestamp, "rows": ctx2.rows})
        self.assertEqual(res["rows"][0]["verdict"], "regressed")


class GitLedgerTests(unittest.TestCase):
    """Two writers on one bare remote: unique files, so both pushes land."""

    def test_two_clones_append_and_both_see_both(self):
        with tempfile.TemporaryDirectory() as tmp:
            remote = Path(tmp) / "remote.git"
            git_fixture_env.init_repo(remote, "--bare")
            # The ledger's own git calls inherit this: auto maintenance off, no redirects (tests/git_fixture_env.py).
            env = git_fixture_env.fixture_env({**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@e",
                                               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@e"})
            old = dict(os.environ)
            os.environ.clear()
            os.environ.update(env)
            try:
                one = Ledger(root=Path(tmp) / "one", remote=str(remote))
                two = Ledger(root=Path(tmp) / "two", remote=str(remote))
                one.append(make_run(nightly("1"), {"launch": 1}, "2026-11-14T00:00:00Z"))
                two.pull()
                one.append(make_run(nightly("2"), {"launch": 2}, "2026-11-15T00:00:00Z"))
                two.append(make_run(nightly("3"), {"launch": 3}, "2026-11-16T00:00:00Z"))  # races one's push
                one.pull()
                self.assertEqual(len(one.runs()), 3)
                self.assertEqual(len(two.runs()), 3)
                # A run file an interrupted append left uncommitted goes out with the next push.
                stranded = make_run(nightly("4"), {"launch": 4}, "2026-11-17T00:00:00Z")
                path = one.root / "runs/2026/11" / f"{stranded[0]['run_id']}.jsonl"
                path.write_text("".join(json.dumps(r) + "\n" for r in stranded))
                one.push()
                two.pull()
                self.assertEqual(len(two.runs()), 4)
                # A bad line is skipped, not fatal to every read.
                with path.open("a") as fh:
                    fh.write("{not json\n")
                self.assertEqual(len(one.runs()), 4)
            finally:
                os.environ.clear()
                os.environ.update(old)


class FleetStepTests(unittest.TestCase):
    def test_a_fleet_step_outside_actions_passes_a_key(self):
        """`cmux-ci run` refuses a step with no --key outside Actions; every fleet bench then read an empty log."""
        import contextlib
        import io
        from benchlib.bench import BenchError
        ctx = Context(bench=Fake(), build={"sha": "b" * 40}, host_role="fleet", dry_run=True)
        old = os.environ.pop("GITHUB_RUN_ID", None)
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), self.assertRaises(BenchError):
                ctx.fleet_step("scripts/measure/launch-ready.sh", ref="c" * 40)
        finally:
            if old is not None:
                os.environ["GITHUB_RUN_ID"] = old
        self.assertIn(f"--key {ctx.run_id}-launch-ready", out.getvalue())


class RegistryAndCliTests(unittest.TestCase):
    def test_every_bench_loads_and_is_described(self):
        benches = load_all()
        self.assertIn("bundle", benches)
        for b in benches.values():
            self.assertTrue(b.summary and b.units and b.owner and b.harness, b.name)
            self.assertTrue(set(b.hosts) <= schema.ROLES, b.name)

    def test_cli_list_json_and_import_compare(self):
        cli = str(BENCH_DIR / "cmux-bench")
        with tempfile.TemporaryDirectory() as tmp:
            env = {**os.environ, "CMUX_BENCH_LEDGER": tmp}
            out = subprocess.run([sys.executable, cli, "list", "--json"], text=True, capture_output=True, env=env, check=True)
            self.assertIn("bundle", {b["name"] for b in json.loads(out.stdout)})
            listing = Path(tmp) / "listing.json"
            for version, extra in (("1", 0), ("2", 20_000_000)):
                listing.write_text(json.dumps({"app": "cmux", "download_bytes": 200_000_000, "files": [
                    ["cmux.app/Contents/MacOS/cmux", 40_000_000 + extra],
                    ["cmux.app/Contents/Frameworks/Engine.framework/Engine", 150_000_000]]}))
                subprocess.run([sys.executable, cli, "bundle", "--import", str(listing), "--build", f"release:{version}",
                                "--host-name", "fixture"], text=True, capture_output=True, env=env, check=True)
            # An import with no --build is never taken for a NIGHTLY.
            plain = Path(tmp) / "plain.json"
            plain.write_text(listing.read_text())
            subprocess.run([sys.executable, cli, "bundle", "--import", str(plain)], text=True, capture_output=True,
                           env=env, check=True)
            shown = subprocess.run([sys.executable, cli, "show", "bundle@latest", "--json", "--no-pull"], text=True,
                                   capture_output=True, env=env, check=True)
            self.assertEqual(json.loads(shown.stdout)[0]["build"]["channel"], "other")
            res = subprocess.run([sys.executable, cli, "compare", "bundle@latest~2", "bundle@latest~1", "--json",
                                  "--no-pull", "--fail-on-regression"], text=True, capture_output=True, env=env)
            self.assertEqual(res.returncode, 1, res.stderr)
            data = json.loads(res.stdout)
            regressed = {(r["metric"], r["labels"]) for r in data["regressions"]}
            self.assertIn(("total_uncompressed", "app=cmux"), regressed)
            self.assertIn(("component", "app=cmux,component=Contents/MacOS/cmux"), regressed)


if __name__ == "__main__":
    unittest.main()
