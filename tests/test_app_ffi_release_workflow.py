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
import workflow_jobs  # noqa: E402
from cmux_next_step_text import inline_steps  # noqa: E402
from test_seed_derived_data import evaluate  # noqa: E402
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import gh_expressions  # noqa: E402  (finds each ${{ }}: a regex cuts at a }} in a string)
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
    return gh_expressions.EXPRESSION.sub(lambda match: str(evaluate(match.group(1), context) or ""), str(text))


def condition(expression: str | None, context: dict, failed: bool, cancelled: bool = False) -> bool:
    """A step's `if:` with the status functions GitHub adds (success() when none is named). A cancelled job (a
    timeout included) has failure() and success() false."""
    if expression is None:
        return not failed and not cancelled
    text = str(expression).strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    named = re.search(r"\b(always|failure|success|cancelled)\(\)", text)
    text = (text.replace("always()", "true").replace("cancelled()", "true" if cancelled else "false")
            .replace("failure()", "true" if failed and not cancelled else "false")
            .replace("success()", "false" if failed or cancelled else "true"))
    return bool(evaluate(text, context)) and (bool(named) or not (failed or cancelled))


class PublishJob(unittest.TestCase):
    def run_publish(self, *, workflow_changed: bool, create: str = "ok", existing: bool = False,
                    read_fails: str = "", curl_fails: str = "") -> tuple[bool, str]:
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        job = document["jobs"]["publish"]
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            bin_dir, state, work = temp_path / "bin", temp_path / "state", temp_path / "work"
            # The job downloads into ${{ runner.temp }}/assets (RUNNER_TEMP is `temp`), not into its workspace.
            assets = temp_path / "assets"
            work.mkdir()
            for path in (bin_dir, state, assets):
                path.mkdir(parents=True)
            executable(bin_dir / "gh", FAKE_GH)
            executable(bin_dir / "curl", FAKE_CURL)
            executable(bin_dir / "sleep", "#!/bin/sh\nexit 0\n")
            archive = assets / "CCmuxAppFFI.xcframework.zip"
            archive.write_bytes(b"xcframework bytes")
            checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
            (assets / "CCmuxAppFFI.xcframework.zip.sha256").write_text(checksum + "\n")
            (assets / "SHA256SUMS").write_text(f"{checksum}  CCmuxAppFFI.xcframework.zip\n")
            (assets / "SOURCE_SHA").write_text(SHA + "\n")
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
            base_env.update({key: render(value, context) for key, value in workflow_jobs.effective_env(document, job).items()})
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

    def test_the_hand_publish_command_is_one_shell_command_that_ends_with_the_pin_proved(self):
        # Review of #37645 at ec4829a3, F1: it read "...; then pin it with ...", prose no shell accepts, so the
        # command named on a failed publish could not be pasted as given.
        command = workflow_jobs.resolve(workflow_jobs.jobs(WORKFLOW)["publish"]).env["HAND_PUBLISH"]
        command = gh_expressions.EXPRESSION.sub("X", command)
        checked = subprocess.run(["bash", "-n", "-c", command], capture_output=True, text=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertRegex(command, r"&& scripts/cmux-next/repin-app-ffi\.sh X X "
                                  r"&& scripts/cmux-next/check-app-ffi-pin\.sh --verify-release$")


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
        self.assertEqual(workflow_jobs.resolve(self.job).environment, {"name": "ffi-release"})
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
# Imported by name, never loaded by path: one module object per file (tests/test_script_module_loads.py).
if str(ROOT / "scripts/ci") not in sys.path:
    sys.path.insert(0, str(ROOT / "scripts/ci"))
import app_ffi_pin  # noqa: E402


def manifest(checksum):
    """A Package.swift holding the loader for CHECKSUM, with text before and after it."""
    return ("// swift-tools-version: 6.2\n\nimport Foundation\nimport PackageDescription\n\n"
            + app_ffi_pin.loader(checksum) + "\nlet package = Package(\n    name: \"x\",\n    targets: [\n        appFFI,\n    ]\n)\n")


class RePin(unittest.TestCase):
    @staticmethod
    def canonical(sha, checksum):
        """app-ffi-pin.json in its one format (scripts/ci/app_ffi_pin.py render)."""
        return json.dumps({"url": f"https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-{sha}/"
                                  "CCmuxAppFFI.xcframework.zip", "checksum": checksum}) + "\n"

    def test_repin_rewrites_only_the_url_sha_and_checksum(self):
        # The pin file's two values and Package.swift's one checksum line, nothing else (SwiftPM caches the evaluated
        # manifest by Package.swift's text, so a re-pin must change that text).
        with tempfile.TemporaryDirectory() as temp:
            pin_file = Path(temp) / "app-ffi-pin.json"
            package = Path(temp) / "Package.swift"
            pin_file.write_text(self.canonical(SHA, "a" * 64))
            package.write_text(manifest("a" * 64))
            new_sha, new_sum = "d" * 40, "e" * 64
            subprocess.run(["bash", str(REPIN), new_sha, new_sum, str(pin_file)], check=True, capture_output=True)
            self.assertEqual(pin_file.read_text(), self.canonical(new_sha, new_sum))
            self.assertEqual(package.read_text(), manifest(new_sum))
            changed = [(a, b) for a, b in zip(manifest("a" * 64).split("\n"), package.read_text().split("\n")) if a != b]
            self.assertEqual(changed, [(f"// app-ffi-pin-checksum: {'a' * 64}", f"// app-ffi-pin-checksum: {new_sum}")])
            for bad in (("x", new_sum), (new_sha, "y")):
                result = subprocess.run(["bash", str(REPIN), *bad, str(pin_file)], capture_output=True)
                self.assertNotEqual(result.returncode, 0, bad)
            self.assertEqual(pin_file.read_text(), self.canonical(new_sha, new_sum))
            self.assertEqual(package.read_text(), manifest(new_sum))

    def test_repin_refuses_a_manifest_whose_checksum_line_is_not_the_pin_files(self):
        with tempfile.TemporaryDirectory() as temp:
            pin_file = Path(temp) / "app-ffi-pin.json"
            package = Path(temp) / "Package.swift"
            pin_file.write_text(self.canonical(SHA, "a" * 64))
            for text in (manifest("b" * 64), manifest("a" * 64).replace(f"// app-ffi-pin-checksum: {'a' * 64}\n", "")):
                package.write_text(text)
                result = subprocess.run(["bash", str(REPIN), "d" * 40, "e" * 64, str(pin_file)], capture_output=True,
                                        text=True)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("app-ffi-pin-checksum", result.stderr)
                self.assertEqual(pin_file.read_text(), self.canonical(SHA, "a" * 64))
                self.assertEqual(package.read_text(), text)

    def test_repin_refuses_a_pin_file_that_is_not_canonical(self):
        with tempfile.TemporaryDirectory() as temp:
            pin_file = Path(temp) / "app-ffi-pin.json"
            (Path(temp) / "Package.swift").write_text(manifest("a" * 64))
            good = self.canonical(SHA, "a" * 64)
            for text in (good.replace('", "checksum"', '", "extra": 1, "checksum"'),
                         json.dumps(json.loads(good), indent=2) + "\n",
                         good.replace("manaflow-ai/cmux", "someone/cmux"),
                         "let x = 1\n"):
                pin_file.write_text(text)
                result = subprocess.run(["bash", str(REPIN), "d" * 40, "e" * 64, str(pin_file)], capture_output=True,
                                        text=True)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("error: Packages/macOS/CmuxNext/app-ffi-pin.json", result.stderr)
                self.assertEqual(pin_file.read_text(), text)

    def test_the_repin_writes_package_swift_only_through_the_pin_reader(self):
        body = REPIN.read_text().split("set -euo pipefail", 1)[1]
        self.assertEqual([line for line in body.splitlines() if "$manifest" in line and "app_ffi_pin.py" not in line
                          and not line.startswith("manifest=")], [])

    def test_repin_job_opens_or_updates_a_pull_request(self):
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        job = workflow["jobs"]["repin"]
        self.assertEqual(job["needs"], ["build", "publish"])
        mint = next(step for step in job["steps"] if step.get("id") == "app-token")
        self.assertEqual(mint["with"]["permission-contents"], "write")
        self.assertNotIn("permission-pull-requests", mint["with"])
        pr_mint = next(step for step in job["steps"] if step.get("id") == "pr-token")
        self.assertEqual(pr_mint["with"]["permission-pull-requests"], "write")
        self.assertTrue(pr_mint.get("continue-on-error"))
        self.assertEqual(pin_step(job)["run"].strip(), "bash scripts/cmux-next/publish-app-ffi-repin.sh")
        base_mint = next(step for step in job["steps"] if step.get("id") == "base-token")
        self.assertEqual(base_mint["with"]["app-id"], "${{ secrets.CMUX_PR_AUTOFIX_APP_ID }}")
        self.assertEqual(base_mint["with"]["permission-contents"], "write")
        self.assertTrue(base_mint.get("continue-on-error"))
        self.assertEqual(pin_step(job)["env"]["BASE_TOKEN"], "${{ steps.base-token.outputs.token }}")


REPIN_FAKE = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
path = Path(os.environ["STATE"])
state = json.loads(path.read_text())
args = sys.argv[1:]
def save(): path.write_text(json.dumps(state))
def server_error():
    """A 502 as gh prints it: GitHub's JSON error body on stdout with no final newline, the error on stderr."""
    sys.stdout.write(json.dumps({"message": "Server Error", "status": "502"}))
    print("gh: Server Error (HTTP 502)", file=sys.stderr); sys.exit(1)
# `gh api --include` prints the status line and headers, a blank line, then the body. The real header that names
# other headers comes first, so a reader that does not anchor at a line's start would take it for retry-after.
INCLUDE = Path(sys.argv[0]).name == "gh" and "--include" in args
if INCLUDE: args.remove("--include")
EXPOSE = "Access-Control-Expose-Headers: ETag, Link, Retry-After, X-RateLimit-Remaining, X-RateLimit-Reset\r\n"
def emit(value):
    if INCLUDE:
        sys.stdout.write("HTTP/2.0 200 OK\n" + EXPOSE + "X-Ratelimit-Remaining: 4000\r\n\r\n"); sys.stdout.flush()
    if "--jq" in args:
        result = subprocess.run(["jq", "-r", args[args.index("--jq") + 1]],
                                input=json.dumps(value), text=True)
        sys.exit(result.returncode)
    print(json.dumps(value))
def refuse_for_the_rate_limit():
    """GitHub's refusal of a rate-limited call, as gh prints it, for the first rule (the test's rate_limits) whose
    match is in the call's words: `times` refusals (-1: every one). The style picks the headers: primary (remaining 0,
    reset in 7 s), far (reset in an hour), retry-after (3 s), secondary (none of these). A call without --include
    (scripts/ci/gh_pages.py's) gets no headers."""
    import time
    words = " ".join(args)
    for rule in state.get("rate_limits", []):
        if rule["match"] not in words or rule.get("times", 1) == 0: continue
        if rule.get("times", 1) > 0: rule["times"] = rule.get("times", 1) - 1
        state.setdefault("refused", []).append(rule["match"]); save()
        style = rule.get("style", "primary")
        headers = {"primary": f"X-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: {int(time.time()) + 7}\r\n",
                   "far": f"X-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: {int(time.time()) + 3600}\r\n",
                   "retry-after": "Retry-After: 3\r\nX-Ratelimit-Remaining: 40\r\n",
                   "secondary": "X-Ratelimit-Remaining: 40\r\n"}[style]
        message = ("You have exceeded a secondary rate limit" if style in ("retry-after", "secondary")
                   else "API rate limit exceeded for installation ID 1")
        if INCLUDE: sys.stdout.write("HTTP/2.0 403 Forbidden\n" + EXPOSE + headers + "\r\n")
        sys.stdout.write(json.dumps({"message": message, "documentation_url": "https://docs.github.com/rest"}))
        print(f"gh: {message}. If you reach out to GitHub Support for help, please include the request ID "
              "E9AE:869ED:15A843:20AEAF:6B00B0AB (HTTP 403)", file=sys.stderr)
        sys.exit(1)
if Path(sys.argv[0]).name == "gh":
    # gh 2.105 prints a hint block on stderr for PR reads, failed or not; a hint that names a rate limit must not make
    # a failed read look rate-limited (the test's 502s carry one).
    print("hint: if you need to wait for this pull request, use gh event listen instead of polling:\n"
          "  - a poll can hit the API rate limit; gh event listen does not.", file=sys.stderr)
    refuse_for_the_rate_limit()
if Path(sys.argv[0]).name == "git":
    if args[0] == "diff":
        # `git diff --quiet A B -- INPUTS`: the FFI inputs of two releases are the same only when the test says so
        # (True: every pair; a list: those pairs, either way round).
        shas = [a for a in args[1:args.index("--")] if not a.startswith("-")] if "--" in args else []
        if len(shas) == 2:
            state.setdefault("input_diffs", []).append(shas)
            state.setdefault("input_paths", []).append(args[args.index("--") + 1:]); save()
            if state.get("diff_exit"): sys.exit(state["diff_exit"])
            same = state.get("same_inputs")
            sys.exit(0 if same is True or (isinstance(same, list) and (shas in same or shas[::-1] in same)) else 1)
        sys.exit(1)
    if args[0] == "show" and "--format=%ct" in args:
        # `git show -s --format=%ct SHA`: the release commit's time, when the test gives its age; else unknown.
        if state.get("pin_age_min") is None: sys.exit(128)
        import time
        print(int(time.time()) - 60 * state["pin_age_min"]); sys.exit(0)
    if args[0] == "log" and "--format=%ct" in args:
        # `git log --format=%ct PIN..RELEASE -- INPUTS`: the times of the FFI commits the base's pin lacks, newest
        # first; the test gives the oldest one's age, else the read fails.
        if state.get("unpinned_age_min") is None: sys.exit(128)
        import time
        print(int(time.time()) - 60 * min(5, state["unpinned_age_min"]))
        print(int(time.time()) - 60 * state["unpinned_age_min"]); sys.exit(0)
    if args[0] == "show":
        # `git show REV:PATH`: the files of the re-pin branch's head (the test's pr_files), nothing else.
        rev, _, file = args[-1].partition(":")
        files = state.get("pr_files", {})
        if rev != state["refs"].get("app-ffi-repin") or file not in files: sys.exit(128)
        print(files[file]); sys.exit(0)
    if args[0] == "rev-parse": print(("d" if ":" in args[-1] else "a") * 40)
    elif args[0] == "hash-object": print("e" * 40)
    elif args[0] == "ls-remote":
        # The runner's git cache: reads of origin may serve a stale snapshot.
        refs = state["refs"] if state["cache"] is None else state["cache"]
        ref = args[-1].removeprefix("refs/heads/")
        if ref in refs: print(refs[ref] + "\trefs/heads/" + ref)
    elif args[0] in ("fetch", "checkout"): pass
    elif args[0] == "merge-base" and "--is-ancestor" not in args:
        # `git merge-base HEAD TIP`: the commit the re-pin head was staged on, when the test gives one.
        if not state.get("staged_on"): sys.exit(1)
        print(state["staged_on"])
    elif args[0] == "merge-base":
        # --is-ancestor A B: A is older than B when the test lists it so; a commit it does not know is unknown here.
        older, newer = args[-2], args[-1]
        sys.exit(0 if [older, newer] in state.get("ancestry", []) else 1)
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
    raise AssertionError("gh pr edit reads Projects (classic) fields GitHub refuses; edit through REST")
elif args[:2] == ["pr", "close"]:
    state["prs"][args[2]] = "closed"; state.setdefault("closes", []).append(args[2]); save()
elif args[:2] == ["workflow", "run"]:
    state.setdefault("dispatches", []).append(args[2:]); save()
elif args[:2] == ["pr", "create"]:
    state["prs"]["2"] = "open"; save()
    print("https://github.com/manaflow-ai/cmux/pull/2")
elif args[0] == "api":
    endpoint = next(a for a in args if a.startswith("repos/"))
    if "PATCH" in args and "/pulls/" in endpoint:
        # The re-pin's title and body edit (REST, not `gh pr edit`: run 44655157417).
        state.setdefault("edits", []).append(endpoint.rsplit("/", 1)[1])
        if state["close_on_edit"]: state["prs"][endpoint.rsplit("/", 1)[1]] = "closed"
        save(); emit({"number": int(endpoint.rsplit("/", 1)[1])})
    elif "contents/" in endpoint:
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
            server_error()
        if ref not in state["refs"]:
            # Real gh prints the error body on stdout, --jq or not (run 42536967661), with no final newline.
            sys.stdout.write(json.dumps({"message": "Not Found", "status": "404"}))
            print("gh: Not Found (HTTP 404)", file=sys.stderr); sys.exit(1)
        emit({"object": {"sha": state["refs"][ref]}})
    elif "/actions/workflows/" in endpoint:
        if os.environ.get("GH_TOKEN") != "read-token":
            print("gh: Resource not accessible by integration (HTTP 403)", file=sys.stderr); sys.exit(1)
        if state.get("runs_read") == "fail":
            server_error()
        state.setdefault("run_reads", []).append(endpoint); save()
        emit({"workflow_runs": state.get("runs", [])})
    elif "/actions/runs?head_sha=" in endpoint:
        # The workflow runs at a re-pin head: held_pr counts the ones that never started.
        if os.environ.get("GH_TOKEN") != "read-token":
            print("gh: Resource not accessible by integration (HTTP 403)", file=sys.stderr); sys.exit(1)
        if state.get("head_runs_read") == "fail":
            server_error()
        emit({"workflow_runs": [{"conclusion": c} for c in state.get("head_runs", [])]})
    elif "/actions/runs/" in endpoint and endpoint.split("?")[0].endswith("/jobs"):
        if os.environ.get("GH_TOKEN") != "read-token":
            print("gh: Resource not accessible by integration (HTTP 403)", file=sys.stderr); sys.exit(1)
        run_id = endpoint.split("/actions/runs/")[1].split("/")[0]
        state.setdefault("job_reads", []).append(run_id); save()
        if state.get("jobs_read") == "fail":
            server_error()
        emit({"total_count": len(state.get("jobs", {}).get(run_id, [])), "jobs": state.get("jobs", {}).get(run_id, [])})
    elif "/pulls?" in endpoint: emit([{"number": 1}])  # stale even after auto-close
    elif "/commits/" in endpoint and os.environ.get("GH_TOKEN") != "read-token":
        print("gh: Resource not accessible by integration (HTTP 403)", file=sys.stderr); sys.exit(1)
    elif endpoint.endswith("/status") and state.get("status_read") == "fail":
        server_error()
    elif "/check-runs?" in endpoint:
        # Named check-0, check-1, ...; at the staged-on commit, the test's base_checks. Served a page at a time
        # (per_page/page, as scripts/ci/gh_pages.py asks).
        base = state.get("staged_on") and f"/commits/{state['staged_on']}/" in endpoint
        if state.get("base_checks_read" if base else "checks_read") == "fail":
            server_error()
        # A check given as [name, conclusion] keeps its name.
        runs = [{"name": c[0], "conclusion": c[1]} if isinstance(c, list) else {"name": f"check-{i}", "conclusion": c}
                for i, c in enumerate(state.get("base_checks" if base else "checks", []))]
        query = dict(part.split("=", 1) for part in endpoint.split("?", 1)[1].split("&") if "=" in part)
        size, number = int(query.get("per_page", 30)), int(query.get("page", 1))
        emit({"total_count": len(runs), "check_runs": runs[(number - 1) * size:number * size]})
    elif endpoint.endswith("/status"): emit({"state": state.get("status", "pending")})
    elif "/commits/" in endpoint:
        import datetime
        at = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=state.get("head_age_min", 600))
        emit({"commit": {"committer": {"date": at.strftime("%Y-%m-%dT%H:%M:%SZ")}}})
    elif "/pulls/" in endpoint:
        if state.get("pr_read") == "fail": server_error()
        number = endpoint.rsplit("/", 1)[1]
        emit({"state": state["prs"][number], "base": {"ref": "feat-cmux-next"},
              "head": {"ref": "app-ffi-repin", "sha": "f" * 40 if state["wrong_head"]
                       else state["refs"]["app-ffi-repin"]}})
    else: raise AssertionError(args)
else: raise AssertionError(args)
'''


# The pin reader: `read FILE` or `read-pin-file JSON MANIFEST` prints the sha its first file holds; "unreadable" fails.
PIN_READER_FAKE = r'''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
path = Path(os.environ["STATE"])
state = json.loads(path.read_text())
state.setdefault("pin_reads", []).append(args[0]); path.write_text(json.dumps(state))
text = Path(args[1]).read_text().strip()
if not text or text == "unreadable":
    print("error: no canonical pin", file=sys.stderr); sys.exit(1)
print(text + " " + "0" * 64)
'''


def pin_step(job: dict) -> dict:
    """The re-pin job's step that runs publish-app-ffi-repin.sh."""
    return next(step for step in job["steps"] if "publish-app-ffi-repin.sh" in str(step.get("run", "")))


def dispatch_step(job: dict) -> dict:
    """The re-pin job's step that starts app-ffi-repin.yml when the re-pin failed."""
    return next(step for step in job["steps"] if "gh workflow run" in str(step.get("run", "")))


class RePinPublication(unittest.TestCase):
    """Execute the workflow step; model GitHub auto-closing a head reset to base."""

    def run_repin(self, *, closed=False, write_mode="ok", push_mode="ok", wrong_head=False, close_on_edit=False,
                  refs=None, cache=None, ref_read="ok", head_age_min=600, checks=(), status="pending", status_read="ok",
                  runs=(), ancestry=(), runs_read="ok", jobs=None, same_inputs=False,
                  workflow=WORKFLOW, pr_files=None, current_pin=None, diff_exit=None,
                  jobs_read="ok", base_result="newer", base_enabled="true", pin_age_min=None,
                  unpinned_age_min=None, staged_on=None, base_checks=(), base_checks_read="ok", checks_read="ok",
                  rate_limits=(), wait_bound=None, pr_read="ok", fleet_verdict=None, head_runs=(),
                  head_runs_read="ok"):
        step = pin_step(yaml.safe_load(workflow.read_text())["jobs"]["repin"])
        with tempfile.TemporaryDirectory() as temp:
            work = Path(temp)
            scripts = work / "scripts/cmux-next"
            scripts.mkdir(parents=True)
            manifest = work / "Packages/macOS/CmuxNext/Package.swift"
            manifest.parent.mkdir(parents=True)
            current = self.PINNED if current_pin is None else current_pin
            # The JSON pin: the pin file holds the pin, Package.swift its loader block (scripts/ci/app_ffi_pin.py).
            manifest.write_text("loader\n")
            (manifest.parent / "app-ffi-pin.json").write_text(current + "\n")
            bin_dir = work / "bin"
            bin_dir.mkdir()
            for command in ("git", "gh"):
                executable(bin_dir / command, REPIN_FAKE)
            # Each sleep is recorded, not slept (state["sleeps"]).
            executable(bin_dir / "sleep", '#!/bin/sh\necho "$1" >> "$RUNNER_TEMP/sleeps"\n')
            executable(scripts / "repin-app-ffi.sh", "#!/usr/bin/env python3\n" + textwrap.dedent('''\
                import json, os, sys
                path = os.environ["STATE"]
                state = json.load(open(path))
                state.setdefault("repins", []).append(sys.argv[1:])
                json.dump(state, open(path, "w"))
                '''))
            executable(scripts / "check-app-ffi-pin.sh",
                       '#!/bin/sh\n[ "$1" = --list-inputs ] && echo cmux-tui/crates/cmux-app-ffi/src\nexit 0\n')
            # The current pin, read as the check reads it.
            (work / "scripts/ci").mkdir()
            executable(work / "scripts/ci/app_ffi_pin.py", PIN_READER_FAKE)
            # The bounded page reader the hold reads check runs with (tests/test_gh_pages.py tests it).
            executable(work / "scripts/ci/gh_pages.py", (ROOT / "scripts/ci/gh_pages.py").read_text())
            # The build fleet's compile verdict for a head (scripts/ci/fleet_compile_result.py): None, no reader.
            if fleet_verdict is not None:
                executable(work / "scripts/ci/fleet_compile_result.py", "#!/usr/bin/env python3\n" + textwrap.dedent(f'''\
                    import json, os, sys
                    path = os.environ["STATE"]
                    state = json.load(open(path))
                    state.setdefault("fleet_reads", []).append(sys.argv[1:])
                    json.dump(state, open(path, "w"))
                    print({fleet_verdict!r})
                    '''))
            # The newest published release (NewestPublishedRelease tests the real one).
            executable(scripts / "newest_app_ffi_release.py",
                       f"print('{'d' * 40} {'e' * 64}')\n")
            # The pin on the base (pin-app-ffi-on-base.test.sh tests the real one): None fails it, else it
            # writes that result; it records the token and switch it was given. "proven" plays a release that does
            # not only add: pinned when PROVEN_PIN names it, else pr.
            result_line = ('if [ -n "$PROVEN_PIN" ] && [ "$PROVEN_PIN" = "$1" ]; then echo result=pinned; '
                           'else echo result=pr; fi >> "$GITHUB_OUTPUT"\n' if base_result == "proven" else
                           f'echo "result={base_result}" >> "$GITHUB_OUTPUT"\n')
            executable(scripts / "pin-app-ffi-on-base.sh", "#!/bin/sh\nexit 1\n" if base_result is None else
                       '#!/bin/sh\n' + result_line +
                       'echo "$TOKEN $ENABLED $1 $2" > "$RUNNER_TEMP/base-call"\n'
                       'echo "${PROVEN_PIN:-none} $1 $2" >> "$RUNNER_TEMP/base-proofs"\n')
            helper = ROOT / "scripts/cmux-next/publish-app-ffi-repin.sh"
            if helper.exists(): executable(scripts / helper.name, helper.read_text())
            state_path = work / "state.json"
            state_path.write_text(json.dumps({"refs": {"app-ffi-repin": "c" * 40} if refs is None else refs,
                "cache": cache, "ref_read": ref_read,
                "prs": {"1": "closed" if closed else "open"}, "published": [],
                "writes": 0, "write_mode": write_mode, "push_mode": push_mode,
                "wrong_head": wrong_head, "close_on_edit": close_on_edit,
                "head_age_min": head_age_min, "checks": list(checks), "status": status,
                "status_read": status_read, "runs": list(runs), "ancestry": [list(pair) for pair in ancestry],
                "runs_read": runs_read, "jobs": jobs or {}, "same_inputs": same_inputs,
                "pr_files": pr_files or {}, "diff_exit": diff_exit, "jobs_read": jobs_read,
                "pin_age_min": pin_age_min, "unpinned_age_min": unpinned_age_min, "staged_on": staged_on, "base_checks": list(base_checks),
                "base_checks_read": base_checks_read, "checks_read": checks_read,
                "rate_limits": [dict(rule) for rule in rate_limits], "pr_read": pr_read,
                "head_runs": list(head_runs), "head_runs_read": head_runs_read}))
            env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", STATE=str(state_path),
                       GH_TOKEN="pr-token", APP_TOKEN="contents-token", READ_TOKEN="read-token", TAG=TAG, CHECKSUM="f" * 64,
                       BASE_TOKEN="base-token", BASE_PIN_ENABLED=base_enabled,
                       GITHUB_SHA=SHA, GITHUB_REPOSITORY=REPO, GITHUB_REPOSITORY_OWNER="manaflow-ai",
                       GITHUB_RUN_ID=RUN_ID, GITHUB_RUN_ATTEMPT="2", GITHUB_SERVER_URL="https://github.com",
                       RUNNER_TEMP=temp, **({} if wait_bound is None else {"REPIN_RATE_LIMIT_WAIT_S": str(wait_bound)}))
            result = subprocess.run(["bash", "-e", "-c", step["run"]], cwd=work,
                                    env=env, capture_output=True, text=True, timeout=10)
            state = json.loads(state_path.read_text())
            base_call = Path(temp) / "base-call"
            state["base_call"] = base_call.read_text().split() if base_call.exists() else None
            proofs = Path(temp) / "base-proofs"
            state["base_proofs"] = [line.split() for line in proofs.read_text().splitlines()] if proofs.exists() else []
            sleeps = Path(temp) / "sleeps"
            state["sleeps"] = [int(word) for word in sleeps.read_text().split()] if sleeps.exists() else []
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
        # One signed commit per pin path: the pin file, then Package.swift's checksum line.
        self.assertEqual(state["writes"], 2)
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
        self.assertEqual(state["writes"], 2)  # each file once, never repeated after a lost response
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

    def test_a_failed_read_leaves_the_re_pin_branch_alone(self):
        # 2026-11-16: the open-PR read hit the App's rate limit and moved #44074 from 8f7f9e7d to 1b93c4a6 (run
        # 43937628010), restarting its CI; a failed read now leaves the branch for the next re-pin run.
        cases = {
            "a failed status read": {"status_read": "fail"},
            "a failed check-run read": {"checks_read": "fail"},
            "a failed read of the head's workflow runs": {"head_runs_read": "fail"},
            # gh prints the 502's JSON body with no final newline, so held_pr's `read` of the PR's state fails: a
            # failed read, not a closed PR (review of #48228: a body copied with a newline moved the head).
            "a failed read of the PR's state": {"pr_read": "fail"},
        }
        for name, options in cases.items():
            with self.subTest(name):
                result, state = self.run_repin(head_age_min=20, **options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("left app-ffi-repin alone", result.stdout)
                self.assertEqual(state["refs"], {"app-ffi-repin": "c" * 40})
                self.assertEqual(state["published"], [])
                self.assertEqual(state["writes"], 0)

    # 2026-11-20, runs 44804668946 and 44820694017: a read of the hold got "API rate limit exceeded for installation"
    # (HTTP 403), held_pr took it for a failed read, and each job ended green with "left app-ffi-repin alone": #48065
    # kept an older pin, and every Mac build lost the prebuilt FFI. A rate-limited call now waits and asks again, and
    # one GitHub still refuses after the run's wait bound fails the job with the reason.
    HEAD = "c" * 40  # the re-pin branch's head (run_repin's refs)
    # Each read of the hold, by a word of its call, with what the run decides once the read answers. A head past the
    # hold moves after its commit read; the check runs and the status are read only for a young head, which is kept.
    HOLD_READS = (
        ("the open re-pin pull request", "pulls?state=open", {}, "moved"),
        ("its state and head", "pulls/1 --jq", {}, "moved"),
        ("the head's commit", f"/commits/{HEAD} --jq", {}, "moved"),
        ("the head's check runs (scripts/ci/gh_pages.py)", "/check-runs", {"head_age_min": 20}, "kept"),
        ("the head's status", "/status", {"head_age_min": 20}, "kept"),
    )
    BACKOFF = [60, 120, 240, 180]  # no retry-after or reset: 60 s doubling, cut at the 600 s bound

    def assert_decided(self, result, state, outcome):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("left app-ffi-repin alone", result.stdout)
        if outcome == "moved":
            self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)
            self.assertIn("verified open", result.stdout)
        else:
            self.assertIn(f"kept #1 at {self.HEAD[:12]}", result.stdout)
            self.assertEqual(state["refs"], {"app-ffi-repin": self.HEAD})

    def assert_failed_loud(self, result, state, sleeps):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("::error title=Re-pin rate-limited::GitHub rate-limited", result.stderr)
        self.assertNotIn("left app-ffi-repin alone", result.stdout)
        self.assertEqual(state["sleeps"], sleeps)
        self.assertLessEqual(sum(state["sleeps"]), 600)

    def test_a_rate_limited_read_of_the_hold_waits_and_asks_again(self):
        # A stand-in gh that answers "API rate limit exceeded" once, then answers the read.
        for name, match, options, outcome in self.HOLD_READS:
            # gh_pages.py asks without --include, so its refusal has no headers: the backoff's first step.
            waits = {"primary": [60], "retry-after": [60], "secondary": [60]} if "gh_pages" in name else \
                {"primary": list(range(6, 10)), "retry-after": [3], "secondary": [60]}
            for style, expected in waits.items():
                with self.subTest(name, style=style):
                    result, state = self.run_repin(rate_limits=[{"match": match, "style": style}], **options)
                    self.assert_decided(result, state, outcome)
                    self.assertEqual(state["refused"], [match])
                    self.assertEqual(len(state["sleeps"]), 1, state["sleeps"])
                    self.assertIn(state["sleeps"][0], expected)
                    self.assertIn("rate limit: GitHub refused", result.stderr)

    def test_a_read_of_the_hold_still_rate_limited_fails_the_job_loud(self):
        # A stand-in gh that never answers: the job fails red with the reason, the branch unchanged, never green.
        for name, match, options, _ in self.HOLD_READS:
            for style in ("far", "secondary"):
                with self.subTest(name, style=style):
                    result, state = self.run_repin(rate_limits=[{"match": match, "style": style, "times": -1}],
                                                   **options)
                    # A reset an hour off is past the bound: no wait at all. No headers: the backoff, to the bound.
                    self.assert_failed_loud(result, state, [] if style == "far" and "gh_pages" not in name
                                            else self.BACKOFF)
                    self.assertEqual(state["refs"], {"app-ffi-repin": self.HEAD})
                    self.assertEqual(state["published"], [])
                    self.assertEqual(state["writes"], 0)
                    reason = result.stderr.split("::error title=Re-pin rate-limited::")[1].splitlines()[0]
                    self.assertIn("rate limit", reason)

    def test_every_other_github_call_waits_out_a_rate_limit_too(self):
        newer = "7" * 40
        pending = {"runs": [{"id": 9, "status": "queued", "head_sha": newer}], "ancestry": [(self.NEWEST, newer)]}
        stale = {"same_inputs": [[self.PINNED, self.NEWEST]], "pr_files": self.pr_head(self.PR_PIN),
                 "ancestry": [(self.PR_PIN, self.NEWEST)]}
        published = lambda result, state: "verified open" in result.stdout  # noqa: E731
        closed = lambda result, state: state["prs"]["1"] == "closed"  # noqa: E731
        cases = (
            # (name, match, options, whether the run did its work once the call answered)
            ("the re-pin branch's head", "/git/ref/heads/app-ffi-repin", {}, published),
            ("the release runs", "/actions/workflows/", {}, published),
            ("a newer release run's jobs", "/actions/runs/9/jobs", pending,
             lambda result, state: "Re-pin held::release run 9" in result.stdout),
            ("the open re-pin PR, when the base has the inputs", "pulls?state=open", stale, closed),
            ("the close of that stale PR", "pr close", stale, closed),
            ("the open re-pin PR, after the pin on the base", "pulls?state=open", {"base_result": "pinned"}, closed),
            ("the close after the pin on the base", "pr close", {"base_result": "pinned"}, closed),
            ("the title and body edit", "-X PATCH", {}, published),
            ("the create of a new PR", "pr create", {"closed": True}, published),
        )
        for name, match, options, done in cases:
            with self.subTest(name, answers="after one refusal"):
                result, state = self.run_repin(rate_limits=[{"match": match, "style": "retry-after"}], **options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(done(result, state), result.stdout)
                self.assertEqual(state["refused"], [match])
                # `gh pr close` and `gh pr create` print no headers: the backoff's first step, not the retry-after.
                self.assertEqual(state["sleeps"], [60] if match.startswith("pr ") else [3])
            with self.subTest(name, answers="never"):
                result, state = self.run_repin(rate_limits=[{"match": match, "style": "secondary", "times": -1}],
                                               **options)
                self.assert_failed_loud(result, state, self.BACKOFF)
                self.assertFalse(done(result, state), result.stdout)

    def test_the_wait_bound_is_for_the_whole_run(self):
        # One refusal waits 60 s; the next call then has 40 s of a 100 s bound left, and fails once that is spent.
        result, state = self.run_repin(head_age_min=20, wait_bound=100, rate_limits=[
            {"match": "pulls/1 --jq", "style": "secondary"}, {"match": "/status", "style": "secondary", "times": -1}])
        self.assert_failed_loud(result, state, [60, 40])
        self.assertIn("past this run's 100s rate-limit wait (100s waited)", result.stderr)

    def test_after_one_call_gives_up_no_other_call_is_made(self):
        # Two newer release runs to read the jobs of; the limit resets in an hour, so the first read gives up at once.
        # The second is never asked (review of #48228: it would ask into the spent limit, and could wait 600 s more).
        runs = [{"id": 9, "status": "queued", "head_sha": "7" * 40}, {"id": 10, "status": "queued", "head_sha": "8" * 40}]
        result, state = self.run_repin(runs=runs, ancestry=[(self.NEWEST, "7" * 40), (self.NEWEST, "8" * 40)],
                                       rate_limits=[{"match": "/jobs?", "style": "far", "times": -1}])
        self.assert_failed_loud(result, state, [])
        self.assertEqual(state["refused"], ["/jobs?"])
        self.assertEqual(state.get("job_reads", []), [])

    def test_a_refusal_that_is_not_the_rate_limit_is_answered_at_once(self):
        # A 502 still leaves the branch alone, a 404 is a missing branch, a failed runs read re-pins as before: none
        # of them waits.
        for name, options, said in (("a 502", {"head_age_min": 20, "status_read": "fail"}, "left app-ffi-repin alone"),
                                    ("a 404", {"refs": {}, "closed": True}, "verified open"),
                                    ("a failed runs read", {"runs_read": "fail"}, "verified open")):
            with self.subTest(name):
                result, state = self.run_repin(**options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(said, result.stdout)
                self.assertEqual(state["sleeps"], [])
                self.assertNotIn("rate limit: GitHub refused", result.stderr)
                self.assertNotIn("Re-pin rate-limited", result.stderr)

    def test_a_head_whose_only_failures_fail_on_its_base_or_were_cancelled_is_kept(self):
        # 2026-11-16: #44074 had about 200 check runs and the cmux-next checks job red on base reds; one page and
        # any failure moved it at every publish (6f1d36c1, fe47e481, a30893db, c5a8aa57), and no head finished CI.
        cases = {
            "more check runs than one page": {"checks": ("success",) * 150},
            "a failure the base has too": {"checks": ("failure", "success"), "staged_on": "5" * 40,
                                           "base_checks": ("failure", "success")},
            # 2026-11-17: the re-pin's own PR edit started a size budget run that cancelled the head's (group
            # cmux-next-size-budget-<PR>, cancel-in-progress), and run 44042861860 moved #45149's head df6ee657 for
            # "8 failed check(s) of its own" while its Mac jobs were still queued: a cancel is not a failure.
            "a check run cancelled by a newer run of its workflow": {"checks": ("success", "cancelled"),
                                                                     "staged_on": "5" * 40,
                                                                     "base_checks": ("success",)},
        }
        for name, options in cases.items():
            with self.subTest(name):
                result, state = self.run_repin(head_age_min=20, **options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("kept #1 at cccccccccccc", result.stdout)
                self.assertEqual(state["refs"], {"app-ffi-repin": "c" * 40})
                self.assertEqual(state["writes"], 0)

    def test_a_head_past_the_hold_or_with_a_failed_check_is_moved(self):
        cases = {
            "past the hold": {"head_age_min": 95},
            "a failed check run": {"head_age_min": 20, "checks": ("success", "failure")},
            "a timed-out check run": {"head_age_min": 20, "checks": ("timed_out",)},
            "a check run that never started": {"head_age_min": 20, "checks": ("startup_failure",)},
            "a stale check run": {"head_age_min": 20, "checks": ("stale",)},
            "a check run waiting for approval": {"head_age_min": 20, "checks": ("action_required",)},
            "a failure on the second page": {"head_age_min": 20, "checks": ("success",) * 100 + ("failure",)},
            "a failure the base does not have": {"head_age_min": 20, "checks": ("success", "failure"),
                                                 "staged_on": "5" * 40, "base_checks": ("failure", "success")},
            "a failure, and the base's checks unreadable": {"head_age_min": 20, "checks": ("failure",),
                                                          "staged_on": "5" * 40, "base_checks": ("failure",),
                                                          "base_checks_read": "fail"},
            # 2026-11-26: #58251's base had a cmux-next.yml over GitHub's size limit, its dispatch never started,
            # and cmux-next/compile stayed pending while the hold kept the head.
            "a workflow run that never started": {"head_age_min": 20, "head_runs": ("success", "startup_failure")},
            "a failed commit status": {"head_age_min": 20, "status": "failure"},
            "an errored commit status": {"head_age_min": 20, "status": "error"},
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
        self.assertEqual(workflow_jobs.resolve(job).environment, {"name": "ffi-release"})
        self.assertEqual(job["concurrency"], {"group": "app-ffi-repin-v2", "cancel-in-progress": False})
        self.assertEqual(job["permissions"], {"actions": "write", "contents": "read", "checks": "read", "statuses": "read"})
        self.assertEqual(release["permissions"], job["permissions"])
        self.assertEqual(pin_step(job)["env"]["READ_TOKEN"], "${{ github.token }}")
        self.assertEqual(pin_step(release)["env"]["READ_TOKEN"], "${{ github.token }}")
        cells = workflow_jobs.runs_on_cells(job)
        self.assertTrue(cells, "repin: runs-on reads a matrix value nothing resolves, or is missing")
        for runs_on in cells:
            self.assertNotIn("macos", runs_on)
        self.assertEqual([s.get("with") for s in job["steps"]], [s.get("with") for s in release["steps"]])
        self.assertEqual(pin_step(job)["run"], pin_step(release)["run"])
        result, state = self.run_repin(workflow=REPIN_WORKFLOW, refs={})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)
        self.assertIn("verified open", result.stdout)

    # 2026-11-10: the re-pin of b2fb62c7's predecessor (#39863 at 8c29468b) pinned 1818fd17 while the release run for
    # a newer input commit (b2fb62c7, run 42737539302) was queued; it was stale on arrival and got BLOCK. The re-pin now
    # leaves the branch to the newer run, which re-pins when it publishes.
    NEWEST = "d" * 40  # the newest published release (the fake newest_app_ffi_release.py)

    def test_a_newer_pending_release_run_re_pins_instead(self):
        newer = "7" * 40
        for status in ("queued", "in_progress", "waiting", "pending", "requested"):
            with self.subTest(status):
                result, state = self.run_repin(
                    runs=[{"id": 9, "status": status, "head_sha": newer}],
                    ancestry=[(self.NEWEST, newer)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("run 9", result.stdout)
                self.assertEqual(state["refs"], {"app-ffi-repin": "c" * 40})
                self.assertEqual(state["published"], [])
                self.assertEqual(state["writes"], 0)

    def test_a_commit_the_checkout_does_not_have_counts_as_newer(self):
        # A push after this job's checkout: it is not in the history here, so it cannot be older than the pin.
        result, state = self.run_repin(runs=[{"id": 9, "status": "queued", "head_sha": "8" * 40}])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["published"], [])

    def test_this_run_an_older_run_or_a_finished_run_does_not_hold_the_re_pin(self):
        older = "6" * 40
        for name, runs in {
            "this run": [{"id": int(RUN_ID), "status": "in_progress", "head_sha": "7" * 40}],
            "an older run still building": [{"id": 9, "status": "in_progress", "head_sha": older}],
            "the pinned release's own run": [{"id": 9, "status": "in_progress", "head_sha": self.NEWEST}],
            "a newer run that failed": [{"id": 9, "status": "completed", "head_sha": "7" * 40}],
        }.items():
            with self.subTest(name):
                result, state = self.run_repin(runs=runs, ancestry=[(older, self.NEWEST)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)
                self.assertIn("verified open", result.stdout)

    def test_the_runs_are_read_with_the_jobs_token_and_a_failed_read_re_pins_as_before(self):
        result, state = self.run_repin(runs=[])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(state.get("run_reads", [])), 1)
        self.assertIn("/actions/workflows/app-ffi-release.yml/runs", state["run_reads"][0])
        self.assertIn("branch=feat-cmux-next", state["run_reads"][0])
        result, state = self.run_repin(runs_read="fail")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)
        self.assertIn("could not read", result.stdout + result.stderr)

    def test_a_failed_or_cancelled_release_run_still_re_pins(self):
        # The newer run that held the re-pin must re-pin itself when it ends without a release, or nothing does.
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["repin"]
        feat = {"ref": "refs/heads/feat-cmux-next", "event_name": "push"}
        for result in ("success", "failure", "cancelled", "skipped"):
            with self.subTest(result):
                context = {"github": feat, "needs": {"publish": {"result": result}, "build": {"result": result}}}
                self.assertTrue(condition(job["if"], context, failed=result != "success"))
        for github in ({"ref": "refs/heads/main", "event_name": "push"},
                       {"ref": "refs/heads/feat-cmux-next", "event_name": "pull_request"}):
            with self.subTest(**github):
                context = {"github": github, "needs": {"publish": {"result": "success"}}}
                self.assertFalse(condition(job["if"], context, failed=False))

    # Review of #40150: a run stays in progress after its own re-pin job ended (its macOS cross-compile shadow needs only
    # the build), so a hold on the run's status could wait for a re-pin that already ran, or two runs whose publishes
    # failed could each hold for the other. Only a run whose re-pin job is still to come holds.
    def test_a_newer_run_whose_re_pin_job_already_ran_does_not_hold(self):
        newer = "7" * 40
        for conclusion in ("success", "failure", "cancelled", "skipped"):
            with self.subTest(conclusion):
                result, state = self.run_repin(
                    runs=[{"id": 9, "status": "in_progress", "head_sha": newer}],
                    ancestry=[(self.NEWEST, newer)],
                    jobs={"9": [{"name": "open the re-pin pull request", "status": "completed",
                                 "conclusion": conclusion}]})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)
                self.assertIn("verified open", result.stdout)
                self.assertEqual(state.get("job_reads"), ["9"])

    def test_a_newer_run_whose_re_pin_job_is_still_to_come_holds(self):
        newer = "7" * 40
        for jobs in ([], [{"name": "open the re-pin pull request", "status": "queued", "conclusion": None}],
                     [{"name": "build xcframework", "status": "in_progress", "conclusion": None}]):
            with self.subTest(jobs=jobs):
                result, state = self.run_repin(runs=[{"id": 9, "status": "in_progress", "head_sha": newer}],
                                               ancestry=[(self.NEWEST, newer)], jobs={"9": jobs})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(state["published"], [])
                self.assertIn("run 9", result.stdout)

    # Review 2 of #40150: in app-ffi-repin.yml GITHUB_SHA is the merge of the Package.swift change, so every release run
    # still building was pushed before it; skipping runs older than GITHUB_SHA re-pinned an older release while the
    # newer one built (stale on arrival, as #39863). In a release run whose build failed, an older run that is still
    # building and newer than the picked release may publish a newer release too. Only the pinned release's ancestry
    # and the run's re-pin job decide: two runs never hold for each other, since one re-pin job runs at a time and the
    # one that ran first is completed when the other reads it.
    def test_a_run_older_than_this_runs_commit_but_newer_than_the_pin_holds(self):
        newer = "6" * 40
        for workflow in (WORKFLOW, REPIN_WORKFLOW):
            with self.subTest(workflow.name):
                result, state = self.run_repin(runs=[{"id": 9, "status": "in_progress", "head_sha": newer}],
                                               ancestry=[(newer, SHA)], workflow=workflow)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(state["published"], [])
                self.assertEqual(state["refs"], {"app-ffi-repin": "c" * 40})
                self.assertIn("run 9", result.stdout)
                self.assertIn("::notice", result.stdout)

    def test_a_run_whose_re_pin_ran_first_does_not_hold_the_later_one(self):
        # The older run's re-pin job ran first (the app-ffi-repin group runs one at a time), so it is completed here.
        older = "6" * 40
        result, state = self.run_repin(
            runs=[{"id": 9, "status": "in_progress", "head_sha": older}], ancestry=[(older, SHA)],
            jobs={"9": [{"name": "open the re-pin pull request", "status": "completed", "conclusion": "success"}]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)

    def test_a_failed_jobs_read_does_not_hold(self):
        newer = "7" * 40
        result, state = self.run_repin(runs=[{"id": 9, "status": "in_progress", "head_sha": newer}],
                                       ancestry=[(self.NEWEST, newer)], jobs_read="fail")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)
        self.assertIn("could not read release run 9's jobs", result.stdout + result.stderr)

    # 2026-11-10: the bot re-pinned #39863 to a release built from the same FFI sources as the current pin, with a new
    # checksum (the archive is not byte-reproducible): a change with nothing to change, and a fresh review to ask for.
    PINNED = "5" * 40  # the current pin (the fake app_ffi_pin.py)

    def test_a_release_with_the_pinned_inputs_is_not_re_pinned(self):
        result, state = self.run_repin(same_inputs=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["input_diffs"], [[self.PINNED, self.NEWEST]])
        self.assertEqual(state["refs"], {"app-ffi-repin": "c" * 40})
        self.assertEqual(state["published"], [])
        self.assertEqual(state["writes"], 0)
        self.assertIn("same app FFI inputs", result.stdout)

    def test_a_release_with_changed_inputs_is_re_pinned(self):
        result, state = self.run_repin()
        self.assertEqual(result.returncode, 0, result.stderr)
        # The skip compares the pin with the release, then the hold compares the tip with it before any runs read.
        self.assertEqual(state["input_diffs"], [[self.PINNED, self.NEWEST], ["a" * 40, self.NEWEST]])
        # The inputs compared are the ones the pin check lists (the fake check-app-ffi-pin.sh --list-inputs).
        self.assertEqual(state["input_paths"], [["cmux-tui/crates/cmux-app-ffi/src"]] * 2)
        self.assertEqual(state["published"], ["b" * 40])

    def test_the_json_pin_is_read_when_the_tree_has_it(self):
        result, state = self.run_repin(same_inputs=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        # Every read is the pin file with Package.swift's loader block, never Package.swift alone.
        self.assertEqual(set(state["pin_reads"]), {"read-pin-file"})
        self.assertEqual(state["input_diffs"], [[self.PINNED, self.NEWEST]])
        self.assertEqual(state["published"], [])

    def test_an_unreadable_pin_or_an_unknown_pin_commit_re_pins_and_says_why(self):
        result, state = self.run_repin(current_pin="unreadable", same_inputs=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["published"], ["b" * 40])
        self.assertIn("could not read the current pin", result.stdout + result.stderr)
        result, state = self.run_repin(same_inputs=True, diff_exit=128)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["published"], ["b" * 40])

    # Review 2 of #40150: the skip compared the picked release only with the base pin. A push that changes only the
    # release workflow publishes a release of the same inputs with a new checksum, and the open re-pin PR was moved to it
    # (after the hold) though it already pinned those inputs. And when the picked inputs are the base pin's (a revert),
    # an open PR that pins something else stayed open, stale.
    PR_PIN = "4" * 40  # the pin at the head of the open re-pin PR

    @staticmethod
    def pr_head(pin):
        """The re-pin branch head's pin files: PIN in app-ffi-pin.json, Package.swift its loader block."""
        return {"Packages/macOS/CmuxNext/Package.swift": "loader", "Packages/macOS/CmuxNext/app-ffi-pin.json": pin}

    def test_a_re_pin_head_without_the_pin_file_pins_nothing(self):
        # A head from before the pin moved to app-ffi-pin.json: its Package.swift alone is no pin, so the run re-pins
        # the picked release instead of keeping the branch's.
        result, state = self.run_repin(same_inputs=[[self.PR_PIN, self.NEWEST]],
                                       pr_files={"Packages/macOS/CmuxNext/Package.swift": self.PR_PIN})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("keeping that release", result.stdout)
        self.assertEqual(state["repins"], [[self.NEWEST, "e" * 64]])

    def test_an_open_re_pin_pr_that_pins_the_picked_inputs_keeps_its_pin(self):
        for name, same in {"the same inputs": [[self.PR_PIN, self.NEWEST]], "the picked release itself": []}.items():
            pr_pin = self.PR_PIN if same else self.NEWEST
            files = self.pr_head(pr_pin)
            with self.subTest(name, head="young, no failed check"):
                result, state = self.run_repin(same_inputs=same, pr_files=files, head_age_min=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(state["refs"], {"app-ffi-repin": "c" * 40})
                self.assertEqual(state["published"], [])
                self.assertEqual(state["writes"], 0)
                self.assertEqual(state["prs"]["1"], "open")
                self.assertIn("kept #1", result.stdout)
            # Review 3 of #40150: a head that must move (a failed check, past the hold) or a closed PR is still rebuilt
            # or replaced, with the release it already pins: no checksum churn, and the pin keeps an owner.
            for head, options in {"a failed check": {"head_age_min": 20, "checks": ("failure",)},
                                  "past the hold": {}, "the PR is closed": {"closed": True}}.items():
                with self.subTest(name, head=head):
                    result, state = self.run_repin(same_inputs=same, pr_files=files, **options)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    # The branch's own checksum (the fake pin reader's) for another release; the picked one's for itself.
                    self.assertEqual(state["repins"], [[pr_pin, "0" * 64 if same else "e" * 64]])
                    self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)
                    self.assertIn("verified open", result.stdout)
                    if options.get("closed"):
                        self.assertEqual(state["prs"].get("2"), "open")

    # Merge of feat into #40150 (lead decision, ffi-pin-rev-5): the steps run in this order, each one before the pin on
    # the base (#40097): the same-inputs skip, the pending-newer hold, the keep-the-branch's-release swap. Moving the pin
    # on the base above the skip or the hold would pin a release with nothing to change, or one a newer run is about to
    # replace; above the swap it would pin the newest release's checksum, not the branch's (checksum churn).
    def test_the_skip_and_the_hold_run_before_the_pin_on_the_base(self):
        newer = "7" * 40
        for name, options in {
                "skip": {"same_inputs": True},
                "hold": {"runs": [{"id": 9, "status": "queued", "head_sha": newer}],
                         "ancestry": [(self.NEWEST, newer)]}}.items():
            with self.subTest(name):
                # A pin on the base that would succeed: it must not be asked.
                result, state = self.run_repin(base_result="pinned", **options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIsNone(state["base_call"])
                self.assertEqual(state["published"], [])
                self.assertEqual(state["prs"]["1"], "open")
                self.assertNotIn("no re-pin pull request", result.stdout)

    def test_the_pin_on_the_base_gets_the_branchs_release_after_the_swap(self):
        result, state = self.run_repin(base_result="pinned", same_inputs=[[self.PR_PIN, self.NEWEST]],
                                       pr_files=self.pr_head(self.PR_PIN))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("keeping that release", result.stdout)
        # The branch's release and its checksum (the fake pin reader's), not the newest release's.
        self.assertEqual(state["base_call"], ["base-token", "true", self.PR_PIN, "0" * 64])

    def test_an_open_re_pin_pr_is_closed_when_the_picked_release_has_the_base_inputs(self):
        result, state = self.run_repin(same_inputs=[[self.PINNED, self.NEWEST]], pr_files=self.pr_head(self.PR_PIN), ancestry=[(self.PR_PIN, self.NEWEST)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state.get("closes"), ["1"])
        self.assertIn("closed #1", result.stdout)
        self.assertEqual(state["published"], [])
        self.assertEqual(state["writes"], 0)
        # Review 3 of #40150: only a PR whose pin is older than the picked release closes. newest_app_ffi_release.py
        # falls back to the current pin when a newer release reads as unpublished (one 404), and a PR that pins a newer
        # release must not close then.
        for name, options in {"no newer release picked": {"current_pin": self.NEWEST},
                              "the PR pins a commit after the picked release": {}}.items():
            with self.subTest(name):
                same = [[options.get("current_pin", self.PINNED), self.NEWEST]]
                result, state = self.run_repin(same_inputs=same, head_age_min=20, pr_files=self.pr_head(self.PR_PIN), **options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("closes", state)
        # A PR that already pins the base's pin, or no re-pin branch at all, is not closed.
        for options in ({"pr_files": self.pr_head(self.PINNED)}, {"refs": {}}):
            with self.subTest(**options):
                result, state = self.run_repin(same_inputs=[[self.PINNED, self.NEWEST]], **options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("closes", state)
                self.assertEqual(state["published"], [])

    def test_a_release_older_than_the_hold_bound_is_pinned_at_once(self):
        # 2026-11-14 (hq#10943): ead26e75 published 148 min after its commit and held for a newer queued run, so the
        # base stayed red. A release whose commit is already older than the bound pins now; a young one still holds.
        newer = "7" * 40
        for age, holds in ((90, False), (10, True)):
            with self.subTest(age=age):
                result, state = self.run_repin(runs=[{"id": 9, "status": "in_progress", "head_sha": newer}],
                                               ancestry=[(self.NEWEST, newer)], jobs={"9": []}, pin_age_min=age)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual("Re-pin held" in result.stdout, holds, result.stdout + result.stderr)
                if not holds:
                    self.assertIn("no newer run holds its re-pin", result.stderr)

    def test_a_young_release_does_not_hold_once_the_oldest_unpinned_ffi_commit_is_past_the_bound(self):
        # 2026-11-18: four FFI pushes 07:56Z to 09:46Z, each 25 to 45 min apart. Every release run held its re-pin for
        # the next one (44262749842 for 44269219861, then 44272641346, then 44279092668): each release's own commit was
        # young, so the bound never ended a hold, and the pin trailed the base's oldest unpinned FFI commit past the
        # 120 min grace. The bound reads that oldest commit's age; this release's commit alone is not enough.
        newer = "7" * 40
        for unpinned, holds in ((90, False), (10, True), (None, True)):
            with self.subTest(unpinned=unpinned):
                result, state = self.run_repin(runs=[{"id": 9, "status": "in_progress", "head_sha": newer}],
                                               ancestry=[(self.NEWEST, newer)], jobs={"9": []}, pin_age_min=5,
                                               unpinned_age_min=unpinned)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual("Re-pin held" in result.stdout, holds, result.stdout + result.stderr)
                if not holds:
                    self.assertIn("no newer run holds its re-pin", result.stderr)

    def test_a_run_waiting_for_hours_does_not_hold(self):
        # A run stuck waiting for a runner or an approval would hold every re-pin until it ends, maybe for days.
        newer = "7" * 40
        result, state = self.run_repin(
            runs=[{"id": 9, "status": "queued", "head_sha": newer, "created_at": "2020-01-01T00:00:00Z"}],
            ancestry=[(self.NEWEST, newer)])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)
        self.assertIn("ignored", result.stdout + result.stderr)

    # Review 2 of #40150: a run that holds leaves the pin to the newer run's re-pin job; when that job fails (a refused
    # write, a timeout), no job re-pinned until the next FFI push or pin merge. A failed re-pin job now starts
    # app-ffi-repin.yml, which re-pins the newest published release.
    def test_a_failed_re_pin_starts_the_re_pin_workflow_once(self):
        for path, event, starts in ((WORKFLOW, "push", True), (WORKFLOW, "workflow_dispatch", True),
                                    (REPIN_WORKFLOW, "push", True), (REPIN_WORKFLOW, "workflow_dispatch", False)):
            job = yaml.safe_load(path.read_text(encoding="utf-8"))["jobs"]["repin"]
            step = dispatch_step(job)
            context = {"github": {"ref": "refs/heads/feat-cmux-next", "event_name": event}}
            with self.subTest(path.name, event=event):
                self.assertEqual(condition(step.get("if"), context, failed=True), starts)
                # A timeout cancels the job: the step runs then too.
                self.assertEqual(condition(step.get("if"), context, failed=False, cancelled=True), starts)
                self.assertFalse(condition(step.get("if"), context, failed=False))
            with tempfile.TemporaryDirectory() as temp:
                bin_dir = Path(temp) / "bin"
                bin_dir.mkdir()
                executable(bin_dir / "gh", REPIN_FAKE)
                state_path = Path(temp) / "state.json"
                state_path.write_text(json.dumps({}))
                env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", STATE=str(state_path),
                           GH_TOKEN="actions-token", GITHUB_REPOSITORY=REPO)
                result = subprocess.run(["bash", "-e", "-c", step["run"]], env=env, capture_output=True, text=True,
                                        timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(state_path.read_text())["dispatches"],
                                 [["app-ffi-repin.yml", "--ref", "feat-cmux-next"]])

    def test_final_pr_must_be_open_at_the_published_commit(self):
        result, _ = self.run_repin(close_on_edit=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("verified open", result.stdout)

    # 2026-11-25: after the force-push to 38e0d0d2, GitHub's pull request still read head 4910b844 (its head sync lags a
    # push), and the job failed "re-pin PR is not open at the published head" though the branch held the new pin. Its
    # failure step then dispatched a re-pin on the same rate-limited quota. An open PR whose branch GitHub serves at the
    # published commit is published: the run re-reads the PR a few times, then warns and succeeds.
    def test_a_pr_head_that_lags_the_published_branch_is_not_a_failure(self):
        result, state = self.run_repin(wrong_head=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)
        self.assertIn("::warning", result.stdout + result.stderr)
        self.assertIn("app-ffi-repin is at bbbbbbbbbbbb", result.stdout + result.stderr)
        self.assertTrue(state["sleeps"], "the PR's head was not re-read after a wait")

    # 2026-11-25: release b6be67e4 changed a declaration over the pin 7c787a1cd7ea (run 45645816280), so the pin on the
    # base refused it and it went to re-pin PR #55633, whose whole rollup never went green on infra reds; base merges
    # restarted its CI, and the pin sat about 11 hours behind. Its app compile had passed. A re-pin PR head whose app
    # compile passed (the build fleet's verdict for that head, scripts/ci/fleet_compile_result.py) and whose fast tier
    # (HandlerCoverageTests) succeeded proves its pin: the pin on the base takes it (PROVEN_PIN).
    PROVEN_CHECKS = (["cmux-next fast tier", "success"], ["cmux-next app compile (build fleet)", "success"])

    def test_a_pin_the_re_pin_pr_proved_lands_on_the_base(self):
        for name, same in {"the picked release itself": [], "the same inputs": [[self.PR_PIN, self.NEWEST]]}.items():
            pr_pin = self.NEWEST if not same else self.PR_PIN
            with self.subTest(name):
                result, state = self.run_repin(base_result="proven", same_inputs=same, pr_files=self.pr_head(pr_pin),
                                               checks=self.PROVEN_CHECKS, fleet_verdict="pass")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("no re-pin pull request", result.stdout)
                self.assertEqual(state["published"], [])
                self.assertEqual(state["base_proofs"][-1], [pr_pin, pr_pin, "0" * 64])
                # The verdict of the PR's head, read with no PR number (that would submit a compile).
                self.assertEqual(len(state["fleet_reads"]), 1)
                read = state["fleet_reads"][0]
                self.assertEqual(read[read.index("--sha") + 1], "c" * 40)
                self.assertNotIn("--pr", read)

    def test_a_pin_the_re_pin_pr_has_not_proved_stays_on_the_pr(self):
        cases = {
            "the compile failed": {"fleet_verdict": "fail"},
            "no compile verdict": {"fleet_verdict": "none"},
            "no verdict reader": {},
            "the fast tier failed": {"fleet_verdict": "pass",
                                     "checks": (["cmux-next fast tier", "failure"],
                                                ["cmux-next fast tier (build fleet)", "success"])},
            "no fast tier yet": {"fleet_verdict": "pass", "checks": (["cmux-next app compile (build fleet)", "success"],)},
            "a failed check-run read": {"fleet_verdict": "pass", "checks": self.PROVEN_CHECKS, "checks_read": "fail"},
            "the head pins the current pin": {"fleet_verdict": "pass", "checks": self.PROVEN_CHECKS,
                                              "pr_files": self.pr_head(self.PINNED)},
        }
        for name, options in cases.items():
            with self.subTest(name):
                options = {"pr_files": self.pr_head(self.NEWEST), "checks": self.PROVEN_CHECKS, **options}
                result, state = self.run_repin(base_result="proven", **options)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("no re-pin pull request", result.stdout)
                self.assertTrue(all(proof[0] == "none" for proof in state["base_proofs"]), state["base_proofs"])

    # 2026-11-25: the hold's read of the release runs (actions/workflows/app-ffi-release.yml/runs?per_page=100) got the
    # installation rate limit's 403. When feat-cmux-next's tip already has the picked release's FFI inputs, no newer
    # release can be building for it, so the hold reads no runs.
    def test_the_hold_reads_no_runs_when_the_tip_has_the_releases_inputs(self):
        newer = "7" * 40
        result, state = self.run_repin(runs=[{"id": 9, "status": "queued", "head_sha": newer}],
                                       ancestry=[(self.NEWEST, newer)], same_inputs=[["a" * 40, self.NEWEST]])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state.get("run_reads", []), [])
        self.assertEqual(state["refs"]["app-ffi-repin"], "b" * 40)


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
        self.pin_file = self.temp / "app-ffi-pin.json"
        self.pin(self.commits[1], "1" * 64)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.work), "-c", "user.name=t", "-c", "user.email=t@t", *args],
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self, name):
        self.git("commit", "-q", "--allow-empty", "-m", name)
        return self.git("rev-parse", "HEAD")

    def pin(self, sha, checksum):
        self.pin_file.write_text(RePin.canonical(sha, checksum).replace("manaflow-ai/cmux", REPO))

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
        return subprocess.run([sys.executable, str(self.PICKER), "--pin-file", str(self.pin_file)], cwd=self.work,
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

    def test_a_pin_file_with_no_pin_fails(self):
        self.pin_file.write_text("let x = 1\n")
        self.assertNotEqual(self.pick().returncode, 0)

    def test_a_pin_file_that_is_not_canonical_fails(self):
        self.pin_file.write_text(self.pin_file.read_text().replace('", "checksum"', '",  "checksum"'))
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
        self.assertEqual(repin["group"], "app-ffi-repin-v2")
        self.assertIs(repin["cancel-in-progress"], False)

    def test_the_re_pin_hold_ends_inside_the_pin_grace(self):
        # publish-app-ffi-repin.sh holds a published release for a newer run created at most REPIN_PENDING_MAX_MIN
        # ago. That hold plus the newer build's timeout-minutes must end inside "Check the app FFI pin"'s
        # --stale-grace, or a newer run still queued turns the base red (2026-11-14, hq#10943: the hold was 180 min,
        # the grace 120).
        script = (ROOT / "scripts/cmux-next/publish-app-ffi-repin.sh").read_text()
        hold = int(re.search(r'pending_max_min="\$\{REPIN_PENDING_MAX_MIN:-(\d+)\}"', script).group(1))
        checks = inline_steps((ROOT / ".github/workflows/cmux-next.yml").read_text())
        grace = int(re.search(r"check-app-ffi-pin\.sh --verify-release --stale-grace (\d+)", checks).group(1)) // 60
        build = int(self.jobs["build"]["timeout-minutes"])
        self.assertLess(hold + build, grace, f"re-pin hold {hold} min + build {build} min vs pin grace {grace} min")

    def test_build_checkout_is_treeless_with_full_history(self):
        # The first checkout: "Drop a reused shallow checkout" runs before it (cmux#44583).
        checkout = next(step for step in self.jobs["build"]["steps"]
                        if str(step.get("uses", "")).startswith("actions/checkout@"))
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


class WaitingBuildIsReplacedByTheNewestRun(unittest.TestCase):
    """A build still waiting for a runner never holds the build group against a newer run.

    A build queued for a runner counts as the group's running job. Run 43978720557 (2026-11-16) queued its build
    on the saturated side-std label for hours while newer FFI runs 43979315440, 43982240915 and 43985437623 each
    went pending behind it and were replaced by the next: nothing built, and the pin stayed red. Each new push or
    dispatch's placement now cancels an older run whose build has not started on a runner; a running build is
    never cancelled (BuildSpeedAndSupersede).
    """

    OWN = 43993339863
    BRANCH = "feat-cmux-next"

    def setUp(self):
        self.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.module = load_module("ffi_build_supersede", ROOT / "scripts/ci/ffi_build_supersede.py")

    def play(self, runs: list[dict], jobs: dict[int, list[dict]]) -> tuple[list[int], list[tuple[str, str]]]:
        calls: list[tuple[str, str]] = []

        def request(method: str, path: str):
            calls.append((method, path))
            if method == "GET" and "/workflows/app-ffi-release.yml/runs" in path:
                return {"workflow_runs": runs}
            if method == "GET" and path.split("?")[0].endswith("/jobs"):
                return {"jobs": jobs[int(path.split("/runs/")[1].split("/")[0])]}
            if method == "POST" and path.endswith("/cancel"):
                return {}
            raise AssertionError(f"unexpected call {method} {path}")

        cancelled = self.module.supersede(request, REPO, self.OWN, self.BRANCH, log=lambda _line: None)
        return cancelled, calls

    def run_(self, run_id: int, status: str = "queued", branch: str = BRANCH) -> dict:
        return {"id": run_id, "status": status, "head_branch": branch}

    @staticmethod
    def build(status: str, runner: str = "") -> list[dict]:
        return [{"name": "place the build", "status": "completed", "runner_name": "blacksmith-linux"},
                {"name": "build xcframework", "status": status, "runner_name": runner}]

    def test_an_older_build_queued_for_a_runner_is_cancelled(self):
        cancelled, calls = self.play([self.run_(self.OWN, "in_progress"), self.run_(43978720557)],
                                     {43978720557: self.build("queued")})
        self.assertEqual(cancelled, [43978720557])
        self.assertIn(("POST", f"/repos/{REPO}/actions/runs/43978720557/cancel"), calls)

    def test_an_older_run_still_placing_is_cancelled_before_its_build_takes_the_group(self):
        # Two close pushes: the older run's build is not created until its placement ends.
        placing = [{"name": "place the build", "status": "in_progress", "runner_name": "blacksmith-linux"}]
        cancelled, _calls = self.play([self.run_(43979315440, "in_progress")], {43979315440: placing})
        self.assertEqual(cancelled, [43979315440])

    def test_a_running_or_finished_build_is_never_cancelled(self):
        cancelled, calls = self.play(
            [self.run_(43978720557, "in_progress"), self.run_(43979315440, "in_progress")],
            {43978720557: self.build("in_progress", "side-runner-6"),
             43979315440: self.build("completed", "side-runner-6")})
        self.assertEqual(cancelled, [])
        self.assertFalse([call for call in calls if call[0] == "POST"])

    def test_newer_finished_or_other_branch_runs_are_left_alone(self):
        cancelled, calls = self.play(
            [self.run_(self.OWN + 1), self.run_(43978720557, "completed"), self.run_(43979315440, branch="main")],
            {})
        self.assertEqual(cancelled, [])
        self.assertEqual([call[0] for call in calls], ["GET"])

    def test_a_failed_call_never_fails_the_placement(self):
        def broken(_method, _path):
            raise self.module.urllib.error.URLError("HTTP 502")

        env = {"GH_TOKEN": "t", "GITHUB_REPOSITORY": REPO, "GITHUB_REF_NAME": self.BRANCH,
               "GITHUB_RUN_ID": str(self.OWN)}
        with unittest.mock.patch.object(self.module, "github_request", return_value=broken):
            self.assertEqual(self.module.main(env), 0)

    def test_the_placement_runs_it_with_a_write_token_and_never_fails_on_it(self):
        placement = self.workflow["jobs"]["placement"]
        self.assertEqual(placement["permissions"].get("actions"), "write")
        step = next(step for step in placement["steps"] if "ffi_build_supersede.py" in str(step.get("run", "")))
        self.assertIs(step.get("continue-on-error"), True)
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ github.token }}")
        # The build does not wait on it: the placement's outputs come from the place step alone.
        self.assertNotIn("supersede", json.dumps(placement["outputs"]))


class PortableUnitTests(unittest.TestCase):
    def test_native_build_requires_linux_tests_even_when_placement_fails(self):
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        self.assertIn("portable-tests", jobs["build"]["needs"])
        for result in ("success", "failure", "skipped", "cancelled", ""):
            with self.subTest(result=result):
                context = {"github": {"ref": "refs/heads/feat-cmux-next"},
                           "needs": {"placement": {"result": "failure"},
                                     "portable-tests": {"result": result}}}
                self.assertEqual(condition(jobs["build"]["if"], context, failed=True), result == "success")
                self.assertFalse(condition(jobs["build"]["if"], context, failed=True, cancelled=True))

    def test_same_locked_suites_run_on_linux_and_leave_the_mac(self):
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        job = jobs["portable-tests"]
        for attempt in (1, 3):
            runner = evaluate(job["runs-on"], {"github": {"repository_owner": "manaflow-ai",
                                                        "run_attempt": attempt}})
            self.assertIn(runner, ("cmux-linux", "cmux-gcp-nightly-x64"))
        self.assertFalse(job.get("continue-on-error", False))
        suites = {(step.get("working-directory"), step.get("run"))
                  for step in job["steps"] if step.get("run", "").startswith("cargo test")}
        self.assertEqual(suites, {
            ("cmux-tui", "cargo test -p cmux-layout-reducer --locked"),
            ("cmux-tui/crates/cmux-rd-ffi", "cargo test --locked"),
            ("cmux-tui", "cargo test -p cmux-palette-ranker --locked"),
        })
        self.assertFalse(any("cargo test" in step.get("run", "") for step in jobs["build"]["steps"]))


class BuildGoesAheadOfThePullRequestQueue(unittest.TestCase):
    """The release build takes a Blacksmith slot ahead of the PR queue when no promote runner is idle, and the
    promote pool once CI_NEXT_PROMOTE_POOL is set (2026-11-10: run 42833220418's build queued 66 minutes on
    blacksmith-6vcpu-macos-26 behind pull request jobs, and the base stayed red 5 h 14 min)."""

    PROMOTE = "glaeda-promote-trusted-std-xcode-26.6"
    SMALL = "blacksmith-6vcpu-macos-26"

    NIGHTLY_SLOT = "glaeda-nightly-std-xcode-26.6"

    def runner(self, promote: str, event: str = "push", attempt: int = 1, slot: str = "off",
               owner: str = "manaflow-ai") -> str:
        """The build's runs-on; `slot` is vars.CI_RELEASE_PIN_SLOT (`off` here reads the routes behind the slot)."""
        build = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["build"]
        return evaluate(workflow_jobs.single_runs_on(build), {
            "github": {"repository_owner": owner, "event_name": event, "run_attempt": attempt},
            "vars": {"CI_NEXT_PROMOTE_POOL": promote, "MACOS_RUNNER_26": self.SMALL, "CI_RELEASE_PIN_SLOT": slot,
                     "RUNNER_POOLS": json.dumps({"macos_26": self.SMALL})}})

    def test_every_attempt_takes_the_nightly_slot_ahead_of_pull_request_jobs(self):
        # RELEASE_FIRST (claude-sr2-coord, 2026-11-16): run 43869638705's build, a dispatch, queued 1 to 4 hours on
        # glaeda-side-std-xcode-26.6 behind PR jobs. glaeda's nightly slot label carries no PR job, and glaeda's
        # hook ranks this build as a nightly job there.
        for event in ("push", "workflow_dispatch"):
            for attempt in (1, 2, 3):
                for promote in ("", self.PROMOTE):
                    with self.subTest(event=event, attempt=attempt, promote=promote):
                        self.assertEqual(self.runner(promote, event, attempt, slot=""), self.NIGHTLY_SLOT)

    def test_the_slot_switch_off_and_a_fork_keep_their_routes(self):
        self.assertEqual(self.runner(self.PROMOTE, slot="off"), self.PROMOTE)
        self.assertEqual(self.runner(self.PROMOTE, slot="", owner="someone"), "macos-26")

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


class BuildRescueToBlacksmith(unittest.TestCase):
    """hq#3690: a build no owned runner took in 20 minutes is re-dispatched to Blacksmith macOS (scripts/ci/
    app_ffi_rescue.py). On 2026-11-16 run 43978720557's build sat queued on glaeda-side-std-xcode-26.6 from 23:23Z to
    02:38Z with no runner and was cancelled having never run."""

    SMALL, LARGE = "blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26"
    SIDE = "glaeda-side-std-xcode-26.6"
    MINUTE = 60.0

    def setUp(self):
        self.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.rescue_module = load_module("app_ffi_rescue", ROOT / "scripts/ci/app_ffi_rescue.py")

    def runner(self, rescue: str, twelve: bool = False, switch: str = "pr-rescue", six: bool = True,
               pin_slot: str = "off") -> str:
        # pin_slot: vars.CI_RELEASE_PIN_SLOT; unset ("") sends the build to the nightly slot (RELEASE_FIRST), so the
        # owned routes these tests pin are read with it `off`.
        build = self.workflow["jobs"]["build"]
        return evaluate(workflow_jobs.single_runs_on(build), {
            "github": {"repository_owner": "manaflow-ai", "event_name": "workflow_dispatch", "run_attempt": 1},
            "inputs": {"rescue": rescue, "rescue_pool": ""},
            "needs": {"placement": {"outputs": {"placed_attempt": "1",
                                                "blacksmith_12_jobs": " app-ffi-build " if twelve else "",
                                                "blacksmith_6_jobs": " app-ffi-build " if six else ""}}},
            "vars": {"CI_SIDE_LANE_RUNNER": self.SIDE, "CI_BLACKSMITH_MACOS": switch, "CI_RELEASE_PIN_SLOT": pin_slot,
                     "RUNNER_POOLS": json.dumps({"macos_26": self.SMALL, "macos_26_large": self.LARGE})}})

    def test_a_rescued_run_takes_the_placements_blacksmith_slot_ahead_of_every_owned_route(self):
        self.assertEqual(self.runner("blacksmith"), self.SMALL)
        self.assertEqual(self.runner("blacksmith", twelve=True), self.LARGE)
        # No live slot (BuildRescueNeverToAnOffOrDeadBlacksmith): no Blacksmith label.
        self.assertEqual(self.runner("blacksmith", six=False), self.SIDE)

    def test_an_ordinary_run_keeps_its_owned_route(self):
        self.assertEqual(self.runner(""), self.SIDE)
        self.assertEqual(self.runner("something-else"), self.SIDE)
        # with the switch unset the ordinary run takes the nightly slot; a rescue still goes first
        self.assertEqual(self.runner("", pin_slot=""), "glaeda-nightly-std-xcode-26.6")
        self.assertEqual(self.runner("blacksmith", pin_slot=""), self.SMALL)

    POOL = "glaeda-promote-trusted-light-xcode-26.6"

    def pool_runner(self, pool: str, rescue: str = "", event: str = "push", attempt: int = 1,
                    pin_slot: str = "off") -> str:
        build = self.workflow["jobs"]["build"]
        return evaluate(workflow_jobs.single_runs_on(build), {
            "github": {"repository_owner": "manaflow-ai", "event_name": event, "run_attempt": attempt},
            "inputs": {"rescue": rescue, "rescue_pool": ""},
            "needs": {"placement": {"outputs": {"placed_attempt": "1",
                                                "blacksmith_6_jobs": " app-ffi-build " if rescue else ""}}},
            "vars": {"CI_FFI_RELEASE_POOL": pool, "CI_SIDE_LANE_RUNNER": self.SIDE, "CI_RELEASE_PIN_SLOT": pin_slot,
                     "CI_NEXT_PROMOTE_POOL": "glaeda-promote-trusted-std-xcode-26.6",
                     "RUNNER_POOLS": json.dumps({"macos_26": self.SMALL, "macos_26_large": self.LARGE})}})

    def test_the_ffi_release_pool_takes_every_attempt_when_set(self):
        for event in ("push", "workflow_dispatch"):
            for attempt in (1, 2):
                with self.subTest(event=event, attempt=attempt):
                    self.assertEqual(self.pool_runner(self.POOL, event=event, attempt=attempt), self.POOL)

    def test_a_rescue_still_goes_first_and_unset_keeps_the_earlier_routes(self):
        self.assertEqual(self.pool_runner(self.POOL, rescue="blacksmith"), self.SMALL)
        self.assertEqual(self.pool_runner(""), self.SIDE)
        # the dedicated pool, when set, goes ahead of the nightly slot; unset, the nightly slot takes the build
        self.assertEqual(self.pool_runner(self.POOL, pin_slot=""), self.POOL)
        self.assertEqual(self.pool_runner("", pin_slot=""), "glaeda-nightly-std-xcode-26.6")

    def test_only_this_workflow_reads_the_ffi_release_pool(self):
        readers = sorted(path.name for path in (ROOT / ".github/workflows").glob("*.yml")
                         if "CI_FFI_RELEASE_POOL" in path.read_text(encoding="utf-8"))
        self.assertEqual(readers, ["app-ffi-release.yml"])

    def test_a_rescued_run_places_with_blacksmith_on(self):
        place = next(step for step in self.workflow["jobs"]["placement"]["steps"] if step.get("id") == "place")
        expression = place["env"]["CI_BLACKSMITH_MACOS"]
        self.assertEqual(render(expression, {"inputs": {"rescue": "blacksmith"}, "vars": {"CI_BLACKSMITH_MACOS": ""}}),
                         "on")
        self.assertEqual(render(expression, {"inputs": {"rescue": ""}, "vars": {"CI_BLACKSMITH_MACOS": "pr-rescue"}}),
                         "pr-rescue")

    def rescue_runs(self, switch: str, rescue: str = "", ref: str = "refs/heads/feat-cmux-next") -> bool:
        """Whether the watch runs; the switch no longer gates it (the script reads it)."""
        job = self.workflow["jobs"]["rescue"]
        return bool(evaluate(str(job["if"]).strip()[3:-2].replace("!cancelled()", "true"), {
            "github": {"ref": ref, "repository_owner": "manaflow-ai"}, "inputs": {"rescue": rescue},
            "vars": {"CI_BLACKSMITH_MACOS": switch}}))

    def test_the_watch_runs_on_feat_cmux_next_and_never_in_a_rescued_run(self):
        for switch in ("pr-rescue", "on", "", "off"):
            self.assertTrue(self.rescue_runs(switch), switch)
        self.assertFalse(self.rescue_runs("pr-rescue", rescue="blacksmith"))
        self.assertFalse(self.rescue_runs("", rescue="owned"))
        self.assertFalse(self.rescue_runs("pr-rescue", ref="refs/heads/main"))

    def test_nothing_waits_on_the_watch(self):
        for name, job in self.workflow["jobs"].items():
            needs = job.get("needs") or []
            self.assertNotIn("rescue", [needs] if isinstance(needs, str) else needs, name)
        self.assertEqual(self.workflow["jobs"]["rescue"]["permissions"], {"actions": "write", "contents": "read"})

    def test_decide(self):
        m = self.rescue_module
        queued = {"name": m.BUILD_JOB, "status": "queued", "runner_name": None}
        self.assertEqual(m.decide(None, None, 0.0), (m.WAIT, None))
        self.assertEqual(m.decide(queued, None, 100.0), (m.WAIT, 100.0))
        self.assertEqual(m.decide(queued, 100.0, 100.0 + 19 * self.MINUTE)[0], m.WAIT)
        self.assertEqual(m.decide(queued, 100.0, 100.0 + 20 * self.MINUTE)[0], m.RESCUE)
        self.assertEqual(m.decide(dict(queued, runner_name="cmux18-glaeda-3"), 100.0, 1e9)[0], m.DONE)
        for status in ("in_progress", "completed"):
            self.assertEqual(m.decide(dict(queued, status=status), 100.0, 1e9)[0], m.DONE)
        # A build that stops being queued (pending again) restarts the clock.
        self.assertEqual(m.decide(dict(queued, status="pending"), 100.0, 1e9), (m.WAIT, None))

    def watch(self, switch: str, pages: list) -> tuple[str, list]:
        m = self.rescue_module
        calls, clock = [], [0.0]

        def api(method, path, token, body=None):
            calls.append((method, path, body))
            return {"jobs": pages[min(len([c for c in calls if c[0] == "GET"]) - 1, len(pages) - 1)]} \
                if method == "GET" else None

        def sleep(seconds):
            clock[0] += seconds

        env = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_RUN_ID": "7", "GITHUB_RUN_ATTEMPT": "1",
               "GH_TOKEN": "t", "GITHUB_REF_NAME": "feat-cmux-next", "CI_BLACKSMITH_MACOS": switch}
        verdict = m.watch(env, api=api, clock=lambda: clock[0], sleep=sleep, out=lambda line: None)
        return verdict, [c for c in calls if c[0] == "POST"]

    def test_a_build_queued_20_minutes_is_dispatched_to_blacksmith_then_its_run_cancelled(self):
        m = self.rescue_module
        verdict, posts = self.watch("pr-rescue", [[{"name": m.BUILD_JOB, "status": "queued"}]])
        self.assertEqual(verdict, m.RESCUE)
        self.assertEqual(posts, [
            ("POST", "repos/manaflow-ai/cmux/actions/workflows/app-ffi-release.yml/dispatches",
             {"ref": "feat-cmux-next", "inputs": {"rescue": "blacksmith", "rescue_pool": "", "rescue_tried": "blacksmith"}}),
            ("POST", "repos/manaflow-ai/cmux/actions/runs/7/cancel", None)])

    def test_a_build_that_got_a_runner_or_a_switch_off_with_no_other_owned_pool_rescues_nothing(self):
        m = self.rescue_module
        started = [[{"name": m.BUILD_JOB, "status": "queued"}], [{"name": m.BUILD_JOB, "status": "in_progress",
                                                                  "runner_name": "cmux14-glaeda-2"}]]
        self.assertEqual(self.watch("pr-rescue", started), (m.DONE, []))
        self.assertEqual(self.watch("off", [[{"name": m.BUILD_JOB, "status": "queued"}]]), (m.WAIT, []))

    def test_the_watch_is_bounded(self):
        m = self.rescue_module
        self.assertEqual(self.watch("pr-rescue", [[]]), (m.WAIT, []))


class BuildRescueNeverToAnOffOrDeadBlacksmith(unittest.TestCase):
    """2026-11-17: vars.CI_BLACKSMITH_MACOS was unset (off) and the Blacksmith macOS labels had 0 of 267 runners
    online, yet a rescued FFI build's runs-on fell back to blacksmith-6vcpu-macos-26 whatever the placement saw. The
    rescue takes Blacksmith macOS only when the switch allows it and the rescued run's placement (dead- and
    stall-aware, next_macos_cascade) found a live slot; otherwise it takes another owned pool than the one the build
    sat on, never Blacksmith."""

    SMALL, LARGE = "blacksmith-6vcpu-macos-26", "blacksmith-12vcpu-macos-26"
    SIDE = "glaeda-side-std-xcode-26.6"
    FFI_POOL = "glaeda-promote-trusted-light-xcode-26.6"
    PROMOTE = "glaeda-promote-trusted-std-xcode-26.6"
    BLACKSMITH = re.compile(r"blacksmith-\d+vcpu-macos-")

    def setUp(self):
        self.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.rescue_module = load_module("app_ffi_rescue", ROOT / "scripts/ci/app_ffi_rescue.py")

    def runner(self, rescue: str, pool: str, switch: str, twelve: bool = False, six: bool = False) -> str:
        """The rescued run's build label; the placement read Blacksmith live (twelve/six) or dead (neither)."""
        return evaluate(workflow_jobs.single_runs_on(self.workflow["jobs"]["build"]), {
            "github": {"repository_owner": "manaflow-ai", "event_name": "workflow_dispatch", "run_attempt": 1},
            "inputs": {"rescue": rescue, "rescue_pool": pool},
            "needs": {"placement": {"outputs": {"placed_attempt": "1",
                                                "blacksmith_12_jobs": " app-ffi-build " if twelve else "",
                                                "blacksmith_6_jobs": " app-ffi-build " if six else ""}}},
            "vars": {"CI_SIDE_LANE_RUNNER": self.SIDE, "CI_BLACKSMITH_MACOS": switch,
                     "CI_FFI_RELEASE_POOL": self.FFI_POOL, "CI_NEXT_PROMOTE_POOL": self.PROMOTE,
                     "RUNNER_POOLS": json.dumps({"macos_26": self.SMALL, "macos_26_large": self.LARGE})}})

    def test_a_dead_blacksmith_label_sends_the_rescued_build_to_the_other_owned_pool(self):
        for switch in ("on", "pr-rescue"):
            with self.subTest(switch=switch):
                label = self.runner("blacksmith", "promote", switch)
                self.assertIsNone(self.BLACKSMITH.match(label), label)
                self.assertEqual(label, self.PROMOTE)
                # A live slot the placement found is still taken.
                self.assertEqual(self.runner("blacksmith", "promote", switch, six=True), self.SMALL)
                self.assertEqual(self.runner("blacksmith", "promote", switch, twelve=True), self.LARGE)

    def test_a_switch_off_rescue_takes_the_other_owned_pool(self):
        for switch in ("", "off"):
            for pool, label in (("promote", self.PROMOTE), ("ffi-pool", self.FFI_POOL), ("side", self.SIDE)):
                with self.subTest(switch=switch, pool=pool):
                    self.assertEqual(self.runner("owned", pool, switch), label)

    def watch(self, switch: str, stuck_on: str) -> tuple[str, list]:
        m = self.rescue_module
        calls, clock = [], [0.0]

        def api(method, path, token, body=None):
            calls.append((method, path, body))
            return {"jobs": [{"name": m.BUILD_JOB, "status": "queued", "labels": [stuck_on]}]} \
                if method == "GET" else None

        def sleep(seconds):
            clock[0] += seconds

        env = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_RUN_ID": "7", "GITHUB_RUN_ATTEMPT": "1",
               "GH_TOKEN": "t", "GITHUB_REF_NAME": "feat-cmux-next", "CI_BLACKSMITH_MACOS": switch,
               "CI_FFI_RELEASE_POOL": self.FFI_POOL, "CI_NEXT_PROMOTE_POOL": self.PROMOTE,
               "CI_SIDE_LANE_RUNNER": self.SIDE}
        verdict = m.watch(env, api=api, clock=lambda: clock[0], sleep=sleep, out=lambda line: None)
        return verdict, [c for c in calls if c[0] == "POST"]

    def test_switch_off_dispatches_an_owned_rescue_never_blacksmith(self):
        m = self.rescue_module
        for switch in ("", "off"):
            with self.subTest(switch=switch):
                verdict, posts = self.watch(switch, self.FFI_POOL)
                self.assertEqual(verdict, m.RESCUE)
                self.assertEqual(posts[0][2], {"ref": "feat-cmux-next", "inputs": {
                    "rescue": "owned", "rescue_pool": "promote", "rescue_tried": "ffi-pool,promote"}})
                self.assertEqual(posts[1], ("POST", "repos/manaflow-ai/cmux/actions/runs/7/cancel", None))
        # The pool the build sat on is never the rescue's pool.
        self.assertEqual(self.watch("", self.PROMOTE)[1][0][2]["inputs"],
                         {"rescue": "owned", "rescue_pool": "ffi-pool", "rescue_tried": "ffi-pool,promote"})

    def test_switch_on_names_the_owned_pool_its_rescued_run_falls_back_to(self):
        m = self.rescue_module
        verdict, posts = self.watch("pr-rescue", self.FFI_POOL)
        self.assertEqual(verdict, m.RESCUE)
        self.assertEqual(posts[0][2]["inputs"], {"rescue": "blacksmith", "rescue_pool": "promote",
                                                 "rescue_tried": "ffi-pool,promote"})

    def rescue_runs(self, switch: str, rescue: str = "") -> bool:
        job = self.workflow["jobs"]["rescue"]
        return bool(evaluate(str(job["if"]).strip()[3:-2].replace("!cancelled()", "true"), {
            "github": {"ref": "refs/heads/feat-cmux-next", "repository_owner": "manaflow-ai"},
            "inputs": {"rescue": rescue}, "vars": {"CI_BLACKSMITH_MACOS": switch}}))

    def test_the_watch_runs_with_the_switch_off_and_never_in_a_rescued_run(self):
        for switch in ("", "off", "on", "pr-rescue"):
            self.assertTrue(self.rescue_runs(switch), switch)
            for rescue in ("blacksmith", "owned"):
                self.assertFalse(self.rescue_runs(switch, rescue), (switch, rescue))
        rescue = self.workflow["jobs"]["rescue"]
        env = next(step for step in rescue["steps"] if "app_ffi_rescue.py" in str(step.get("run")))["env"]
        for name in ("CI_FFI_RELEASE_POOL", "CI_NEXT_PROMOTE_POOL", "CI_SIDE_LANE_RUNNER"):
            self.assertEqual(env.get(name), f"${{{{ vars.{name} }}}}", name)



class BuildRescueAgainToAnUntriedPool(unittest.TestCase):
    """2026-11-20: rescued run 44734106982 (dispatched 12:14Z) sent its build to glaeda-side-std-xcode-26.6, the pool
    its rescue picked; it sat there 110 min with no runner and was cancelled at 14:04Z, while a push run's build got
    another owned Mac in 15 s. A rescued run never rescued again, so nothing moved it, and the app FFI pin passed its
    120 min bound (goal fix-running-ffi-pin). A rescued run now rescues again, to an owned pool no build of its chain
    has named (`rescue_tried`, pool keys), never Blacksmith again, and leaves the build queued once every owned
    pool is tried: at most three dispatches in a chain."""

    SIDE = "glaeda-side-std-xcode-26.6"
    FFI_POOL = "glaeda-promote-trusted-light-xcode-26.6"
    PROMOTE = "glaeda-promote-trusted-std-xcode-26.6"

    def setUp(self):
        self.workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.rescue_module = load_module("app_ffi_rescue", ROOT / "scripts/ci/app_ffi_rescue.py")

    def watch(self, switch: str, stuck_on: str, tried: str) -> tuple[str, list]:
        m = self.rescue_module
        calls, clock = [], [0.0]

        def api(method, path, token, body=None):
            calls.append((method, path, body))
            return {"jobs": [{"name": m.BUILD_JOB, "status": "queued", "labels": [stuck_on] if stuck_on else []}]} \
                if method == "GET" else None

        def sleep(seconds):
            clock[0] += seconds

        env = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_RUN_ID": "7", "GITHUB_RUN_ATTEMPT": "1",
               "GH_TOKEN": "t", "GITHUB_REF_NAME": "feat-cmux-next", "CI_BLACKSMITH_MACOS": switch,
               "CI_FFI_RELEASE_POOL": self.FFI_POOL, "CI_NEXT_PROMOTE_POOL": self.PROMOTE,
               "CI_SIDE_LANE_RUNNER": self.SIDE, "RESCUE_TRIED": tried}
        verdict = m.watch(env, api=api, clock=lambda: clock[0], sleep=sleep, out=lambda line: None)
        return verdict, [c for c in calls if c[0] == "POST"]

    def test_a_rescued_build_stuck_on_its_rescue_pool_moves_to_an_untried_pool(self):
        m = self.rescue_module
        # The 2026-11-20 chain: the first build sat on the FFI pool, its rescue sent the build to the side pool.
        for switch in ("", "pr-rescue"):
            with self.subTest(switch=switch):
                verdict, posts = self.watch(switch, self.SIDE, "ffi-pool,side")
                self.assertEqual(verdict, m.RESCUE)
                # A rescued run's rescue is always an owned one: Blacksmith first would win over rescue_pool again.
                self.assertEqual(posts[0][2], {"ref": "feat-cmux-next", "inputs": {
                    "rescue": "owned", "rescue_pool": "promote", "rescue_tried": "ffi-pool,promote,side"}})
                self.assertEqual(posts[1], ("POST", "repos/manaflow-ai/cmux/actions/runs/7/cancel", None))

    def test_every_owned_pool_tried_leaves_the_build_queued(self):
        m = self.rescue_module
        # The side pool's build can ask for labels other than CI_SIDE_LANE_RUNNER (CI_SIDE_LANE_LABELS): the chain
        # records the pool it sent the build to, not the labels, so that pool still counts as tried.
        for switch in ("", "on", "pr-rescue"):
            for stuck in (self.PROMOTE, "glaeda-side-xcode-26.6", "blacksmith-6vcpu-macos-26"):
                with self.subTest(switch=switch, stuck=stuck):
                    self.assertEqual(self.watch(switch, stuck, "ffi-pool,promote,side"), (m.WAIT, []))

    def test_a_blacksmith_rescue_that_waits_again_moves_to_an_owned_pool_and_the_chain_ends(self):
        m = self.rescue_module
        # Rescue 1 (switch on): rescue=blacksmith, falling back to promote; the chain records both pools it named.
        verdict, posts = self.watch("pr-rescue", self.FFI_POOL, "")
        self.assertEqual(posts[0][2]["inputs"], {"rescue": "blacksmith", "rescue_pool": "promote",
                                                 "rescue_tried": "ffi-pool,promote"})
        # Rescue 2: its build waited on a Blacksmith label; never Blacksmith again, the last owned pool.
        verdict, posts = self.watch("pr-rescue", "blacksmith-6vcpu-macos-26", "ffi-pool,promote")
        self.assertEqual(posts[0][2]["inputs"], {"rescue": "owned", "rescue_pool": "side",
                                                 "rescue_tried": "ffi-pool,promote,side"})
        # Rescue 3: nothing left; at most three dispatches in a chain.
        self.assertEqual(self.watch("pr-rescue", self.SIDE, "ffi-pool,promote,side"), (m.WAIT, []))

    def test_a_first_rescue_starts_the_tried_list(self):
        m = self.rescue_module
        verdict, posts = self.watch("", self.FFI_POOL, "")
        self.assertEqual(verdict, m.RESCUE)
        self.assertEqual(posts[0][2]["inputs"], {"rescue": "owned", "rescue_pool": "promote",
                                                 "rescue_tried": "ffi-pool,promote"})
        # A first build whose job lists no labels still starts a chain the rescued run can continue.
        verdict, posts = self.watch("", "", "")
        self.assertEqual(posts[0][2]["inputs"]["rescue_tried"], "ffi-pool")

    def rescue_runs(self, rescue: str, tried: str) -> bool:
        job = self.workflow["jobs"]["rescue"]
        return bool(evaluate(str(job["if"]).strip()[3:-2].replace("!cancelled()", "true"), {
            "github": {"ref": "refs/heads/feat-cmux-next", "repository_owner": "manaflow-ai"},
            "inputs": {"rescue": rescue, "rescue_tried": tried}, "vars": {"CI_BLACKSMITH_MACOS": ""}}))

    def test_the_watch_runs_in_a_rescued_run_that_carries_its_tried_labels(self):
        self.assertTrue(self.rescue_runs("", ""))
        for rescue in ("blacksmith", "owned"):
            self.assertTrue(self.rescue_runs(rescue, "ffi-pool"), rescue)
            # A rescued run from before rescue_tried existed still never rescues.
            self.assertFalse(self.rescue_runs(rescue, ""), rescue)
        inputs = self.workflow[True]["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["rescue_tried"]["type"], "string")
        rescue = self.workflow["jobs"]["rescue"]
        env = next(step for step in rescue["steps"] if "app_ffi_rescue.py" in str(step.get("run")))["env"]
        self.assertEqual(env.get("RESCUE_TRIED"), "${{ inputs.rescue_tried }}")


STATUS_CALL = re.compile(r"\b(success|failure|cancelled|always)\(\)")


def run_jobs(results: dict[str, str], event: str = "push") -> dict[str, str]:
    """Which jobs of the workflow run, given the result of the jobs named in `results`, by GitHub's job-gate rule:
    an `if` with no status function is `success() && (if)`, and success() asks that every ancestor, not only the
    named needs, succeeded; failure() asks that one failed. A job that runs and is not in `results` succeeds."""
    jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
    needs = {name: ([job["needs"]] if isinstance(job.get("needs"), str) else list(job.get("needs") or ()))
             for name, job in jobs.items()}
    outcome: dict[str, str] = {}

    def ancestors(name: str) -> set[str]:
        found: set[str] = set()
        for parent in needs[name]:
            found |= {parent} | ancestors(parent)
        return found

    def decide(name: str) -> str:
        if name not in outcome:
            for parent in needs[name]:
                decide(parent)
            above = [outcome[a] for a in ancestors(name)]
            status = {"success": all(r == "success" for r in above), "failure": "failure" in above,
                      "cancelled": False, "always": True}
            condition = str(jobs[name].get("if", "true")).strip()
            if condition.startswith("${{") and condition.endswith("}}"):
                condition = condition[3:-2]
            if not STATUS_CALL.search(condition):
                condition = f"success() && ({condition})"
            condition = STATUS_CALL.sub(lambda m: "true" if status[m.group(1)] else "false", condition)
            context = {"github": {"ref": "refs/heads/feat-cmux-next", "event_name": event,
                                  "repository_owner": "manaflow-ai"},
                       "needs": {p: {"result": outcome[p]} for p in needs[name]}}
            outcome[name] = results.get(name, "success") if evaluate(condition, context) else "skipped"
        return outcome[name]

    for name in jobs:
        decide(name)
    return outcome


class PlacementNeverGatesThePublish(unittest.TestCase):
    """The build runs past its placement (it only picks a runner), so nothing after the build may wait on the
    placement either. A downstream `if` without a status function keeps the implicit success() over every
    ancestor, placement included: a failed placement then skipped publish and repin under a green build, and the
    FFI pin stayed red (Codex review of cmux#40734 at 2283666f, P1)."""

    def test_a_failed_placement_still_publishes_and_repins_a_good_build(self):
        for event in ("push", "workflow_dispatch"):
            ran = run_jobs({"placement": "failure"}, event)
            self.assertEqual(ran["build"], "success", event)
            for job in ("macos-cross-shadow", "publish", "repin"):
                self.assertEqual(ran[job], "success", (event, job))

    def test_a_failed_build_publishes_nothing(self):
        for placement in ("success", "failure"):
            ran = run_jobs({"placement": placement, "build": "failure"})
            for job in ("macos-cross-shadow", "publish"):
                self.assertEqual(ran[job], "skipped", (placement, job))

    # Merge of feat into #40150: the re-pin job keeps always(). A run that ends with no release (a failed build or
    # publish) still re-pins the newest published release, since a newer run's pending build holds the re-pin of an
    # older one (publish-app-ffi-repin.sh); a failed placement cannot skip it either.
    def test_a_run_with_no_release_still_re_pins_the_newest_published_release(self):
        for results in ({"placement": "success", "build": "failure"}, {"placement": "failure", "build": "failure"},
                        {"placement": "failure", "publish": "failure"}):
            with self.subTest(**results):
                self.assertEqual(run_jobs(results)["repin"], "success")

    # A run whose build was cancelled (a newer push replaced it while it waited in the build group, or a cancel by
    # hand) re-pins too. It cannot pin its own artifact: publish-app-ffi-repin.sh ignores the build's TAG and CHECKSUM
    # and picks the newest published release. It cannot race the newer run: the re-pin jobs run one at a time, and the
    # newer run, still building with its re-pin to come, holds this one.
    def test_a_run_whose_build_was_cancelled_still_re_pins(self):
        for results in ({"build": "cancelled"}, {"placement": "failure", "build": "cancelled"},
                        {"publish": "cancelled"}):
            with self.subTest(**results):
                self.assertEqual(run_jobs(results)["repin"], "success")


if __name__ == "__main__":
    unittest.main()
