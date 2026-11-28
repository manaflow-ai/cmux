#!/usr/bin/env python3
"""gate-plan's CmuxNext suite steps stay inside the cmux-ci controller's ci-step limits.

On 2026-10-22 a merge train touched a cmux-next workflow, the route selected every CmuxNext test
target, and gate-plan wrote all 1,275 suite filters as ONE 26 KB `--arg`. The controller
(hq build-fleet/cmd/controller/ci_step.go) refuses an arg over 2048 bytes or a step with more
than 16 args with HTTP 400, so the gate failed in 4 s before anything ran.

This test builds the plan's suite steps from the real SwiftPM target graph with every test
target selected (the same list as that train), parses each step line as gate-run.sh's bash
would, and checks it against the controller's rules: arg count, arg length, the arg and key
patterns, distinct idempotency keys, and that the steps together run every filter once, in order.
"""
from __future__ import annotations

import importlib.util
import os
import re
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
spec = importlib.util.spec_from_file_location("gate_plan", ROOT / "scripts" / "cmux-next" / "gate-plan.py")
gate_plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate_plan)

# The controller's patterns (ci_step.go ciStepArgPattern, ciStepKeyPattern) and limits.
ARG = re.compile(r"^[A-Za-z0-9._/@+=,:-]+$")
KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$")
MAX_ARGS, MAX_ARG_LEN = 16, 2048
HEAD = "59eaf7ccdc6a4f4d4812b8da9427561c3e803b59"


def every_suite_filter() -> list[str]:
    graph = gate_plan.route_mod.load_graph(ROOT)
    names: list[str] = []
    for target in sorted(n for n, t in graph["targets"].items() if t["kind"] == "test"):
        names += gate_plan.suite_filters(graph, target, [], every=True)[0]
    return list(dict.fromkeys(names))


def controller_view(step: str) -> tuple[str, list[str]]:
    """The key and args cmux-ci sends for one step line (as bash splits it)."""
    words = shlex.split(step)
    key, args = "", []
    for i, word in enumerate(words):
        if word == "--key":
            key = words[i + 1]
        elif word.startswith("--arg="):
            args.append(word[len("--arg="):])
        elif word == "--arg":
            args.append(words[i + 1])
    return key, args


class SuiteStepsTests(unittest.TestCase):
    def test_every_target_plan_fits_the_controller(self) -> None:
        names = every_suite_filter()
        self.assertGreater(len(",".join(names)), MAX_ARG_LEN, "the full list must exceed one arg for this test to mean anything")
        steps = gate_plan.suite_steps(names, HEAD, "landing-train-1022")
        self.assertGreater(len(steps), 0)
        keys, ran = [], []
        for step in steps:
            key, args = controller_view(step)
            self.assertRegex(key, KEY)
            keys.append(key)
            self.assertLessEqual(len(args), MAX_ARGS, key)
            self.assertEqual(args[:2], ["suite", gate_plan.CMUXNEXT_DIR], key)
            for arg in args:
                self.assertLessEqual(len(arg), MAX_ARG_LEN, key)
                self.assertRegex(arg, ARG)
            ran += [name for arg in args[2:] for name in arg.split(",")]
        self.assertEqual(len(set(keys)), len(keys), "each step needs its own idempotency key")
        self.assertEqual(ran, names, "the steps together run every filter once, in plan order")

    def test_a_short_list_stays_one_step_with_the_lane_key(self) -> None:
        steps = gate_plan.suite_steps(["SuiteA", "SuiteB", "SuiteA"], HEAD, "lane")
        self.assertEqual(len(steps), 1)
        key, args = controller_view(steps[0])
        self.assertEqual(key, f"lane-gate-{HEAD[:12]}")
        self.assertEqual(args, ["suite", gate_plan.CMUXNEXT_DIR, "SuiteA,SuiteB"])


class HqToolTests(unittest.TestCase):
    """gate-plan finds hq by walking up from worktrees/<slug>, which reaches the shared primary hq checkout,
    and that can be thousands of commits behind (2026-11-28: 24,885). Run from there, its
    cmux-next-receipts.py called package_input_key.package_receipt, which the keyer no longer has
    (AttributeError), so every gate with a Swift package unit died. The hq tools must run as installed hq
    main (scripts/lib/hq_installed.py exec), never as the checkout's files."""

    def run_tool(self, hq: Path, env: dict[str, str]) -> list[str]:
        seen: list[list[str]] = []

        def run(argv, **_):
            seen.append(argv)
            return subprocess.CompletedProcess(argv, 0, "", "")

        with mock.patch.object(gate_plan.subprocess, "run", run), mock.patch.dict(os.environ, env, clear=False):
            gate_plan.hq_tool(hq, "cmux-next-receipts.py", "plan", "--root", "x")
        return seen[0]

    def checkout(self, base: Path) -> Path:
        (base / ".git").mkdir()
        (base / "scripts" / "lib").mkdir(parents=True)
        (base / "scripts" / "lib" / "hq_installed.py").write_text("", encoding="utf-8")
        (base / "scripts" / "cmux-next-receipts.py").write_text("", encoding="utf-8")
        return base

    def test_a_checkout_runs_the_tool_as_installed_hq_main(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            hq = self.checkout(Path(tmp))
            argv = self.run_tool(hq, {"CMUX_HQ_RUN_CHECKOUT_CODE": ""})
        self.assertEqual(argv, [sys.executable, "-I", "-B", str(hq / "scripts" / "lib" / "hq_installed.py"), "exec",
                                "scripts/cmux-next-receipts.py", str(hq), "plan", "--root", "x"])

    def test_checkout_code_on_request_or_outside_a_checkout_runs_the_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            hq = self.checkout(Path(tmp))
            direct = [sys.executable, "-I", str(hq / "scripts" / "cmux-next-receipts.py"), "plan", "--root", "x"]
            self.assertEqual(self.run_tool(hq, {"CMUX_HQ_RUN_CHECKOUT_CODE": "1"}), direct)
            (hq / ".git").rmdir()  # an installed release: already hq main
            self.assertEqual(self.run_tool(hq, {"CMUX_HQ_RUN_CHECKOUT_CODE": ""}), direct)


if __name__ == "__main__":
    unittest.main()
