#!/usr/bin/env python3
"""Tests for scripts/ci/warm_distance.py: distance features, the admission record, routing and the fit."""

from __future__ import annotations

import datetime as dt
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
sys.path.insert(0, str(ROOT / "tests"))

import owned_build_state as state  # noqa: E402
import warm_distance as wd  # noqa: E402
import git_fixture_env  # noqa: E402,F401  (disables git auto maintenance)

NOW = dt.datetime(2026, 9, 26, 3, 0, tzinfo=dt.timezone.utc)
ROOT_LABEL = "glaeda-root-std-xcode-26.6"


def label(name: str) -> str:
    return f"glaeda-runner-{name}"


def runner(name: str, busy: bool = False) -> dict:
    return {"name": name, "status": "online", "busy": busy,
            "labels": [{"name": ROOT_LABEL}, {"name": label(name)}]}


MODEL = {
    "near_app_swift_files": 5,
    "hot_files": ["Sources/DockPanelView.swift"],
    "tiers": {"near": {"p50": 140.0}, "far": {"p50": 270.0}, "rebuild": {"p50": 400.0}},
    "start_classes": {"base": {"expected": 300.0, "by_job_tier": {"near": {"expected": 120.0}}},
                      "pr": {"expected": 200.0}, "none": {"expected": 350.0}},
    "job_seconds": {"macos-compile-admission": {"p50": 420.0, "p90": 800.0}},
}


class Features(unittest.TestCase):
    def test_app_swift_files_leave_out_tests(self):
        paths = ["Sources/A.swift", "cmuxTests/ATests.swift", "Packages/macOS/X/Tests/XTests/T.swift",
                 "Packages/macOS/X/Sources/X/X.swift", "README.md", "cmuxUITests/U.swift"]
        feature = wd.features(paths, interface=False)
        self.assertEqual((feature["app_swift_files"], feature["package_swift_files"]), (2, 1))
        self.assertIs(feature["package_interface"], False)
        # No package change: the interface flag is False whatever was passed.
        self.assertIs(wd.features(["Sources/A.swift"], interface=None)["package_interface"], False)

    def test_tiers(self):
        near = wd.features([f"Sources/F{i}.swift" for i in range(5)], interface=False)
        far = wd.features([f"Sources/F{i}.swift" for i in range(6)], interface=False)
        self.assertEqual((wd.tier(near, MODEL), wd.tier(far, MODEL)), ("near", "far"))
        # A package interface change, or one git could not read, rebuilds the app; an implementation-only one does not.
        package = ["Packages/macOS/X/Sources/X/X.swift"]
        self.assertEqual(wd.tier(wd.features(package, interface=True), MODEL), "rebuild")
        self.assertEqual(wd.tier(wd.features(package, interface=None), MODEL), "rebuild")
        self.assertEqual(wd.tier(wd.features(package, interface=False), MODEL), "near")
        hot = wd.features(["Sources/DockPanelView.swift"], interface=False, hot_files=MODEL["hot_files"])
        self.assertEqual(wd.tier(hot, MODEL), "rebuild")
        self.assertEqual(wd.predict(far, MODEL), ("far", 270.0))
        self.assertEqual(wd.predict(far, {}), ("far", None))

    def test_interface_lines(self):
        for line in ("+public func run() {}", "-    public var x: Int", "+  @MainActor public final class A {",
                     "+open class B {}", "+package struct C {}", "+@inlinable func d() {}",
                     "-@usableFromInline internal let e = 1", "+@_exported import Foo"):
            self.assertTrue(wd.interface_change(line), line)
        for line in ("+    let value = compute()", "+func helper() {}", "+// public API note",
                     "+++ b/Packages/X.swift", "--- a/Packages/X.swift", " public func unchanged() {}"):
            self.assertFalse(wd.interface_change(line), line)

    def test_swift_units_count_each_file_of_a_batch(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp, "cmux-build.log")
            log.write_text(
                "SwiftCompile normal arm64 Compiling A.swift, B.swift /s/A.swift /s/B.swift (in target 'cmux' from project 'cmux')\n"
                "SwiftCompile normal arm64 Compiling\\ C.swift /s/C.swift (in target 'cmux' from project 'cmux')\n"
                "SwiftCompile normal arm64 /s/C.swift (in target 'cmux' from project 'cmux')\n"
                "SwiftCompile normal arm64 Compiling P.swift /p/P.swift (in target 'CmuxKit' from project 'CmuxKit')\n"
                "SwiftDriver cmux normal arm64 (in target 'cmux')\n")
            self.assertEqual(wd.swift_units(log), {"cmux": 3, "CmuxKit": 1})


class StartDistance(unittest.TestCase):
    def test_record_writes_the_changed_swift_paths_from_the_adopted_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, derived, out = Path(tmp, "src"), Path(tmp, "dd"), Path(tmp, "start.json")
            (source / "Sources").mkdir(parents=True)
            for name in ("A", "B"):
                (source / "Sources" / f"{name}.swift").write_text(name)
            derived.mkdir()
            start = state.seed.warm.record(source)
            (derived / state.seed.MANIFEST).write_text(json.dumps(start))  # a seed's record
            (source / "Sources" / "B.swift").write_text("changed")
            (source / "Sources" / "C.swift").write_text("new")
            with unittest.mock.patch("sys.stdout", io.StringIO()):
                state.record(source, derived, str(out))
            document = json.loads(out.read_text())
            self.assertEqual(document["start"], "warm")
            self.assertEqual(document["swift_paths"], ["Sources/B.swift", "Sources/C.swift"])
            # The owned record now describes this compile; the next start compares against it.
            self.assertTrue((derived / state.RECORD).is_file())

    def test_the_path_cap_keeps_package_changes_and_leaves_out_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp, "start.json")
            changed = {f"Sources/F{i:04}.swift" for i in range(wd.MAX_PATHS + 50)}
            changed |= {"vendor/bonsplit/Sources/B.swift", "cmuxTests/T.swift"}
            wd.start_distance({}, {}, changed, out)
            document = json.loads(out.read_text())
            self.assertIn("vendor/bonsplit/Sources/B.swift", document["swift_paths"])
            self.assertNotIn("cmuxTests/T.swift", document["swift_paths"])
            self.assertEqual((len(document["swift_paths"]), document["swift_paths_total"]),
                             (wd.MAX_PATHS, wd.MAX_PATHS + 51))

    def test_a_cold_start_says_so(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, derived, out = Path(tmp, "src"), Path(tmp, "dd"), Path(tmp, "start.json")
            source.mkdir()
            (source / "A.swift").write_text("a")
            with unittest.mock.patch("sys.stdout", io.StringIO()):
                state.record(source, derived, str(out))
            self.assertEqual(json.loads(out.read_text()), {"start": "cold"})


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


class Keep(unittest.TestCase):
    def test_keep_drops_the_previous_builds_own_diff(self):
        with tempfile.TemporaryDirectory() as tmp:
            store, derived = Path(tmp, "store"), Path(tmp, "dd")
            derived.mkdir()
            store.mkdir()
            (store / "stamp.json").write_text(json.dumps({"fingerprint": "x", "pr": 3, "pr_app_swift_files": ["A.swift"],
                                                          "pr_package_interface": True, "pr_app_swift_total": 1}))
            with unittest.mock.patch("owned_build_state.subprocess.run") as run:
                run.return_value.returncode = 1
                state.keep(store, derived, "fp", "a" * 40, "9")
            stamp = json.loads((store / "stamp.json").read_text())
            self.assertEqual(stamp["pr"], 9)
            self.assertFalse({"pr_app_swift_files", "pr_package_interface", "pr_app_swift_total"} & set(stamp))

    def test_a_failed_distance_never_costs_the_record(self):
        with tempfile.TemporaryDirectory() as tmp:
            source, derived = Path(tmp, "src"), Path(tmp, "dd")
            source.mkdir()
            (source / "A.swift").write_text("a")
            with unittest.mock.patch("sys.stdout", io.StringIO()), \
                    unittest.mock.patch.object(wd, "start_distance", side_effect=KeyError("boom")):
                self.assertEqual(state.record(source, derived, str(Path(tmp, "out.json")))["recorded"], "true")
            self.assertTrue((derived / state.RECORD).is_file())


class Admission(unittest.TestCase):
    def test_one_line_per_admission_and_the_stamp_learns_the_pull_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo, store = tmp / "repo", tmp / "store"
            (repo / "Sources").mkdir(parents=True)
            (repo / "Packages/macOS/X/Sources/X").mkdir(parents=True)
            package = repo / "Packages/macOS/X/Sources/X/X.swift"
            package.write_text("public func a() {}\n")
            (repo / "Sources/A.swift").write_text("a\n")
            git(repo, "init", "-q")
            git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "add", ".")
            git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base")
            base = git(repo, "rev-parse", "HEAD")
            package.write_text("public func a() {}\npublic func b() {}\n")
            (repo / "Sources/A.swift").write_text("b\n")
            git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "pr")
            store.mkdir()
            (store / "stamp.json").write_text(json.dumps({"fingerprint": "f-owned-rec1", "merged_onto": base, "pr": 5}))
            start = tmp / "start.json"
            start.write_text(json.dumps({"start": "warm", "changed_inputs": 3, "swift_paths_total": 2,
                                         "swift_paths": ["Packages/macOS/X/Sources/X/X.swift", "Sources/A.swift"]}))
            logs = tmp / "dd"
            logs.mkdir()
            (logs / "cmux-build.log").write_text("".join(
                f"SwiftCompile normal arm64 Compiling F{i}.swift /s/F{i}.swift (in target 'cmux' from project 'cmux')\n"
                for i in range(1200)))
            metrics = tmp / "metrics.json"
            metrics.write_text(json.dumps({"compile_duration_seconds": 401.5, "total_macos_compile_admission_seconds": 600,
                                           "queue_to_start_seconds": 4}))
            env = {"MERGED_ONTO": base, "PR_NUMBER": "7", "HEAD_SHA": "e" * 40, "GITHUB_SHA": git(repo, "rev-parse", "HEAD"),
                   "CMUX_WARM_DISTANCE_START": str(start), "CMUX_WARM_START_STAMP": str(store / "stamp.json"),
                   "OWNED_ADOPT_HIT": "true", "KEPT": "true", "COMPILE_OUTCOME": "success", "METRICS": str(metrics),
                   "BUILD_LOGS": str(logs), "RUNNER_NAME": "cmux14-glaeda-1", "GITHUB_RUN_ID": "1",
                   "ADMISSION_RUNNER": json.dumps([ROOT_LABEL, label("cmux14-glaeda-1")]),
                   "PICKER_ROUTE": json.dumps({"mode": "distance", "chosen": "cmux14-glaeda-1", "predicted": 140.0,
                                               "baseline": 266.5, "candidates": []})}
            with unittest.mock.patch.object(wd, "load_model", return_value=MODEL):
                record = wd.admission(store, env, repo, lambda: NOW)
            line = json.loads((store / wd.LOG_NAME).read_text().splitlines()[-1])
            self.assertEqual(line, json.loads(json.dumps(record)))
            self.assertEqual(record["start"], {"kind": "kept", "merged_onto": base, "pr": 5})
            distance = record["distance"]
            self.assertEqual((distance["app_swift_files"], distance["package_swift_files"]), (2, 1))
            self.assertIs(distance["package_interface"], True)
            self.assertEqual((distance["same_base"], distance["same_pr"]), (True, False))
            self.assertEqual((record["tier"], record["predicted_seconds"]), ("rebuild", 400.0))
            self.assertEqual((record["swift_units_total"], record["app_rebuilt"], record["compile_seconds"]),
                             (1200, True, 401.5))
            self.assertEqual(record["own"]["app_swift_files"], 2)
            self.assertEqual(record["route"]["picker"]["chosen"], "cmux14-glaeda-1")
            self.assertEqual(record["route"]["picker"]["predicted"], 140.0)
            stamp = json.loads((store / "stamp.json").read_text())
            self.assertEqual(stamp["pr_app_swift_files"], ["Packages/macOS/X/Sources/X/X.swift", "Sources/A.swift"])
            self.assertIs(stamp["pr_package_interface"], True)
            self.assertEqual(stamp["merged_onto"], base)  # keep's fields stay
            self.assertTrue((store / wd.HOOK_MODEL_NAME).is_file())
            # Root 2's store writes to the mini's one log and model copy, beside root 1's stamp.
            self.assertEqual(wd.fleet_dir(store / "cmux-ci-2"), store)
            self.assertEqual(wd.fleet_dir(store), store)
            self.assertIn("start: kept", wd.summary_line(record))

    def test_the_command_never_fails_the_job(self):
        with tempfile.TemporaryDirectory() as tmp, unittest.mock.patch("sys.stdout", io.StringIO()), \
                unittest.mock.patch.object(wd, "admission", side_effect=OSError("disk")):
            self.assertEqual(wd.main(["warm_distance.py", "admission", tmp]), 0)


class Routing(unittest.TestCase):
    def route(self, runners, *, running=None, job_tier="near", max_wait=600.0, base=(), pr=()):
        return wd.route_admission(runners, ROOT_LABEL, base_warm=base, pr_warm=pr, running=running or {},
                                  job_tier=job_tier, model=MODEL, now=NOW, max_wait=max_wait, runner_label=label)

    def test_an_idle_warm_runner_wins_by_its_predicted_compile(self):
        name, decision = self.route([runner("a"), runner("b")], base={"b"})
        self.assertEqual(name, "b")
        self.assertEqual(decision["baseline_seconds"], 350.0)
        self.assertEqual(decision["candidates"], [{"runner": "b", "start": "base", "wait": 0.0,
                                                   "compile": 120.0, "cost": 120.0}])
        # The start class's overall value when the job's tier has no cell.
        self.assertEqual(self.route([runner("a"), runner("b")], base={"b"}, job_tier="far")[1]["candidates"][0]["compile"], 300.0)

    def test_a_small_saving_is_not_worth_a_pin(self):
        model = {**MODEL, "start_classes": {"base": {"expected": 330.0}, "none": {"expected": 350.0}}}
        name, decision = wd.route_admission([runner("a"), runner("b")], ROOT_LABEL, base_warm={"b"}, pr_warm=(),
                                            running={}, job_tier="near", model=model, now=NOW, max_wait=600,
                                            runner_label=label)
        self.assertEqual(name, "")
        self.assertIn("does not beat", decision["why"])

    def test_a_busy_warm_runner_counts_its_wait(self):
        almost = {"b": {"job": "macOS / macOS compile admission",
                        "started_at": (NOW - dt.timedelta(seconds=400)).strftime("%Y-%m-%dT%H:%M:%SZ")}}
        self.assertEqual(self.route([runner("a"), runner("b", busy=True)], base={"b"}, running=almost)[0], "b")
        # Past the rescue-covered wait, with nothing known about its job, or past its p90, it is not taken.
        self.assertEqual(self.route([runner("a"), runner("b", busy=True)], base={"b"}, running=almost, max_wait=30)[0], "")
        self.assertEqual(self.route([runner("a"), runner("b", busy=True)], base={"b"})[0], "")
        hung = {"b": {**almost["b"], "started_at": (NOW - dt.timedelta(seconds=900)).strftime("%Y-%m-%dT%H:%M:%SZ")}}
        self.assertEqual(self.route([runner("a"), runner("b", busy=True)], base={"b"}, running=hung)[0], "")

    def test_when_every_root_runner_is_busy_the_root_label_waits_too(self):
        started = (NOW - dt.timedelta(seconds=100)).strftime("%Y-%m-%dT%H:%M:%SZ")
        running = {name: {"job": "macOS compile admission", "started_at": started} for name in ("a", "b")}
        name, decision = self.route([runner("a", busy=True), runner("b", busy=True)], pr={"b"}, running=running)
        # Both finish in 320 s: the root label costs 320 + 350, the pin 320 + 200.
        self.assertEqual((name, decision["baseline_seconds"]), ("b", 670.0))
        # An idle root runner without its own label still takes the root label at once.
        bare = {"name": "c", "status": "online", "busy": False, "labels": [{"name": ROOT_LABEL}]}
        self.assertEqual(self.route([runner("a", busy=True), runner("b", busy=True), bare], pr={"b"},
                                    running=running)[1]["baseline_seconds"], 350.0)

    def test_no_model_no_route(self):
        name, decision = wd.route_admission([runner("a")], ROOT_LABEL, base_warm={"a"}, pr_warm=(), running={},
                                            job_tier="near", model={}, now=NOW, max_wait=600, runner_label=label)
        self.assertEqual((name, decision["why"]), ("", "no model"))

    def test_remaining_seconds(self):
        def entry(seconds, job="macOS / macOS compile admission"):
            return {"job": job, "started_at": (NOW - dt.timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")}
        self.assertEqual(wd.remaining_seconds(entry(20), MODEL, NOW), 400.0)
        self.assertEqual(wd.remaining_seconds(entry(500), MODEL, NOW), 300.0)  # past the p50: the p90 less its run
        self.assertEqual(wd.remaining_seconds(entry(790), MODEL, NOW), 60.0)
        self.assertIsNone(wd.remaining_seconds(entry(810), MODEL, NOW))  # past its p90: it may hang
        self.assertIsNone(wd.remaining_seconds(entry(10, "app-host unit tests (3)"), MODEL, NOW))
        self.assertIsNone(wd.remaining_seconds(None, MODEL, NOW))
        self.assertEqual(wd.job_key("macOS / app-host unit tests (3)"), "app-host-unit-tests")

    def test_the_wait_limit_follows_the_queue_rounds(self):
        self.assertEqual([wd.routed_wait_limit(rounds) for rounds in (0, 1, 2, None)], [0, 600, 600, 0])


HOOK_BASE = "b" * 40
HOOK_MODEL = {"near_app_swift_files": 5, "hot_files": ["Sources/Hot.swift"],
              "tiers": {"near": {"p50": 140.0}, "far": {"p50": 266.5}, "rebuild": {"p50": 400.7}},
              "start_classes": {"none": {"expected": 309.7}}}


def swift(*numbers: int) -> set[str]:
    return {f"Sources/F{number}.swift" for number in numbers}


PACKAGE = "Packages/macOS/X/Sources/X/X.swift"
# (main's changes, the root's stamp, the job's pull request) -> what glaeda's hook (warm_root_costs())
# answered for that root on 2026-09-27 (teamleaderleo/glaeda 6ff2366f).
HOOK_CASES = [
    ((None, None, 7), (401.7, "cold", -1)),
    (((swift(1), False), {"merged_onto": HOOK_BASE, "pr": 5}, 7), (309.7, "unknown", -1)),
    (((swift(1, 2), False), {"merged_onto": HOOK_BASE, "pr": 7}, 7), (140.0, "near", 2)),
    ((None, {"merged_onto": HOOK_BASE, "pr": 5, "pr_app_swift_files": []}, 7), (309.7, "unknown", -1)),
    (((swift(1, 2, 3), False), {"merged_onto": HOOK_BASE, "pr": 5, "pr_app_swift_files": sorted(swift(3, 4, 5)),
                                "pr_app_swift_total": 3, "pr_package_interface": False}, 7), (140.0, "near", 5)),
    (((swift(1, 2, 3, 4, 5, 6), False), {"merged_onto": HOOK_BASE}, 7), (266.5, "far", 6)),
    (((swift(1), True), {"merged_onto": HOOK_BASE, "pr": 5, "pr_app_swift_files": [], "pr_app_swift_total": 0,
                         "pr_package_interface": False}, 7), (400.7, "rebuild", 1)),
    (((swift(1), False), {"merged_onto": HOOK_BASE, "pr": 5, "pr_app_swift_files": [PACKAGE], "pr_app_swift_total": 1,
                          "pr_package_interface": None}, 7), (400.7, "rebuild", 2)),
    (((swift(1), False), {"merged_onto": HOOK_BASE, "pr": 5, "pr_app_swift_files": [PACKAGE], "pr_app_swift_total": 1,
                          "pr_package_interface": False}, 7), (140.0, "near", 2)),
    (((swift(1), False), {"merged_onto": HOOK_BASE, "pr": 5, "pr_app_swift_files": sorted(swift(9)),
                          "pr_app_swift_total": 3, "pr_package_interface": False}, 7), (140.0, "near", 4)),
    (((swift(1), False), {"merged_onto": HOOK_BASE, "pr": 5, "pr_app_swift_files": sorted(swift(9)),
                          "pr_app_swift_total": 3}, 7), (400.7, "rebuild", 4)),
    ((({"Sources/Hot.swift"}, False), {"merged_onto": HOOK_BASE}, 7), (400.7, "rebuild", 1)),
    (((set(), False), {"merged_onto": HOOK_BASE, "pr": 5, "pr_app_swift_files": ["Sources/Hot.swift", "cmuxTests/T.swift"],
                       "pr_app_swift_total": 1, "pr_package_interface": False}, None), (400.7, "rebuild", 1)),
]


def glaeda_hook():
    """glaeda's hook module, from GLAEDA_HOOK or a glaeda checkout beside this one, or None."""
    import importlib.machinery
    import importlib.util
    candidates = [os.environ.get("GLAEDA_HOOK") or "", str(ROOT.parent / "glaeda/scripts/glaeda-cmux-runner-hook"),
                  str(ROOT.parent.parent / "glaeda/scripts/glaeda-cmux-runner-hook")]
    path = next((candidate for candidate in candidates if candidate and Path(candidate).is_file()), None)
    if path is None:
        return None
    loader = importlib.machinery.SourceFileLoader("glaeda_cmux_runner_hook", path)
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module if hasattr(module, "warm_root_costs") else None


class HookParity(unittest.TestCase):
    """hook_root_cost(), hook_model() and hook_changes() answer as glaeda's hook does."""

    def test_the_recorded_answers(self):
        model = wd.hook_model(HOOK_MODEL)
        for (changes, stamp, number), expected in HOOK_CASES:
            seconds, name, files = wd.hook_root_cost(changes, stamp, number, model)
            self.assertEqual((round(seconds, 1), name, files), expected, stamp)

    def test_the_job_own_files_join_the_distance(self):
        model = wd.hook_model(HOOK_MODEL)
        stamp = {"merged_onto": HOOK_BASE, "pr": 5, "pr_app_swift_files": [], "pr_app_swift_total": 0,
                 "pr_package_interface": False}
        own = {"paths": sorted(swift(10, 11, 12, 13)), "package_swift_files": 0, "package_interface": False}
        self.assertEqual(wd.hook_root_cost((swift(1, 2), False), stamp, 7, model, own), (266.5, "far", 6))
        package = {"paths": [PACKAGE], "package_swift_files": 1, "package_interface": None}
        self.assertEqual(wd.hook_root_cost((set(), False), stamp, 7, model, package)[1], "rebuild")

    def test_model_and_changes(self):
        self.assertEqual(wd.hook_model(HOOK_MODEL), {"near_app_swift_files": 5, "hot_files": ["Sources/Hot.swift"],
                                                     "tiers": {"near": 140.0, "far": 266.5, "rebuild": 400.7},
                                                     "unknown": 309.7})
        self.assertEqual(wd.hook_model({"tiers": {}}), wd.HOOK_DEFAULT_MODEL)
        raw = ("\0".join([":100644 100644 a b M", "Sources/A.swift", ":100644 100644 a b M", "cmuxTests/T.swift",
                           ":160000 160000 a b M", "vendor/ghostty", ":100644 100644 a b M", "README.md"]) + "\0")
        self.assertEqual(wd.hook_changes(raw), ({"Sources/A.swift"}, True))
        self.assertEqual(wd.hook_changes(":100644 100644 a b M\0Packages/macOS/X/Sources/X/X.swift\0"),
                         ({"Packages/macOS/X/Sources/X/X.swift"}, True))

    def test_against_the_hook_itself_when_at_hand(self):
        hook = glaeda_hook()
        if hook is None:
            self.skipTest("no glaeda checkout (set GLAEDA_HOOK to scripts/glaeda-cmux-runner-hook)")
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / ".prefetch/cmux.git").mkdir(parents=True)
            (Path(tmp) / ".prefetch/cmux.git/HEAD").write_text("ref: refs/heads/main\n")
            (Path(tmp) / "warm-distance-model.json").write_text(json.dumps(HOOK_MODEL))
            self.assertEqual(hook.read_warm_model(tmp), wd.hook_model(HOOK_MODEL))
            for (changes, stamp, number), _ in HOOK_CASES:
                # A second, comparable root, so the hook never falls back to the exact keys.
                stamps = [stamp, {"merged_onto": "c" * 40}]
                with unittest.mock.patch.object(hook, "root_stamp", lambda k, _dir="": stamps[k - 1]), \
                        unittest.mock.patch.object(hook, "main_changes", lambda _mirror, old, _new: changes
                                                   if old == HOOK_BASE else (set(), False)):
                    _, predicted = hook.warm_root_costs([0, 1], "d" * 40, number, tmp)
                ours = wd.hook_root_cost(changes, stamp, number, wd.hook_model(HOOK_MODEL))
                self.assertEqual((predicted["root-1"]["seconds"], predicted["root-1"]["tier"],
                                  predicted["root-1"]["app_swift_files"]), (round(ours[0], 1), ours[1], ours[2]))
            raw = ":100644 100644 a b M\0Sources/A.swift\0:160000 160000 a b M\0vendor/ghostty\0"
            done = subprocess.CompletedProcess([], 0, stdout=raw.encode(), stderr=b"")
            with unittest.mock.patch.object(hook.subprocess, "run", return_value=done):
                self.assertEqual(hook.main_changes(Path(tmp), "a" * 40, "b" * 40), wd.hook_changes(raw))


def distance_runner(name: str, busy: bool = False) -> dict:
    return runner(name, busy)


class DistanceRouting(unittest.TestCase):
    MODEL = {**MODEL, "hot_files": [], "start_classes": {"none": {"expected": 309.7}}}

    def route(self, runners, minis, changes, *, own=None, legacy=None, running=None, max_wait=600.0):
        member = lambda name: name.split("-glaeda")[0]  # noqa: E731
        return wd.distance_route(runners, ROOT_LABEL, minis=minis, changes=lambda onto: changes.get(onto),
                                 pr_number=7, own=own, legacy=legacy or {}, running=running or {},
                                 model=self.MODEL, now=NOW, max_wait=max_wait, runner_label=label, member=member)

    def stamp(self, onto, root=1):
        return {"root": root, "merged_onto": onto, "pr": 3, "pr_app_swift_files": [], "pr_app_swift_total": 0,
                "pr_package_interface": False}

    def test_the_nearest_mini_beats_the_root_labels_mean(self):
        minis = {"m1": [self.stamp("1" * 40)], "m2": [self.stamp("2" * 40), {"root": 2}]}
        changes = {"1" * 40: (swift(*range(8)), False), "2" * 40: (swift(1), False)}
        name, decision = self.route([runner("m1-glaeda"), runner("m2-glaeda")], minis, changes)
        self.assertEqual(name, "m2-glaeda")
        self.assertEqual((decision["predicted"], decision["baseline"]), (140.0, 205.0))
        self.assertEqual(decision["candidates"][0]["root"], "root-1")

    def test_a_busy_root_runner_holds_the_minis_nearest_root(self):
        # m2's second runner is busy and holds a root: its idle runner gets the next one, cold.
        minis = {"m1": [self.stamp("1" * 40)], "m2": [self.stamp("2" * 40), {"root": 2}]}
        changes = {"1" * 40: (swift(*range(8)), False), "2" * 40: (swift(1), False)}
        runners = [runner("m1-glaeda"), runner("m2-glaeda"), runner("m2-glaeda-1", busy=True)]
        name, decision = self.route(runners, minis, changes)
        costs = {row["runner"]: (row["tier"], row["compile"]) for row in decision["candidates"]}
        self.assertEqual(costs["m2-glaeda"], ("cold", 401.0))
        self.assertEqual(costs["m1-glaeda"], ("far", 270.0))
        # The far build beats GitHub's pick between the two (335.5 s) by more than the margin.
        self.assertEqual((name, decision["baseline"]), ("m1-glaeda", 335.5))

    def test_equal_costs_do_not_pin_and_ties_are_deterministic(self):
        minis = {"m1": [self.stamp("1" * 40)], "m2": [self.stamp("1" * 40)]}
        changes = {"1" * 40: (swift(1), False)}
        name, decision = self.route([runner("m2-glaeda"), runner("m1-glaeda")], minis, changes)
        self.assertEqual(name, "")
        self.assertEqual([row["runner"] for row in decision["candidates"]], ["m1-glaeda", "m2-glaeda"])

    def test_a_mini_without_stamps_costs_its_exact_key_or_the_unknown_start(self):
        minis = {"m2": [self.stamp("2" * 40)]}
        changes = {"2" * 40: (swift(*range(8)), False)}
        name, decision = self.route([runner("m1-glaeda"), runner("m2-glaeda"), runner("m3-glaeda")], minis, changes,
                                    legacy={"m1-glaeda": 120.0})
        costs = {row["runner"]: (row["tier"], row["compile"]) for row in decision["candidates"]}
        self.assertEqual(costs, {"m1-glaeda": ("key", 120.0), "m2-glaeda": ("far", 270.0),
                                 "m3-glaeda": ("unknown", 309.7)})
        self.assertEqual(name, "m1-glaeda")

    def test_record_is_bounded_and_reads_either_mode(self):
        minis = {"m1": [self.stamp("1" * 40)]}
        _, decision = self.route([runner("m1-glaeda")], minis, {"1" * 40: (swift(1), False)})
        record = wd.route_record(decision)
        self.assertEqual((record["mode"], record["chosen"], record["predicted"]), ("distance", "", 140.0))
        _, legacy = wd.route_admission([runner("a"), runner("b")], ROOT_LABEL, base_warm={"b"}, pr_warm=(), running={},
                                       job_tier="near", model=MODEL, now=NOW, max_wait=600, runner_label=label)
        record = wd.route_record(legacy)
        self.assertEqual((record["mode"], record["chosen"], record["predicted"], record["baseline"]),
                         ("key", "b", 120.0, 350.0))
        self.assertEqual(wd.picker_route_record(json.dumps(record)), record)
        self.assertIsNone(wd.picker_route_record("not json"))
        self.assertIsNone(wd.picker_route_record(""))


def row(files: int, seconds: float, rebuilt: bool, *, package: bool = False, paths=(), at="2026-09-25T13:00:00Z",
        **extra) -> dict:
    distance = {"app_swift_files": files, "package_swift_files": 1 if package else 0, "package_interface": package,
                "hot_files": [], "paths": list(paths)}
    return {"distance": distance, "compile_seconds": seconds, "app_rebuilt": rebuilt, "at": at,
            "start": {"kind": "seed"}, "own": {"app_swift_files": files, "package_swift_files": 0,
                                               "package_interface": False, "hot_files": []}, **extra}


class Fit(unittest.TestCase):
    def test_tiers_hot_files_and_misclassification(self):
        rows = [row(2, 100 + i, False) for i in range(6)]
        rows += [row(12, 250 + i, i == 0) for i in range(5)]
        rows += [row(3, 420 + i, True, package=True) for i in range(4)] + [row(3, 150, False, package=True)]
        rows += [row(8, 430 + i, True, paths=["Sources/Hot.swift"]) for i in range(3)]
        rows += [{"distance": None, "compile_seconds": 1}]  # unusable
        model = wd.fit(rows, now=NOW, jobs=[{"job": "macos-compile-admission", "seconds": s} for s in range(100, 600, 100)])
        self.assertEqual(model["hot_files"], ["Sources/Hot.swift"])
        self.assertEqual(model["rows"], 19)
        self.assertEqual(model["tiers"]["near"]["n"], 6)
        self.assertEqual(model["tiers"]["far"]["n"], 5)
        self.assertEqual(model["tiers"]["rebuild"]["n"], 8)
        self.assertEqual(model["tiers"]["near"]["p50"], 102)
        # 1 far rebuild, 1 package start that did not rebuild.
        self.assertEqual(model["misclassified"]["rows"], 2)
        self.assertEqual(model["job_seconds"]["macos-compile-admission"]["p50"], 300.0)
        self.assertEqual(model["start_classes"]["none"]["n"], 19)
        self.assertIn("| near | 6 |", wd.table(model))
        self.assertIn("| near |", wd.evaluate(rows, model))

    def test_the_committed_model_reads(self):
        model = wd.load_model()
        self.assertEqual(set(model["tiers"]), set(wd.TIERS))
        for name in ("base", "pr", "none"):
            self.assertIn(name, model["start_classes"])
        self.assertIsNotNone(wd.predict({"app_swift_files": 1}, model)[1])


if __name__ == "__main__":
    unittest.main()
