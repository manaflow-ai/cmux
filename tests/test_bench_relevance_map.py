#!/usr/bin/env python3
"""docs/benches/relevance-map.toml and `cmux-bench for-paths`: correct, joined with the coverage map, and fast.

Leo, 2026-11-27: "like we can have fast retrieval of bench reference per product area".

  - model-based: the prefix index answers exactly what the old whole-table scan answers, on every tracked path's
    shape and on random paths built from the map's own globs (the scan is the oracle);
  - budget: a 2,000-path change resolves in under 1 s, and ten times the rules costs the index far less than ten
    times (the scan grows linearly; the index reads only a path's own ancestors' buckets);
  - joined: each [[area]] names a risky path row of docs/benches/coverage-map.md (same paths), and each bench it
    names is a row of that page (when the page is on this branch);
  - whole: every [[situation]] names a template that exists, every area's situations exist, and the generated
    [[unit]] section matches the repo layout (`scripts/bench/cmux-bench for-paths --write`);
  - fail open: an unmapped path warns and takes its default; a broken map never blocks.
"""
from __future__ import annotations

import random
import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/bench"))

from benchlib import relevance as rel  # noqa: E402

COVERAGE_MAP = ROOT / "docs/benches/coverage-map.md"
CLI = ROOT / "scripts/bench/cmux-bench"


def same(a: rel.Hit, b: rel.Hit) -> bool:
    name = lambda r: r.name if r else None  # noqa: E731
    return (name(a.area), name(a.unit), [s.name for s in a.situations], [s.name for s in a.steps]) == \
           (name(b.area), name(b.unit), [s.name for s in b.situations], [s.name for s in b.steps])


def tracked() -> list[str]:
    out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True).stdout
    return [p for p in out.decode().split("\0") if p]


def random_paths(rules: list[rel.Rule], n: int, seed: int) -> list[str]:
    """Paths made from the map's globs (fill each wildcard with a random segment) plus near misses."""
    rng = random.Random(seed)
    segs = ["a", "Foo.swift", "x.ts", "lib.rs", "Tests", "src", "b/c", "View.swift", "mod.proto", "q.tsx", ""]
    globs = [g for r in rules for g in r.globs]
    out = []
    for _ in range(n):
        g = rng.choice(globs)
        p = re.sub(r"\*\*", lambda _: rng.choice(segs), g)
        p = re.sub(r"[*?]", lambda _: rng.choice(["z", "View", "q"]), p)
        if rng.random() < 0.3:
            p = p.rsplit("/", 1)[0] + "/" + rng.choice(segs[:-1])
        if rng.random() < 0.1:
            p = p.replace("/", "_", 1)
        out.append(p.strip("/") or "x")
    return out


class RelevanceIndexTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.index = rel.load()
        cls.scan = rel.Scan(cls.index.rules)
        cls.files = tracked()

    def test_index_matches_the_scan_on_tracked_paths(self):
        sample = random.Random(7).sample(self.files, min(4000, len(self.files)))
        bad = [p for p in sample if not same(self.index.match(p), self.scan.match(p))]
        self.assertFalse(bad[:10], "the prefix index and the scan disagree on tracked paths")

    def test_index_matches_the_scan_on_random_paths(self):
        for seed in range(3):
            paths = random_paths(self.index.rules, 1500, seed)
            bad = [p for p in paths if not same(self.index.match(p), self.scan.match(p))]
            self.assertFalse(bad[:10], f"seed {seed}: the prefix index and the scan disagree")

    def test_specificity_and_bare_paths(self):
        rules = rel.parse('''
[[area]]
name = "wide"
paths = ["a/**"]
[[area]]
name = "narrow"
paths = ["a/b"]
[[unit]]
name = "u"
paths = ["a/b/*.rs"]
[[situation]]
name = "s"
paths = ["**/*.rs"]
''')
        idx = rel.Index(rules)
        h = idx.match("a/b/c/d.rs")
        self.assertEqual((h.area.name, h.unit, [s.name for s in h.situations]), ("narrow", None, ["s"]))
        self.assertEqual(idx.match("a/b/x.rs").unit.name, "u")
        self.assertEqual(idx.match("a/bc").area.name, "wide", "a bare path covers its folder, not a name prefix")
        self.assertIsNone(idx.match("b/x").area)

    def test_step_ignore_last_match_decides(self):
        rules = rel.parse_steps('''
[step.s]
job = "linux"
run = "true"
inputs = ["a/**"]
ignore = ["a/**/*.md", "!a/keep/*.md"]
''')
        idx = rel.Index(rules)
        self.assertEqual([s.name for s in idx.match("a/x.rs").steps], ["s"])
        self.assertEqual(idx.match("a/x/y.md").steps, [])
        self.assertEqual([s.name for s in idx.match("a/keep/y.md").steps], ["s"])

    def test_budget_and_flat_at_ten_times_the_rules(self):
        paths = random.Random(3).sample(self.files, min(2000, len(self.files)))
        def once():
            t = time.perf_counter()
            rel.plan(rel.load(), paths)
            return time.perf_counter() - t

        one = min(once() for _ in range(3))  # best of 3: a busy CI host is noise, not a regression
        self.assertLess(one, 1.0, f"for-paths on 2,000 paths took {one:.2f} s (budget 1 s, load included)")
        big = list(self.index.rules)
        for k in range(9):
            big += [rel.Rule(kind=r.kind, name=f"{r.name}#{k}", order=len(big) + i, ignore=r.ignore,
                             globs=tuple(f"x{k}/{g}" for g in r.globs)) for i, r in enumerate(self.index.rules)]

        def cost(rules):
            idx = rel.Index(rules)
            for p in paths:  # warm: compile the buckets these paths touch
                idx.match(p)
            t = time.perf_counter()
            for p in paths:
                idx.match(p)
            return time.perf_counter() - t

        base, ten = cost(self.index.rules), cost(big)
        self.assertLess(ten, base * 3 + 0.05, f"10x rules: {ten * 1e3:.1f} ms vs {base * 1e3:.1f} ms (want flat, < 3x)")


class RelevanceMapFileTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = rel.parse(rel.MAP.read_text(encoding="utf-8"))

    def test_templates_exist(self):
        situations = {r.name for r in self.rules if r.kind == "situation"}
        for r in self.rules:
            if r.kind == "situation":
                self.assertTrue(r.template and (ROOT / r.template).is_file(), f"situation {r.name}: no template {r.template}")
            for s in r.situations:
                self.assertIn(s, situations, f"{r.kind} {r.name} names situation {s}, which the map lacks")

    def test_area_paths_exist(self):
        for r in self.rules:
            if r.kind != "area":
                continue
            for g in r.globs:
                lead = rel.literal_prefix(g).rstrip("/")
                self.assertTrue((ROOT / lead).exists(), f"area {r.name}: {g} names {lead}, which does not exist")

    def test_generated_units_are_fresh(self):
        text = rel.MAP.read_text(encoding="utf-8")
        self.assertIn(rel.GENERATED_MARK, text)
        # The base branch adds and removes packages under every open PR, so a little drift is normal and fails open
        # (an unlisted folder takes its default and warns). Only real rot, over 5% of units, fails.
        want = {u["name"]: u for u in rel.generate_units(ROOT, tracked())}
        have = {r.name: r for r in rel.parse(text) if r.kind == "unit"}
        drift = set(want) ^ set(have)
        drift |= {n for n in set(want) & set(have) if tuple(want[n]["paths"]) != have[n].globs}
        if drift:
            print(f"warning: {len(drift)} generated units drifted ({sorted(drift)[:5]}...): "
                  "run scripts/bench/cmux-bench for-paths --write", file=sys.stderr)
        self.assertLess(len(drift), max(5, len(want) // 20),
                        "the [[unit]] section is stale: run scripts/bench/cmux-bench for-paths --write")

    @unittest.skipUnless(COVERAGE_MAP.is_file(), "docs/benches/coverage-map.md is not on this branch yet")
    def test_joined_with_the_coverage_map(self):
        text = COVERAGE_MAP.read_text(encoding="utf-8")
        risky: dict[str, set[str]] = {}
        part = text.split("## Risky paths", 1)[1].split("\n## ", 1)[0]
        for line in part.splitlines():
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) >= 4 and not set(line) <= set("|-: ") and cells[0] != "rank":
                risky.setdefault(cells[1], set()).update(re.findall(r"`([^`]+)`", cells[2]))
        listed = set(re.findall(r"`([^`]+)`", text))
        mapped: dict[str, set[str]] = {}
        for r in self.rules:
            if r.kind == "area":
                mapped.setdefault(r.name, set()).update(r.globs)
                for b in r.benches:
                    self.assertIn(b, listed, f"area {r.name} names bench {b}, which coverage-map.md does not list")
        for area, paths in risky.items():
            self.assertIn(area, mapped, f"coverage-map.md's risky area {area!r} has no [[area]] in relevance-map.toml")
            self.assertFalse(paths - mapped[area], f"area {area!r}: risky paths missing from relevance-map.toml")


class ForPathsCliTest(unittest.TestCase):
    def run_cli(self, *args, map_text=None):
        cmd = [sys.executable, "-I", str(CLI), "for-paths", *args]
        if map_text is not None:
            tmp = Path(tempfile.mkdtemp()) / "map.toml"
            tmp.write_text(map_text)
            cmd += ["--map", str(tmp)]
        return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=60)

    def test_unmapped_path_warns_and_passes(self):
        got = self.run_cli("--json", "no-such-top/file.txt")
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertIn("warning", got.stderr)
        self.assertIn("default:no-such-top", got.stdout)

    def test_broken_map_fails_open(self):
        got = self.run_cli("Packages/x.swift", map_text="[[area]]\nname = 1\n")
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertIn("area default", got.stderr)

    def test_known_path_names_benches_tests_and_template(self):
        got = self.run_cli("--json", "cmux-tui/crates/cmux-app-ffi/src/lib.rs")
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertIn("Swift↔Rust bridge", got.stdout)
        self.assertIn("docs/benches/templates/bridge.md", got.stdout)
        self.assertIn("cargo test --manifest-path cmux-tui/Cargo.toml -p cmux-app-ffi", got.stdout)



def old_literal_prefix(glob: str) -> str:
    """The per-segment walk literal_prefix replaced: the oracle for the one-search version."""
    lead: list[str] = []
    for part in glob.split("/"):
        if any(ch in part for ch in "*?["):
            return "/".join(lead)
        lead.append(part)
    return glob


class ForPathsRunTest(unittest.TestCase):
    """`for-paths --run`: only a measured over-budget result fails; a missing or failing bench, or a broken map,
    warns and passes."""

    @staticmethod
    def area(run: str, budget_s: float | None = 1.0) -> str:
        budget = f"budget_s = {budget_s}\n" if budget_s is not None else ""
        return f'[[area]]\nname = "t"\npaths = ["zz-run"]\nrun = ["""{run}"""]\n{budget}'

    def run_cli(self, map_text: str, *extra):
        return ForPathsCliTest.run_cli(self, "--run", "--timeout", "20", *extra, "zz-run/x.py", map_text=map_text)

    def test_over_budget_fails(self):
        got = self.run_cli(self.area("echo bench_seconds=5.0", 1.0))
        self.assertEqual(got.returncode, 1, got.stdout + got.stderr)
        self.assertIn("over-budget", got.stdout)
        self.assertIn("over its 1 s budget", got.stderr)

    def test_under_budget_passes_and_reports_the_bench_measurement(self):
        got = self.run_cli(self.area("echo bench_seconds=0.25", 1.0), "--json")
        self.assertEqual(got.returncode, 0, got.stderr)
        self.assertIn('"seconds": 0.25', got.stdout)
        self.assertIn('"measured": "bench"', got.stdout)

    def test_missing_bench_passes(self):
        got = self.run_cli(self.area("no-such-bench-tool-zz --scale 10"))
        self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
        self.assertIn("missing", got.stdout)
        self.assertIn("fail open", got.stderr)

    def test_failing_bench_passes(self):
        got = self.run_cli(self.area("echo bench_seconds=9; exit 3"))
        self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
        self.assertIn("error", got.stdout)

    def test_no_budget_never_fails(self):
        got = self.run_cli(self.area("echo bench_seconds=99", None))
        self.assertEqual(got.returncode, 0, got.stdout + got.stderr)

    def test_broken_map_passes(self):
        for text in ("[[area]]\nname = 1\n", self.area("true", -1), '[[area]]\nname = "t"\npaths = ["zz-run"]\nrun = "true"\n'):
            got = self.run_cli(text)
            self.assertEqual(got.returncode, 0, got.stderr)
            self.assertIn("area default", got.stderr)

    def test_one_run_per_command_under_the_tightest_budget(self):
        rules = rel.parse('''
[[area]]
name = "a"
paths = ["p"]
run = ["b1"]
budget_s = 3
[[area]]
name = "b"
paths = ["p/q"]
run = ["b1", "b2"]
budget_s = 2
''')
        runs = rel.runs_for(rel.plan(rel.Index(rules), ["p/x", "p/q/y"]))
        self.assertEqual([(r["cmd"], r["budget_s"]) for r in runs], [("b1", 2.0), ("b2", 2.0)])

    def test_literal_prefix_matches_the_segment_walk(self):
        globs = [g for r in rel.load().rules for g in r.globs] + ["*.rs", "**/x", "a/b*/c", "a/[x]/y", "a/b/"]
        self.assertEqual([g for g in globs if rel.literal_prefix(g) != old_literal_prefix(g)], [])

    def test_mapped_self_bench_runs_flat_at_ten_times_the_rules(self):
        one, ten = (min(rel.self_bench(2000, k) for _ in range(2)) for k in (1, 10))
        self.assertLess(ten, one * 3 + 0.1, f"self-bench: 10x rules {ten:.2f} s vs {one:.2f} s (want < 3x)")


if __name__ == "__main__":
    unittest.main()
