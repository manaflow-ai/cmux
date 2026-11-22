#!/usr/bin/env python3
"""scripts/ci/step_inputs.py: a declared step skips only when its inputs are the ones a base green passed on.

Leo, 2026-11-22 06:19Z: "i hope you guys continue the trend of thinking of good ways to reduce wall time and reduce
minutes." A skip must never hide a real red: these tests hold that any change to a step's inputs, tools, declaration
or the key code runs it, that a red step writes no receipt, that a missing or foreign manifest runs everything, and
that every declaration in ci/steps.toml matches files.
"""
from __future__ import annotations

import io
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import step_inputs  # noqa: E402

TABLE = textwrap.dedent('''
    [tools]
    bun = 'scripts/ci/ensure-bun.sh 1.4.4 "$CI_TOOLS/bin"'

    [check.demo]
    check = "demo check"
    workflow = ".github/workflows/demo.yml"
    job = "demo"

    [check.demo.step.lint]
    inputs = ["lint/**", "tools/lint.py"]
    tools = ["python3@3.12"]

    [check.demo.step.web]
    inputs = ["web/**"]
    tools = ["bun"]
''')


def sh(cwd: Path, *args: str) -> str:
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


class Repo:
    def __init__(self, root: Path):
        self.root = root
        sh(root, "git", "init", "-q", "-b", "main")
        sh(root, "git", "config", "user.email", "t@example.com")
        sh(root, "git", "config", "user.name", "t")
        for rel in step_inputs.SELF_INPUTS:
            self.write(rel, (ROOT / rel).read_text(encoding="utf-8"))
        self.write("ci/steps.toml", TABLE)
        self.write(".github/workflows/demo.yml", "on: push\n")
        self.write("lint/a.txt", "a\n")
        self.write("tools/lint.py", "print(1)\n")
        self.write("web/app.ts", "x\n")
        self.write("other/readme.md", "hi\n")
        self.commit("base")

    def write(self, rel: str, text: str) -> None:
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")

    def commit(self, msg: str) -> str:
        sh(self.root, "git", "add", "-A")
        sh(self.root, "git", "commit", "-q", "-m", msg)
        return sh(self.root, "git", "rev-parse", "HEAD")

    def keys(self, rev: str = "HEAD") -> dict[str, str]:
        checks, tools = step_inputs.load(self.root / "ci/steps.toml")
        return step_inputs.keys(checks["demo"], tools, rev, cwd=self.root)

    def manifest(self, green: list[str], rev: str = "HEAD") -> dict:
        here = self.keys(rev)
        return {"version": step_inputs.VERSION, "check": "demo", "rev": sh(self.root, "git", "rev-parse", rev),
                "run_id": "1", "steps": {n: here[n] for n in green}}

    def plan(self, manifest: dict | None, audit: int = 0, enabled: bool = True) -> dict:
        checks, _ = step_inputs.load(self.root / "ci/steps.toml")
        return step_inputs.plan(checks["demo"], self.keys(), manifest, audit, "9", "1", enabled)


class StepInputSkip(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(Path(self.tmp.name))

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_change_outside_every_input_skips_every_step(self):
        m = self.repo.manifest(["lint", "web"])
        self.repo.write("other/readme.md", "changed\n")
        self.repo.commit("docs")
        p = self.repo.plan(m)
        self.assertEqual(sorted(p["skip"]), ["lint", "web"])
        self.assertTrue(p["all_skipped"])
        self.assertEqual({e["event"] for e in p["events"]}, {"step-input-skip"})

    def test_a_changed_input_runs_that_step_and_only_that_step(self):
        m = self.repo.manifest(["lint", "web"])
        self.repo.write("web/app.ts", "y\n")
        self.repo.commit("web")
        p = self.repo.plan(m)
        self.assertEqual(p["run"], ["web"])
        self.assertEqual(p["skip"], ["lint"])
        self.assertFalse(p["all_skipped"])

    def test_an_added_or_deleted_or_mode_changed_input_runs_the_step(self):
        m = self.repo.manifest(["lint"])
        self.repo.write("lint/new.txt", "n\n")
        self.repo.commit("add")
        self.assertIn("lint", self.repo.plan(m)["run"])
        m = self.repo.manifest(["lint"])
        (self.repo.root / "lint/a.txt").unlink()
        self.repo.commit("delete")
        self.assertIn("lint", self.repo.plan(m)["run"])
        m = self.repo.manifest(["lint"])
        os.chmod(self.repo.root / "tools/lint.py", 0o755)
        self.repo.commit("chmod")
        self.assertIn("lint", self.repo.plan(m)["run"])

    def test_a_step_red_on_base_has_no_receipt_so_it_runs(self):
        m = self.repo.manifest(["web"])  # lint failed on base: not in the green list
        self.repo.write("other/readme.md", "changed\n")
        self.repo.commit("docs")
        p = self.repo.plan(m)
        self.assertEqual(p["run"], ["lint"])
        self.assertEqual(p["skip"], ["web"])

    def test_a_changed_declaration_tool_or_key_code_runs_every_affected_step(self):
        m = self.repo.manifest(["lint", "web"])
        self.repo.write("ci/steps.toml", TABLE.replace("python3@3.12", "python3@3.13"))
        self.repo.commit("tool")
        self.assertEqual(self.repo.plan(m)["run"], ["lint"])
        m = self.repo.manifest(["lint", "web"])
        self.repo.write("ci/steps.toml", self.repo.root.joinpath("ci/steps.toml").read_text().replace("1.4.4", "1.4.5"))
        self.repo.commit("bun pin")
        self.assertEqual(self.repo.plan(m)["run"], ["web"])
        m = self.repo.manifest(["lint", "web"])
        self.repo.write("scripts/ci/step_inputs.py",
                        self.repo.root.joinpath("scripts/ci/step_inputs.py").read_text() + "\n# changed\n")
        self.repo.commit("key code")
        self.assertEqual(sorted(self.repo.plan(m)["run"]), ["lint", "web"])

    def test_no_manifest_a_foreign_manifest_or_the_switch_off_runs_everything(self):
        self.assertEqual(sorted(self.repo.plan(None)["run"]), ["lint", "web"])
        m = self.repo.manifest(["lint", "web"])
        checks, _ = step_inputs.load(self.repo.root / "ci/steps.toml")
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({**m, "check": "other"}, f)
        self.assertIsNone(step_inputs.read_manifest(f.name, checks["demo"]))
        Path(f.name).write_text("not json")
        self.assertIsNone(step_inputs.read_manifest(f.name, checks["demo"]))
        os.unlink(f.name)
        self.assertEqual(sorted(self.repo.plan(m, enabled=False)["run"]), ["lint", "web"])

    def test_the_audit_runs_a_would_be_skip_and_records_it(self):
        m = self.repo.manifest(["lint", "web"])
        p = self.repo.plan(m, audit=100)
        self.assertEqual(sorted(p["run"]), ["lint", "web"])
        self.assertEqual(sorted(p["audit"]), ["lint", "web"])
        self.assertEqual({e["event"] for e in p["events"]}, {"step-input-audit"})

    def test_plan_cli_writes_outputs_and_events_and_fails_open(self):
        m = self.repo.manifest(["lint", "web"])
        mf = self.repo.root / "m.json"
        mf.write_text(json.dumps(m))
        out_file = self.repo.root / "out.txt"
        events = self.repo.root / "events.jsonl"
        env = {"GITHUB_OUTPUT": str(out_file), "CI_STEP_EVENTS": str(events), "CI_STEP_INPUT_SKIP": "1"}
        with mock.patch.dict(os.environ, env), mock.patch.object(step_inputs, "ROOT", self.repo.root):
            buf = io.StringIO()
            with redirect_stdout(buf):
                code = step_inputs.main(["--table", str(self.repo.root / "ci/steps.toml"), "plan", "--check", "demo",
                                         "--manifest", str(mf), "--audit-percent", "0"])
        self.assertEqual(code, 0)
        self.assertIn("all_skipped=true", out_file.read_text())
        rows = [json.loads(line) for line in events.read_text().splitlines()]
        self.assertEqual(sorted(r["step"] for r in rows), ["lint", "web"])
        self.assertTrue(all(r["event"] == "step-input-skip" and r["green_rev"] == m["rev"] for r in rows))
        # An unknown check or unreadable table fails open: every step runs, exit 0.
        with mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(out_file)}):
            buf = io.StringIO()
            with redirect_stdout(buf):
                self.assertEqual(step_inputs.main(["--table", "/nonexistent.toml", "plan", "--check", "demo"]), 0)
        self.assertIn("all_skipped=false", buf.getvalue())

    def test_a_whole_tree_glob_is_refused(self):
        bad = TABLE.replace('inputs = ["web/**"]', 'inputs = ["**"]')
        import tomllib
        with self.assertRaises(step_inputs.DeclError):
            step_inputs.parse_checks(tomllib.loads(bad))


class TheRepositoryTable(unittest.TestCase):
    def test_every_declared_check_parses_and_every_glob_matches_a_file(self):
        checks, _ = step_inputs.load()
        self.assertEqual(step_inputs.lint(checks), [])


if __name__ == "__main__":
    unittest.main()
