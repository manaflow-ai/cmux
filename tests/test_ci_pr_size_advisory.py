#!/usr/bin/env python3
"""The PR size advisory counts the right lines and can never block a merge.

  - every glob in scripts/ci/pr_size_exclusions.json still matches a tracked
    file, so a stale entry cannot quietly drop authored lines from the count;
  - over the limit it warns with a split hint, a `Size:` line overrides it, and
    allowlisted generated files never push a pull request over;
  - it exits 0 for any size;
  - its job (`size` in .github/workflows/pr-checks.yml) stays advisory:
    pull_request only (never pull_request_target), a read-only token, no secrets
    or environment, Linux, not a required check, draft-skipping and
    CI_QUOTA_HOLD-gated.
"""

from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

from test_ci_quota_hold_gate import DRAFT, DRAFT_SKIPPED, GATE, HOLD_GATED  # noqa: E402
from test_ci_required_checks_are_bounded import context_of, load  # noqa: E402
from test_ci_required_checks_have_no_path_filters import REQUIRED_CHECKS  # noqa: E402

SCRIPT = ROOT / "scripts/ci/pr_size.py"
WORKFLOW = ROOT / ".github/workflows/pr-checks.yml"
JOB = "size"

spec = importlib.util.spec_from_file_location("pr_size", SCRIPT)
assert spec and spec.loader
pr_size = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = pr_size
spec.loader.exec_module(pr_size)

LIMIT, GLOBS = pr_size.load_config()


def tracked() -> list[str]:
    out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return out.splitlines()


class ExclusionAllowlistTests(unittest.TestCase):
    def test_limit_is_the_rulebook_number(self) -> None:
        self.assertEqual(LIMIT, 800)

    def test_every_glob_matches_a_tracked_file(self) -> None:
        paths = tracked()
        self.assertGreater(len(paths), 1000, "git ls-files returned almost nothing")
        stale = [g for g in GLOBS if not any(pr_size.glob_regex(g).match(p) for p in paths)]
        self.assertEqual(stale, [], "exclusion globs that match no tracked file; drop or fix them")

    def test_every_entry_says_why(self) -> None:
        data = json.loads(pr_size.EXCLUSIONS.read_text(encoding="utf-8"))
        for entry in data["exclude"]:
            self.assertTrue(entry.get("why"), entry)
        self.assertEqual(len(GLOBS), len(set(GLOBS)))

    def test_glob_semantics(self) -> None:
        match = lambda glob, path: bool(pr_size.glob_regex(glob).match(path))  # noqa: E731
        self.assertTrue(match("**/bun.lock", "bun.lock"))
        self.assertTrue(match("**/bun.lock", "webviews/bun.lock"))
        self.assertFalse(match("**/bun.lock", "webviews/bun.lockb"))
        self.assertTrue(match("**/generated/**", "webviews/src/protocol/generated/a/b.ts"))
        self.assertFalse(match("**/generated/**", "webviews/src/notgenerated/b.ts"))
        self.assertTrue(match("docs/mdm/com.manaflow.cmux.*", "docs/mdm/com.manaflow.cmux.json"))
        self.assertFalse(match("docs/mdm/com.manaflow.cmux.*", "docs/mdm/vendors.md"))
        self.assertFalse(match("web/data/next-docs/*.generated.json", "web/data/next-docs/x/y.generated.json"))

    def test_authored_code_is_counted(self) -> None:
        for path in (
            "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Cloud/CloudStartSession.swift",
            "cmux-tui/crates/acpmux/src/hub/lane_reports.rs",
            "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/CloudStartSessionTests.swift",
            "docs/mdm/vendors.md",
            ".github/workflows/pr-checks.yml",
        ):
            self.assertIsNone(pr_size.excluded_by(path, GLOBS), path)
        for path in (
            "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Resources/CloudSessions.xcstrings",
            "plans/cmux-next/action-surfaces.json",
            "schemas/settings/settings-schema.json",
            "web/data/next-docs/cli-reference.generated.json",
            "cmux-tui/Cargo.lock",
            "docs/mdm/managed-preferences.md",
            "schemas/defaults/cmux-next.json",
            "web/data/cmux-shortcuts.generated.json",
        ):
            self.assertIsNotNone(pr_size.excluded_by(path, GLOBS), path)


    def test_every_committed_generator_output_is_excluded(self) -> None:
        # scripts/cmux-next/generated_outputs.py is the repo's list of committed
        # generated files (fnmatch, `*` crosses `/`); none of them may count.
        import fnmatch

        spec = importlib.util.spec_from_file_location("generated_outputs", ROOT / "scripts/cmux-next/generated_outputs.py")
        assert spec and spec.loader
        outputs = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(outputs)
        patterns = [pattern for group, _, _ in outputs.OUTPUTS for pattern in group]
        self.assertTrue(patterns)
        counted = sorted(
            path for path in tracked()
            if any(fnmatch.fnmatchcase(path, pattern) for pattern in patterns)
            and pr_size.excluded_by(path, GLOBS) is None
        )
        self.assertEqual(counted, [], "generated outputs the size check would count; add their globs")


def jsonl(*rows: tuple[int, int, str]) -> str:
    return "".join(json.dumps({"filename": f, "additions": a, "deletions": d}) + "\n" for a, d, f in rows)


class MeasureTests(unittest.TestCase):
    def run_main(self, files: str, body: str | None) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "files.tsv").write_text(files, encoding="utf-8")
            (directory / "event.json").write_text(json.dumps({"pull_request": {"body": body}}), encoding="utf-8")
            summary = directory / "summary.md"
            stdout = io.StringIO()
            env = {"GITHUB_STEP_SUMMARY": str(summary)}
            old = {k: pr_size.os.environ.get(k) for k in env}
            pr_size.os.environ.update(env)
            try:
                with redirect_stdout(stdout):
                    code = pr_size.main(["--files", str(directory / "files.tsv"), "--event", str(directory / "event.json")])
            finally:
                for key, value in old.items():
                    if value is None:
                        pr_size.os.environ.pop(key, None)
                    else:
                        pr_size.os.environ[key] = value
            return code, stdout.getvalue() + summary.read_text(encoding="utf-8")

    def test_over_the_limit_warns_with_a_split_hint_and_exits_zero(self) -> None:
        code, out = self.run_main(jsonl((700, 200, "src/a.swift")), "A change")
        self.assertEqual(code, 0)
        self.assertIn("::warning title=PR size over 800 lines::", out)
        self.assertIn("How to split", out)
        self.assertIn("tests", out)

    def test_size_line_overrides_and_prints_the_reason(self) -> None:
        code, out = self.run_main(jsonl((700, 200, "src/a.swift")), "Intro\n\nSize: one atomic rename across the tree\n")
        self.assertEqual(code, 0)
        self.assertNotIn("::warning", out)
        self.assertIn("Size: one atomic rename across the tree", out)

    def test_size_line_must_start_the_line_and_carry_a_reason(self) -> None:
        self.assertIsNone(pr_size.override_reason("Note the Size: is big"))
        self.assertIsNone(pr_size.override_reason("Size:   \n"))
        self.assertEqual(pr_size.override_reason("x\r\n  Size: reason here\r\n"), "reason here")

    def test_allowlisted_lines_do_not_count(self) -> None:
        files = jsonl((300, 0, "src/a.swift"), (2000, 0, "App/Resources/Foo.xcstrings"), (500, 0, "bun.lock"))
        code, out = self.run_main(files, None)
        self.assertEqual(code, 0)
        self.assertNotIn("::warning", out)
        self.assertIn("300 counted lines", out)
        self.assertIn("2500 more in allowlisted", out)

    def test_odd_file_names_stay_one_record(self) -> None:
        files = jsonl((10, 0, "src/a\nb.py"), (5, 0, "src/c\td.py"), (1, 0, "src/e\u2028f.py"), (2, 0, "x`|y.md"))
        rows = pr_size.parse_files(files)
        self.assertEqual([p for p, _ in rows], ["src/a\nb.py", "src/c\td.py", "src/e\u2028f.py", "x`|y.md"])
        code, out = self.run_main(files, None)
        self.assertEqual(code, 0)
        self.assertIn("18 counted lines", out)

    def test_exactly_the_limit_passes(self) -> None:
        result = pr_size.measure([("a.py", 800)], None, LIMIT, GLOBS)
        self.assertFalse(result.over)
        self.assertTrue(pr_size.measure([("a.py", 801)], None, LIMIT, GLOBS).over)


class WorkflowShapeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.text = WORKFLOW.read_text(encoding="utf-8")
        self.workflow = load(WORKFLOW)
        self.job = self.workflow["jobs"][JOB]

    def test_pull_request_only_into_feat_cmux_next(self) -> None:
        on = self.workflow.get("on", self.workflow.get(True))
        self.assertEqual(list(on), ["pull_request"])
        self.assertEqual(on["pull_request"]["branches"], ["feat-cmux-next"])
        self.assertIn("ready_for_review", on["pull_request"]["types"])
        self.assertNotIn("pull_request_target", self.text)

    def test_read_only_token_no_secrets_no_environment(self) -> None:
        self.assertEqual(self.workflow["permissions"], {})
        job = self.job
        self.assertEqual(job["permissions"], {"contents": "read", "pull-requests": "read"})
        self.assertNotIn("environment", job)
        self.assertNotIn("macos", str(job["runs-on"]).lower())
        self.assertNotIn("self-hosted", str(job["runs-on"]).lower())
        self.assertNotIn("secrets.", self.text)

    def test_advisory_not_required_gated_and_draft_skipping(self) -> None:
        job = self.job
        self.assertEqual(job["name"], "PR size (advisory)")
        self.assertNotIn(context_of(JOB, job, WORKFLOW, self.workflow), REQUIRED_CHECKS)
        self.assertNotIn("continue-on-error", job)
        self.assertIn(GATE, str(job["if"]))
        self.assertIn(DRAFT, str(job["if"]))
        self.assertIn(JOB, HOLD_GATED[WORKFLOW.name])
        self.assertIn(JOB, DRAFT_SKIPPED[WORKFLOW.name])

    def test_script_comes_from_the_base_commit(self) -> None:
        checkout = self.job["steps"][0]
        self.assertEqual(checkout["with"]["ref"], "${{ github.event.pull_request.base.sha }}")
        self.assertIn("scripts/ci/pr_size.py", self.text)
        self.assertIn("scripts/ci/pr_size_exclusions.json", self.text)


if __name__ == "__main__":
    unittest.main()
