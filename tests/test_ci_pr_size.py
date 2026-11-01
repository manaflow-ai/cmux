#!/usr/bin/env python3
"""The PR size check counts the right lines and warns on an oversized PR that does not say why.

  - every glob in scripts/ci/pr_size_exclusions.json still matches a tracked
    file, so a stale entry cannot quietly drop authored lines from the count;
  - over the limit it warns with a split hint and exits 3, a `Size:` line with a
    reason overrides it (exit 0), and allowlisted generated files never push a
    pull request over;
  - its job (`size` in .github/workflows/pr-checks.yml) never fails: an oversized
    pull request, an API error and a script crash all warn and pass (Leo,
    2026-10-28: "you don't need to make it, like, a hard gate"), carries no "(advisory)" in its
    name (next-autoland ignores such checks), and stays pull_request only (never
    pull_request_target), a read-only token, no secrets or environment, Linux,
    not a ruleset required check, draft-skipping and CI_QUOTA_HOLD-gated.
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
    def run_main(self, files: str, body: str | None, changed_files: int | None = None) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "files.tsv").write_text(files, encoding="utf-8")
            pull = {"body": body} if changed_files is None else {"body": body, "changed_files": changed_files}
            (directory / "event.json").write_text(json.dumps({"pull_request": pull}), encoding="utf-8")
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

    def test_over_the_limit_without_a_reason_warns_with_a_split_hint(self) -> None:
        code, out = self.run_main(jsonl((700, 200, "src/a.swift")), "A change")
        self.assertEqual(code, pr_size.OVER)
        self.assertEqual(pr_size.OVER, 3)
        self.assertIn("::warning title=PR size over 800 lines::", out)
        self.assertNotIn("::error", out)
        self.assertIn("How to split", out)
        self.assertIn("tests", out)
        self.assertIn("over about 800 lines should say in its body why it isn't split", out)

    def test_size_line_overrides_and_prints_the_reason(self) -> None:
        code, out = self.run_main(jsonl((700, 200, "src/a.swift")), "Intro\n\nSize: one atomic rename across the tree\n")
        self.assertEqual(code, 0)
        self.assertNotIn("::error", out)
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
        self.assertNotIn("::error", out)
        self.assertIn("300 counted lines", out)
        self.assertIn("2500 more in allowlisted", out)

    def test_odd_file_names_stay_one_record(self) -> None:
        files = jsonl((10, 0, "src/a\nb.py"), (5, 0, "src/c\td.py"), (1, 0, "src/e\u2028f.py"), (2, 0, "x`|y.md"))
        rows = pr_size.parse_files(files)
        self.assertEqual([p for p, _ in rows], ["src/a\nb.py", "src/c\td.py", "src/e\u2028f.py", "x`|y.md"])
        code, out = self.run_main(files, None)
        self.assertEqual(code, 0)
        self.assertIn("18 counted lines", out)

    def test_a_size_word_without_a_reason_does_not_override(self) -> None:
        for body in (None, "", "Size:", "Size:   \n", "Note the Size: is big", "size: lower case"):
            with self.subTest(body=body):
                code, out = self.run_main(jsonl((801, 0, "src/a.swift")), body)
                self.assertEqual(code, pr_size.OVER)
                self.assertIn("::warning title=PR size over", out)

    def test_within_the_limit_passes_without_a_reason(self) -> None:
        code, out = self.run_main(jsonl((400, 400, "src/a.swift")), None)
        self.assertEqual(code, 0)
        self.assertNotIn("::error", out)

    def test_a_cut_off_files_list_counts_as_over(self) -> None:
        # GitHub's list stops at 3000 files: what it left out could be counted lines.
        files = jsonl((10, 0, "src/a.swift"))
        code, out = self.run_main(files, "Why.", changed_files=3500)
        self.assertEqual(code, pr_size.OVER)
        self.assertIn("counts as over the limit", out)
        code, _ = self.run_main(files, "Size: tree-wide generated move", changed_files=3500)
        self.assertEqual(code, 0)
        code, _ = self.run_main(files, "Why.", changed_files=1)
        self.assertEqual(code, 0)

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

    def test_not_ruleset_required_gated_and_draft_skipping(self) -> None:
        job = self.job
        self.assertEqual(job["name"], "PR size")
        self.assertNotIn("advisory", job["name"].lower())
        self.assertNotIn(context_of(JOB, job, WORKFLOW, self.workflow), REQUIRED_CHECKS)
        self.assertNotIn("continue-on-error", job)
        # Only the checkout may fail open (it measures nothing); the count step never does.
        for step in job["steps"]:
            if step.get("id") != "checkout":
                self.assertNotIn("continue-on-error", step)
        self.assertIn("steps.checkout.outcome", str(job["steps"][-1]["env"]))
        self.assertIn(GATE, str(job["if"]))
        self.assertIn(DRAFT, str(job["if"]))
        self.assertIn(JOB, HOLD_GATED[WORKFLOW.name])
        self.assertIn(JOB, DRAFT_SKIPPED[WORKFLOW.name])

    def test_every_edit_runs_it(self) -> None:
        # Edited runs share one cancel-in-progress group: a title edit that skipped the job could cancel
        # the run of a body edit and leave no measured answer.
        condition = str(self.job["if"])
        self.assertIn('"edited"', condition)
        self.assertNotIn("changes.body", condition)
        self.assertNotIn("changes.title", condition)

    def run_step(self, script_exit: int | None, gh_exit: int = 0, checkout: str = "success",
                 live_body: str | None = None, event_body: str = "", lines: int = 10) -> int:
        return self.run_step_output(script_exit, gh_exit, checkout, live_body, event_body, lines)[0]

    def run_step_output(self, script_exit: int | None, gh_exit: int = 0, checkout: str = "success",
                        live_body: str | None = None, event_body: str = "", lines: int = 10,
                        graphql: list[str] | None = None, calls: list[str] | None = None) -> tuple[int, str]:
        """The job's own count step with gh stubbed, and the script stubbed (SCRIPT_EXIT) or the real one (None).
        `graphql`: the lines the GraphQL query's --jq prints (None: the query fails, so the REST fallback reads).
        `calls` collects each gh invocation's arguments."""
        run = self.job["steps"][-1]["run"]
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "scripts/ci").mkdir(parents=True)
            if script_exit is None:
                for name in ("pr_size.py", "pr_size_exclusions.json"):
                    (directory / "scripts/ci" / name).write_bytes((SCRIPT.parent / name).read_bytes())
            else:
                (directory / "scripts/ci/pr_size.py").write_text(f"import sys\nsys.exit({script_exit})\n",
                                                                 encoding="utf-8")
            files = json.dumps({"filename": "src/a.swift", "additions": lines, "deletions": 0})
            live = json.dumps({"pull_request": {"body": live_body, "changed_files": 1}})
            (directory / "files.out").write_text(files + "\n", encoding="utf-8")
            (directory / "live.out").write_text(live + "\n", encoding="utf-8")
            event = directory / "event.json"
            event.write_text(json.dumps({"pull_request": {"body": event_body}}), encoding="utf-8")
            bin_dir = directory / "bin"
            bin_dir.mkdir()
            live_exit = 1 if live_body is None else 0
            graphql_exit = 1 if graphql is None else 0
            (directory / "graphql.out").write_text("".join(line + "\n" for line in graphql or []), encoding="utf-8")
            (bin_dir / "gh").write_text(
                "#!/bin/sh\n"
                f'printf "%s\\n" "$*" >> "{directory}/calls.log"\n'
                f'case "$1 $2" in "api graphql") [ {graphql_exit} = 0 ] && cat "{directory}/graphql.out"; '
                f'exit {graphql_exit};; esac\n'
                f'case "$*" in *pulls/1/files*) [ {gh_exit} = 0 ] && cat "{directory}/files.out"; exit {gh_exit};; esac\n'
                f'[ {live_exit} = 0 ] && cat "{directory}/live.out"; exit {live_exit}\n', encoding="utf-8")
            (bin_dir / "gh").chmod(0o755)
            env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "RUNNER_TEMP": str(directory),
                   "GITHUB_EVENT_PATH": str(event), "REPOSITORY": "o/r", "PR": "1", "CHECKOUT": checkout}
            done = subprocess.run(["bash", "-c", run], cwd=directory, env=env, capture_output=True, text=True)
            if calls is not None and (directory / "calls.log").exists():
                calls.extend((directory / "calls.log").read_text(encoding="utf-8").splitlines())
            return done.returncode, done.stdout

    @staticmethod
    def graphql_lines(body: str | None, lines: int, pages: int = 1) -> list[str]:
        """What the query's --jq prints: each page's body line, then its files."""
        out = []
        for page in range(pages):
            out.append(json.dumps({"pull_request": {"body": body, "changed_files": pages}}))
            out.append(json.dumps({"filename": f"src/{page}.swift", "additions": lines, "deletions": 0}))
        return out

    def test_one_graphql_query_reads_files_and_the_current_body(self) -> None:
        # 2026-10-31: the GITHUB_TOKEN REST pool ran out at 00:50Z; the size check now spends none of it.
        warned = "::warning title=PR size over"
        calls: list[str] = []
        code, out = self.run_step_output(None, graphql=self.graphql_lines("Why.", 900), event_body="Size: x",
                                         calls=calls)
        self.assertEqual(code, 0)
        self.assertIn(warned, out, "the current body (no Size: line) decides, not the event's")
        self.assertEqual([c.split()[:2] for c in calls], [["api", "graphql"]], "no REST read")
        self.assertIn("--paginate", calls[0])
        code, out = self.run_step_output(None, graphql=self.graphql_lines("Size: atomic rename", 900))
        self.assertNotIn(warned, out)
        # Two pages: each repeats the body line; both pages' files count (2 x 450 > 800), the body line is no file.
        code, out = self.run_step_output(None, graphql=self.graphql_lines("Why.", 450, pages=2))
        self.assertIn(warned, out)
        code, out = self.run_step_output(None, graphql=self.graphql_lines("Why.", 300, pages=2))
        self.assertNotIn(warned, out)

    def test_the_query_pages_with_end_cursor(self) -> None:
        # gh api graphql --paginate re-sends page 1 forever unless the cursor variable is $endCursor.
        run = self.job["steps"][-1]["run"]
        self.assertIn("$endCursor:String", run)
        self.assertIn("after:$endCursor", run)
        self.assertIn("pageInfo{hasNextPage endCursor}", run)

    def test_a_failed_graphql_read_falls_back_to_rest(self) -> None:
        calls: list[str] = []
        code, out = self.run_step_output(None, lines=900, live_body="Size: atomic rename", calls=calls)
        self.assertEqual(code, 0)
        self.assertNotIn("::warning title=PR size over", out)
        self.assertEqual(calls[0].split()[:2], ["api", "graphql"])
        self.assertTrue(any("pulls/1/files" in c for c in calls[1:]))

    def test_the_current_body_decides_not_the_events_copy(self) -> None:
        # A re-run of an older run whose event still had the `Size:` line the body has since dropped.
        warned = "::warning title=PR size over"
        code, out = self.run_step_output(None, lines=900, live_body="Why.", event_body="Size: atomic rename")
        self.assertEqual(code, 0)
        self.assertIn(warned, out)
        code, out = self.run_step_output(None, lines=900, live_body="Size: atomic rename", event_body="Why.")
        self.assertEqual(code, 0)
        self.assertNotIn(warned, out)
        # The body unread: the event's copy answers.
        code, out = self.run_step_output(None, lines=900, live_body=None, event_body="Size: atomic rename")
        self.assertEqual(code, 0)
        self.assertNotIn(warned, out)
        code, out = self.run_step_output(None, lines=900, live_body=None, event_body="Why.")
        self.assertEqual(code, 0)
        self.assertIn(warned, out)
        code, out = self.run_step_output(None, lines=10, live_body="Why.")
        self.assertEqual(code, 0)
        self.assertNotIn(warned, out)

    def test_the_step_never_fails(self) -> None:
        self.assertEqual(self.run_step(0), 0)
        self.assertEqual(self.run_step(3), 0, "an oversized pull request warns and passes")
        self.assertEqual(self.run_step(1), 0, "a script crash warns and passes")
        self.assertEqual(self.run_step(2), 0, "a script crash warns and passes")
        self.assertEqual(self.run_step(3, gh_exit=1), 0, "an unread file list warns and passes")
        self.assertEqual(self.run_step(3, checkout="failure"), 0, "a failed checkout warns and passes")

    def test_script_comes_from_the_base_commit(self) -> None:
        checkout = self.job["steps"][0]
        self.assertEqual(checkout["with"]["ref"], "${{ github.event.pull_request.base.sha }}")
        self.assertIn("scripts/ci/pr_size.py", self.text)
        self.assertIn("scripts/ci/pr_size_exclusions.json", self.text)


if __name__ == "__main__":
    unittest.main()
