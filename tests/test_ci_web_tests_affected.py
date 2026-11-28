#!/usr/bin/env python3
"""scripts/ci/web_tests_affected.py picks the web tests whose imports or read paths hold a changed file, and the
web-tests-affected step runs them on every feat-cmux-next pull request (pr_scope = false)."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import ci_steps  # noqa: E402
import web_tests_affected as wta  # noqa: E402

FILES = {
    "web/package.json": "{}",
    "web/tests/test-preload.ts": 'import "./helpers/preload-env";\n',
    "web/tests/helpers/preload-env.ts": "export {};\n",
    # Reads a workflow outside web/ by literal and a directory by a template literal's prefix.
    "web/tests/roll.test.ts": (
        'import { decide } from "../../images/vm/roll";\n'
        'const wf = new URL("../../.github/workflows/roll.yml", import.meta.url);\n'
        "const each = (name: string) => new URL(`../../workers/vm/${name}`, import.meta.url);\n"),
    "images/vm/roll.ts": 'import cfg from "./roll.json";\nexport const decide = () => cfg;\n',
    "images/vm/roll.json": "{}",
    ".github/workflows/roll.yml": "on: push\n",
    ".github/workflows/other.yml": "on: push\n",
    "workers/vm/wrangler.jsonc": "{}",
    # An @/ import chain into a .js-specifier TypeScript module.
    "web/tests/billing.test.tsx": 'import { plans } from "@/services/billing/plans";\n',
    "web/services/billing/plans.ts": 'export { price } from "./price.js";\nexport const plans = 1;\n',
    "web/services/billing/price.ts": "export const price = 2;\n",
    # App code quoting a repo path as text: not a read.
    "web/app/page.tsx": 'import "@/services/billing/plans";\nconst src = "cmux-tui/crates/acpmux";\n',
    "web/tests/page.test.tsx": 'import "../app/page";\n',
    "cmux-tui/crates/acpmux/lib.rs": "",
    "web/messages/en.json": "{}",
}
# A catalog most tests import: over the cap alone.
for n in range(4):
    FILES[f"web/tests/msg{n}.test.ts"] = 'import en from "../messages/en.json";\n'


class SelectTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.dir = tempfile.TemporaryDirectory()
        root = Path(cls.dir.name)
        for path, text in FILES.items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(text)
        git = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(git + ["add", "-A"], cwd=root, check=True)
        subprocess.run(git + ["commit", "-qm", "t"], cwd=root, check=True)
        cls.tree = wta.Tree(None, root)
        cls.at_rev = wta.Tree("HEAD", root)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.dir.cleanup()

    def pick(self, *changed: str, cap: int = 3, tree: wta.Tree | None = None) -> dict:
        return wta.select(tree or self.tree, list(changed), cap)

    def test_a_path_a_test_reads_by_literal_outside_web(self) -> None:
        for path in (".github/workflows/roll.yml", "images/vm/roll.json", "workers/vm/wrangler.jsonc"):
            with self.subTest(path=path):
                self.assertEqual(self.pick(path)["tests"], ["web/tests/roll.test.ts"])
                self.assertEqual(self.pick(path, tree=self.at_rev)["tests"], ["web/tests/roll.test.ts"])

    def test_an_alias_import_chain(self) -> None:
        self.assertEqual(self.pick("web/services/billing/price.ts")["tests"],
                         ["web/tests/billing.test.tsx", "web/tests/page.test.tsx"])

    def test_a_changed_test_picks_itself(self) -> None:
        self.assertEqual(self.pick("web/tests/billing.test.tsx")["tests"], ["web/tests/billing.test.tsx"])

    def test_an_unread_path_picks_nothing(self) -> None:
        for path in (".github/workflows/other.yml", "cmux-tui/crates/acpmux/lib.rs", "README.md"):
            with self.subTest(path=path):
                self.assertEqual(self.pick(path)["tests"], [])

    def test_what_every_test_loads_is_left_to_the_shards(self) -> None:
        for path in ("web/package.json", "web/tests/helpers/preload-env.ts"):
            with self.subTest(path=path):
                result = self.pick(path, "images/vm/roll.json")
                self.assertIn(path, result["left"])
                self.assertEqual(result["tests"], ["web/tests/roll.test.ts"])

    def test_a_path_over_the_cap_is_left_and_the_rest_still_pick(self) -> None:
        result = self.pick("web/messages/en.json", "images/vm/roll.ts")
        self.assertIn("web/messages/en.json", result["left"])
        self.assertEqual(result["tests"], ["web/tests/roll.test.ts"])
        self.assertEqual(self.pick("web/messages/en.json", cap=10)["tests"], [f"web/tests/msg{n}.test.ts" for n in range(4)])

    def test_a_union_over_the_cap_picks_none(self) -> None:
        result = self.pick("web/services/billing/price.ts", "images/vm/roll.ts", cap=2)
        self.assertEqual(result["tests"], [])
        self.assertIn("over the cap", result["skipped"])

    def test_the_cli_prints_bun_paths_and_fails_open(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".txt") as listed:
            listed.write("images/vm/roll.json\n")
            listed.flush()
            out = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/web_tests_affected.py"), "--rev",
                                  "no-such-rev", listed.name], capture_output=True, text=True, cwd=self.dir.name)
        self.assertEqual(out.returncode, 0)
        self.assertEqual(out.stdout, "")
        self.assertIn("cannot select", out.stderr)


class RealTreeTest(unittest.TestCase):
    def test_the_roll_workflow_picks_the_auto_roll_test(self) -> None:
        # #53974 changed only .github/workflows; vm-image-cmux-vm-auto-roll.test.ts reads them and went red post-merge.
        result = wta.select(wta.Tree(None), [".github/workflows/cloud-vm-image-roll.yml"])
        self.assertIn("web/tests/vm-image-cmux-vm-auto-roll.test.ts", result["tests"])
        self.assertLessEqual(len(result["tests"]), wta.DEFAULT_CAP)


class StepTest(unittest.TestCase):
    def test_the_step_routes_on_every_pull_request_and_runs_only_what_it_picks(self) -> None:
        table = ci_steps.load()
        step = table.steps["web-tests-affected"]
        self.assertEqual(step.job, "linux")
        self.assertFalse(step.pr_scope)
        self.assertEqual(tuple(step.inputs), ("**",))
        self.assertEqual(tuple(step.needs), ("bun",))
        self.assertIn("scripts/ci/web_tests_affected.py", step.run)
        self.assertIn('flock "$CI_TOOLS/bun-install.lock" bun install --frozen-lockfile', step.run)
        self.assertIn('./scripts/run-tests.sh "${files[@]}"', step.run)
        routed = ci_steps.route(table, ["images/cmux-vm/auto-roll.ts"], pr_scope=True).get("linux", [])
        self.assertIn("web-tests-affected", routed)

    def test_no_change_list_exits_at_once(self) -> None:
        step = ci_steps.load().steps["web-tests-affected"]
        env = {k: v for k, v in os.environ.items() if k != "CI_PATHS_FILE"}
        out = subprocess.run(["bash", "-euo", "pipefail", "-c", step.run], cwd=ROOT, env=env, capture_output=True,
                             text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("No change list", out.stdout)

    def test_an_unread_change_exits_without_bun(self) -> None:
        step = ci_steps.load().steps["web-tests-affected"]
        with tempfile.NamedTemporaryFile("w", suffix=".txt") as listed:
            listed.write("README.md\n")
            listed.flush()
            env = dict(os.environ, CI_PATHS_FILE=listed.name, CI_TOOLS="/nonexistent")
            out = subprocess.run(["bash", "-euo", "pipefail", "-c", step.run], cwd=ROOT, env=env,
                                 capture_output=True, text=True, timeout=120)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("No web test reaches", out.stdout)


if __name__ == "__main__":
    unittest.main()
