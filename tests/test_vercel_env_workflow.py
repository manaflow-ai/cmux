#!/usr/bin/env python3
"""The Vercel env workflow writes only allowlisted names, from secrets, approved.

.github/workflows/vercel-env.yml changes env variables on the cmux.com
production project with a token that can change any of them. What keeps that
narrow is checked here:

- the workflow's name choices and its secret map are exactly the names in
  .github/vercel-env-allowlist.json, and the project there is the one
  web/scripts/cloud-vm/projects.mjs calls production;
- it runs only on workflow_dispatch (never pull_request_target), and every
  input is a fixed choice, so no value can ever arrive as a logged input;
- the job runs in the allowlist's environment, on Linux, with pinned actions,
  no secrets or inputs spliced into shell text, and no xtrace;
- the script refuses unlisted names, never shares an entry across targets, and
  keeps the value out of everything it prints.
"""

from __future__ import annotations

import io
import json
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "vercel-env.yml"
ALLOWLIST = ROOT / ".github" / "vercel-env-allowlist.json"
PROJECTS = ROOT / "web" / "scripts" / "cloud-vm" / "projects.mjs"
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import vercel_env  # noqa: E402

PINNED = re.compile(r"^[^@\s]+@[0-9a-f]{40}$")
SECRET_REF = re.compile(r"secrets\.([A-Z0-9_]+)")
PAIR = re.compile(r"inputs\.name == '([A-Z0-9_]+)' && secrets\.([A-Z0-9_]+)")


def load() -> tuple[dict, dict]:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8")), json.loads(ALLOWLIST.read_text(encoding="utf-8"))


class WorkflowMatchesAllowlist(unittest.TestCase):
    def setUp(self) -> None:
        self.doc, self.allow = load()
        # PyYAML's YAML 1.1 loader reads the Actions `on` key as True.
        self.events = self.doc.get("on", self.doc.get(True))
        self.job = self.doc["jobs"]["apply"]
        self.apply_step = next(s for s in self.job["steps"] if s.get("name") == "Apply and verify")

    def test_only_workflow_dispatch(self) -> None:
        self.assertEqual(list(self.events), ["workflow_dispatch"])
        self.assertNotIn("pull_request_target", WORKFLOW.read_text(encoding="utf-8"))

    def test_every_input_is_a_fixed_choice(self) -> None:
        inputs = self.events["workflow_dispatch"]["inputs"]
        self.assertEqual(set(inputs), {"name", "target", "action"})
        for key, spec in inputs.items():
            with self.subTest(input=key):
                self.assertEqual(spec["type"], "choice", "a free-text input could carry a value into the logs")
        self.assertEqual(inputs["name"]["options"], sorted(self.allow["variables"]))
        self.assertEqual(inputs["target"]["options"], self.allow["targets"])
        self.assertEqual(inputs["target"]["default"], "production")
        self.assertEqual(inputs["action"]["options"], ["set", "remove"])

    def test_secret_map_is_the_allowlist(self) -> None:
        expr = self.apply_step["env"]["VERCEL_ENV_VALUE"]
        pairs = PAIR.findall(expr)
        self.assertTrue(all(a == b for a, b in pairs), f"each name must map to its own secret: {pairs}")
        self.assertEqual(sorted(a for a, _ in pairs), sorted(self.allow["variables"]))
        self.assertEqual(sorted(SECRET_REF.findall(expr)), sorted(self.allow["variables"]))
        self.assertTrue(expr.strip().startswith("${{ inputs.action == 'set' && ("))
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("secrets[", text, "dynamic secret lookup could read any secret")
        referenced = set(SECRET_REF.findall(text))
        self.assertEqual(referenced, set(self.allow["variables"]) | {"VERCEL_TOKEN"})

    def test_job_is_protected_and_narrow(self) -> None:
        self.assertEqual(self.doc["permissions"], {})
        self.assertEqual(self.job["environment"], self.allow["environment"])
        self.assertEqual(self.job["permissions"], {"contents": "read", "actions": "read"})
        self.assertEqual(self.job["if"], "${{ github.ref == 'refs/heads/main' }}")
        self.assertEqual(
            self.job["runs-on"],
            "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }}",
            "no repository variable may move this job",
        )
        self.assertIs(self.doc["concurrency"]["cancel-in-progress"], False)
        names = [s.get("name") for s in self.job["steps"]]
        self.assertLess(names.index("Refuse an unprotected environment"), names.index("Apply and verify"))

    def test_steps_keep_secrets_and_inputs_out_of_shell_text(self) -> None:
        for step in self.job["steps"]:
            if "uses" in step:
                self.assertRegex(step["uses"], PINNED)
                self.assertFalse(step.get("with", {}).get("persist-credentials", False))
            run = step.get("run", "")
            with self.subTest(step=step.get("name")):
                self.assertNotIn("${{", run, "secrets and inputs reach the shell through env only")
                self.assertNotRegex(run, r"set\s+-[a-wyz]*x|xtrace|\becho\b|printenv|\benv\b")
            if "secrets." in json.dumps(step.get("env", {})):
                self.assertEqual(step["name"], "Apply and verify")

    def test_project_is_production_from_projects_mjs(self) -> None:
        text = PROJECTS.read_text(encoding="utf-8")
        block = re.search(r"production:\s*\{(.*?)\}", text, re.DOTALL).group(1)
        project = self.allow["project"]
        self.assertIn(f'projectId: "{project["id"]}"', block)
        self.assertIn(f'orgId: "{project["teamId"]}"', block)
        self.assertIn(f'projectName: "{project["name"]}"', block)
        self.assertEqual(project["teamSlug"], "manaflow")

    def test_allowlist_entries_are_typed(self) -> None:
        allow = vercel_env.load_allowlist(ALLOWLIST)
        for name, entry in allow["variables"].items():
            with self.subTest(name=name):
                self.assertRegex(name, r"^[A-Z][A-Z0-9_]*$")
                self.assertIsInstance(entry["secret"], bool)
        self.assertTrue(allow["variables"]["CMUX_RUN_WORKER_SECRET"]["secret"])
        self.assertTrue(allow["variables"]["CMUX_RUN_WORKER_TOKEN"]["secret"])


def env(key: str, target, id_: str = "env_1", type_: str = "encrypted", updated: int = 100, branch=None) -> dict:
    return {"id": id_, "key": key, "target": target, "type": type_, "updatedAt": updated, "gitBranch": branch}


class Planner(unittest.TestCase):
    N = "CMUX_RUN_WORKER_TOKEN"

    def test_create_when_absent_uses_sensitive_for_secrets(self) -> None:
        self.assertEqual(vercel_env.plan([], self.N, "production", "set", True)["type"], "sensitive")
        self.assertEqual(vercel_env.plan([], self.N, "production", "set", False)["type"], "encrypted")

    def test_branch_entries_are_ignored(self) -> None:
        step = vercel_env.plan([env(self.N, ["preview"], branch="feat")], self.N, "preview", "set", True)
        self.assertEqual(step["op"], "create")

    def test_update_own_entry(self) -> None:
        step = vercel_env.plan([env(self.N, ["production"], type_="sensitive")], self.N, "production", "set", True)
        self.assertEqual((step["op"], step["id"]), ("update", "env_1"))

    def test_shared_entry_is_never_rewritten(self) -> None:
        with self.assertRaisesRegex(vercel_env.Refused, "remove for production first"):
            vercel_env.plan([env(self.N, ["production", "preview"])], self.N, "production", "set", False)

    def test_entry_of_the_wrong_type_is_refused(self) -> None:
        with self.assertRaisesRegex(vercel_env.Refused, "must be sensitive"):
            vercel_env.plan([env(self.N, "production", type_="encrypted")], self.N, "production", "set", True)
        with self.assertRaisesRegex(vercel_env.Refused, "must be encrypted"):
            vercel_env.plan([env(self.N, "production", type_="sensitive")], self.N, "production", "set", False)
        with self.assertRaisesRegex(vercel_env.Refused, "expected encrypted"):
            vercel_env.verify([env(self.N, ["production"], type_="plain")], self.N, "production", "set", False, {"op": "create"})

    def test_remove(self) -> None:
        self.assertEqual(vercel_env.plan([], self.N, "production", "remove", True)["op"], "none")
        self.assertEqual(vercel_env.plan([env(self.N, ["production"])], self.N, "production", "remove", True)["op"], "delete")
        step = vercel_env.plan([env(self.N, ["production", "preview"])], self.N, "production", "remove", True)
        self.assertEqual((step["op"], step["target"]), ("narrow", ["preview"]))

    def test_verify_requires_a_fresh_update(self) -> None:
        step = {"op": "update", "previousUpdatedAt": 100}
        with self.assertRaisesRegex(vercel_env.Refused, "no update"):
            vercel_env.verify([env(self.N, ["production"], type_="sensitive")], self.N, "production", "set", True, step)
        kind = vercel_env.verify([env(self.N, ["production"], type_="sensitive", updated=200)], self.N, "production", "set", True, step)
        self.assertEqual(kind, "sensitive")

    def test_environment_must_require_review_and_admit_only_main(self) -> None:
        good = {
            "protection_rules": [{"type": "required_reviewers", "reviewers": [{"type": "User"}]}],
            "deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True},
        }
        main_only = {"total_count": 1, "branch_policies": [{"name": "main", "type": "branch"}]}
        vercel_env.check_environment(good, main_only, "e")
        refused = {
            "required reviewers": ({**good, "protection_rules": []}, main_only),
            "selected branches": ({**good, "deployment_branch_policy": None}, None),
            "selected branches ": ({**good, "deployment_branch_policy": {"protected_branches": True, "custom_branch_policies": False}}, None),
            "exactly the branch main": (good, {"branch_policies": [{"name": "*", "type": "branch"}]}),
            "exactly the branch main ": (good, {"branch_policies": [{"name": "main", "type": "branch"}, {"name": "dev", "type": "branch"}]}),
            "exactly the branch main  ": (good, {"branch_policies": [{"name": "main", "type": "tag"}]}),
            "exactly the branch main   ": (good, {"branch_policies": []}),
        }
        for reason, (doc, policies) in refused.items():
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(vercel_env.Refused, reason.strip()):
                    vercel_env.check_environment(doc, policies, "e")


class ScriptNeverPrintsTheValue(unittest.TestCase):
    VALUE = "s3cr3t-value-line-one\nline-two-of-it"
    TOKEN = "vercel-token-abcdef"

    def run_script(self, argv: list[str], fake) -> tuple[int, str]:
        out, err = io.StringIO(), io.StringIO()
        summary = tempfile.NamedTemporaryFile("r", suffix=".md")
        environ = {"VERCEL_TOKEN": self.TOKEN, "VERCEL_ENV_VALUE": self.VALUE, "GITHUB_STEP_SUMMARY": summary.name}
        with mock.patch.dict("os.environ", environ), mock.patch.object(vercel_env, "http_request", lambda *_: fake):
            with redirect_stdout(out), redirect_stderr(err):
                code = vercel_env.main(argv)
        text = out.getvalue() + err.getvalue() + Path(summary.name).read_text()
        summary.close()
        return code, text

    def assert_clean(self, text: str) -> None:
        for fragment in (self.VALUE, "s3cr3t-value-line-one", "line-two-of-it", self.TOKEN):
            self.assertNotIn(fragment, text)

    def test_unlisted_name_is_refused_before_any_request(self) -> None:
        def fake(*_):
            raise AssertionError("no request for an unlisted name")

        code, text = self.run_script(["--name", "DATABASE_URL", "--target", "production", "--action", "set"], fake)
        self.assertEqual(code, 1)
        self.assertIn("not in .github/vercel-env-allowlist.json", text)

    def test_create_and_errors_stay_redacted(self) -> None:
        state: list[dict] = []
        sent: list[tuple] = []

        def fake(method, path, body):
            sent.append((method, path))
            if method == "GET":
                return {"envs": list(state)}
            if method == "POST":
                self.assertNotIn(self.VALUE, path)
                state.append(env(body["key"], body["target"], type_=body["type"]))
                return {"created": {}}
            raise AssertionError(method)

        argv = ["--name", "CMUX_RUN_WORKER_TOKEN", "--target", "production", "--action", "set"]
        code, text = self.run_script(argv, fake)
        self.assertEqual(code, 0, text)
        self.assertIn("created (type sensitive)", text)
        self.assertEqual([m for m, _ in sent], ["GET", "POST", "GET"])
        self.assert_clean(text)

        def failing(method, path, body):
            if method == "GET":
                return {"envs": []}
            raise vercel_env.Refused(f"Vercel said bad value {self.VALUE} with {self.TOKEN}")

        code, text = self.run_script(argv, failing)
        self.assertEqual(code, 1)
        self.assertIn("***", text)
        self.assert_clean(text)

    def test_missing_secret_points_at_remove(self) -> None:
        with mock.patch.object(self, "VALUE", ""):
            code, text = self.run_script(["--name", "CMUX_RUN_SANDBOX_USER_IDS", "--target", "production", "--action", "set"], lambda *_: {"envs": []})
        self.assertEqual(code, 1)
        self.assertIn("to clear a variable, run remove", text)


class HttpErrorsPrintNoProviderText(unittest.TestCase):
    """The real request function, fed a Vercel error that echoes the value."""

    def test_http_error_body_is_reduced_to_status_and_code(self) -> None:
        import urllib.error

        value = "v" * 290 + "-the-secret-tail"
        bodies = [
            {"error": {"code": "bad_request", "message": f"invalid value {value}"}},
            {"error": {"code": f"x {value}", "message": "m"}},
            {"error": {"code": value[:40] + "\u0000", "message": json.dumps(value)}},
            {"error": "plain string " + value},
        ]
        vercel_env.register_secret(value)
        for body in bodies:
            raw = json.dumps(body).encode()
            error = urllib.error.HTTPError("https://api.vercel.com/x", 400, "Bad", {}, io.BytesIO(raw))
            request = vercel_env.http_request("tok", "team")
            with self.subTest(body=str(body)[:60]), mock.patch("urllib.request.urlopen", side_effect=error):
                with self.assertRaises(vercel_env.Refused) as caught:
                    request("POST", "/v10/projects/p/env", {"value": value})
                self.assertEqual(str(caught.exception), "Vercel POST /v10/projects/p/env returned HTTP 400")

    def test_unexpected_exceptions_print_only_their_class(self) -> None:
        err = io.StringIO()
        with mock.patch.object(vercel_env, "run", side_effect=RuntimeError("leaky secret text")), redirect_stderr(err):
            self.assertEqual(vercel_env.main(["--name", "X", "--target", "production", "--action", "set"]), 1)
        self.assertEqual(err.getvalue().strip(), "::error::failed with RuntimeError")


if __name__ == "__main__":
    unittest.main()
