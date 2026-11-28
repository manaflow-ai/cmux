"""scripts/ci/pr_receipt.py: a green receipt keyed on a check's inputs skips the check on a later head."""

from __future__ import annotations

import argparse
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import pr_receipt  # noqa: E402


def git(root: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout.strip()


class KeyTests(unittest.TestCase):
    """The key moves with an input, a definition file or the change's diff in the inputs, and nothing else."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        git(self.root, "init", "-q", "-b", "main")
        git(self.root, "config", "user.email", "t@example.com")
        git(self.root, "config", "user.name", "t")
        self.write("web/app.ts", "1")
        self.write("docs/readme.md", "1")
        self.write("ci/steps.toml", "table")
        self.commit()
        self.base = git(self.root, "rev-parse", "HEAD")
        self.check = "web-browser"
        self.saved = dict(pr_receipt.MATCHERS)
        pr_receipt.MATCHERS[self.check] = lambda _root: (lambda path: path.startswith("web/"))

    def tearDown(self) -> None:
        pr_receipt.MATCHERS.clear()
        pr_receipt.MATCHERS.update(self.saved)
        self.tmp.cleanup()

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def commit(self) -> str:
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "--allow-empty", "-m", "c")
        return git(self.root, "rev-parse", "HEAD")

    def key(self, merge: str = "HEAD", base: str | None = None, **env: str) -> str | None:
        return pr_receipt.key(self.check, self.root, merge, base or self.base, env=env)

    def test_unrelated_change_keeps_the_key(self) -> None:
        self.write("web/app.ts", "2")
        first = self.key(self.commit())
        self.write("docs/readme.md", "2")
        self.assertEqual(self.key(self.commit()), first)

    def test_input_change_moves_the_key(self) -> None:
        self.write("web/app.ts", "2")
        first = self.key(self.commit())
        self.write("web/app.ts", "3")
        self.assertNotEqual(self.key(self.commit()), first)

    def test_definition_change_moves_the_key(self) -> None:
        first = self.key(self.commit())
        self.write("ci/steps.toml", "table 2")
        self.assertNotEqual(self.key(self.commit()), first)

    def test_same_tree_with_another_diff_moves_the_key(self) -> None:
        self.write("web/app.ts", "2")
        merge = self.commit()
        self.assertNotEqual(self.key(merge, base=self.base), self.key(merge, base=merge))

    def test_runner_is_part_of_the_web_browser_key(self) -> None:
        self.assertNotEqual(self.key(RUNNER_ARCH="X64"), self.key(RUNNER_ARCH="ARM64"))

    def test_no_matcher_means_no_key(self) -> None:
        pr_receipt.MATCHERS[self.check] = lambda _root: None
        self.assertIsNone(self.key())


class RealTreeTests(unittest.TestCase):
    def test_both_checks_key_this_checkout(self) -> None:
        for check in ("web-browser", "fast-gates"):
            with self.subTest(check=check):
                self.assertRegex(pr_receipt.key(check, ROOT, "HEAD", "HEAD") or "", r"^[0-9a-f]{64}$")


def artifact(run_id: int, branch: str = "lane/x", created: str = "2026-11-25T00:00:00Z", **extra: object) -> dict:
    run = {"id": run_id, "repository_id": 1, "head_repository_id": 1, "head_branch": branch, "head_sha": "a" * 40}
    run.update(extra.pop("run", {}))
    return {"name": pr_receipt.artifact_name("fast-gates", "k" * 64), "expired": False, "created_at": created,
            "workflow_run": run, **extra}


class FindTests(unittest.TestCase):
    def find(self, artifacts: list[dict], run_id: str = "99") -> dict | None:
        return pr_receipt.find("fast-gates", "k" * 64, ["lane/x", "feat-cmux-next"], run_id,
                               lambda _path: {"artifacts": artifacts})

    def test_picks_the_newest_same_repo_receipt(self) -> None:
        hit = self.find([artifact(1, created="2026-11-24T00:00:00Z"), artifact(2, created="2026-11-25T00:00:00Z")])
        self.assertEqual(hit["workflow_run"]["id"], 2)

    def test_base_branch_vouches(self) -> None:
        self.assertIsNotNone(self.find([artifact(1, branch="feat-cmux-next")]))

    def test_skips_forks_other_branches_expired_and_this_run(self) -> None:
        self.assertIsNone(self.find([
            artifact(1, run={"head_repository_id": 2}),
            artifact(2, branch="lane/other"),
            artifact(3, expired=True),
            artifact(99),
            artifact(4, name="pr-receipt-fast-gates-other"),
        ]))


def args(**overrides: object) -> argparse.Namespace:
    base = {"check": "fast-gates", "root": str(ROOT), "merge": "HEAD", "base": "HEAD", "variant": "",
            "repository": "o/r", "branch": ["lane/x"], "run_id": "99", "no_find": False}
    base.update(overrides)
    return argparse.Namespace(**base)


class LookupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.calls = 0

    def call(self, _path: str) -> dict:
        self.calls += 1
        return {"artifacts": [artifact(1, name=pr_receipt.artifact_name("fast-gates", self.key))]}

    def lookup(self, env: dict[str, str] | None = None, call=None, **overrides: object) -> dict[str, str]:
        self.key = pr_receipt.key("fast-gates", ROOT, "HEAD", "HEAD")
        return pr_receipt.lookup(args(**overrides), {"CI_PR_RECEIPTS_AUDIT_PERCENT": "0", **(env or {})},
                                 call or self.call, out=io.StringIO())

    def test_hit_links_the_run(self) -> None:
        self.assertEqual(self.lookup()["run"], "https://github.com/o/r/actions/runs/1")

    def test_off_switch_and_no_find_ask_nothing(self) -> None:
        self.assertEqual(self.lookup({"CI_PR_RECEIPTS": "off"})["run"], "")
        self.assertEqual(self.lookup(no_find=True)["run"], "")
        self.assertEqual(self.calls, 0)

    def test_api_error_is_a_miss(self) -> None:
        def broken(_path: str) -> dict:
            raise OSError("HTTP 403")

        result = self.lookup(call=broken)
        self.assertEqual(result["run"], "")
        self.assertRegex(result["key"], r"^[0-9a-f]{64}$")

    def test_audit_runs_the_job(self) -> None:
        self.assertEqual(self.lookup({"CI_PR_RECEIPTS_AUDIT_PERCENT": "100"})["run"], "")

    def test_audit_is_stable_per_run_and_near_its_percent(self) -> None:
        self.assertEqual(pr_receipt.audited("123", 5), pr_receipt.audited("123", 5))
        share = sum(pr_receipt.audited(str(n), 5) for n in range(4000)) / 4000
        self.assertGreater(share, 0.02)
        self.assertLess(share, 0.08)


class RecordTests(unittest.TestCase):
    def test_record_writes_only_a_real_key(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "r" / "receipt.json"
            self.assertEqual(pr_receipt.main(["record", "--check", "web-browser", "--key", "", "--out", str(out)]), 0)
            self.assertFalse(out.exists())
            pr_receipt.main(["record", "--check", "web-browser", "--key", "a" * 64, "--out", str(out)])
            self.assertEqual(json.loads(out.read_text())["key"], "a" * 64)


if __name__ == "__main__":
    unittest.main()
