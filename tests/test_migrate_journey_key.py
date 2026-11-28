#!/usr/bin/env python3
"""migrate-journey-pr.yml skips `migrate` when its inputs already passed (ci10k), and only then.

Leo: "de facto, im asking for 99% fewer minutes of ci time, period." scripts/ci/migrate_journey_key.py hashes what
the workflow's `paths:` filter watches. This pins:
- the key's inputs are exactly the workflow's `paths:` (a new watched path is in the key, or the test fails);
- an edit to a watched file changes the key; an edit anywhere else (a base merge's other files) keeps it;
- `migrate` skips only on the scope job's hit, and saves the marker only after a passing journey step;
- the scope job never runs on a dispatch, and full-ci still runs the journey.
"""
from __future__ import annotations

import importlib.util
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "migrate-journey-pr.yml"
KEY_SCRIPT = ROOT / "scripts" / "ci" / "migrate_journey_key.py"

spec = importlib.util.spec_from_file_location("migrate_journey_key", KEY_SCRIPT)
mjk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mjk)


def workflow_paths() -> list[str]:
    text = WORKFLOW.read_text()
    block = text.split("pull_request:", 1)[1].split("paths:", 1)[1].split("\n\n", 1)[0]
    return [m.group(1) for m in re.finditer(r"^\s+- (\S+)$", block, re.M)]


def job_block(name: str) -> str:
    text = WORKFLOW.read_text()
    start = text.index(f"\n  {name}:\n")
    rest = text[start + 1:]
    nxt = re.search(r"\n  [a-z][a-z0-9-]*:\n", rest[1:])
    return rest if nxt is None else rest[: nxt.start() + 1]


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


class KeyInputsTest(unittest.TestCase):
    def test_inputs_cover_the_paths_filter(self) -> None:
        covered = set(mjk.TREES) | {f"{mjk.CLI_DIR}/{p}*" for p in mjk.CLI_PREFIXES}
        for path in workflow_paths():
            bare = path.removesuffix("/**")
            ok = bare in covered or path in covered or any(
                bare.startswith(f"{mjk.CLI_DIR}/{p}") for p in mjk.CLI_PREFIXES
            )
            self.assertTrue(ok, f"{path} is in paths: but not in migrate_journey_key.py")
        self.assertGreaterEqual(len(workflow_paths()), 5)


class KeyBehaviorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "t@example.invalid")
        git(self.repo, "config", "user.name", "t")
        for rel in [
            "cmux-tui/crates/cmux-migrate/src/lib.rs",
            f"{mjk.CLI_DIR}/migrate.rs",
            f"{mjk.CLI_DIR}/cloud_journey/repo.rs",
            f"{mjk.CLI_DIR}/other.rs",
            "scripts/cmux-next/migrate-journey-ci.sh",
            ".github/workflows/migrate-journey-pr.yml",
            "README.md",
        ]:
            self.write(rel, "one\n")
        self.commit()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, rel: str, body: str) -> None:
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)

    def commit(self) -> None:
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "-q", "-m", "c")

    def key(self) -> str:
        return mjk.key("HEAD", str(self.repo))

    def test_watched_edits_change_the_key(self) -> None:
        for rel in [
            "cmux-tui/crates/cmux-migrate/src/lib.rs",
            f"{mjk.CLI_DIR}/migrate.rs",
            f"{mjk.CLI_DIR}/cloud_journey/repo.rs",
            "scripts/cmux-next/migrate-journey-ci.sh",
            ".github/workflows/migrate-journey-pr.yml",
        ]:
            before = self.key()
            self.write(rel, (self.repo / rel).read_text() + "x\n")
            self.commit()
            self.assertNotEqual(before, self.key(), rel)

    def test_other_edits_keep_the_key(self) -> None:
        before = self.key()
        self.write("README.md", "two\n")
        self.write(f"{mjk.CLI_DIR}/other.rs", "two\n")
        self.commit()
        self.assertEqual(before, self.key())
        self.assertRegex(before, r"^[0-9a-f]{40}$")

    def test_no_tree_means_no_reuse(self) -> None:
        self.assertEqual(mjk.key("no-such-rev", str(self.repo)), "")


class WorkflowWiringTest(unittest.TestCase):
    def test_migrate_skips_only_on_a_hit(self) -> None:
        migrate = job_block("migrate")
        self.assertIn("needs: [self-edit, scope]", migrate)
        self.assertIn("needs.scope.outputs.hit != 'true'", migrate)

    def test_marker_saved_only_after_a_pass(self) -> None:
        migrate = job_block("migrate")
        journey = migrate.index("run: bash scripts/cmux-next/migrate-journey-ci.sh")
        save = migrate.index("actions/cache/save@")
        self.assertLess(journey, save)
        self.assertIn("key: migrate-journey-green-${{ needs.scope.outputs.key }}", migrate)
        mark = migrate[journey:save]
        self.assertIn("if: ${{ success() && needs.scope.outputs.key != '' }}", mark)

    def test_scope_is_pull_request_only_and_full_ci_runs(self) -> None:
        scope = job_block("scope")
        cond = scope.split("if:", 1)[1].split("\n", 1)[0]
        self.assertIn("github.event_name == 'pull_request'", cond)
        self.assertIn("'full-ci'", cond)
        self.assertIn("CI_MIGRATE_JOURNEY_REUSE", cond)
        self.assertIn("lookup-only: true", scope)
        self.assertIn("key: migrate-journey-green-${{ steps.key.outputs.key }}", scope)


if __name__ == "__main__":
    unittest.main()
