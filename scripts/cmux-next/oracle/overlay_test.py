#!/usr/bin/env python3
"""Tests for overlay.py (p15-oracle-202): the overlay commit, the v0 fallback and the not-comparable mask.

Run: python3 -I scripts/cmux-next/oracle/overlay_test.py (stdlib unittest; throwaway git repositories, no network,
no build). The v0 list and the oracle.py diff test read this checkout's snapshot schema and facets_v0.py.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
import unittest.mock
from pathlib import Path
from typing import Any, Dict, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import oracle  # noqa: E402
import overlay  # noqa: E402

HERMETIC = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
CARGO = "[workspace]\nmembers = []\n\n[profile.release]\nlto = true\n"
PROFILE = "\n[profile.oracle]\ninherits = \"release\"\n"


class Repo:
    def __init__(self, root: Path) -> None:
        self.root = root
        root.mkdir(parents=True)
        self.git = overlay.Git(root, HERMETIC)
        self.git.run("init", "-q", "-b", "main")
        self.tick = 1_700_000_000

    def commit(self, subject: str, files: Mapping[str, Optional[str]]) -> str:
        for path, text in files.items():
            target = self.root / path
            if text is None:
                target.unlink()
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
        self.tick += 60
        when = {"GIT_AUTHOR_DATE": f"{self.tick} +0000", "GIT_COMMITTER_DATE": f"{self.tick} +0000"}
        self.git.run("add", "-A")
        self.git.run("commit", "-q", "--no-gpg-sign", "-m", subject, env=when)
        return self.git.text("rev-parse", "HEAD").strip()

    def checkout(self, ref: str) -> None:
        self.git.run("checkout", "-q", "--detach", ref)

    def show(self, rev: str, path: str) -> Optional[str]:
        proc = self.git.run("show", f"{rev}:{path}", check=False)
        return proc.stdout.decode() if proc.returncode == 0 else None


class PrepareCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self.tmp.name) / "r")
        self.base = self.repo.commit("base", {
            "cmux-tui/Cargo.toml": CARGO, "cmux-tui/src/main.rs": "fn main() {}\n",
            "Packages/App/Main.swift": "let app = 1\n", "scripts/cmux-next/oracle/old.py": "old\n"})
        self.refactor = self.repo.commit("perf: a refactor the base must not get",
                                         {"cmux-tui/src/main.rs": "fn main() { fast() }\n"})
        self.profile = self.repo.commit("p15-oracle-201: cargo oracle profile",
                                        {"cmux-tui/Cargo.toml": CARGO + PROFILE,
                                         "cmux-tui/spec/oracle.md": "the oracle profile\n"})
        self.app = self.repo.commit("oracle: app registration (p15-oracle-030)",
                                    {"Packages/App/Oracle.swift": "let oracle = 1\n"})
        self.runner = self.repo.commit("oracle: schema (p15-oracle-011)",
                                       {"schemas/oracle/s.json": "{}\n", "scripts/cmux-next/oracle/old.py": None,
                                        "scripts/cmux-next/oracle/oracle.py": "new\n"})
        self.head = self.runner

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def prepare(self, base: str, head: str, **kwargs: Any) -> Dict[str, Any]:
        return overlay.prepare(self.repo.root, base, head, **kwargs)


class PrepareTests(PrepareCase):
    def test_daemon_overlay_adds_the_oracle_in_its_scope_and_nothing_else(self) -> None:
        plan = self.prepare(self.base, self.head)
        self.assertEqual((plan["mode"], plan["facets"]), ("overlay", "v1"))
        sha = plan["overlaySha"]
        self.assertEqual(plan["buildSha"], sha)
        self.assertEqual(self.repo.show(sha, "cmux-tui/Cargo.toml"), CARGO + PROFILE)
        self.assertEqual(self.repo.show(sha, "cmux-tui/src/main.rs"), "fn main() {}\n", "the refactor stays out")
        self.assertIsNone(self.repo.show(sha, "cmux-tui/spec/oracle.md"), "prose never builds")
        self.assertIsNone(self.repo.show(sha, "Packages/App/Oracle.swift"), "the app is not in the daemon's scope")
        self.assertEqual(self.repo.show(sha, "scripts/cmux-next/oracle/old.py"), "old\n",
                         "the VM runs this checkout's runner, so the daemon overlay leaves the base's")
        self.assertEqual([c["sha"] for c in plan["commits"]], [self.profile, self.app, self.runner])
        self.assertEqual(plan["applied"], [self.profile])
        self.assertEqual(plan["files"], ["cmux-tui/Cargo.toml"])
        self.assertEqual(self.repo.git.text("rev-parse", f"{sha}^").strip(), self.base)
        self.assertEqual(plan["notComparable"], [])

    def test_app_overlay_takes_the_runner_whole_from_head(self) -> None:
        plan = self.prepare(self.base, self.head, product="app")
        sha = plan["overlaySha"]
        self.assertEqual(plan["mode"], "overlay")
        self.assertEqual(self.repo.show(sha, "Packages/App/Oracle.swift"), "let oracle = 1\n")
        self.assertEqual(self.repo.show(sha, "Packages/App/Main.swift"), "let app = 1\n")
        self.assertEqual(self.repo.show(sha, "scripts/cmux-next/oracle/oracle.py"), "new\n")
        self.assertIsNone(self.repo.show(sha, "scripts/cmux-next/oracle/old.py"), "the runner is head's exactly")
        self.assertEqual(self.repo.show(sha, "cmux-tui/src/main.rs"), "fn main() {}\n")

    def test_the_overlay_sha_is_a_function_of_base_head_and_product(self) -> None:
        first = self.prepare(self.base, self.head)["overlaySha"]
        self.assertEqual(self.prepare(self.base, self.head)["overlaySha"], first)
        self.assertNotEqual(self.prepare(self.base, self.head, product="app")["overlaySha"], first)

    def test_the_overlay_commit_is_kept_by_a_ref_and_describes_itself(self) -> None:
        plan = self.prepare(self.base, self.head)
        sha = plan["overlaySha"]
        self.assertEqual(self.repo.git.text("rev-parse", f"refs/oracle-overlay/{sha}").strip(), sha)
        self.assertEqual(overlay.describe(self.repo.root, sha), {
            "overlaySha": sha, "base": self.base, "head": self.head, "product": "daemon", "mode": "overlay",
            "applied": [self.profile]})
        self.assertIsNone(overlay.describe(self.repo.root, self.head))

    def test_a_base_with_the_oracle_is_native(self) -> None:
        plan = self.prepare(self.profile, self.head)
        self.assertEqual((plan["mode"], plan["facets"], plan["buildSha"]), ("native", "v1", self.profile))
        self.assertNotIn("overlaySha", plan)
        self.assertEqual(self.prepare(self.head, self.head)["mode"], "native")

    def test_three_way_merges_a_drifted_shared_file(self) -> None:
        self.repo.checkout(self.base)
        drifted = self.repo.commit("other: a comment on top", {"cmux-tui/Cargo.toml": "# top\n" + CARGO})
        plan = self.prepare(drifted, self.head)
        self.assertEqual(plan["mode"], "overlay")
        self.assertEqual(self.repo.show(plan["buildSha"], "cmux-tui/Cargo.toml"), "# top\n" + CARGO + PROFILE)

    def test_a_conflict_falls_back_to_v0_on_the_base(self) -> None:
        self.repo.checkout(self.base)
        conflicting = self.repo.commit("other: a different tail", {"cmux-tui/Cargo.toml": CARGO + "\n[profile.bench]\n"})
        plan = self.prepare(conflicting, self.head)
        self.assertEqual((plan["mode"], plan["facets"], plan["buildSha"]), ("v0", "v0", conflicting))
        self.assertIn("git apply --3way", plan["reason"])
        self.assertIn(self.profile[:12], plan["reason"])
        self.assertIn("conflicts in cmux-tui/Cargo.toml", plan["reason"])
        names = [e["facet"] for e in plan["notComparable"]]
        self.assertIn("daemon/journalHead", names)
        self.assertNotIn("daemon", names)

    def test_app_v0_puts_head_runner_alone_on_the_base(self) -> None:
        self.repo.checkout(self.base)
        conflicting = self.repo.commit("other: a different tail", {"cmux-tui/Cargo.toml": CARGO + "\n[profile.bench]\n"})
        plan = self.prepare(conflicting, self.head, product="app")
        self.assertEqual((plan["mode"], plan["facets"]), ("v0", "v0"))
        sha = plan["overlaySha"]
        self.assertEqual(plan["buildSha"], sha)
        self.assertEqual(self.repo.show(sha, "scripts/cmux-next/oracle/oracle.py"), "new\n")
        self.assertIsNone(self.repo.show(sha, "Packages/App/Oracle.swift"), "v0 adds no product change")
        self.assertEqual(self.repo.show(sha, "cmux-tui/Cargo.toml"), CARGO + "\n[profile.bench]\n")
        self.assertEqual(overlay.describe(self.repo.root, sha)["mode"], "v0")

    def test_an_oracle_commit_that_removes_product_lines_is_not_additive(self) -> None:
        self.repo.checkout(self.head)
        head = self.repo.commit("p15-oracle-180: switches", {"cmux-tui/src/main.rs": "fn main() { switched() }\n"})
        plan = self.prepare(self.refactor, head)
        self.assertEqual(plan["mode"], "v0")
        self.assertIn("not additive", plan["reason"])
        self.assertIn("cmux-tui/src/main.rs: 1 removed lines", plan["reason"])

    def test_a_later_oracle_fix_of_its_own_lines_stays_additive(self) -> None:
        self.repo.checkout(self.head)
        head = self.repo.commit("p15-oracle-201 (fixer): one more key",
                                {"cmux-tui/Cargo.toml": CARGO + PROFILE.replace('"release"\n', '"release"\nlto = "off"\n')})
        plan = self.prepare(self.base, head)
        self.assertEqual(plan["mode"], "overlay")
        self.assertEqual(plan["applied"], [self.profile, head])

    def test_forced_v0(self) -> None:
        plan = self.prepare(self.base, self.head, force_v0="the overlay does not build")
        self.assertEqual((plan["mode"], plan["buildSha"], plan["reason"]), ("v0", self.base, "the overlay does not build"))

    def test_bad_input(self) -> None:
        with self.assertRaises(overlay.OverlayError):
            self.prepare("no-such-ref", self.head)
        with self.assertRaises(overlay.OverlayError):
            self.prepare(self.base, self.head, product="windows")


class V0ListTests(unittest.TestCase):
    def test_v0_list_follows_facets_v0(self) -> None:
        names = {e["facet"] for e in overlay.v0_not_comparable("daemon")}
        for comparable in ("daemon", "daemon/session", "daemon/settings", "cli", "mcp"):
            self.assertNotIn(comparable, names)
        for missing in ("layout", "tabs", "terminals", "topology", "daemon/journalHead", "daemon/oracle"):
            self.assertIn(missing, names)
        app = {e["facet"] for e in overlay.v0_not_comparable("app")}
        self.assertNotIn("topology", app)
        self.assertIn("layout", app)
        self.assertEqual({e["facet"] for e in overlay.v0_not_comparable("cli")}, names)


def snap(**facets: Any) -> Dict[str, Any]:
    return {"schema": "cmux.oracle.snapshot/v1", "meta": {"facets": sorted(facets)}, "facets": facets}


NC = {"status": "not-comparable", "reason": "v0"}


def write_run(path: Path, rows: Sequence[Tuple[str, Dict[str, Any]]], results: Optional[Dict[str, str]] = None,
              extra: Optional[Dict[str, Dict[str, Any]]] = None) -> None:
    path.mkdir(parents=True)
    cases = {case: {"result": (results or {}).get(case, "Pass")} for case, _ in rows}
    (path / "receipt.json").write_text(json.dumps({"runId": path.name, "cases": cases}), encoding="utf-8")
    with (path / "checkpoints.jsonl").open("w", encoding="utf-8") as handle:
        for case, snapshot in rows:
            row = {"case": case, "step": "s", "index": 0, "checkpoint": "settled", "snapshot": snapshot,
                   "sha256": "x", **(extra or {}).get(case, {})}
            handle.write(json.dumps(row) + "\n")


def read(path: Path) -> Tuple[Dict[str, Any], list]:
    receipt = json.loads((path / "receipt.json").read_text())
    rows = [json.loads(line) for line in (path / "checkpoints.jsonl").read_text().splitlines() if line.strip()]
    return receipt, rows


class MaskTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_masks_both_sides_and_skips_cases_with_nothing_comparable(self) -> None:
        write_run(self.dir / "a", [("s/mixed", snap(daemon={"session": 1}, layout=NC)),
                                   ("s/none", snap(layout=NC)),
                                   ("s/clean", snap(daemon={"session": 1}))])
        write_run(self.dir / "b", [("s/mixed", snap(daemon={"session": 1, "journalHead": 9}, layout={"r": 0.5})),
                                   ("s/none", snap(layout={"r": 1})),
                                   ("s/clean", snap(daemon={"session": 1}))])
        result = overlay.mask_runs(self.dir / "a", self.dir / "b", self.dir / "m",
                                   [{"facet": "daemon/journalHead", "reason": "v0"}])
        (ra, a), (rb, b) = read(result.a_dir), read(result.b_dir)
        self.assertEqual(a[0]["snapshot"], b[0]["snapshot"])
        self.assertEqual(b[0]["snapshot"]["facets"]["layout"], overlay.MARKER)
        self.assertEqual(b[0]["snapshot"]["facets"]["daemon"]["journalHead"], overlay.MARKER)
        self.assertNotIn("journalHead", b[2]["snapshot"]["facets"]["daemon"], "absent on both sides: left absent")
        self.assertNotIn("sha256", b[0])
        self.assertEqual(b[2]["sha256"], "x", "a checkpoint with nothing to mask keeps its hash")
        self.assertEqual(sorted(result.facets), ["daemon/journalHead", "layout"])
        self.assertEqual(sorted(result.cases), ["s/none"])
        self.assertEqual((ra["cases"]["s/none"]["result"], rb["cases"]["s/none"]["result"]), ("Skip", "Skip"))
        self.assertEqual(rb["cases"]["s/mixed"]["result"], "Pass")

    def test_different_results_stay_a_divergence(self) -> None:
        write_run(self.dir / "a", [("s/c", snap(layout=NC))], results={"s/c": "Pass"})
        write_run(self.dir / "b", [("s/c", snap(layout={"r": 1}))], results={"s/c": "Crash"})
        result = overlay.mask_runs(self.dir / "a", self.dir / "b", self.dir / "m")
        self.assertEqual(result.cases, {})
        self.assertEqual(read(result.b_dir)[0]["cases"]["s/c"]["result"], "Crash")

    def test_driver_row_marks_are_masked(self) -> None:
        write_run(self.dir / "a", [("s/c", snap(tabs={"p": 1}, daemon={}))], extra={"s/c": {"notComparable": ["tabs"]}})
        write_run(self.dir / "b", [("s/c", snap(tabs={"p": 2}, daemon={}))])
        result = overlay.mask_runs(self.dir / "a", self.dir / "b", self.dir / "m")
        self.assertEqual(read(result.b_dir)[1][0]["snapshot"]["facets"]["tabs"], overlay.MARKER)
        self.assertEqual(result.cases, {})


class DiffTests(unittest.TestCase):
    """`oracle.py diff --overlay`: never a pass for what was not compared."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_dir(self, name: str, rows: Sequence[Tuple[str, Dict[str, Any]]], sha: str = "0" * 40) -> Path:
        path = self.dir / name
        cases = {case: {"suite": case.split("/")[0], "result": "Pass", "outcome": "expected", "flaky": False,
                        "reasons": [], "attempts": 1, "checkpoints": 1} for case, _ in rows}
        selection = sorted(cases)
        receipt = {"schema": oracle.RUN_SCHEMA, "runId": name, "sha": sha, "dry_run": False,
                   "platform": "linux", "product": "daemon", "arm": None,
                   "config": {"product": "daemon", "build": "debug", "arm": None, "shard_total": 1, "seed": None,
                              "shard_index": 0},
                   "fingerprint": "f", "host": {"name": "h", "os": "Linux", "osVersion": "1", "arch": "x86_64",
                                                "display": "none"},
                   "selection": {"count": len(selection), "digest": oracle.digest(selection)}, "shards": [0],
                   "seeds": {"0": None}, "order": selection, "cases": cases,
                   **oracle.run_summary(cases, hits={}, readback={}, config={}, dry_run=False, infra_errors=[])}
        path.mkdir()
        oracle.write_json(path / "receipt.json", receipt)
        oracle.write_jsonl(path / "checkpoints.jsonl", [
            {"case": case, "suite": case.split("/")[0], "step": "s", "index": 0, "checkpoint": "settled",
             "snapshot": snapshot, "sha256": oracle.snapshot_sha256(snapshot), "attempt": 1, "result": "Pass"}
            for case, snapshot in rows])
        return path

    def plan(self, **extra: Any) -> Path:
        path = self.dir / "overlay.json"
        path.write_text(json.dumps({"schema": overlay.SCHEMA, "product": "daemon", "mode": "v0", "facets": "v0",
                                    "base": "a" * 40, "head": "b" * 40, "buildSha": "a" * 40,
                                    "reason": "conflicts in cmux-tui/Cargo.toml",
                                    "notComparable": [{"facet": "layout", "reason": "v0"}], **extra}))
        return path

    def diff(self, a: Path, b: Path, plan: Path) -> Tuple[int, Dict[str, Any]]:
        out = self.dir / "cmp"
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = oracle.main(["diff", "--base-run", str(a), "--head-run", str(b), "--overlay", str(plan),
                                "--out", str(out), "--expectations-root", str(self.dir / "no-expectations")])
        return code, json.loads((out / "comparison.json").read_text())

    def test_only_not_comparable_facets_is_refused_never_a_pass(self) -> None:
        a = self.run_dir("a", [("s/c", snap(layout={"r": 1}))])
        b = self.run_dir("b", [("s/c", snap(layout={"r": 2}))])
        code, comparison = self.diff(a, b, self.plan())
        self.assertEqual(code, oracle.EXIT_REFUSED)
        self.assertEqual(comparison["refused"], "nothing compared")
        self.assertFalse(comparison["ok"])
        self.assertIn("s/c", comparison["not_comparable"])
        self.assertEqual(comparison["overlay"]["mode"], "v0")
        self.assertIn("layout", comparison["overlay"]["notComparableFacets"])

    def test_equal_not_comparable_markers_are_not_a_pass(self) -> None:
        # Two v0 runs mark the same facets not-comparable: diff.py alone calls the equal markers equal (ok).
        a = self.run_dir("a", [("s/c", snap(layout=NC, tabs=NC))])
        b = self.run_dir("b", [("s/c", snap(layout=NC, tabs=NC))])
        out = self.dir / "plain"
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            plain = oracle.main(["diff", "--base-run", str(a), "--head-run", str(b), "--out", str(out),
                                 "--expectations-root", str(self.dir / "no-expectations")])
        self.assertEqual(plain, 0, "the gap this plan closes: equal markers compare equal")
        code, comparison = self.diff(a, b, self.plan())
        self.assertEqual(code, oracle.EXIT_REFUSED)
        self.assertEqual(comparison["compared"], 0)
        self.assertEqual(sorted(comparison["overlay"]["notComparableFacets"]), ["layout", "tabs"])

    def test_comparable_facets_still_diverge(self) -> None:
        a = self.run_dir("a", [("s/c", snap(layout={"r": 1}, daemon={"n": 1}))])
        b = self.run_dir("b", [("s/c", snap(layout={"r": 2}, daemon={"n": 2}))])
        code, comparison = self.diff(a, b, self.plan(mode="overlay", facets="v1", overlaySha="c" * 40,
                                                     notComparable=[]))
        self.assertEqual(code, 1)
        self.assertEqual(comparison["divergent"], ["s/c"])
        self.assertEqual(comparison["overlay"]["overlaySha"], "c" * 40)

    def test_a_bad_plan_is_bad_input(self) -> None:
        a = self.run_dir("a", [("s/c", snap(daemon={}))])
        path = self.dir / "bad.json"
        path.write_text("{}")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = oracle.main(["diff", "--base-run", str(a), "--head-run", str(a), "--overlay", str(path),
                                "--out", str(self.dir / "cmp")])
        self.assertEqual(code, 2)

    def test_queued_base_head_diff_runs_the_plan_build_on_the_base_side(self) -> None:
        # `oracle.py diff --base --head` on the VM: two `linux_run.sh run` jobs; a v0 plan reaches both.
        # Each run is of the commit its side built: the base of the plan's build, the head of head (task 112).
        a = self.run_dir("a", [("s/c", snap(layout=NC, daemon={"n": 1}))], sha="c" * 40)
        b = self.run_dir("b", [("s/c", snap(layout=NC, daemon={"n": 1}))], sha="b" * 40)
        plan = self.plan(buildSha="c" * 40)
        commands: list = []

        class FakePopen:
            def __init__(self, command: Sequence[str], **_: Any) -> None:
                commands.append(list(command))
                self.returncode = 0
                self.dir = (a, b)[len(commands) - 1]
                # linux_run.sh run's build receipt (`--receipt`): the commit it built (task 112).
                receipt = Path(command[command.index("--receipt") + 1])
                receipt.write_text(json.dumps({"schema": "cmux-oracle-build-v1", "sha": command[3], "gitlinks": {}}))

            def communicate(self) -> Tuple[str, None]:
                return f"{self.dir}\n", None

        out = self.dir / "cmp"
        out.mkdir()  # cmd_diff makes it before queued_diff
        args = oracle.build_parser().parse_args(["diff", "--base", "a" * 40, "--head", "b" * 40, "--out", str(out),
                                                 "--expectations-root", str(self.dir / "no-expectations")])
        sides, expected = oracle.diff_sides(args, {})
        with unittest.mock.patch.object(oracle, "queued_overlay", return_value=plan), \
                unittest.mock.patch.object(oracle, "subprocess", types.SimpleNamespace(
                    Popen=FakePopen, run=subprocess.run, PIPE=subprocess.PIPE, DEVNULL=subprocess.DEVNULL)), \
                unittest.mock.patch.object(oracle, "resolve_commit", side_effect=lambda ref: ref), \
                contextlib.redirect_stdout(io.StringIO()):
            code = oracle.queued_diff(args, sides, expected, out)
        self.assertEqual([c[3] for c in commands], ["c" * 40, "b" * 40])
        self.assertTrue(all(c[-2:] == ["--facets", "v0"] for c in commands), commands)
        comparison = json.loads((out / "comparison.json").read_text())
        self.assertEqual((code, comparison["overlay"]["mode"], comparison["compared"]), (0, "v0", 1))
        self.assertEqual(list(comparison["overlay"]["notComparableFacets"]), ["layout"])
        self.assertEqual((comparison["builds"]["base"]["sha"], comparison["builds"]["head"]["sha"]),
                         ("c" * 40, "b" * 40))


class CliTests(PrepareCase):
    def test_prepare_writes_the_plan_and_describe_reads_the_commit(self) -> None:
        out = Path(self.tmp.name) / "plan" / "o.json"
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = overlay.main(["prepare", "--repo", str(self.repo.root), "--base", self.base, "--head", self.head,
                                 "--out", str(out)])
        self.assertEqual(code, 0)
        plan = json.loads(out.read_text())
        self.assertEqual((plan["schema"], plan["mode"], plan["product"]), (overlay.SCHEMA, "overlay", "daemon"))
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            overlay.main(["describe", plan["overlaySha"], "--repo", str(self.repo.root)])
        self.assertEqual(json.loads(stdout.getvalue())["base"], self.base)

    def test_unknown_ref_exits_2(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = overlay.main(["prepare", "--repo", str(self.repo.root), "--base", "nope", "--head", self.head])
        self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
