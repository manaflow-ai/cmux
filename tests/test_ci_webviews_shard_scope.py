"""The webview shard planner preserves runner assignment and skips empty focused shards."""
from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/webviews_shard_scope.py"


class ShardScopeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp())
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
        self.manifest = self.root / "durations.json"
        self.manifest.write_text(json.dumps({"test/leaf.test.ts": 10, "test/other.test.ts": 10}) + "\n")

    def run_scope(self, shard: int, count: int = 4) -> dict[str, object]:
        out = self.root / f"scope-{shard}.json"
        subprocess.run([
            "python3", str(SCRIPT), "--root", str(self.root), "--base", "HEAD^1", "--head", "HEAD",
            "--manifest", str(self.manifest), "--shard", str(shard), "--shard-count", str(count),
            "--pull-request", "--out", str(out),
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


if __name__ == "__main__":
    unittest.main()
