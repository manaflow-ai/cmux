#!/usr/bin/env python3
"""scripts/ci/cmux_tui_team_sign.py and .github/workflows/cmux-tui-team-signed.yml (cmuxterm-hq#11364).

The Team-signed darwin tree takes exactly the bytes hot-apply would take for a key, signs them only
where the NEXT nightly's identity lives (release-next, ref nightly-next), and publishes them beside
the ad-hoc tree without touching it. Nothing that gates a merge waits on it.
"""
from __future__ import annotations

import hashlib
import http.server
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cmux_tui_team_sign.py"
WORKFLOW = ROOT / ".github/workflows/cmux-tui-team-signed.yml"
ARTIFACTS = ROOT / ".github/workflows/cmux-tui-artifacts.yml"
KEY = "3b08e5154853a7da9004830e1ad74292a2cd2384"
OWNER = "f5547041076e51debf53959c9dd75625f3c6277b"
TARGET = "aarch64-apple-darwin"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


class Served:
    """A files.cmux.com stand-in: ROOT/cmux-tui/... over HTTP (404 for anything absent)."""

    def __init__(self):
        self.dir = Path(tempfile.mkdtemp(prefix="team-sign-test-"))
        handler = lambda *a, **k: http.server.SimpleHTTPRequestHandler(*a, directory=str(self.dir), **k)  # noqa: E731
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.server.RequestHandlerClass.log_message = lambda *a: None
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_port}/cmux-tui"

    def put(self, path: str, body: bytes | str | dict) -> None:
        target = self.dir / "cmux-tui" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(body, dict):
            body = json.dumps(body)
        target.write_bytes(body.encode() if isinstance(body, str) else body)

    def close(self):
        self.server.shutdown()


def publish_tree(served: Served, *, cmux=b"cmux-adhoc", cloud=b"cloud-adhoc", holder=None) -> dict[str, bytes]:
    name = f"cmux-tui-{TARGET}"
    served.put(f"tree/{KEY}/{name}", cmux)
    served.put(f"tree/{KEY}/{name}.sha256", f"{sha(cmux)}  {name}\n")
    served.put(f"tree/{KEY}/completion.json", {"key": KEY, "binaries": {name: sha(cmux)}})
    served.put(f"tree/{KEY}/source.json", {"key": KEY, "commit": OWNER})
    binaries = {f"cmux-tui-cloud-server-{TARGET}": sha(cloud)}
    served.put(f"{OWNER}/cmux-tui-cloud-server-{TARGET}", cloud)
    if holder is not None:
        binaries[f"cmux-tui-holder-{TARGET}"] = sha(holder)
        served.put(f"{OWNER}/cmux-tui-holder-{TARGET}", holder)
    served.put(f"{OWNER}/manifest.json", {"binaries": binaries})
    return {"cmux": cmux, "cmux-cloud": cloud}


class TeamSignScript(unittest.TestCase):
    def setUp(self):
        self.served = Served()
        os.environ["CMUX_TEAM_SIGN_TUI_BASE"] = f"{self.served.base}/tree"
        os.environ.pop("CMUX_TEAM_SIGN_COMMIT_BASE", None)
        self.mod = load("cmux_tui_team_sign_under_test", SCRIPT)
        self.out = Path(tempfile.mkdtemp(prefix="team-sign-out-"))

    def tearDown(self):
        self.served.close()
        os.environ.pop("CMUX_TEAM_SIGN_TUI_BASE", None)

    def run_main(self, *argv) -> tuple[int, str]:
        import contextlib
        import io
        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer), contextlib.redirect_stderr(io.StringIO()):
            code = self.mod.main(list(argv))
        return code, buffer.getvalue()

    def test_its_companions_are_hot_applys(self):
        hot = load("hot_apply_for_team_sign_test", ROOT / "scripts/cmux-next/hot-apply.py")
        self.assertEqual(self.mod.COMPANIONS, hot.COMPANIONS)

    def test_plan_signs_a_published_tree_once(self):
        code, out = self.run_main("plan", KEY)
        self.assertEqual(code, 0)
        self.assertIn("tree_published=false", out)
        self.assertIn("needed=false", out)
        publish_tree(self.served)
        self.assertIn("needed=true", self.run_main("plan", KEY)[1])
        self.served.put(f"tree/{KEY}/team-signed/completion.json", {"schema": 1})
        self.assertIn("needed=false", self.run_main("plan", KEY)[1])

    def test_fetch_takes_the_trees_cmux_and_the_owner_manifests_companions(self):
        bodies = publish_tree(self.served, holder=b"holder-adhoc")
        self.assertEqual(self.run_main("fetch", KEY, str(self.out))[0], 0)
        self.assertEqual((self.out / "cmux").read_bytes(), bodies["cmux"])
        self.assertEqual((self.out / "cmux-cloud").read_bytes(), bodies["cmux-cloud"])
        self.assertEqual((self.out / "cmux-holder").read_bytes(), b"holder-adhoc")
        record = json.loads((self.out / "unsigned.json").read_text())
        self.assertEqual(record["commit"], OWNER)
        self.assertIsNone(record["files"]["cmux-app-host"])  # the build has none: the app's goes away
        self.assertFalse((self.out / "cmux-app-host").exists())

    def test_fetch_refuses_bytes_that_differ_from_their_published_sha256(self):
        publish_tree(self.served)
        self.served.put(f"{OWNER}/cmux-tui-cloud-server-{TARGET}", b"something else")
        self.assertEqual(self.run_main("fetch", KEY, str(self.out))[0], 1)
        self.served.put(f"{OWNER}/cmux-tui-cloud-server-{TARGET}", b"cloud-adhoc")
        self.served.put(f"tree/{KEY}/cmux-tui-{TARGET}.sha256", f"{'0' * 64}  x\n")
        self.assertEqual(self.run_main("fetch", KEY, str(self.out))[0], 1)

    def sign(self):
        """What codesign does to each file: other bytes."""
        for file in self.out.iterdir():
            if file.suffix != ".json":
                file.write_bytes(file.read_bytes() + b"+signed")

    def test_manifest_names_each_signed_file_and_refuses_an_unsigned_one(self):
        publish_tree(self.served)
        self.run_main("fetch", KEY, str(self.out))
        args = ("manifest", KEY, str(self.out), "--team", "7WLXT3NR37", "--commit", OWNER, "--run-url", "u")
        self.assertEqual(self.run_main(*args)[0], 1)  # still the ad-hoc bytes
        self.sign()
        self.assertEqual(self.run_main(*args)[0], 0)
        completion = json.loads((self.out / "completion.json").read_text())
        self.assertEqual(completion["team"], "7WLXT3NR37")
        self.assertEqual(completion["files"]["cmux"]["sha256"], sha(b"cmux-adhoc+signed"))
        self.assertEqual(completion["files"]["cmux"]["unsigned_sha256"], sha(b"cmux-adhoc"))
        self.assertIsNone(completion["files"]["cmux-tui-host"])
        self.assertEqual(self.run_main("verify", str(self.out))[0], 0)
        self.assertEqual(self.run_main("manifest", KEY, str(self.out), "--team", "adhoc", "--commit", OWNER)[0], 1)

    def test_verify_and_objects_upload_files_by_digest_then_completion_last(self):
        publish_tree(self.served)
        self.run_main("fetch", KEY, str(self.out))
        self.sign()
        self.run_main("manifest", KEY, str(self.out), "--team", "7WLXT3NR37", "--commit", OWNER)
        lines = self.run_main("objects", str(self.out))[1].splitlines()
        self.assertEqual(lines[-1], f"cmux-tui/tree/{KEY}/team-signed/completion.json {self.out / 'completion.json'}")
        self.assertIn(f"cmux-tui/tree/{KEY}/team-signed/{sha(b'cmux-adhoc+signed')}/cmux {self.out / 'cmux'}", lines)
        self.assertEqual(len(lines), 3)
        for line in lines:  # never the ad-hoc tree's own objects
            self.assertIn("/team-signed/", line.split()[0])
        (self.out / "cmux").write_bytes(b"tampered")
        self.assertEqual(self.run_main("verify", str(self.out))[0], 1)


class TeamSignedWorkflow(unittest.TestCase):
    def setUp(self):
        self.doc = yaml.safe_load(WORKFLOW.read_text())
        self.jobs = self.doc["jobs"]

    def test_it_signs_only_on_nightly_next_with_the_nightlys_environment(self):
        self.assertIn("refs/heads/nightly-next", self.jobs["plan"]["if"])
        self.assertEqual(self.jobs["sign"]["environment"], "release-next")
        self.assertEqual(self.jobs["sign"]["needs"], "plan")

    def test_only_the_sign_jobs_hold_the_signing_secrets_and_they_delete_their_keychain(self):
        signers = {"sign", "sign-helper"}
        for name, job in self.jobs.items():
            text = yaml.safe_dump(job)
            holds = "APPLE_CERTIFICATE" in text or "APPLE_SIGNING_IDENTITY" in text
            self.assertEqual(holds, name in signers, name)
        for name in signers:
            steps = self.jobs[name]["steps"]
            runs = [step.get("run", "") for step in steps]
            create = next(i for i, run in enumerate(runs) if "signing-keychain.sh create" in run)
            delete = next(i for i, run in enumerate(runs) if "signing-keychain.sh delete" in run)
            self.assertLess(next(i for i, run in enumerate(runs) if "signing-runner-claim.sh" in run), create)
            self.assertLess(create, delete)
            self.assertEqual(steps[delete].get("if"), "always()")
            self.assertNotIn("env", self.jobs[name])
            self.assertEqual(self.jobs[name]["environment"], "release-next")

    def test_the_helper_is_built_without_secrets_and_signed_as_data(self):
        build = self.jobs["build-helper"]
        self.assertNotIn("environment", build)
        self.assertNotIn("secrets.", yaml.safe_dump(build))
        self.assertEqual(build["needs"], "plan")
        self.assertIn("needs.plan.outputs.helper_needed == 'true'", build["if"])
        sign = self.jobs["sign-helper"]
        self.assertEqual(sign["needs"], ["plan", "build-helper"])
        # Its checkout is this workflow's tools, never the commit: no commit code runs where the key is.
        refs = [step["with"]["ref"] for step in sign["steps"] if "actions/checkout@" in step.get("uses", "")]
        self.assertEqual(refs, ["${{ github.sha }}"])
        runs = [step.get("run", "") for step in sign["steps"]]
        self.assertIn("screen_sharing_helper_release.py check", "\n".join(runs))
        self.assertNotIn("cargo", "\n".join(runs))
        delete = next(i for i, run in enumerate(runs) if "signing-keychain.sh delete" in run)
        record = next(i for i, run in enumerate(runs) if "screen_sharing_helper_release.py record" in run)
        self.assertLess(delete, record)
        publish = "\n".join(step.get("run", "") for step in self.jobs["publish-helper"]["steps"])
        self.assertIn("--write-once", publish)
        self.assertIn("screen_sharing_helper_release.py objects", publish)
        self.assertEqual(self.jobs["publish-helper"]["needs"], ["plan", "sign-helper"])

    def test_it_never_writes_the_ad_hoc_tree(self):
        run = "\n".join(step.get("run", "") for step in self.jobs["publish"]["steps"])
        self.assertIn("--write-once", run)
        self.assertIn("cmux_tui_team_sign.py objects", run)

    def test_the_artifacts_workflow_requests_it_and_nothing_waits_on_that(self):
        jobs = yaml.safe_load(ARTIFACTS.read_text())["jobs"]
        request = jobs["request-team-signed-tree"]
        self.assertTrue(request["continue-on-error"])
        self.assertIn("refs/heads/feat-cmux-next", request["if"])
        # The windowed tree build is a feat-cmux-next dispatch; its tree's pushes deferred before it
        # published, so a push-only request never signed it (run 44978301534, 2026-11-22).
        self.assertIn("(github.event_name == 'push' || github.event_name == 'workflow_dispatch')", request["if"])
        # A push whose tree another run published (the same-key owner wait) asks too: run 43725236906,
        # #43724's own merge, skipped the request when it read publish-tree's result.
        self.assertEqual(request["needs"], ["tree-preflight", "publish-tree-tested"])
        self.assertIn("needs.publish-tree-tested.result != 'failure'", request["if"])
        self.assertNotIn("needs.publish-tree.result", request["if"])
        (step,) = [s for s in request["steps"] if s.get("name") == "Dispatch cmux-tui-team-signed.yml on nightly-next"]
        run = step["run"]
        self.assertIn("--ref nightly-next", run)
        # A push whose key is signed already dispatches nothing; one that does names the key's group.
        # The dispatch goes through gh_budget_wait.sh, which moves a rate-limited call to the bot token.
        self.assertLess(run.index("team-signed/completion.json"), run.index("gh_budget_wait.sh workflow run"))
        self.assertIn('-f key="$KEY"', run)
        self.assertIn("inputs.key", self.doc["concurrency"]["group"])
        for name, job in jobs.items():
            if name == "drop-build-artifacts":  # the run's cleanup waits for every job; it gates nothing
                continue
            needs = job.get("needs") or []
            self.assertNotIn("request-team-signed-tree", [needs] if isinstance(needs, str) else needs, name)


if __name__ == "__main__":
    unittest.main()
