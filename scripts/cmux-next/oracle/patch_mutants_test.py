#!/usr/bin/env python3
"""Tests for patch_mutants.py (`oracle.py selftest --mutants`, p15-oracle-115).

Run: python3 -I scripts/cmux-next/oracle/patch_mutants_test.py (stdlib unittest; selftest.py runs it).
No cargo and no fleet: the end-to-end case builds a throwaway git repository, a stand-in for
linux_run.sh that "builds" the daemon by copying its source, and a fake driver whose snapshot
depends on that build, then runs the real worktree apply/build/revert loop, oracle.run_one and
diff.py through the CLI.
"""

from __future__ import annotations

import io
import json
import subprocess
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import oracle  # noqa: E402
import patch_mutants as pm  # noqa: E402


def mutant(product="daemon", paths=("cmux-tui/src/lib.rs",), suites=(), stem="m"):
    return pm.Mutant(f"{product}/{stem}", product, Path(f"/nonexistent/{stem}.patch"), tuple(paths), tuple(suites), stem)


def outcome(verdict, product="daemon", stem="m"):
    return pm.Outcome(mutant(product, stem=stem), verdict)


def receipt(unexpected=(), flaky=(), infra=(), cases=None):
    return {"unexpected": list(unexpected), "flaky": list(flaky), "infra_errors": list(infra),
            "cases": cases or {cid: {"status": "Failure"} for cid in unexpected}}


def quiet(fn, *args, **kwargs):
    out = io.StringIO()
    with redirect_stdout(out), redirect_stderr(out):
        return fn(*args, **kwargs), out.getvalue()


class ParseTests(unittest.TestCase):
    def test_header_fields_and_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "split-drops-pane.patch"
            path.write_text(
                "From 0000 Mon Sep 17 00:00:00 2001\n"
                "Subject: [PATCH] split forgets the new pane\n"
                "Oracle-Fault: split.right returns a receipt but adds no pane\n"
                "Oracle-Suites: daemon-ops, walks\n"
                "Oracle-Suites: daemon-ops,streams\n"
                "---\n"
                "diff --git a/cmux-tui/crates/core/src/layout.rs b/cmux-tui/crates/core/src/layout.rs\n"
                "--- a/cmux-tui/crates/core/src/layout.rs\n+++ b/cmux-tui/crates/core/src/layout.rs\n"
                "@@ -1 +1 @@\n-a\n+b\n"
                "Oracle-Suites: not-a-header-inside-the-diff\n"
            )
            m = pm.parse_mutant(path, "daemon")
        self.assertEqual(m.id, "daemon/split-drops-pane")
        self.assertEqual(m.fault, "split.right returns a receipt but adds no pane")
        self.assertEqual(m.suites, ("daemon-ops", "walks", "streams"))
        self.assertEqual(m.paths, ("cmux-tui/crates/core/src/layout.rs",))
        self.assertEqual(m.path_errors(), [])

    def test_subject_is_the_default_fault(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "x.patch"
            path.write_text("Subject: [PATCH 1/1] focus skips the last pane\n\ndiff --git a/Packages/A.swift b/Packages/A.swift\n")
            self.assertEqual(pm.parse_mutant(path, "app").fault, "focus skips the last pane")

    def test_wrong_paths_make_a_mutant_unviable(self):
        self.assertTrue(mutant("daemon", ("Packages/macOS/X.swift",)).path_errors())
        self.assertTrue(mutant("app", ("cmux-tui/src/lib.rs",)).path_errors())
        self.assertTrue(mutant("daemon", ("cmux-tui/Cargo.lock",)).path_errors())
        self.assertTrue(mutant("daemon", ("ghostty-next",)).path_errors())
        self.assertTrue(mutant("daemon", ()).path_errors())
        self.assertEqual(mutant("app", ("Packages/macOS/X.swift",)).path_errors(), [])

    def test_load_mutants_filters_and_sorts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel in ("daemon/b.patch", "daemon/a.patch", "app/z.patch", "app/notes.txt"):
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                (root / rel).write_text("")
            self.assertEqual([m.id for m in pm.load_mutants(root, pm.PRODUCTS)], ["app/z", "daemon/a", "daemon/b"])
            self.assertEqual([m.id for m in pm.load_mutants(root, ("daemon",), ["*/b"])], ["daemon/b"])


class CandidateTests(unittest.TestCase):
    SIZES = {"walks": 900, "daemon-ops": 402, "streams": 19, "empty-for-product": 0}

    def test_header_suites_run_smallest_first_and_skip_empty_ones(self):
        m = mutant(suites=("walks", "daemon-ops", "streams", "empty-for-product", "unknown"))
        self.assertEqual(pm.candidate_suites(m, self.SIZES, []),
                         ([("streams", 19), ("daemon-ops", 402), ("walks", 900)], "Oracle-Suites"))

    def test_suite_map_then_every_suite(self):
        rules = [("cmux-tui/crates/core/*", ("daemon-ops", "walks")), ("Packages/*", ("actions",))]
        core = mutant(paths=("cmux-tui/crates/core/src/router.rs",))
        self.assertEqual(pm.candidate_suites(core, self.SIZES, rules),
                         ([("daemon-ops", 402), ("walks", 900)], "suite-map.json"))
        other = mutant(paths=("cmux-tui/crates/other/src/x.rs",))
        self.assertEqual(pm.candidate_suites(other, self.SIZES, rules),
                         ([("streams", 19), ("daemon-ops", 402), ("walks", 900)], "every suite"))

    def test_suite_map_formats(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "suite-map.json"
            path.write_text(json.dumps({"rules": [{"paths": ["a/*", "b/*"], "suites": ["s"]}]}))
            self.assertEqual(pm.load_suite_map(path), [("a/*", ("s",)), ("b/*", ("s",))])
            path.write_text(json.dumps({"$comment": "x", "a/*": ["s", "t"]}))
            self.assertEqual(pm.load_suite_map(path), [("a/*", ("s", "t"))])
            self.assertEqual(pm.load_suite_map(Path(tmp) / "absent.json"), [])


class JudgeTests(unittest.TestCase):
    def test_divergence_catches(self):
        verdict, reasons = pm.judge(receipt(), receipt(), {"divergent": ["s/a"], "compared": 3})
        self.assertEqual((verdict, reasons), (pm.CAUGHT, ["divergent: s/a"]))

    def test_new_unexpected_result_catches_but_a_base_red_does_not(self):
        verdict, reasons = pm.judge(receipt(["s/old"]), receipt(["s/old", "s/new"], cases={"s/old": {}, "s/new": {"status": "Crash"}}),
                                    {"divergent": [], "compared": 2})
        self.assertEqual((verdict, reasons), (pm.CAUGHT, ["new unexpected result: s/new (Crash)"]))
        verdict, _ = pm.judge(receipt(["s/old"]), receipt(["s/old"]), {"divergent": [], "compared": 2})
        self.assertEqual(verdict, pm.SURVIVED)

    def test_new_invariant_violation_catches(self):
        verdict, reasons = pm.judge(receipt(), receipt(), {"divergent": [], "compared": 1},
                                    [("I2", "s/a", "/topology/panes/0/id")])
        self.assertEqual(verdict, pm.CAUGHT)
        self.assertIn("I2", reasons[0])

    def test_flaky_only_survives(self):
        verdict, reasons = pm.judge(receipt(), receipt(flaky=["s/a"]), {"divergent": [], "compared": 4})
        self.assertEqual(verdict, pm.SURVIVED)
        self.assertIn("flaky only", reasons[0])

    def test_refused_or_infra_is_unmeasured(self):
        self.assertEqual(pm.judge(receipt(), receipt(), {"refused": "host-mismatch: os"})[0], pm.UNMEASURED)
        self.assertEqual(pm.judge(receipt(infra=["lost"]), receipt(), {"divergent": ["s/a"]})[0], pm.UNMEASURED)

    def test_violation_key_accepts_dicts_and_objects(self):
        class V:
            id, case, pointer = "I1", "s/a", "/x"

        self.assertEqual(pm.violation_key({"id": "I1", "case": "s/a", "pointer": "/x"}), pm.violation_key(V()))


class GateTests(unittest.TestCase):
    FULL = {"app": True, "daemon": True}

    def outcomes(self, app_caught, daemon_caught, rest=pm.MISSED):
        return ([outcome(pm.CAUGHT if i < app_caught else rest, "app", f"a{i}") for i in range(10)]
                + [outcome(pm.CAUGHT if i < daemon_caught else rest, "daemon", f"d{i}") for i in range(10)])

    def test_required_counts(self):
        self.assertEqual(pm.required(20, pm.TOTAL_RATE), 19)
        self.assertEqual(pm.required(10, pm.PRODUCT_RATE), 9)
        self.assertEqual(pm.required(0, pm.TOTAL_RATE), 0)

    def test_nineteen_of_twenty_passes_eighteen_fails(self):
        self.assertEqual(pm.gate(self.outcomes(10, 9), self.FULL)[1], pm.EXIT_OK)
        report, code = pm.gate(self.outcomes(9, 9), self.FULL)
        self.assertEqual(code, pm.EXIT_FAILED)
        self.assertEqual(report["total"]["state"], "fail")
        self.assertEqual(report["products"]["app"]["state"], "pass")

    def test_unviable_counts_as_not_caught(self):
        self.assertEqual(pm.gate(self.outcomes(10, 8, rest=pm.UNVIABLE), self.FULL)[1], pm.EXIT_FAILED)

    def test_unmeasured_is_undecided_unless_already_failed_or_passed(self):
        self.assertEqual(pm.gate(self.outcomes(10, 8, rest=pm.UNMEASURED), self.FULL)[1], pm.EXIT_UNDECIDED)
        mixed = self.outcomes(10, 9)
        mixed[-1] = outcome(pm.UNMEASURED, "daemon", "d9")
        self.assertEqual(pm.gate(mixed, self.FULL)[1], pm.EXIT_OK)
        failed = self.outcomes(6, 10)
        failed[-1] = outcome(pm.UNMEASURED, "daemon", "d9")
        self.assertEqual(pm.gate(failed, self.FULL)[1], pm.EXIT_FAILED)

    def test_one_product_applies_its_own_gate_only(self):
        daemon = self.outcomes(0, 9)[10:]
        report, code = pm.gate(daemon, {"daemon": True})
        self.assertEqual(code, pm.EXIT_OK)
        self.assertFalse(report["total"]["applies"])

    def test_a_subset_needs_every_selected_mutant(self):
        subset = [outcome(pm.CAUGHT, stem="a"), outcome(pm.MISSED, stem="b")]
        self.assertEqual(pm.gate(subset, {"daemon": False})[1], pm.EXIT_FAILED)
        self.assertEqual(pm.gate(subset[:1], {"daemon": False})[1], pm.EXIT_OK)

    def test_corpus_gap_lines_for_missed_mutants_only(self):
        missed = pm.Outcome(mutant(stem="gap"), pm.MISSED, trials=[pm.Trial("streams", 19, pm.SURVIVED), pm.Trial("walks", 900, pm.SURVIVED)])
        none = pm.Outcome(mutant(stem="nothing"), pm.MISSED)
        lines = pm.corpus_gaps([missed, none, outcome(pm.CAUGHT), outcome(pm.UNVIABLE), outcome(pm.UNMEASURED)], "abc")
        self.assertEqual([line["mutant"] for line in lines], ["daemon/gap", "daemon/nothing"])
        self.assertEqual(lines[0]["queue"], "MQ-mutants")
        self.assertEqual(lines[0]["suites_tried"], ["streams", "walks"])
        self.assertIn("the streams suite", lines[0]["task"])
        self.assertIn("no runnable case", lines[1]["task"])


class EvaluateTests(unittest.TestCase):
    class Scripted(pm.Backend):
        def __init__(self, verdicts):
            self.verdicts, self.calls = verdicts, []

        def trial(self, m, suite, cases, out):
            self.calls.append((m.id, suite))
            verdict = self.verdicts.get((m.id, suite), pm.SURVIVED)
            if verdict == "mutant-error":
                raise pm.MutantError("does not compile")
            if verdict == "infra":
                raise pm.InfraError("driver lost")
            return pm.Trial(suite, cases, verdict)

    def cases(self, tmp):
        for suite, n in (("small", 2), ("large", 5)):
            for i in range(n):
                path = Path(tmp) / "corpus" / suite / f"c{i}.json"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps({"steps": [{"id": "s", "op": "snapshot"}]}))
        cases, errors = oracle.load_corpus(Path(tmp) / "corpus")
        self.assertEqual(errors, [])
        return cases

    def test_stops_at_the_smallest_catching_suite(self):
        with tempfile.TemporaryDirectory() as tmp:
            backend = self.Scripted({("daemon/a", "small"): pm.CAUGHT, ("daemon/b", "large"): pm.CAUGHT,
                                     ("daemon/c", "small"): "mutant-error", ("daemon/d", "small"): "infra"})
            ms = [mutant(stem=s) for s in "abcde"]
            results, _ = quiet(pm.evaluate, ms, {"daemon": backend}, self.cases(tmp), [], Path(tmp) / "out", lambda m: None)
        self.assertEqual([(o.mutant.id, o.verdict, o.caught_by) for o in results], [
            ("daemon/a", pm.CAUGHT, "small"), ("daemon/b", pm.CAUGHT, "large"), ("daemon/c", pm.UNVIABLE, None),
            ("daemon/d", pm.UNMEASURED, None), ("daemon/e", pm.MISSED, None)])
        self.assertEqual(backend.calls, [("daemon/a", "small"), ("daemon/b", "small"), ("daemon/b", "large"),
                                         ("daemon/c", "small"), ("daemon/d", "small"), ("daemon/d", "large"),
                                         ("daemon/e", "small"), ("daemon/e", "large")])

    def test_apply_check_failure_and_missing_backend(self):
        with tempfile.TemporaryDirectory() as tmp:
            ms = [mutant(stem="a"), mutant("app", ("Packages/X.swift",), stem="b")]
            results, _ = quiet(pm.evaluate, ms, {"daemon": self.Scripted({}), "app": None}, self.cases(tmp), [],
                               Path(tmp) / "out", lambda m: "patch does not apply" if m.id == "daemon/a" else None)
        self.assertEqual([o.verdict for o in results], [pm.UNVIABLE, pm.UNMEASURED])
        self.assertIn("git apply --check", results[0].error)

    def test_a_failed_base_build_stops_the_daemon_backend(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo = root / "repo"
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
                            "--allow-empty", "-m", "base"], check=True)
            failing = root / "build.sh"
            failing.write_text("#!/usr/bin/env bash\necho 'error: base does not compile' >&2\nexit 101\n")
            backend = pm.VmDaemonBackend(repo=repo, sha="HEAD", out=root / "out", corpus=root / "corpus",
                                         expectations_root=root, worktree_base=root / "wt", target_dir=root / "t",
                                         jobs=1, build_script=failing)
            try:
                for _ in range(2):
                    with self.assertRaisesRegex(pm.InfraError, "base: build of base failed"):
                        backend.trial(mutant(), "s", 1, root / "trial")
            finally:
                backend.close()

    def test_app_without_fleet_py_is_unmeasured(self):
        backend = pm.FleetAppBackend(sha="abc", fleet=Path("/nonexistent/fleet.py"))
        with self.assertRaises(pm.InfraError):
            backend.trial(mutant("app", ("Packages/X.swift",)), "actions", 3, Path("/tmp/none"))


class CliTests(unittest.TestCase):
    def test_oracle_selftest_mutants_routes_here(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = subprocess.run([sys.executable, "-I", str(HERE / "oracle.py"), "selftest", "--mutants",
                                   "--mutants-root", tmp, "--list"], check=False, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        self.assertEqual(proc.returncode, pm.EXIT_USAGE)
        self.assertIn("no mutants under", proc.stderr)
        self.assertIn("p15-oracle-026", proc.stderr)


# ------------------------------------------------------------------------------------- end to end


FAKE_BUILD = r"""#!/usr/bin/env bash
# Stand-in for linux_run.sh build: the "binary" is a copy of the daemon's source.
set -euo pipefail
[[ "$1" == build ]]; shift
while (($#)); do case "$1" in --checkout) co="$2"; shift 2 ;; --target-dir) td="$2"; shift 2 ;; *) shift ;; esac; done
grep -q COMPILE_ERROR "$co/cmux-tui/src/lib.rs" && { echo "error: does not compile" >&2; exit 101; }
mkdir -p "$td/oracle"
cp "$co/cmux-tui/src/lib.rs" "$td/oracle/cmux-tui"
echo "cargo noise"
echo "$td/oracle/cmux-tui"
"""


class SourceDriver:
    """Snapshot of a `beta` case is the built source; `alpha` cases never see the daemon's change."""

    def __init__(self):
        self.mutex = threading.Lock()  # test bookkeeping across the runner's worker threads
        self.binaries = set()

    def open_session(self, ctx):
        driver, binary = self, ctx["binary"]
        with self.mutex:
            self.binaries.add(binary)

        class Session:
            def run_case(self, case, case_ctx):
                source = Path(binary).read_text()
                value = source if case_ctx["suite"] == "beta" else "constant"
                if "CRASH" in source and case_ctx["suite"] == "gamma":
                    return {"status": "Crash", "checkpoints": [], "message": "daemon exited"}
                return {"status": "Pass", "checkpoints": [
                    {"step": "s1", "checkpoint": "settled", "snapshot": {"topology": {"panes": 1}, "value": value}}]}

            def close(self):
                pass

        return Session()


def patch_text(subject, path, old, new, suites=None):
    header = f"Subject: [PATCH] {subject}\n" + (f"Oracle-Suites: {suites}\n" if suites else "") + "---\n"
    return (header + f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n"
            f"@@ -1 +1 @@\n-{old}\n+{new}\n")


class EndToEndTests(unittest.TestCase):
    def test_worktree_build_revert_and_gate(self):
        with tempfile.TemporaryDirectory(prefix="oracle-mutants-test-") as tmp:
            root = Path(tmp)
            repo = root / "repo"
            (repo / "cmux-tui" / "src").mkdir(parents=True)
            (repo / "cmux-tui" / "src" / "lib.rs").write_text("fn add(a: i32, b: i32) -> i32 { a + b }\n")
            (repo / "cmux-tui" / "NOTES.md").write_text("notes\n")
            for args in (["init", "-q"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base"]):
                subprocess.run(["git", "-C", str(repo), *args], check=True)
            mutants = root / "mutants" / "daemon"
            mutants.mkdir(parents=True)
            lib = "fn add(a: i32, b: i32) -> i32 { a + b }"
            (mutants / "add-subtracts.patch").write_text(patch_text(
                "add subtracts", "cmux-tui/src/lib.rs", lib, "fn add(a: i32, b: i32) -> i32 { a - b }", "beta,alpha"))
            (mutants / "notes-only.patch").write_text(patch_text("notes only", "cmux-tui/NOTES.md", "notes", "changed"))
            (mutants / "stale.patch").write_text(patch_text("stale", "cmux-tui/src/lib.rs", "fn gone()", "fn x()"))
            (mutants / "no-build.patch").write_text(patch_text("no build", "cmux-tui/src/lib.rs", lib, "COMPILE_ERROR"))
            (mutants / "crash.patch").write_text(patch_text("crash", "cmux-tui/src/lib.rs", lib, "CRASH", "gamma"))
            for suite, n in (("alpha", 2), ("beta", 4), ("gamma", 3)):
                for i in range(n):
                    path = root / "corpus" / suite / f"c{i}.json"
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(json.dumps({"steps": [{"id": "s1", "op": "snapshot"}]}))
            build = root / "fake_build.sh"
            build.write_text(FAKE_BUILD)
            out = Path(tempfile.mkdtemp(prefix="oracle-mutants-out-"))
            sha = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], check=True, stdout=subprocess.PIPE,
                                 text=True).stdout.strip()
            driver = SourceDriver()
            backend = pm.VmDaemonBackend(repo=repo, sha=sha, out=out / "daemon", corpus=root / "corpus",
                                         expectations_root=root / "expectations", worktree_base=root / "wt",
                                         target_dir=root / "target", jobs=4, build_script=build,
                                         open_session=driver.open_session)
            code, log = quiet(pm.main, ["--repo", str(repo), "--mutants-root", str(root / "mutants"), "--product",
                                        "daemon", "--corpus", str(root / "corpus"), "--expectations-root",
                                        str(root / "expectations"), "--out", str(out)],
                              backends={"daemon": backend})
            document = json.loads((out / "mutants.json").read_text())
            by_id = {m["id"]: m for m in document["mutants"]}
            gaps = [json.loads(line) for line in (out / "corpus-gaps.jsonl").read_text().splitlines()]
            worktrees = subprocess.run(["git", "-C", str(repo), "worktree", "list"], check=True,
                                       stdout=subprocess.PIPE, text=True).stdout

        self.assertEqual(code, pm.EXIT_FAILED, log)
        # Oracle-Suites beta,alpha: alpha (2 cases) runs first and survives, beta catches.
        add = by_id["daemon/add-subtracts"]
        self.assertEqual((add["verdict"], add["caught_by"]), (pm.CAUGHT, "beta"), add)
        self.assertEqual([(t["suite"], t["verdict"]) for t in add["trials"]], [("alpha", "survived"), ("beta", "caught")])
        self.assertTrue(any(r.startswith("divergent: beta/") for r in add["trials"][1]["reasons"]))
        crash = by_id["daemon/crash"]
        self.assertEqual((crash["verdict"], crash["caught_by"]), (pm.CAUGHT, "gamma"))
        self.assertIn("new unexpected result: gamma/c0 (Crash)", crash["trials"][0]["reasons"])
        # No header and no suite map: every suite, smallest first, none catches a notes change.
        notes = by_id["daemon/notes-only"]
        self.assertEqual(notes["verdict"], pm.MISSED)
        self.assertEqual([t["suite"] for t in notes["trials"]], ["alpha", "gamma", "beta"])
        self.assertEqual(by_id["daemon/stale"]["verdict"], pm.UNVIABLE)
        self.assertIn("git apply --check", by_id["daemon/stale"]["error"])
        self.assertEqual(by_id["daemon/no-build"]["verdict"], pm.UNVIABLE)
        self.assertIn("does not compile", by_id["daemon/no-build"]["error"])
        self.assertEqual([g["mutant"] for g in gaps], ["daemon/notes-only"])
        gate = document["gate"]["products"]["daemon"]
        self.assertEqual((gate["caught"], gate["mutants"], gate["required"], gate["state"]), (2, 5, 5, "fail"))
        # Base, then each viable patch built once; the worktree was clean after every revert and is gone.
        self.assertEqual(len(driver.binaries), 4)
        self.assertNotIn(str(root / "wt"), worktrees)


if __name__ == "__main__":
    unittest.main()
