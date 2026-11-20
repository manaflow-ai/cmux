"""The webview shard planner preserves runner assignment and skips empty focused shards."""
from __future__ import annotations

import json
import os
import sys
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/webviews_shard_scope.py"
sys.path.insert(0, str(SCRIPT.parent))
import webviews_test_history as history_module


def step_script(name: str) -> str:
    workflow = (ROOT / ".github/workflows/ci-web.yml").read_text()
    step = workflow.split("      - name: " + name + "\n", 1)[1].split("\n      - name:", 1)[0]
    lines = step.split("        run: |\n", 1)[1].splitlines()
    body = []
    for line in lines:
        if line and not line.startswith("          "):
            break
        body.append(line[10:] if line else "")
    return "\n".join(body) + "\n"


class ShardScopeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(["git", "-C", str(self.root), "init", "-q"], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.email", "tests@example.com"], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.name", "tests"], check=True)
        (self.root / "webviews/test").mkdir(parents=True)
        (self.root / "webviews/src").mkdir()
        (self.root / "webviews/package.json").write_text("{}\n")
        (self.root / "webviews/src/leaf.ts").write_text("export const leaf = 1;\n")
        (self.root / "webviews/test/leaf.test.ts").write_text('import { leaf } from "../src/leaf";\n')
        (self.root / "webviews/test/other.test.ts").write_text("test(\"other\", () => {});\n")
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", "base"], check=True)
        (self.root / "webviews/src/leaf.ts").write_text("export const leaf = 2;\n")
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", "change"], check=True)
        self.base_sha = subprocess.check_output(["git", "-C", str(self.root), "rev-parse", "HEAD^1"], text=True).strip()
        self.history = self.root / "history.json"
        self.base_run = {"sha": self.base_sha, "time": 123, "inputs": "fixture",
                         "files": ["test/leaf.test.ts", "test/other.test.ts"], "red": []}
        self.history.write_text(json.dumps({"runs": [self.base_run]}))
        self.manifest = self.root / "durations.json"
        self.manifest.write_text(json.dumps({"test/leaf.test.ts": 10, "test/other.test.ts": 10}) + "\n")

    def run_scope(self, shard: int, count: int = 4) -> dict[str, object]:
        out = self.root / f"scope-{shard}.json"
        subprocess.run([
            "python3", str(SCRIPT), "--root", str(self.root), "--base", "HEAD^1", "--head", "HEAD",
            "--manifest", str(self.manifest), "--shard", str(shard), "--shard-count", str(count),
            "--pull-request", "--history", str(self.history), "--out", str(out),
        ], check=True, capture_output=True, text=True)
        return json.loads(out.read_text())

    def test_only_the_shard_with_an_affected_test_runs(self) -> None:
        results = [self.run_scope(shard) for shard in range(1, 5)]
        selected = [result for result in results if result["run"]]
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0]["files"], "test/leaf.test.ts")
        self.assertEqual({result["mode"] for result in results}, {"focused"})
        self.assertTrue(results[0]["setup"])
        for index, result in enumerate(results):
            self.assertEqual(result["setup"], result["run"] or index == 0)

    def test_full_ci_keeps_every_matrix_shard(self) -> None:
        out = self.root / "scope-full.json"
        subprocess.run([
            "python3", str(SCRIPT), "--root", str(self.root), "--base", "HEAD^1", "--manifest", str(self.manifest),
            "--shard", "4", "--shard-count", "4", "--pull-request", "--full-ci", "--out", str(out),
        ], check=True)
        self.assertEqual(json.loads(out.read_text()), {"files": "", "mode": "full", "run": True, "setup": True})

    def test_missing_wrong_base_and_malformed_history_run_full(self) -> None:
        for content in ("{}", "not json", json.dumps({"runs": [{**self.base_run, "sha": "0" * 40}]})):
            with self.subTest(content=content):
                self.history.write_text(content)
                result = self.run_scope(3)
                self.assertEqual(result, {"files": "", "mode": "full", "run": True, "setup": True})

    def test_red_and_uncovered_files_are_not_skipped(self) -> None:
        for base_run in ({**self.base_run, "red": ["test/other.test.ts > failed"]},
                         {**self.base_run, "files": ["test/leaf.test.ts"]}):
            with self.subTest(run=base_run):
                self.history.write_text(json.dumps({"runs": [base_run]}))
                files = [name for shard in range(1, 5) for name in self.run_scope(shard)["files"].splitlines()]
                self.assertCountEqual(files, ["test/leaf.test.ts", "test/other.test.ts"])

    def test_latest_base_red_overrides_older_green(self) -> None:
        newer = {**self.base_run, "time": 124, "red": ["test/other.test.ts"]}
        self.history.write_text(json.dumps({"runs": [newer, self.base_run]}))
        files = [name for shard in range(1, 5) for name in self.run_scope(shard)["files"].splitlines()]
        self.assertCountEqual(files, ["test/leaf.test.ts", "test/other.test.ts"])

    def test_runner_change_forces_every_shard(self) -> None:
        path = self.root / "scripts/ci/webviews_shard_scope.py"
        path.parent.mkdir(parents=True)
        path.write_text("# changed runner input\n")
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", "runner"], check=True)
        self.assertEqual(self.run_scope(4)["mode"], "full")

    def test_empty_artifacts_join_with_real_runner(self) -> None:
        scripts = self.root / "scripts/ci"
        scripts.mkdir(parents=True)
        for filename in ("run-webviews-tests.sh", "timeout.sh", "webviews_test_results.py",
                         "webviews_test_shards.py", "guards_new_reds.py", "webviews_test_history.py", "test_reds.py"):
            (scripts / filename).write_text("runner marker\n")
        shards = self.root / "artifacts"
        for shard in (1, 2):
            run_temp = self.root / f"runner-{shard}"
            run_temp.mkdir()
            script = step_script("Publish empty result for unchanged shard").replace("${{ matrix.shard }}", str(shard))
            subprocess.run(["bash", "-e", "-c", script], cwd=self.root,
                           env={**os.environ, "RUNNER_TEMP": str(run_temp)}, check=True)
            artifact = shards / history_module.HEAD_ARTIFACT.format(shard)
            artifact.parent.mkdir(exist_ok=True)
            (run_temp / "webviews-head-results").rename(artifact)
        joined = self.root / "joined"
        self.assertIsNone(history_module.join_heads(shards, 2, joined))
        self.assertEqual(json.loads((joined / history_module.HEAD_RESULTS).read_text()), {})
        self.assertEqual((joined / "runner/run-webviews-tests.sh").read_text(), "runner marker\n")

    def test_workflow_keeps_planned_files_and_full_ci_empty(self) -> None:
        scripts = self.root / "scripts/ci"
        scripts.mkdir(parents=True)
        for filename in ("run-webviews-tests.sh", "timeout.sh", "webviews_test_results.py",
                         "webviews_test_shards.py", "guards_new_reds.py", "webviews_test_history.py", "test_reds.py"):
            (scripts / filename).write_text("# runner fixture\n")
        runner = scripts / "webviews-tests-new-reds.sh"
        runner.write_text('#!/bin/bash\nprintf "%s" "$CMUX_WEB_TEST_FILES" > "$RUNNER_TEMP/actual-files"\n')
        runner.chmod(0o755)
        for full_ci, files in (("false", "test/leaf.test.ts"), ("true", "")):
            with self.subTest(full_ci=full_ci):
                run_temp = self.root / ("shell-" + full_ci)
                run_temp.mkdir()
                subprocess.run(["bash", "-e", "-c", step_script("Test webviews")],
                               cwd=self.root / "webviews", check=True,
                               env={**os.environ, "RUNNER_TEMP": str(run_temp), "BASE_REF": "HEAD^1",
                                    "FULL_CI": full_ci, "GITHUB_EVENT_NAME": "pull_request",
                                    "CMUX_WEB_TEST_FILES": files, "CMUX_WEB_TEST_JOB_MINUTES": ""})
                self.assertEqual((run_temp / "actual-files").read_text(), files)


if __name__ == "__main__":
    unittest.main()
