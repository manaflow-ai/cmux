#!/usr/bin/env python3
"""Tests for scripts/ci/owned_warm_labels.py (no network: HTTP is mocked)."""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import unittest
import unittest.mock
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


labels = load("owned_warm_labels", ROOT / "scripts/ci/owned_warm_labels.py")

MINI = "glaeda-std-xcode-26.6"
ROOT_STD = "glaeda-root-std-xcode-26.6"
ROOT_LIGHT = "glaeda-root-light-xcode-26.6"
A, B, C = "aaaaaaaaaaaa", "bbbbbbbbbbbb", "cccccccccccc"


def warm(key: str) -> str:
    return "glaeda-warm-" + key


def runner(runner_id, *names, name=None):
    return {"id": runner_id, "name": name or f"cmux{runner_id}", "status": "online", "busy": False,
            "labels": [{"name": label, "type": "custom"} for label in names]}


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class FakeHTTP:
    """Answers urllib.request.urlopen for the jobs, runners and label endpoints."""

    def __init__(self, jobs, runners, org_runners=(), groups=None):
        self.jobs, self.runners, self.calls = jobs, runners, []
        self.org_runners = list(org_runners)
        self.groups = [{"id": 23, "name": "glaeda-minis"}] if groups is None else groups

    def __call__(self, request, timeout=None):
        method, url = request.get_method(), request.full_url
        body = json.loads(request.data) if request.data else None
        self.calls.append((method, url.removeprefix("https://api.github.com").removeprefix("/repos/manaflow-ai/cmux"),
                           body))
        if "/jobs?" in url:
            return Response(json.dumps({"jobs": self.jobs}).encode())
        if "/orgs/manaflow-ai/actions/runner-groups?" in url:
            if isinstance(self.groups, int):
                raise urllib.error.HTTPError(url, self.groups, "forbidden", {}, None)
            return Response(json.dumps({"runner_groups": self.groups}).encode())
        if "/runner-groups/23/runners?" in url:
            return Response(json.dumps({"runners": self.org_runners}).encode())
        if url.split("?")[0].endswith("/actions/runners"):
            return Response(json.dumps({"runners": self.runners}).encode())
        if method == "DELETE" and "glaeda-warm-dddddddddddd" in url:
            raise urllib.error.HTTPError(url, 404, "not found", {}, None)
        return Response(b"")

    def writes(self):
        return [(method, path, body) for method, path, body in self.calls if method != "GET"]


class Plan(unittest.TestCase):
    def test_keys_are_validated_deduplicated_and_capped(self):
        document = {"keys": [A.upper(), A, "nope", "../../x", B + "ffff", C, "dddddddddddd", "eeeeeeeeeeee", 7]}
        self.assertEqual(labels.keys(document), [A, B, C, "dddddddddddd"])
        self.assertEqual(len(labels.keys(document)), labels.MAX_KEYS)
        self.assertEqual(labels.keys({"keys": "aaaaaaaaaaaa"}), [])
        self.assertEqual(labels.keys(["aaaaaaaaaaaa"]), [])

    def test_the_runner_takes_its_keys_and_the_rest_of_its_pool_loses_them(self):
        runners = [runner(1, MINI, ROOT_STD, warm(C)),
                   runner(2, MINI, ROOT_STD, warm(A)),
                   # Another pool keeps its own copy of a key.
                   runner(3, "glaeda-light-xcode-26.6", ROOT_LIGHT, warm(A)),
                   runner(4, MINI, ROOT_STD, warm(B), warm(C))]
        changes, why = labels.plan(runners, 1, [A, B])
        self.assertEqual(changes, [labels.Change(2, remove=(warm(A),)),
                                   labels.Change(4, remove=(warm(B),)),
                                   labels.Change(1, add=(warm(A), warm(B)), remove=(warm(C),))])
        self.assertIn(ROOT_STD, why)

    def test_nothing_changes_for_a_labeled_runner_or_one_without_a_root_label(self):
        runners = [runner(1, MINI, ROOT_STD, warm(A))]
        self.assertEqual(labels.plan(runners, 1, [A])[0], [])
        self.assertEqual(labels.plan([runner(1, MINI)], 1, [A])[0], [])
        self.assertEqual(labels.plan(runners, 9, [A])[0], [])
        # No keys: the runner drops the ones it had.
        self.assertEqual(labels.plan(runners, 1, [])[0], [labels.Change(1, remove=(warm(A),))])

    def test_the_admission_job_is_found_under_its_caller(self):
        jobs = [{"name": "macOS / app-host unit tests (1)", "runner_id": 5},
                {"name": "macOS / macOS compile admission", "runner_id": 0},
                {"name": "macOS / macOS compile admission", "runner_id": 7, "runner_name": "cmux7"}]
        self.assertEqual(labels.admission_job(jobs)["runner_id"], 7)
        self.assertIsNone(labels.admission_job(jobs[:2]))


class Run(unittest.TestCase):
    def run_script(self, document, *, jobs=None, runners=None, path=".github/workflows/ci.yml",
                   org_runners=(), groups=None):
        jobs = jobs if jobs is not None else [
            {"name": "macOS / macOS compile admission", "runner_id": 1, "runner_name": "cmux1"}]
        runners = runners if runners is not None else [
            runner(1, MINI, ROOT_STD, warm("dddddddddddd")), runner(2, MINI, ROOT_STD, warm(A))]
        http = FakeHTTP(jobs, runners, org_runners, groups)
        with tempfile.TemporaryDirectory() as tmp, \
                unittest.mock.patch.object(labels.urllib.request, "urlopen", side_effect=http), \
                unittest.mock.patch("sys.stdout", io.StringIO()) as stdout:
            keys_file = Path(tmp, "warm-keys.json")
            keys_file.write_text(document if isinstance(document, str) else json.dumps(document))
            env = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GH_TOKEN": "actions-token", "ROUTE_TOKEN": "app-token",
                   "RUN_ID": "42", "RUN_ATTEMPT": "2", "RUN_PATH": path, "KEYS_FILE": str(keys_file)}
            self.assertEqual(labels.main(env), 0)
        return http, stdout.getvalue()

    def test_labels_the_runner_that_ran_admission(self):
        http, output = self.run_script({"runner": "cmux1", "pool": ROOT_STD, "keys": [A, B]})
        self.assertIn(("GET", "/actions/runs/42/attempts/2/jobs?per_page=100&page=1", None), http.calls)
        self.assertEqual(http.writes(), [
            ("DELETE", f"/actions/runners/2/labels/{warm(A)}", None),
            # Already gone (404) is fine.
            ("DELETE", "/actions/runners/1/labels/glaeda-warm-dddddddddddd", None),
            ("POST", "/actions/runners/1/labels", {"labels": [warm(A), warm(B)]}),
        ])
        self.assertIn("2 runner(s) changed", output)

    def test_the_jobs_listing_uses_the_actions_token_and_the_labels_the_apps(self):
        seen = []
        http = FakeHTTP([{"name": "macOS / macOS compile admission", "runner_id": 1, "runner_name": "cmux1"}],
                        [runner(1, MINI, ROOT_STD)])

        def urlopen(request, timeout=None):
            seen.append((request.get_method(), request.full_url.split("?")[0].rsplit("/", 1)[-1],
                         request.get_header("Authorization")))
            return http(request, timeout)

        with tempfile.TemporaryDirectory() as tmp, \
                unittest.mock.patch.object(labels.urllib.request, "urlopen", side_effect=urlopen), \
                unittest.mock.patch("sys.stdout", io.StringIO()):
            keys_file = Path(tmp, "warm-keys.json")
            keys_file.write_text(json.dumps({"runner": "cmux1", "keys": [A]}))
            labels.main({"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GH_TOKEN": "actions-token",
                         "ROUTE_TOKEN": "app-token", "RUN_ID": "42", "RUN_PATH": ".github/workflows/ci.yml",
                         "KEYS_FILE": str(keys_file)})
        self.assertEqual(seen, [("GET", "jobs", "Bearer actions-token"), ("GET", "runner-groups", "Bearer app-token"),
                                ("GET", "runners", "Bearer app-token"), ("GET", "runners", "Bearer app-token"),
                                ("POST", "labels", "Bearer app-token")])

    def test_org_runners_in_glaeda_minis_are_labeled_through_the_org(self):
        # glaeda#1222 made the minis org runners, which the repository runners
        # endpoint neither lists nor labels.
        org = [runner(1, MINI, ROOT_STD, warm("dddddddddddd")), runner(2, MINI, ROOT_STD, warm(A))]
        http, output = self.run_script({"runner": "cmux1", "pool": ROOT_STD, "keys": [A, B]},
                                       runners=[runner(7, "glaeda-trusted")], org_runners=org)
        self.assertIn(("GET", "/orgs/manaflow-ai/actions/runner-groups?per_page=100&visible_to_repository=cmux",
                       None), http.calls)
        self.assertEqual(http.writes(), [
            ("DELETE", f"/orgs/manaflow-ai/actions/runners/2/labels/{warm(A)}", None),
            ("DELETE", "/orgs/manaflow-ai/actions/runners/1/labels/glaeda-warm-dddddddddddd", None),
            ("POST", "/orgs/manaflow-ai/actions/runners/1/labels", {"labels": [warm(A), warm(B)]}),
        ])
        self.assertIn("2 runner(s) changed", output)

    def test_an_unreadable_org_group_warns_and_labels_repository_runners(self):
        for groups, why in ((403, "unreadable (HTTP 403)"), ([{"id": 4, "name": "Blacksmith"}], "no runner group"),
                            ([{"name": "glaeda-minis"}], "no runner group")):
            http, output = self.run_script({"runner": "cmux1", "pool": ROOT_STD, "keys": [A]}, groups=groups)
            self.assertIn(why, output)
            self.assertNotIn("runner-groups/None", "".join(path for _, path, _ in http.calls))
            self.assertIn(("POST", "/actions/runners/1/labels", {"labels": [warm(A)]}), http.writes())
        self.assertIn("Self-hosted runners: read and write", self.run_script(
            {"runner": "cmux1", "pool": ROOT_STD, "keys": [A]}, groups=403)[1])

    def test_an_artifact_naming_another_runner_or_pool_changes_nothing(self):
        for document in ({"runner": "cmux2", "pool": ROOT_STD, "keys": [A]},
                         {"runner": "cmux1", "pool": ROOT_LIGHT, "keys": [A]},
                         ["not", "an", "object"],
                         "{not json"):
            http, _ = self.run_script(document)
            self.assertEqual(http.writes(), [], document)

    def test_other_runs_change_nothing(self):
        http, output = self.run_script({"runner": "cmux1", "keys": [A]}, path=".github/workflows/other.yml")
        self.assertEqual(http.calls, [])
        http, output = self.run_script({"runner": "cmux1", "keys": [A]}, jobs=[])
        self.assertEqual(http.writes(), [])
        self.assertIn("no compile admission job", output)

    def test_an_api_failure_warns_and_never_fails_the_job(self):
        def broken(request, timeout=None):
            raise urllib.error.HTTPError(request.full_url, 403, "forbidden", {}, None)

        with tempfile.TemporaryDirectory() as tmp, \
                unittest.mock.patch.object(labels.urllib.request, "urlopen", side_effect=broken), \
                unittest.mock.patch("sys.stdout", io.StringIO()) as stdout:
            keys_file = Path(tmp, "warm-keys.json")
            keys_file.write_text(json.dumps({"runner": "cmux1", "keys": [A]}))
            self.assertEqual(labels.main({"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GH_TOKEN": "t",
                                          "ROUTE_TOKEN": "a", "RUN_ID": "42",
                                          "RUN_PATH": ".github/workflows/ci.yml", "KEYS_FILE": str(keys_file)}), 0)
        self.assertIn("::warning title=owned warm labels::", stdout.getvalue())
        # Missing tokens: nothing is requested.
        with unittest.mock.patch("sys.stdout", io.StringIO()):
            self.assertEqual(labels.main({"GITHUB_REPOSITORY": "manaflow-ai/cmux", "RUN_ID": "42"}), 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
