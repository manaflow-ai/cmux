#!/usr/bin/env python3
"""scripts/ci/guard_base_verdicts.py: reuse feat-cmux-next's push-run verdicts, re-run only the rest on the base."""
from __future__ import annotations

import io
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import guard_base_verdicts as gbv  # noqa: E402

REPO = "o/r"
BASE = "b" * 40
ANCESTOR = "a" * 40
OTHER = "c" * 40


def fake_get(runs: list[dict], compares: dict[str, dict], artifacts: dict[int, list[dict]]):
    def get(path: str, _token: str) -> dict:
        if "/workflows/" in path:
            return {"workflow_runs": runs}
        if "/compare/" in path:
            sha = path.split("/compare/", 1)[1].split("...", 1)[0]
            return compares[sha]
        if "/artifacts?" in path:
            run_id = int(path.split("/runs/", 1)[1].split("/", 1)[0])
            return {"artifacts": artifacts.get(run_id, [])}
        raise AssertionError(path)
    return get


def zipped(results: dict, failures: dict | None = None) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("guards-head.json", json.dumps(results))
        if failures is not None:
            archive.writestr("guards-head.json.failures.json", json.dumps(failures))
    return buffer.getvalue()


class FindSourceTests(unittest.TestCase):
    def test_exact_base_run_wins(self) -> None:
        runs = [{"id": 2, "head_sha": OTHER}, {"id": 1, "head_sha": BASE}]
        run, changed = gbv.find_source(REPO, BASE, "t", get=fake_get(runs, {}, {}))
        self.assertEqual(run["id"], 1)
        self.assertIsNone(changed)

    def test_nearest_ancestor_with_its_diff(self) -> None:
        runs = [{"id": 3, "head_sha": OTHER}, {"id": 2, "head_sha": ANCESTOR}]
        compares = {
            OTHER: {"status": "diverged", "ahead_by": 1, "behind_by": 2},
            ANCESTOR: {"status": "ahead", "ahead_by": 3, "behind_by": 0, "files": [{"filename": "docs/x.md"}]},
        }
        run, changed = gbv.find_source(REPO, BASE, "t", get=fake_get(runs, compares, {}))
        self.assertEqual(run["id"], 2)
        self.assertEqual(changed, ["docs/x.md"])

    def test_no_ancestor_within_reach(self) -> None:
        runs = [{"id": 2, "head_sha": ANCESTOR}]
        compares = {ANCESTOR: {"status": "ahead", "ahead_by": gbv.MAX_BEHIND + 1, "behind_by": 0, "files": []}}
        self.assertIsNone(gbv.find_source(REPO, BASE, "t", get=fake_get(runs, compares, {})))

    def test_cut_listing_reads_as_everything_changed(self) -> None:
        runs = [{"id": 2, "head_sha": ANCESTOR}]
        files = [{"filename": f"f{i}"} for i in range(300)]
        compares = {ANCESTOR: {"status": "ahead", "ahead_by": 2, "behind_by": 0, "files": files}}
        _run, changed = gbv.find_source(REPO, BASE, "t", get=fake_get(runs, compares, {}))
        self.assertGreater(len(changed), 400)


    def test_cancelled_runs_are_never_compared(self) -> None:
        # 98 of 100 completed push runs were cancelled (2026-11-26); each one compared was a shared-budget read.
        runs = [{"id": 9, "head_sha": OTHER, "conclusion": "cancelled"},
                {"id": 8, "head_sha": BASE, "conclusion": "skipped"},
                {"id": 2, "head_sha": ANCESTOR, "conclusion": "failure"}]
        compares = {ANCESTOR: {"status": "ahead", "ahead_by": 3, "behind_by": 0, "files": []}}
        run, changed = gbv.find_source(REPO, BASE, "t", get=fake_get(runs, compares, {}))  # OTHER: KeyError if read
        self.assertEqual(run["id"], 2)
        self.assertEqual(changed, [])

    def test_first_ancestor_stops_the_compares(self) -> None:
        runs = [{"id": 3, "head_sha": ANCESTOR}, {"id": 2, "head_sha": OTHER}]
        compares = {ANCESTOR: {"status": "ahead", "ahead_by": 2, "behind_by": 0, "files": []}}
        run, _changed = gbv.find_source(REPO, BASE, "t", get=fake_get(runs, compares, {}))  # OTHER: KeyError if read
        self.assertEqual(run["id"], 3)

    def test_an_ancestor_past_reach_ends_the_search(self) -> None:
        runs = [{"id": 3, "head_sha": ANCESTOR}, {"id": 2, "head_sha": OTHER}]
        compares = {ANCESTOR: {"status": "ahead", "ahead_by": gbv.MAX_BEHIND + 1, "behind_by": 0, "files": []}}
        self.assertEqual(list(gbv.sources(REPO, BASE, "t", get=fake_get(runs, compares, {}))), [])


class DownloadTests(unittest.TestCase):
    def test_reads_results_and_failures(self) -> None:
        run = {"id": 7, "head_sha": BASE}
        artifacts = {7: [{"id": 70, "name": f"guard-verdicts-{BASE}", "expired": False}]}
        blob = zipped({"A": False, "_cmux_complete": True}, {"A": ["boom"]})
        results, failures = gbv.download_results(REPO, run, "t", get=fake_get([], {}, artifacts), fetch=lambda *_: blob)
        self.assertEqual(results["A"], False)
        self.assertEqual(failures, {"A": ["boom"]})

    def test_no_artifact(self) -> None:
        run = {"id": 7, "head_sha": BASE}
        self.assertIsNone(gbv.download_results(REPO, run, "t", get=fake_get([], {}, {}), fetch=lambda *_: b""))


class ReuseTests(unittest.TestCase):
    RESULTS = {"A": False, "A :: one": False, "B": True, "_cmux_complete": True}

    def test_reuses_every_recorded_step_at_the_base(self) -> None:
        kept, failures, left = gbv.reuse(self.RESULTS, {"A": ["x"]}, ["A", "B", "C"], None)
        self.assertEqual(kept, {"A": False, "A :: one": False, "B": True})
        self.assertEqual(failures, {"A": ["x"]})
        self.assertEqual(left, ["C"])

    def test_ancestor_reuses_only_unreached_steps(self) -> None:
        kept, _failures, left = gbv.reuse(self.RESULTS, {}, ["A", "B"], {"B"})
        self.assertEqual(kept, {"B": True})
        self.assertEqual(left, ["A"])


class MainTests(unittest.TestCase):
    def run_main(self, steps: list[str], **patches) -> tuple[list[str], dict]:
        with tempfile.TemporaryDirectory() as tmp:
            red = Path(tmp, "red.txt")
            red.write_text("\n".join(steps) + "\n")
            out = Path(tmp, "out.json")
            argv = ["--repo", REPO, "--base", BASE, "--root", tmp, "--steps", str(red), "--out", str(out)]
            printed = io.StringIO()
            with mock.patch.dict("os.environ", {"GH_TOKEN": "t", "CI_CACHE_R2_PUBLIC_URL": ""}), mock.patch("sys.stdout", printed), \
                    mock.patch("sys.stderr", io.StringIO()):
                with mock.patch.multiple(gbv, **patches):
                    self.assertEqual(gbv.main(argv), 0)
            body = json.loads(out.read_text()) if out.exists() else {}
            return printed.getvalue().split(), body

    def test_api_error_reruns_every_step(self) -> None:
        def broken(*_args, **_kwargs):
            raise OSError("network down")
        left, body = self.run_main(["A", "B"], sources=broken)
        self.assertEqual(left, ["A", "B"])
        self.assertEqual(body, {})

    def test_reused_results_are_incomplete(self) -> None:
        left, body = self.run_main(
            ["A", "C"],
            sources=lambda *_: iter([({"id": 1, "head_sha": BASE}, None)]),
            download_results=lambda *_: ({"A": False, "_cmux_complete": True}, {}),
        )
        self.assertEqual(left, ["C"])
        self.assertEqual(body, {"A": False, "_cmux_complete": False})


    def test_a_run_with_no_artifact_falls_to_the_next(self) -> None:
        older = {"id": 2, "head_sha": ANCESTOR}
        left, body = self.run_main(
            ["A"],
            sources=lambda *_: iter([({"id": 3, "head_sha": OTHER}, ["docs/x.md"]), (older, None)]),
            download_results=lambda _repo, run, _token: None if run["id"] == 3 else ({"A": False}, {}),
        )
        self.assertEqual(left, [])
        self.assertEqual(body, {"A": False, "_cmux_complete": False})


def tar_blob(files: dict[str, dict]) -> bytes:
    import tarfile
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as archive:
        for name, body in files.items():
            data = json.dumps(body).encode()
            info = tarfile.TarInfo(f"./{name}")
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return buf.getvalue()


class R2Tests(unittest.TestCase):
    """The CI cache copy: a public URL, no token, so a spent REST quota never forces the base re-run."""

    def fetcher(self, objects: dict[str, bytes]):
        seen: list[str] = []

        def fetch(url: str) -> bytes | None:
            seen.append(url)
            return next((blob for key, blob in objects.items() if url.endswith(key)), None)
        return fetch, seen

    def test_reads_the_base_with_no_token(self) -> None:
        blob = tar_blob({"guards-head.json": {"A": False}, "guards-head.json.failures.json": {"A": "log"}})
        fetch, seen = self.fetcher({f"guard-verdicts-{BASE}.tar.gz": blob})
        hit = gbv.r2_source("https://cache.example", Path("."), BASE, fetch=fetch, shas=[BASE, ANCESTOR])
        self.assertEqual(hit, (BASE, ({"A": False}, {"A": "log"}), None))
        self.assertTrue(all(url.startswith("https://cache.example/v1/guard-verdicts/objects/") for url in seen))

    def test_nearest_ancestor_carries_its_diff(self) -> None:
        fetch, _ = self.fetcher({f"guard-verdicts-{ANCESTOR}.tar.gz": tar_blob({"guards-head.json": {"A": True}})})
        with mock.patch.object(gbv, "changed_between", return_value=["docs/x.md"]):
            hit = gbv.r2_source("https://cache.example", Path("."), BASE, fetch=fetch, shas=[BASE, OTHER, ANCESTOR])
        self.assertEqual(hit, (ANCESTOR, ({"A": True}, {}), ["docs/x.md"]))

    def test_nothing_in_the_cache(self) -> None:
        fetch, _ = self.fetcher({})
        self.assertIsNone(gbv.r2_source("https://cache.example", Path("."), BASE, fetch=fetch, shas=[BASE]))

    def test_main_prefers_the_cache_over_the_api(self) -> None:
        def no_api(*_args, **_kwargs):
            raise AssertionError("the artifact API was read")
        with tempfile.TemporaryDirectory() as tmp:
            red = Path(tmp, "red.txt")
            red.write_text("A\nC\n")
            out = Path(tmp, "out.json")
            printed = io.StringIO()
            with mock.patch.dict("os.environ", {"CI_CACHE_R2_PUBLIC_URL": "https://cache.example", "GH_TOKEN": ""}), \
                    mock.patch("sys.stdout", printed), mock.patch("sys.stderr", io.StringIO()), \
                    mock.patch.multiple(gbv, sources=no_api,
                                        r2_source=lambda *_a, **_k: (BASE, ({"A": False}, {}), None)):
                self.assertEqual(gbv.main(["--repo", REPO, "--base", BASE, "--root", tmp, "--steps", str(red),
                                           "--out", str(out)]), 0)
            self.assertEqual(printed.getvalue().split(), ["C"])
            self.assertEqual(json.loads(out.read_text()), {"A": False, "_cmux_complete": False})

    def test_a_broken_cache_read_falls_to_the_api(self) -> None:
        def broken(*_a, **_k):
            raise OSError("bucket down")
        with tempfile.TemporaryDirectory() as tmp:
            red = Path(tmp, "red.txt")
            red.write_text("A\n")
            printed = io.StringIO()
            with mock.patch.dict("os.environ", {"CI_CACHE_R2_PUBLIC_URL": "https://cache.example", "GH_TOKEN": "t"}), \
                    mock.patch("sys.stdout", printed), mock.patch("sys.stderr", io.StringIO()), \
                    mock.patch.multiple(gbv, r2_source=broken,
                                        sources=lambda *_: iter([({"id": 1, "head_sha": BASE}, None)]),
                                        download_results=lambda *_: ({"A": True}, {})):
                gbv.main(["--repo", REPO, "--base", BASE, "--root", tmp, "--steps", str(red),
                          "--out", str(Path(tmp, "o.json"))])
            self.assertEqual(printed.getvalue().split(), [])


class MergeTests(unittest.TestCase):
    def test_merge_complete_only_when_the_rerun_finished(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            recorded, rerun, out = Path(tmp, "rec.json"), Path(tmp, "run.json"), Path(tmp, "base.json")
            recorded.write_text(json.dumps({"A": False, "_cmux_complete": False}))
            Path(str(recorded) + ".failures.json").write_text(json.dumps({"A": ["a"]}))
            rerun.write_text(json.dumps({"C": True, "_cmux_complete": False}))
            body = gbv.merge(recorded, rerun, out)
            self.assertEqual(body, {"A": False, "C": True, "_cmux_complete": False})
            rerun.write_text(json.dumps({"C": True, "_cmux_complete": True}))
            self.assertTrue(gbv.merge(recorded, rerun, out)["_cmux_complete"])
            self.assertEqual(json.loads(Path(str(out) + ".failures.json").read_text()), {"A": ["a"]})
            self.assertTrue(gbv.merge(recorded, None, out)["_cmux_complete"])
            self.assertFalse(gbv.merge(recorded, Path(tmp, "missing.json"), out)["_cmux_complete"])

    def test_decision_rule_unchanged(self) -> None:
        """A head red the reused base verdict also has is the base's; one the base passed is the change's."""
        with tempfile.TemporaryDirectory() as tmp:
            head, recorded, out = Path(tmp, "head.json"), Path(tmp, "rec.json"), Path(tmp, "base.json")
            recorded.write_text(json.dumps({"A": False, "_cmux_complete": False}))
            gbv.merge(recorded, None, out)
            reds = ROOT / "scripts" / "ci" / "guards_new_reds.py"
            head.write_text(json.dumps({"A": False, "_cmux_complete": True}))
            self.assertEqual(subprocess.run([sys.executable, str(reds), str(head), str(out)],
                                            capture_output=True).returncode, 0)
            recorded.write_text(json.dumps({"A": True, "_cmux_complete": False}))
            gbv.merge(recorded, None, out)
            self.assertEqual(subprocess.run([sys.executable, str(reds), str(head), str(out)],
                                            capture_output=True).returncode, 1)


class UnreachableTests(unittest.TestCase):
    def test_everything_reason_reuses_nothing(self) -> None:
        self.assertEqual(gbv.unreachable_steps(ROOT, ["Validate Python test harness syntax"],
                                               [f"f{i}" for i in range(gbv.ANCESTOR_MAX_CHANGED + 1)]), set())

    def test_docs_only_diff_reaches_few_steps(self) -> None:
        import guard_step_inputs
        names = [s[0] for s in guard_step_inputs.guard_steps(ROOT)][:40]
        unreached = gbv.unreachable_steps(ROOT, names + ["not a ci-guards step"], ["docs/nothing-reads-this.txt"])
        self.assertNotIn("not a ci-guards step", unreached)
        self.assertTrue(unreached <= set(names))

    def test_runner_change_reuses_nothing(self) -> None:
        self.assertEqual(gbv.unreachable_steps(ROOT, ["Validate Python test harness syntax"],
                                               ["docs/x.txt", "scripts/ci/run_ci_guards.py"]), set())

    def _workflow_change(self, edit) -> set[str]:
        import guard_step_inputs
        import run_ci_guards
        names = [s[0] for s in guard_step_inputs.guard_steps(ROOT)]
        older = run_ci_guards.load_yaml(ROOT / gbv.WORKFLOW_PATH)
        edit(older)
        original = gbv.workflow_at
        gbv.workflow_at = lambda git_root, sha: older
        try:
            return gbv.unreachable_steps(ROOT, names, ["docs/nothing-reads-this.txt", gbv.WORKFLOW_PATH],
                                         ROOT, "ancestor")
        finally:
            gbv.workflow_at = original

    def test_workflow_change_elsewhere_still_reuses(self) -> None:
        # A step the diff's ci-guards.yml edit did not touch keeps its ancestor verdict, unless it reads the workflow.
        unreached = self._workflow_change(lambda wf: None)
        self.assertTrue(unreached)

    def test_changed_step_definition_is_not_reused(self) -> None:
        import guard_step_inputs
        unchanged = self._workflow_change(lambda wf: None)
        target = sorted(unchanged)[0]

        def edit(wf: dict) -> None:
            for job in wf["jobs"].values():
                for step in job.get("steps") or []:
                    if step.get("name") == target:
                        step["run"] = str(step.get("run")) + "\ntrue"
        self.assertNotIn(target, self._workflow_change(edit))
        self.assertIn(target, {s[0] for s in guard_step_inputs.guard_steps(ROOT)})

    def test_changed_job_env_reuses_none_of_its_steps(self) -> None:
        def edit(wf: dict) -> None:
            wf["env"] = dict(wf.get("env") or {}, CMUX_TEST_ONLY="1")
        self.assertEqual(self._workflow_change(edit), set())

    def test_unreadable_ancestor_workflow_reuses_nothing(self) -> None:
        self.assertEqual(gbv.unreachable_steps(ROOT, ["Validate Python test harness syntax"],
                                               [gbv.WORKFLOW_PATH], ROOT, "0" * 40), set())


if __name__ == "__main__":
    unittest.main()
