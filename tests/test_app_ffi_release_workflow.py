#!/usr/bin/env python3
"""app-ffi-release.yml's publish job never reports success without a release.

Run 37556534995 (C3, 45845b2d13d7) built the FFI, skipped the create step
because workflow files had changed since the last FFI tag, printed a notice and
went green with no release. The pin check then failed on every Swift run until
a person noticed. Whenever the job cannot create the release (workflow files
changed, an HTTP 403, or a create that silently publishes nothing), it now
fails and names the hand-publish command.

GITHUB_TOKEN may not create a cmux-app-ffi-* tag: ruleset 24624526 admits
only admins and the FFI release App (manaflow-cmux-ffi-release). The create
step therefore uses a token of that App, minted in the `ffi-release` environment
(deployment policy: feat-cmux-next only) for this repository alone, with
contents:write, plus workflows:write only when the tagged tree's
.github/workflows differs from the default branch tip, the merge-base with it,
or the last FFI tag. No other step sees the App token.

The test runs the publish job's own shell steps in order, as the runner would,
against a fake `gh` and `curl` that play each outcome.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
import unittest.mock
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/app-ffi-release.yml"
REPIN_WORKFLOW = ROOT / ".github/workflows/app-ffi-repin.yml"
sys.path.insert(0, str(ROOT / "tests"))
from test_seed_derived_data import evaluate  # noqa: E402
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

SHA = "45845b2d13d794c435d31f72ea74dc0f4a5739d0"
TAG = f"cmux-app-ffi-{SHA}"
REPO = "manaflow-ai/cmux"
RUN_ID = "37556534995"

FAKE_GH = r"""#!/usr/bin/env bash
# Fake gh: FAKE_CREATE is ok, 403 or noop. A created release is the directory $STATE/release.
set -u
rel="$STATE/release"
# FAKE_READ_FAILS: the release reads (view and download, counted from 1) that
# fail with a 502, as GitHub's did in run 42919934207, whether or not the
# release exists; "all" fails every read.
if [[ "$1 $2" == "release view" || "$1 $2" == "release download" ]]; then
  reads=$(( $(cat "$STATE/reads" 2>/dev/null || echo 0) + 1 ))
  echo "$reads" > "$STATE/reads"
  if [[ "${FAKE_READ_FAILS:-}" == all || " ${FAKE_READ_FAILS:-} " == *" $reads "* ]]; then
    echo "HTTP 502: Bad Gateway" >&2; exit 1
  fi
fi
case "$1 $2" in
  "release view") [[ -d "$rel" ]] && exit 0; echo "release not found" >&2; exit 1 ;;
  "release create")
    case "$FAKE_CREATE" in
      403) echo "HTTP 403: Resource not accessible by integration" >&2; exit 1 ;;
      noop) exit 0 ;;
    esac
    mkdir -p "$rel"
    shift 3
    for arg in "$@"; do [[ -f "$arg" ]] && cp "$arg" "$rel/"; done
    exit 0 ;;
  "release download")
    [[ -d "$rel" ]] || { echo "release not found" >&2; exit 1; }
    dir=.
    while [[ $# -gt 0 ]]; do [[ "$1" == --dir ]] && dir="$2"; shift; done
    mkdir -p "$dir"; cp "$rel/CCmuxAppFFI.xcframework.zip" "$dir/"; exit 0 ;;
  "api repos/manaflow-ai/cmux/releases/latest") echo "v0.99.0"; exit 0 ;;
esac
echo "fake gh: unexpected: $*" >&2
exit 2
"""

FAKE_CURL = r"""#!/usr/bin/env bash
set -u
# FAKE_CURL_FAILS: the downloads (counted from 1) that fail with a 502.
calls=$(( $(cat "$STATE/curls" 2>/dev/null || echo 0) + 1 ))
echo "$calls" > "$STATE/curls"
if [[ " ${FAKE_CURL_FAILS:-} " == *" $calls "* ]]; then echo "curl: (22) The requested URL returned error: 502" >&2; exit 22; fi
out=""
while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && out="$2"; shift; done
[[ -f "$STATE/release/CCmuxAppFFI.xcframework.zip" ]] || { echo "curl: (22) 404" >&2; exit 22; }
cp "$STATE/release/CCmuxAppFFI.xcframework.zip" "$out"
"""


def executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def render(text: str, context: dict) -> str:
    return re.sub(r"\$\{\{(.*?)\}\}", lambda match: str(evaluate(match.group(1), context) or ""), str(text))


def condition(expression: str | None, context: dict, failed: bool) -> bool:
    """A step's `if:` with the status functions GitHub adds (success() when none is named)."""
    if expression is None:
        return not failed
    text = str(expression).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    named = re.search(r"\b(always|failure|success|cancelled)\(\)", text)
    text = (text.replace("always()", "true").replace("cancelled()", "false")
            .replace("failure()", "true" if failed else "false")
            .replace("success()", "false" if failed else "true"))
    return bool(evaluate(text, context)) and (bool(named) or not failed)


class PublishJob(unittest.TestCase):
    def run_publish(self, *, workflow_changed: bool, create: str = "ok", existing: bool = False,
                    read_fails: str = "", curl_fails: str = "") -> tuple[bool, str]:
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["publish"]
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            bin_dir, state, work = temp_path / "bin", temp_path / "state", temp_path / "work"
            for path in (bin_dir, state, work / "assets"):
                path.mkdir(parents=True)
            executable(bin_dir / "gh", FAKE_GH)
            executable(bin_dir / "curl", FAKE_CURL)
            executable(bin_dir / "sleep", "#!/bin/sh\nexit 0\n")
            archive = work / "assets/CCmuxAppFFI.xcframework.zip"
            archive.write_bytes(b"xcframework bytes")
            checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
            (work / "assets/CCmuxAppFFI.xcframework.zip.sha256").write_text(checksum + "\n")
            (work / "assets/SHA256SUMS").write_text(f"{checksum}  CCmuxAppFFI.xcframework.zip\n")
            (work / "assets/SOURCE_SHA").write_text(SHA + "\n")
            if existing:
                (state / "release").mkdir()
                (state / "release/CCmuxAppFFI.xcframework.zip").write_bytes(archive.read_bytes())
            context = {
                "steps": {"app-token": {"outputs": {"token": "" if workflow_changed else "fake-app-token"}},
                          "app-token-workflows": {"outputs": {"token": "fake-app-token" if workflow_changed else ""}}},
                "github": {"token": "fake-token", "repository": REPO, "sha": SHA, "run_id": RUN_ID,
                           "ref": "refs/heads/feat-cmux-next", "event_name": "push",
                           "server_url": "https://github.com", "repository_owner": "manaflow-ai"},
                "needs": {"build": {"outputs": {"tag": TAG, "checksum": checksum,
                                                "workflow_changed": "true" if workflow_changed else "false"}}},
                "vars": {}, "runner": {"temp": str(temp_path)},
            }
            base_env = git_fixture_env.fixture_env({"PATH": f"{bin_dir}:{os.environ['PATH']}", "HOME": temp, "STATE": str(state),
                        "FAKE_CREATE": create, "FAKE_READ_FAILS": read_fails, "FAKE_CURL_FAILS": curl_fails, "GITHUB_SHA": SHA, "GITHUB_REPOSITORY": REPO,
                        "GITHUB_RUN_ID": RUN_ID, "GITHUB_SERVER_URL": "https://github.com",
                        "RUNNER_TEMP": temp, "GITHUB_OUTPUT": str(temp_path / "output"),
                        "GITHUB_STEP_SUMMARY": str(temp_path / "summary")})
            base_env.update({key: render(value, context) for key, value in (job.get("env") or {}).items()})
            failed, log = False, []
            for step in job["steps"]:
                if "run" not in step or not condition(step.get("if"), context, failed):
                    continue
                env = dict(base_env)
                env.update({key: render(value, context) for key, value in (step.get("env") or {}).items()})
                script = render(step["run"], context)
                result = subprocess.run(["bash", "-e", "-c", script], cwd=work, env=env,
                                        capture_output=True, text=True, timeout=60)
                log.append(f"--- {step.get('name')} (exit {result.returncode})\n{result.stdout}{result.stderr}")
                if result.returncode != 0 and not step.get("continue-on-error"):
                    failed = True
            return not failed, "\n".join(log)

    def assert_fails_loud(self, passed: bool, log: str) -> None:
        self.assertFalse(passed, "the publish job reported success without a release:\n" + log)
        self.assertIn("publish by hand", log.lower(), log)
        # The exact command a person runs: the release create for this tag and commit.
        self.assertRegex(log, rf"gh release create {TAG}\b.*--target {SHA}", log)
        self.assertIn(f"gh run download {RUN_ID}", log, log)

    def test_workflow_files_changed_still_publishes_with_the_app_token(self):
        # Run 37556534995 skipped the create here; the App token creates the tag.
        passed, log = self.run_publish(workflow_changed=True)
        self.assertTrue(passed, log)
        self.assertNotIn("publish by hand", log.lower(), log)

    def test_a_refused_create_fails_with_the_hand_publish_command(self):
        # Run 37272232472: GITHUB_TOKEN got HTTP 403 creating the tag; a refused
        # App token must fail the same way.
        self.assert_fails_loud(*self.run_publish(workflow_changed=False, create="403"))

    def test_a_create_that_publishes_nothing_fails_with_the_hand_publish_command(self):
        self.assert_fails_loud(*self.run_publish(workflow_changed=False, create="noop"))

    def test_a_created_release_passes(self):
        passed, log = self.run_publish(workflow_changed=False)
        self.assertTrue(passed, log)
        self.assertNotIn("publish by hand", log.lower(), log)

    def test_a_rerun_over_the_same_release_passes(self):
        passed, log = self.run_publish(workflow_changed=False, existing=True)
        self.assertTrue(passed, log)

    def test_a_failed_read_of_a_published_release_is_asked_again(self):
        # Run 42919934207 published the release, then one read in the last
        # check failed (GitHub 502s) and the job said the release did not
        # exist, which skipped the re-pin and left base red. Download 1 is the
        # anonymous check; downloads 2 and 3 are the last check's first two tries.
        passed, log = self.run_publish(workflow_changed=False, curl_fails="2 3")
        self.assertTrue(passed, log)
        self.assertIn("read 2 of release", log, log)
        self.assertIn("exists with checksum", log, log)
        self.assertNotIn("publish by hand", log.lower(), log)

    def test_a_failed_read_before_the_create_is_asked_again(self):
        # The create step's own read fails first; it asks again instead of
        # taking the 502 for "no release" and creating over a published tag.
        passed, log = self.run_publish(workflow_changed=False, existing=True, create="403", read_fails="1")
        self.assertTrue(passed, log)
        self.assertIn("already has the matching archive", log, log)

    def test_a_release_that_never_reads_fails_loud_without_a_create(self):
        # Six failed reads are not "no release": the create step stops there
        # instead of creating, and still names the hand publish.
        passed, log = self.run_publish(workflow_changed=False, existing=True, create="403", read_fails="all")
        self.assert_fails_loud(passed, log)
        self.assertIn("could not read release", log, log)
        self.assertNotIn("HTTP 403", log, log)

APP_TOKEN_ACTION = "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1"


class PublishToken(unittest.TestCase):
    """Only the release create holds write access, through the release App."""

    def setUp(self):
        self.job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["publish"]
        self.steps = {step.get("id") or step.get("name"): step for step in self.job["steps"]}

    def test_the_job_runs_in_the_ffi_release_environment_with_a_read_only_github_token(self):
        self.assertEqual(self.job.get("environment"), "ffi-release")
        self.assertEqual(self.job.get("permissions"), {"contents": "read"})

    def test_the_app_tokens_are_scoped_to_this_repository(self):
        for step_id, workflows in (("app-token", False), ("app-token-workflows", True)):
            step = self.steps.get(step_id)
            self.assertIsNotNone(step, f"no step with id {step_id}")
            self.assertEqual(step["uses"].split(" ")[0], APP_TOKEN_ACTION)
            inputs = step["with"]
            self.assertEqual(inputs["app-id"], "${{ secrets.CMUX_FFI_RELEASE_APP_ID }}")
            self.assertEqual(inputs["private-key"], "${{ secrets.CMUX_FFI_RELEASE_APP_KEY }}")
            self.assertEqual(inputs["repositories"], "${{ github.event.repository.name }}")
            self.assertEqual(inputs["permission-contents"], "write")
            self.assertEqual("permission-workflows" in inputs, workflows, step_id)
            if workflows:
                self.assertEqual(inputs["permission-workflows"], "write")
            names = {key for key in inputs if key.startswith("permission-")}
            self.assertLessEqual(names, {"permission-contents", "permission-workflows"}, step_id)
        self.assertIn("workflow_changed == 'true'", self.steps["app-token-workflows"]["if"])
        self.assertIn("workflow_changed != 'true'", self.steps["app-token"]["if"])

    def test_only_the_release_create_uses_the_app_token(self):
        users = [step.get("name") for step in self.job["steps"]
                 if "uses" not in step and "app-token" in yaml.safe_dump(step)]
        self.assertEqual(users, ["Create the release (never overwrite)"])
        create = next(step for step in self.job["steps"] if step.get("name") == users[0])
        self.assertEqual(create["env"]["GH_TOKEN"],
                         "${{ steps.app-token.outputs.token || steps.app-token-workflows.outputs.token }}")


REPIN = ROOT / "scripts/cmux-next/repin-app-ffi.sh"


class RePin(unittest.TestCase):
    @staticmethod
    def canonical(sha, checksum, extra=""):
        return ("// CmuxNextCloud -> CCmuxAppFFI\nlet appFFI: Target = .binaryTarget(\n"
                '    name: "CCmuxAppFFI",\n'
                f'    url: "https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-{sha}/CCmuxAppFFI.xcframework.zip",\n'
                f'    checksum: "{checksum}"\n)\n'
                '            dependencies: ["CmuxNextDesign", "CCmuxAppFFI"],\n'
                f'let other = [1] // checksum is {"a" * 64}\n{extra}')

    def test_repin_rewrites_only_the_url_sha_and_checksum(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = Path(temp) / "Package.swift"
            old_sum = "a" * 64
            manifest.write_text(self.canonical(SHA, old_sum).replace(f"is {'a' * 64}", "unchanged"))
            new_sha, new_sum = "d" * 40, "e" * 64
            subprocess.run(["bash", str(REPIN), new_sha, new_sum, str(manifest)], check=True, capture_output=True)
            self.assertEqual(manifest.read_text(),
                             self.canonical(new_sha, new_sum).replace(f"is {'a' * 64}", "unchanged"))
            for bad in (("x", new_sum), (new_sha, "y")):
                result = subprocess.run(["bash", str(REPIN), *bad, str(manifest)], capture_output=True)
                self.assertNotEqual(result.returncode, 0, bad)

    def test_repin_refuses_a_manifest_that_is_not_canonical(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = Path(temp) / "Package.swift"
            for text in (self.canonical(SHA, "a" * 64, extra='let s = """\nx\n"""\n'),
                         self.canonical(SHA, "a" * 64).replace('name: "CCmuxAppFFI"', "name: ffiName"),
                         self.canonical(SHA, "a" * 64, extra='.binaryTarget(name: "Other", path: "x"),\n')):
                manifest.write_text(text)
                result = subprocess.run(["bash", str(REPIN), "d" * 40, "e" * 64, str(manifest)], capture_output=True,
                                        text=True)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("error: Package.swift", result.stderr)
                self.assertEqual(manifest.read_text(), text)

    def test_repin_job_opens_or_updates_a_pull_request(self):
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        job = workflow["jobs"]["repin"]
        self.assertEqual(job["needs"], ["build", "publish"])
        self.assertIn("needs.publish.result == 'success'", job["if"])
        mint = next(step for step in job["steps"] if step.get("id") == "app-token")
        self.assertEqual(mint["with"]["permission-contents"], "write")
        self.assertNotIn("permission-pull-requests", mint["with"])
        pr_mint = next(step for step in job["steps"] if step.get("id") == "pr-token")
        self.assertEqual(pr_mint["with"]["permission-pull-requests"], "write")
        self.assertTrue(pr_mint.get("continue-on-error"))
        base_mint = next(step for step in job["steps"] if step.get("id") == "base-token")
        self.assertEqual(base_mint["with"]["app-id"], "${{ secrets.CMUX_PR_AUTOFIX_APP_ID }}")
        self.assertEqual(base_mint["with"]["permission-contents"], "write")
        self.assertTrue(base_mint.get("continue-on-error"))
        self.assertEqual(job["steps"][-1]["env"]["BASE_TOKEN"], "${{ steps.base-token.outputs.token }}")
        script = "\n".join(str(step.get("run", "")) for step in job["steps"])
        self.assertEqual(script.strip(), "bash scripts/cmux-next/publish-app-ffi-repin.sh")


REPIN_FAKE = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
path = Path(os.environ["STATE"])
state = json.loads(path.read_text())
args = sys.argv[1:]
def save(): path.write_text(json.dumps(state))
def emit(value):
    if "--jq" in args:
        result = subprocess.run(["jq", "-r", args[args.index("--jq") + 1]],
                                input=json.dumps(value), text=True)
        sys.exit(result.returncode)
    print(json.dumps(value))
if Path(sys.argv[0]).name == "git":
    if args[0] == "diff": sys.exit(1)
    if args[0] == "rev-parse": print(("d" if ":" in args[-1] else "a") * 40)
    elif args[0] == "hash-object": print("e" * 40)
    elif args[0] == "ls-remote":
        # The runner's git cache: reads of origin may serve a stale snapshot.
        refs = state["refs"] if state["cache"] is None else state["cache"]
        ref = args[-1].removeprefix("refs/heads/")
        if ref in refs: print(refs[ref] + "\trefs/heads/" + ref)
    elif args[0] in ("fetch", "checkout"): pass
    elif args[0] == "push":
        if "--delete" in args: state["refs"].pop(args[-1], None)
        else:
            sha, ref = args[-1].split(":refs/heads/")
            if ref == "app-ffi-repin":
                if state["push_mode"] == "conflict": state["refs"][ref] = "f" * 40
                lease = next((a for a in args if a.startswith("--force-with-lease=")), None)
                if lease and state["refs"].get(ref, "") != lease.rsplit(":", 1)[1]:
                    save(); sys.exit(1)
            state["refs"][ref] = sha
            if ref == "app-ffi-repin":
                state["published"].append(sha)
                if sha == "a" * 40: state["prs"]["1"] = "closed"
        save()
        if "--delete" not in args and ref == "app-ffi-repin" and state["push_mode"] == "lost": sys.exit(1)
    else: raise AssertionError(args)
elif args[:2] == ["pr", "list"]: print("1")  # deliberately stale
elif args[:2] == ["pr", "edit"]:
    if state["close_on_edit"]: state["prs"][args[2]] = "closed"; save()
elif args[:2] == ["pr", "close"]:
    state["prs"][args[2]] = "closed"; save()
elif args[:2] == ["pr", "create"]:
    state["prs"]["2"] = "open"; save()
    print("https://github.com/manaflow-ai/cmux/pull/2")
elif args[0] == "api":
    endpoint = next(a for a in args if a.startswith("repos/"))
    if "contents/" in endpoint:
        if "PUT" in args:
            payload = json.loads(Path(args[args.index("--input") + 1]).read_text())
            state["writes"] += 1
            if state["write_mode"] != "fail": state["refs"][payload["branch"]] = "b" * 40
            save()
            if state["write_mode"] in ("fail", "lost"): sys.exit(1)
            emit({"commit": {"sha": "b" * 40}})
        else: emit({"sha": "e" * 40 if state["write_mode"] != "fail" else "d" * 40})
    elif "/git/ref/heads/" in endpoint:
        ref = endpoint.split("/heads/")[1]
        if state["ref_read"] == "fail":
            print("gh: Server Error (HTTP 502)", file=sys.stderr); sys.exit(1)
        if ref not in state["refs"]:
            # Real gh prints the error body on stdout, --jq or not (run 42536967661).
            print(json.dumps({"message": "Not Found", "status": "404"}))
            print("gh: Not Found (HTTP 404)", file=sys.stderr); sys.exit(1)
        emit({"object": {"sha": state["refs"][ref]}})
    elif "/pulls?" in endpoint: emit([{"number": 1}])  # stale even after auto-close
    elif "/commits/" in endpoint and os.environ.get("GH_TOKEN") != "read-token":
        print("gh: Resource not accessible by integration (HTTP 403)", file=sys.stderr); sys.exit(1)
    elif endpoint.endswith("/status") and state.get("status_read") == "fail":
        print("gh: Server Error (HTTP 502)", file=sys.stderr); sys.exit(1)
    elif endpoint.endswith("/check-runs?per_page=100"):
        runs = [{"conclusion": c} for c in state.get("checks", [])]
        emit({"total_count": state.get("check_total", len(runs)), "check_runs": runs})
    elif endpoint.endswith("/status"): emit({"state": state.get("status", "pending")})
    elif "/commits/" in endpoint:
        import datetime
        at = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=state.get("head_age_min", 600))
        emit({"commit": {"committer": {"date": at.strftime("%Y-%m-%dT%H:%M:%SZ")}}})
    elif "/pulls/" in endpoint:
        number = endpoint.rsplit("/", 1)[1]
        emit({"state": state["prs"][number], "base": {"ref": "feat-cmux-next"},
              "head": {"ref": "app-ffi-repin", "sha": "f" * 40 if state["wrong_head"]
                       else state["refs"]["app-ffi-repin"]}})
    else: raise AssertionError(args)
else: raise AssertionError(args)
'''


class RePinPublication(unittest.TestCase):
    """Execute the workflow step; model GitHub auto-closing a head reset to base."""

    def run_repin(self, *, closed=False, write_mode="ok", push_mode="ok", wrong_head=False, close_on_edit=False,
                  refs=None, cache=None, ref_read="ok", head_age_min=600, checks=(), status="pending", status_read="ok",
                  check_total=None, base_result="newer", base_enabled="true",
                  workflow=WORKFLOW):
        step = yaml.safe_load(workflow.read_text())["jobs"]["repin"]["steps"][-1]
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            scripts = work / "scripts/cmux-next"
            scripts.mkdir(parents=True)
            manifest = work / "Packages/macOS/CmuxNext/Package.swift"
            manifest.parent.mkdir(parents=True)
            manifest.write_text("pin\n")
            bin_dir = work / "bin"
            bin_dir.mkdir()
            for command in ("git", "gh"):
                executable(bin_dir / command, REPIN_FAKE)
            executable(bin_dir / "sleep", "#!/bin/sh\nexit 0\n")
            for command in ("repin-app-ffi.sh", "check-app-ffi-pin.sh"):
                executable(scripts / command, "#!/bin/sh\nexit 0\n")
            # The newest published release (NewestPublishedRelease tests the real one).
            executable(scripts / "newest_app_ffi_release.py",
                       f"print('{'d' * 40} {'e' * 64}')\n")
            # The pin on the base (pin-app-ffi-on-base.test.sh tests the real one): None fails it, else it
            # writes that result; it records the token and switch it was given.
            executable(scripts / "pin-app-ffi-on-base.sh", "#!/bin/sh\nexit 1\n" if base_result is None else
                       f'#!/bin/sh\necho "result={base_result}" >> "$GITHUB_OUTPUT"\n'
                       f'echo "$TOKEN $ENABLED $1 $2" > "$RUNNER_TEMP/base-call"\n')
            helper = ROOT / "scripts/cmux-next/publish-app-ffi-repin.sh"
            if helper.exists(): executable(scripts / helper.name, helper.read_text())
            state_path = work / "state.json"
            state_path.write_text(json.dumps({"refs": {"app-ffi-repin": "c" * 40} if refs is None else refs,
                "cache": cache, "ref_read": ref_read,
                "prs": {"1": "closed" if closed else "open"}, "published": [],
                "writes": 0, "write_mode": write_mode, "push_mode": push_mode,
                "wrong_head": wrong_head, "close_on_edit": close_on_edit,
                "head_age_min": head_age_min, "checks": list(checks), "status": status,
                "status_read": status_read,
                **({} if check_total is None else {"check_total": check_total})}))
            env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", STATE=str(state_path),
                       GH_TOKEN="pr-token", APP_TOKEN="contents-token", READ_TOKEN="read-token", TAG=TAG, CHECKSUM="f" * 64,
                       BASE_TOKEN="base-token", BASE_PIN_ENABLED=base_enabled,
                       GITHUB_SHA=SHA, GITHUB_REPOSITORY=REPO, GITHUB_REPOSITORY_OWNER="manaflow-ai",
                       GITHUB_RUN_ID=RUN_ID, GITHUB_RUN_ATTEMPT="2", GITHUB_SERVER_URL="https://github.com",
                       RUNNER_TEMP=temp)
            result = subprocess.run(["bash", "-e", "-c", step["run"]], cwd=work,
                                    env=env, capture_output=True, text=True, timeout=10)
            state = json.loads(state_path.read_text())
            base_call = Path(temp) / "base-call"
            state["base_call"] = base_call.read_text().split() if base_call.exists() else None
            return result, state

    def test_a_pin_on_the_base_opens_no_pull_request(self):
        for base_result in ("pinned", "already"):
            with self.subTest(base_result):
                result, state = self.run_repin(base_result=base_result)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(state["published"], [])
                self.assertEqual(state["refs"], {"app-ffi-repin": "c" * 40})
                self.assertIn("no re-pin pull request", result.stdout)
                # The open re-pin pull request pins an older release now: it is closed.
                self.assertEqual(state["prs"]["1"], "closed")

    def test_the_pin_on_the_base_gets_the_picked_release_and_the_switch(self):
        result, state = self.run_repin(base_result="pinned")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["base_call"], ["base-token", "true", "d" * 40, "e" * 64])
        # Off (CMUX_NEXT_BASE_AUTOFIX is not 1): a dry run, which falls through to the pull request.
        result, state = self.run_repin(base_result="dry-run", base_enabled="false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["base_call"], ["base-token", "d" * 40, "e" * 64])
        self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)

    def test_no_pin_on_the_base_falls_through_to_the_pull_request(self):
        for base_result in ("newer", "pr", "dry-run", None):
            with self.subTest(base_result):
                result, state = self.run_repin(base_result=base_result)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)
                self.assertIn(f"app FFI pin on feat-cmux-next: {base_result or 'failed'}", result.stdout)

    def test_stable_ref_never_points_to_unpinned_base(self):
        result, state = self.run_repin()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["published"], ["b" * 40])
        self.assertEqual(state["prs"]["1"], "open")
        self.assertEqual(list(state["refs"]), ["app-ffi-repin"])

    def test_closed_cached_pr_is_replaced_by_an_open_pr(self):
        result, state = self.run_repin(closed=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["prs"].get("2"), "open")

    def test_failed_pin_write_preserves_existing_ref_and_pr(self):
        result, state = self.run_repin(write_mode="fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["refs"], {"app-ffi-repin": "c" * 40})
        self.assertEqual(state["prs"]["1"], "open")
        self.assertEqual(state["writes"], 5)

    def test_lost_write_response_reuses_the_signed_commit(self):
        result, state = self.run_repin(write_mode="lost")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["writes"], 1)
        self.assertEqual(state["published"], ["b" * 40])

    def test_concurrent_stable_ref_change_is_preserved(self):
        result, state = self.run_repin(push_mode="conflict")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["refs"], {"app-ffi-repin": "f" * 40})
        self.assertEqual(state["published"], [])
        self.assertNotIn("verified open", result.stdout)

    def test_lost_push_response_verifies_the_published_commit(self):
        result, state = self.run_repin(push_mode="lost")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["refs"], {"app-ffi-repin": "b" * 40})
        self.assertIn("verified open", result.stdout)

    def test_heads_are_read_from_github_not_the_runners_git_cache(self):
        # Run 42493097381: the merge of the last re-pin PR deleted app-ffi-repin;
        # the push recreated it on GitHub, but `git ls-remote origin` went through
        # the runner's git cache, still saw the old head, and failed "the re-pin
        # head moved". The cache may also lag an existing head (wrong lease).
        # Run 42536967661: gh printed the 404 body on stdout, and that JSON became
        # the push lease ("cannot parse expected object name").
        cases = {
            "deleted, cache shows nothing": ({}, {}),
            "deleted, cache shows the merged head": ({}, {"app-ffi-repin": "c" * 40}),
            "existing, cache shows an older head": ({"app-ffi-repin": "c" * 40}, {"app-ffi-repin": "9" * 40}),
        }
        for name, (refs, cache) in cases.items():
            with self.subTest(name):
                result, state = self.run_repin(refs=refs, cache=cache, closed=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(state["refs"].get("app-ffi-repin"), "b" * 40)
                self.assertIn("verified open", result.stdout)

    def test_a_failed_head_read_fails_loud(self):
        result, state = self.run_repin(ref_read="fail")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["published"], [])

    def test_a_young_head_under_ci_is_kept_not_moved(self):
        # 2026-11-09: #39384 was moved five times in 4.5 hours; each move
        # cancelled its checks, nothing landed, and the pin fell 359 min behind.
        result, state = self.run_repin(head_age_min=20, checks=("success", "skipped", None))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("kept #1 at cccccccccccc", result.stdout)
        self.assertEqual(state["refs"], {"app-ffi-repin": "c" * 40})
        self.assertEqual(state["published"], [])
        self.assertEqual(state["writes"], 0)

    def test_a_head_past_the_hold_or_with_a_failed_check_is_moved(self):
        cases = {
            "past the hold": {"head_age_min": 95},
            "a failed check run": {"head_age_min": 20, "checks": ("success", "failure")},
            "a timed-out check run": {"head_age_min": 20, "checks": ("timed_out",)},
            "a check run that never started": {"head_age_min": 20, "checks": ("startup_failure",)},
            "a stale check run": {"head_age_min": 20, "checks": ("stale",)},
            "a check run waiting for approval": {"head_age_min": 20, "checks": ("action_required",)},
            "more check runs than one page": {"head_age_min": 20, "checks": ("success",), "check_total": 101},
            "a failed commit status": {"head_age_min": 20, "status": "failure"},
            "an errored commit status": {"head_age_min": 20, "status": "error"},
            "a failed status read": {"head_age_min": 20, "status_read": "fail"},
            "the PR is closed": {"head_age_min": 20, "closed": True},
        }
        for name, options in cases.items():
            with self.subTest(name):
                result, state = self.run_repin(**options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)
                self.assertIn("verified open", result.stdout)

    def test_the_pin_landing_re_pins_with_no_ffi_build(self):
        # The releases published while a head was held: its merge changes
        # Package.swift, and app-ffi-repin.yml re-pins them at once.
        workflow = yaml.safe_load(REPIN_WORKFLOW.read_text(encoding="utf-8"))
        push = workflow[True]["push"]
        self.assertEqual(push["branches"], ["feat-cmux-next"])
        self.assertIn("Packages/macOS/CmuxNext/Package.swift", push["paths"])
        # A schedule would run from main, where the job and its environment refuse it.
        self.assertNotIn("schedule", workflow[True])
        job = workflow["jobs"]["repin"]
        release = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["repin"]
        self.assertNotIn("needs", job)
        self.assertEqual(job["environment"], "ffi-release")
        self.assertEqual(job["concurrency"], {"group": "app-ffi-repin", "cancel-in-progress": False})
        self.assertEqual(job["permissions"], {"contents": "read", "checks": "read", "statuses": "read"})
        self.assertEqual(release["permissions"], job["permissions"])
        self.assertEqual(job["steps"][-1]["env"]["READ_TOKEN"], "${{ github.token }}")
        self.assertEqual(release["steps"][-1]["env"]["READ_TOKEN"], "${{ github.token }}")
        self.assertNotIn("macos", str(job["runs-on"]))
        self.assertEqual([s.get("with") for s in job["steps"]], [s.get("with") for s in release["steps"]])
        self.assertEqual(job["steps"][-1]["run"], release["steps"][-1]["run"])
        result, state = self.run_repin(workflow=REPIN_WORKFLOW, refs={})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)
        self.assertIn("verified open", result.stdout)

    def test_final_pr_must_be_open_at_the_published_commit(self):
        for options in ({"wrong_head": True}, {"close_on_edit": True}):
            with self.subTest(**options):
                result, _ = self.run_repin(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("verified open", result.stdout)


class NewestPublishedRelease(unittest.TestCase):
    """The re-pin pins the newest published release on feat-cmux-next (latest wins, 2026-11-07).

    cmux#37353 sat four FFI commits behind: each step-A push cancelled the
    previous build, and the re-pin of a published release refused because the
    base's sources had moved past it. Now it pins the newest commit newer than
    the current pin whose release is published, skipping one whose SHA256SUMS
    or SOURCE_SHA is a 404, and never waits for an unpublished head.
    """

    PICKER = ROOT / "scripts/cmux-next/newest_app_ffi_release.py"

    def setUp(self):
        self.temp = Path(tempfile.mkdtemp())
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.temp)])
        self.origin, self.work, self.releases = self.temp / "origin.git", self.temp / "work", self.temp / "releases"
        self.releases.mkdir()
        git_fixture_env.init_repo(self.origin, "--bare")
        subprocess.run(["git", "init", "-q", str(self.work)], check=True)
        self.git("remote", "add", "origin", str(self.origin))
        self.commits = [self.commit(f"c{i}") for i in range(6)]
        self.manifest = self.temp / "Package.swift"
        self.pin(self.commits[1], "1" * 64)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.work), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, name):
        self.git("commit", "-q", "--allow-empty", "-m", name)
        return self.git("rev-parse", "HEAD")

    def pin(self, sha, checksum):
        self.manifest.write_text(RePin.canonical(sha, checksum).replace("manaflow-ai/cmux", REPO))

    def publish(self, sha, checksum, *, sums=True, source=None):
        """A release: its tag on origin, and the files its downloads serve (a missing one is a 404)."""
        self.git("push", "-q", "origin", f"{sha}:refs/tags/cmux-app-ffi-{sha}")
        where = self.releases / f"cmux-app-ffi-{sha}"
        where.mkdir()
        (where / "SOURCE_SHA").write_text((source or sha) + "\n")
        if sums:
            (where / "SHA256SUMS").write_text(f"{checksum}  CCmuxAppFFI.xcframework.zip\n"
                                              f"{'9' * 64}  CCmuxAppFFI.xcframework.zip.sha256\n")

    def pick(self):
        env = dict(os.environ, CMUX_APP_FFI_RELEASE_DOWNLOAD=self.releases.as_uri())
        return subprocess.run([sys.executable, str(self.PICKER), "--manifest", str(self.manifest)], cwd=self.work,
                              env=env, capture_output=True, text=True, timeout=30)

    def test_the_newest_published_release_wins(self):
        self.publish(self.commits[2], "2" * 64)
        self.publish(self.commits[3], "3" * 64)
        result = self.pick()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), [self.commits[3], "3" * 64])

    def test_a_release_whose_sha256sums_is_a_404_is_skipped(self):
        self.publish(self.commits[2], "2" * 64)
        self.publish(self.commits[4], "4" * 64, sums=False)  # its tag exists, its upload is not finished
        result = self.pick()
        self.assertEqual(result.stdout.split(), [self.commits[2], "2" * 64])
        self.assertIn(f"skipped cmux-app-ffi-{self.commits[4]}: not published", result.stderr)

    def test_a_release_whose_source_sha_names_another_commit_is_skipped(self):
        self.publish(self.commits[2], "2" * 64)
        self.publish(self.commits[3], "3" * 64, source=self.commits[0])
        self.assertEqual(self.pick().stdout.split(), [self.commits[2], "2" * 64])

    def test_an_unpublished_head_is_never_waited_for(self):
        # The tip (commits[5]) has no release at all: the newest published one is pinned now.
        self.publish(self.commits[3], "3" * 64)
        result = self.pick()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split()[0], self.commits[3])

    def test_never_an_older_release_than_the_current_pin(self):
        self.publish(self.commits[0], "0" * 64)
        self.pin(self.commits[3], "3" * 64)
        self.assertEqual(self.pick().stdout.split(), [self.commits[3], "3" * 64])

    def test_nothing_newer_published_keeps_the_current_pin(self):
        result = self.pick()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), [self.commits[1], "1" * 64])
        self.assertIn("nothing newer", result.stderr)

    def test_a_manifest_with_no_pin_fails(self):
        self.manifest.write_text("let x = 1\n")
        self.assertNotEqual(self.pick().returncode, 0)

    def test_a_manifest_whose_pin_is_not_canonical_fails(self):
        self.manifest.write_text(self.manifest.read_text() + 'let s = #"x"#\n')
        result = self.pick()
        self.assertEqual(result.returncode, 1)
        self.assertIn("no canonical cmux-app-ffi pin", result.stderr)

    def test_any_number_of_unpublished_releases_is_skipped_down_to_the_pin(self):
        # Review of 6e7159aa (F2): no cap on unpublished releases; the walk ends at the current pin, in pages.
        more = [self.commit(f"d{i}") for i in range(45)]
        self.publish(self.commits[3], "3" * 64)
        for sha in more:
            self.publish(sha, "5" * 64, sums=False)
        result = self.pick()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), [self.commits[3], "3" * 64])
        self.assertEqual(result.stderr.count(": not published"), 45)

    def test_the_walk_reads_pages_and_errors_past_its_bound(self):
        picker = importlib.util.spec_from_file_location("picker", self.PICKER)
        module = importlib.util.module_from_spec(picker)
        picker.loader.exec_module(module)
        cwd = os.getcwd()
        os.chdir(self.work)
        try:
            with unittest.mock.patch.object(module, "PAGE", 2):
                self.assertEqual(list(module.newer_commits("HEAD", self.commits[1])), self.commits[:1:-1])
                with unittest.mock.patch.object(module, "MAX_PAGES", 1):
                    with self.assertRaisesRegex(RuntimeError, "more than 2 commits"):
                        list(module.newer_commits("HEAD", self.commits[1]))
        finally:
            os.chdir(cwd)

    def test_repin_checkout_has_the_history_to_walk(self):
        steps = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["repin"]["steps"]
        checkout = next(step for step in steps if str(step.get("uses", "")).startswith("actions/checkout@"))
        self.assertEqual(checkout["with"]["fetch-depth"], 0)
        self.assertEqual(checkout["with"]["filter"], "tree:0")


class BuildSpeedAndSupersede(unittest.TestCase):
    """A newer FFI push queues behind a running build, never cancels it, and the build clones treeless.

    The run-level group (cancel-in-progress: false) made a newer push wait for
    the whole older run, publish and re-pin included (#36262). The build job's
    group then cancelled the running build on each newer FFI push (#36346):
    on 2026-11-08 FFI pushes at 18:19, 18:39, 19:01 and 19:04Z cancelled every
    build, a dispatch (run 42511706663) too, so nothing newer than fcf8221e
    published and the pin stayed red. A build is never cancelled: the group
    keeps one running and only the newest pending, and the re-pin pins the
    newest published release (latest wins). The full clone of every ref was 5
    to 10 minutes of each build.
    """

    def setUp(self):
        # yaml reads the `on:` key as True; only jobs and concurrency matter here.
        self.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.jobs = self.workflow["jobs"]

    def test_no_run_level_group_queues_a_newer_push(self):
        self.assertNotIn("concurrency", self.workflow)

    def test_a_newer_push_never_cancels_a_running_build(self):
        concurrency = self.jobs["build"]["concurrency"]
        self.assertIn("${{ github.ref }}", concurrency["group"])
        self.assertIs(concurrency["cancel-in-progress"], False)

    def test_publish_is_never_cancelled_and_repins_run_one_at_a_time(self):
        publish = self.jobs["publish"]["concurrency"]
        self.assertEqual(publish["group"], "app-ffi-release-publish-${{ github.sha }}")
        self.assertIs(publish["cancel-in-progress"], False)
        repin = self.jobs["repin"]["concurrency"]
        self.assertEqual(repin["group"], "app-ffi-repin")
        self.assertIs(repin["cancel-in-progress"], False)

    def test_build_checkout_is_treeless_with_full_history(self):
        checkout = self.jobs["build"]["steps"][0]
        self.assertTrue(checkout["uses"].startswith("actions/checkout@"))
        self.assertEqual(checkout["with"]["fetch-depth"], 0)
        self.assertEqual(checkout["with"]["filter"], "tree:0")



def load_module(name: str, path: Path):
    """A scripts/ci module by path, with scripts/ci importable for its own imports."""
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


class BuildGoesAheadOfThePullRequestQueue(unittest.TestCase):
    """The release build takes a Blacksmith slot ahead of the PR queue when no promote runner is idle, and the
    promote pool once CI_NEXT_PROMOTE_POOL is set (2026-11-10: run 42833220418's build queued 66 minutes on
    blacksmith-6vcpu-macos-26 behind pull request jobs, and the base stayed red 5 h 14 min)."""

    PROMOTE = "glaeda-promote-trusted-std-xcode-26.6"
    SMALL = "blacksmith-6vcpu-macos-26"

    def runner(self, promote: str, event: str = "push", attempt: int = 1) -> str:
        build = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["build"]
        return evaluate(build["runs-on"], {
            "github": {"repository_owner": "manaflow-ai", "event_name": event, "run_attempt": attempt},
            "vars": {"CI_NEXT_PROMOTE_POOL": promote, "MACOS_RUNNER_26": self.SMALL,
                     "RUNNER_POOLS": json.dumps({"macos_26": self.SMALL})}})

    def snapshot(self, path: str) -> dict:
        janitor = load_module("queue_janitor", ROOT / "scripts/ci/queue_janitor.py")
        runs = [{"id": 1, "name": "app FFI release", "path": path}]
        jobs = {1: [{"labels": [self.SMALL], "status": "queued", "created_at": "2026-11-10T14:21:18Z",
                     "name": "build xcframework"}]}
        now = dt.datetime(2026, 11, 10, 14, 30, tzinfo=dt.timezone.utc)
        return janitor.pool_load_snapshot(runs, jobs, now=now)["pools"][self.SMALL]

    def test_a_push_takes_the_promote_pool_once_it_is_set(self):
        self.assertEqual(self.runner(self.PROMOTE), self.PROMOTE)

    def test_with_no_promote_pool_a_push_takes_blacksmith(self):
        self.assertEqual(self.runner(""), self.SMALL)

    def test_a_rerun_or_a_dispatch_takes_blacksmith_even_with_the_promote_pool_set(self):
        self.assertEqual(self.runner(self.PROMOTE, attempt=2), self.SMALL)
        self.assertEqual(self.runner(self.PROMOTE, event="workflow_dispatch"), self.SMALL)

    def test_its_queued_build_holds_the_label_against_pull_request_placements(self):
        held = self.snapshot(".github/workflows/app-ffi-release.yml")
        self.assertEqual((held["queued"], held["reserved_queued"]), (1, 1))
        # Only this workflow's path: a look-alike file name reserves nothing.
        for path in (".github/workflows/my-app-ffi-release.yml", ".github/workflows/app-ffi-release-shadow.yml",
                     ".github/workflows/app-ffi-repin.yml"):
            self.assertEqual(self.snapshot(path)["reserved_queued"], 0, path)

    def test_the_cascade_gives_a_held_label_to_a_nightly_feed_not_to_a_pull_request_job(self):
        cascade = load_module("next_macos_cascade", ROOT / "scripts/ci/next_macos_cascade.py")
        held = (self.SMALL,)
        # The build queued on 6 vCPU: the pool has room, and 12 vCPU takes nothing while any Mac job queues.
        live, waiting = {cascade.LARGE: 0, self.SMALL: 0}, {self.SMALL: 1}
        pr = cascade.cascade(["fast-tier"], live, waiting, reserved=held)
        self.assertEqual(pr[self.SMALL], ())
        nightly = cascade.cascade(["release-compile"], live, waiting, reserved=held, fresh=("release-compile",))
        self.assertEqual(nightly[self.SMALL], ("release-compile",))


if __name__ == "__main__":
    unittest.main()
