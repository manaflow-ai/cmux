#!/usr/bin/env python3
"""scripts/ci/job_inputs.py on small fixture trees: which source declares each pull request job, and the fixer."""
from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))

import job_inputs  # noqa: E402

WORKFLOWS = {
    "guards.yml": """
        on:
          pull_request:
            branches: [feat-cmux-next]
            paths: ['**', '!**/*.md']
          push:
            branches: [feat-cmux-next]
        jobs:
          fast-check-route:
            runs-on: ubuntu-latest
            steps:
              - run: python3 scripts/ci/fast_check_route.py route
          routed:
            needs: [fast-check-route]
            runs-on: ubuntu-latest
            steps:
              - run: python3 scripts/check.py
          tooling:
            runs-on: ubuntu-latest
            steps:
              - if: needs.placement.outputs.tooling_all != 'false' || contains(needs.placement.outputs.tooling_steps, ' tt-a ')
                run: bash scripts/a.test.sh
          loose:
            runs-on: ubuntu-latest
            steps:
              - run: python3 scripts/check.py
          push-only:
            if: ${{ github.event_name == 'push' && github.repository_owner == 'manaflow-ai' }}
            runs-on: ubuntu-latest
            steps:
              - run: echo push
    """,
    "next.yml": """
        on:
          pull_request:
            branches: [feat-cmux-next]
        jobs:
          path_route:
            runs-on: ubuntu-latest
            steps:
              - run: echo route
          build:
            needs: [path_route]
            if: needs.path_route.outputs.app == 'true'
            runs-on: ubuntu-latest
            steps:
              - run: echo build
          daemon-test:
            runs-on: ubuntu-latest
            steps:
              - run: echo test
    """,
    "narrow.yml": """
        on:
          pull_request:
            paths: ['web/**']
        jobs:
          lint:
            runs-on: ubuntu-latest
            steps:
              - run: echo lint
    """,
    "main-only.yml": """
        on:
          pull_request_target:
            branches: [main]
        jobs:
          cla:
            runs-on: ubuntu-latest
            steps:
              - run: echo cla
    """,
    "pr-router.yml": """
        on:
          pull_request:
            branches: [feat-cmux-next]
        jobs:
          route:
            runs-on: ubuntu-latest
            steps:
              - run: echo route
          size-budget:
            needs: route
            uses: ./.github/workflows/size.yml
    """,
}
MAPS = {
    "scripts/ci/fast-check-inputs.json": {"workflows": {".github/workflows/guards.yml": {"routed": {"inputs": []}}}},
    "scripts/ci/affected-jobs.json": {"workflows": {".github/workflows/next.yml": {"inputs": {}, "jobs": {"daemon-test": {}}}}},
    "scripts/ci/pr_router.json": {"callees": {"size.yml": {"affects": ["Resources/**"]}}},
}


class JobInputsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for name, text in WORKFLOWS.items():
            self.write(f".github/workflows/{name}", textwrap.dedent(text).lstrip())
        for rel, data in MAPS.items():
            self.write(rel, json.dumps(data))
        self.write("scripts/check.py", 'open("config/rules.json")\n')
        self.write("config/rules.json", "{}\n")

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def files(self) -> list[str]:
        return sorted(str(p.relative_to(self.root)) for p in self.root.rglob("*") if p.is_file())

    def sources(self) -> dict[str, str | None]:
        return {f"{r['workflow'].rsplit('/', 1)[-1]}:{r['job']}": r["source"] for r in job_inputs.survey(self.root)}

    def quiet(self, fn, *args, **kwargs):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = fn(*args, **kwargs)
        return code, out.getvalue(), err.getvalue()

    def test_each_source_declares_its_jobs(self):
        self.assertEqual(self.sources(), {
            "guards.yml:fast-check-route": None,
            "guards.yml:routed": "fast-check-inputs",
            "guards.yml:tooling": "tooling-steps",
            "guards.yml:loose": None,
            "next.yml:path_route": None,
            "next.yml:build": "path-route",
            "next.yml:daemon-test": "affected-jobs",
            "narrow.yml:lint": "workflow-paths",
            "pr-router.yml:route": None,
            "pr-router.yml:size-budget": "pr-router",
        })

    def test_a_workflow_for_another_branch_is_not_listed(self):
        self.assertNotIn("main-only.yml:cla", self.sources())

    def test_check_names_the_undeclared_job_and_the_fix(self):
        code, _, err = self.quiet(job_inputs.check, self.root)
        self.assertEqual(code, 1)
        self.assertIn("job loose declares no inputs", err)
        self.assertIn("python3 scripts/ci/job_inputs.py fix", err)

    def test_fix_records_each_undeclared_job_with_what_it_reads(self):
        self.quiet(job_inputs.fix, self.root, files=self.files())
        data = json.loads((self.root / job_inputs.ALWAYS).read_text())
        loose = data["jobs"][".github/workflows/guards.yml"]["loose"]
        self.assertEqual(loose["why"], job_inputs.UNDECLARED_WHY)
        self.assertIn("scripts/check.py", loose["suggested_inputs"])
        self.assertIn("config/rules.json", loose["suggested_inputs"])
        self.assertNotIn("routed", data["jobs"][".github/workflows/guards.yml"])
        self.assertEqual(self.quiet(job_inputs.check, self.root)[0], 0)
        self.assertEqual(self.sources()["guards.yml:loose"], "always")

    def test_fix_keeps_a_reviewed_reason_and_drops_entries_a_router_now_declares(self):
        self.quiet(job_inputs.fix, self.root, files=self.files())
        path = self.root / job_inputs.ALWAYS
        data = json.loads(path.read_text())
        data["jobs"][".github/workflows/next.yml"]["path_route"] = {"why": "the router itself"}
        path.write_text(json.dumps(data))
        fast = {"workflows": {".github/workflows/guards.yml": {"routed": {}, "loose": {}}}}
        self.write("scripts/ci/fast-check-inputs.json", json.dumps(fast))
        _, out, _ = self.quiet(job_inputs.fix, self.root, files=self.files())
        self.assertIn("dropped: .github/workflows/guards.yml loose", out)
        data = json.loads(path.read_text())
        self.assertNotIn("loose", data["jobs"][".github/workflows/guards.yml"])
        self.assertEqual(data["jobs"][".github/workflows/next.yml"]["path_route"], {"why": "the router itself"})

    def test_fix_with_nothing_to_do_leaves_the_file_alone(self):
        self.quiet(job_inputs.fix, self.root, files=self.files())
        path = self.root / job_inputs.ALWAYS
        before = path.read_text()
        _, out, _ = self.quiet(job_inputs.fix, self.root, files=self.files())
        self.assertEqual(out, "")
        self.assertEqual(path.read_text(), before)

    def test_report_totals(self):
        self.quiet(job_inputs.fix, self.root, files=self.files())
        _, out, _ = self.quiet(job_inputs.report, self.root, True)
        totals = json.loads(out)["totals"]
        self.assertEqual(totals["jobs"], 10)
        self.assertEqual(totals["by_source"]["always"], 4)
        self.assertEqual(totals["whole"], 4)
        self.assertEqual(totals["narrow"], 6)
        self.assertEqual(totals["by_source"]["undeclared"], 0)

    def test_a_job_for_another_event_is_not_listed(self):
        self.assertNotIn("guards.yml:push-only", self.sources())
        self.assertTrue(job_inputs.runs_on_pull_requests({"if": "github.event_name == 'push' || inputs.force"}))
        self.assertTrue(job_inputs.runs_on_pull_requests({"if": "github.event_name == 'pull_request' && a"}))
        # ci.yml's shapes: skipped for a pull request to feat-cmux-next, or on any pull request.
        self.assertFalse(job_inputs.runs_on_pull_requests({"if": "${{ !cancelled() && !(github.event_name == "
                                                                 "'pull_request' && github.event.pull_request.base.ref "
                                                                 "== 'feat-cmux-next') }}"}, ["pull_request"]))
        self.assertFalse(job_inputs.runs_on_pull_requests({"if": "${{ (!cancelled() && ((github.event_name != "
                                                                 "'pull_request' || github.event.pull_request.base.ref "
                                                                 "!= 'feat-cmux-next') && needs.a.outputs.b == 'true')) }}"},
                                                          ["pull_request"]))
        self.assertTrue(job_inputs.runs_on_pull_requests({"if": "${{ contains(fromJSON('[\"a\"]'), "
                                                                "github.event.label.name) }}"}))
        self.assertTrue(job_inputs.runs_on_pull_requests({"if": "(unbalanced"}))

    def test_a_long_suggestion_keeps_the_first_paths_and_the_count(self):
        paths = [f"p{i:03}" for i in range(job_inputs.SUGGESTED_MAX + 5)]
        self.assertEqual(job_inputs.suggestion(paths), {"suggested_inputs": paths[:job_inputs.SUGGESTED_MAX],
                                                        "suggested_inputs_more": 5})
        self.assertEqual(job_inputs.suggestion(["a"]), {"suggested_inputs": ["a"]})

    def test_docs_only_paths_are_not_narrow(self):
        self.assertFalse(job_inputs.narrow_paths([{"paths": ["**", "!**/*.md"]}]))
        self.assertTrue(job_inputs.narrow_paths([{"paths": ["web/**", "!web/**/*.md"]}]))
        self.assertFalse(job_inputs.narrow_paths([{"paths": ["web/**"]}, None]))


if __name__ == "__main__":
    unittest.main()
