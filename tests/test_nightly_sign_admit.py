#!/usr/bin/env python3
"""Behavior of the nightly signing admission (scripts/ci/nightly_sign_admit.py).

nightly-sign.yml runs the tool from main on a `workflow_run` of nightly.yml.
Each case runs the tool as the workflow does (a subprocess with GH_TOKEN,
GITHUB_API_URL and GITHUB_OUTPUT) against a local fake GitHub API that serves
the run, its attempt, the workflow, the branch comparison, the jobs, the
producing jobs' annotations, the artifacts and their blobs. It checks the exit
code, the step outputs and the files the tool leaves.

Refused (exit 1): a prepared app whose tarball sha256 is not the one its
producing job recorded; an artifact zip whose sha256 is not the API digest; a
source run of another workflow path or id; a head SHA that is not on
nightly-next (or main); a fork head; a non-publishing event; an attempt
record for another attempt; an unknown branch; a missing or malformed digest
record; an artifact of another channel; a zip with extra members; a head
SHA that is only on a tag with the branch's name; a run that built an app but
has no prepare job; prepare jobs that disagree on publishing; a job from a newer
attempt; an API redirect (never followed with the token).
Skipped (exit 0, admitted=false): a failed source run, a superseded attempt
(before or during the downloads), a run that prepared no app, a run that does
not publish (fast build). Admitted: main, nightly-next and rc runs.
"""

from __future__ import annotations

import copy
import hashlib
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.parse
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "scripts" / "ci" / "nightly_sign_admit.py"
REPO = "manaflow-ai/cmux"
RUN_ID = 38867835181
ATTEMPT = 2
HEAD = "c" * 40
WORKFLOW_ID = 234270400


def zip_of(members: dict[str, bytes]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as archive:
        for name, data in members.items():
            archive.writestr(name, data)
    return buf.getvalue()


def scenario(branch: str = "main", variants: tuple[str, ...] = ("arm64", "universal"),
             publish: str = "true", fast: str = "false") -> dict:
    channel = "rc" if branch.startswith("rc/") else "nightly"
    run = {
        "id": RUN_ID,
        "run_attempt": ATTEMPT,
        "path": ".github/workflows/nightly.yml",
        "workflow_id": WORKFLOW_ID,
        "repository": {"full_name": REPO},
        "head_repository": {"full_name": REPO},
        "head_branch": branch,
        "head_sha": HEAD,
        "event": "push",
        "status": "completed",
        "conclusion": "success",
    }
    jobs = [
        {"id": 100, "name": "decide", "conclusion": "success", "run_id": RUN_ID, "head_sha": HEAD, "run_attempt": ATTEMPT},
        {"id": 101, "name": "build-nightly-app", "conclusion": "success" if variants else "skipped",
         "run_id": RUN_ID, "head_sha": HEAD, "run_attempt": ATTEMPT},
    ]
    annotations: dict[int, list] = {}
    artifacts = []
    blobs: dict[int, bytes] = {}
    tarballs: dict[str, bytes] = {}
    for index, variant in enumerate(variants):
        job_id = 200 + index
        artifact_id = 300 + index
        name = f"cmux-{channel}-prepared-app-{variant}-{HEAD[:7]}"
        tarball = f"prepared app {variant} {branch}".encode() * 1000
        tarballs[variant] = tarball
        blob = zip_of({"cmux-prepared-app.tar.gz": tarball})
        blobs[artifact_id] = blob
        jobs.append({"id": job_id, "name": f"prepare-nightly-variant ({variant})", "conclusion": "success",
                     "run_id": RUN_ID, "head_sha": HEAD, "run_attempt": ATTEMPT})
        annotations[job_id] = [
            {"annotation_level": "warning", "title": "Node.js 20 is deprecated", "message": "..."},
            {"annotation_level": "notice", "title": "nightly-prepared-app",
             "message": f"variant={variant} artifact={name} sha256={hashlib.sha256(tarball).hexdigest()}"
                        f" publish={publish} fast={fast}"},
        ]
        artifacts.append({
            "id": artifact_id,
            "name": name,
            "expired": False,
            "created_at": "2026-10-16T08:00:00Z",
            "size_in_bytes": len(blob),
            "digest": f"sha256:{hashlib.sha256(blob).hexdigest()}",
            "archive_download_url": None,  # filled by the server with its own address
            "workflow_run": {"id": RUN_ID, "head_sha": HEAD, "head_branch": branch},
        })
    return {
        "run": run,
        "latest_attempt": ATTEMPT,
        "workflow": {"id": WORKFLOW_ID, "path": ".github/workflows/nightly.yml"},
        # compare/<base>...<head> status, keyed "base...head". The tool must
        # compare against the full branch ref; a bare name can resolve to a tag.
        "compare": {f"{HEAD}...refs/heads/{branch}": "ahead"},
        "jobs": jobs,
        "annotations": annotations,
        "artifacts": artifacts,
        "blobs": blobs,
        "tarballs": tarballs,
    }


class FakeGitHub:
    def __init__(self, data: dict) -> None:
        self.data = data
        self.requests: list[tuple[str, bool]] = []
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args) -> None:  # noqa: D102
                pass

            def do_GET(self) -> None:  # noqa: N802
                fake.requests.append((self.path, "Authorization" in self.headers))
                parsed = urllib.parse.urlsplit(self.path)
                query = urllib.parse.parse_qs(parsed.query)
                status, body, headers = fake.route(urllib.parse.unquote(parsed.path), query)
                self.send_response(status)
                for key, value in headers.items():
                    self.send_header(key, value)
                if isinstance(body, (dict, list)):
                    body = json.dumps(body).encode()
                    self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def route(self, path: str, query: dict) -> tuple[int, object, dict]:
        d = self.data
        page = int((query.get("page") or ["1"])[0])
        repo = f"/repos/{REPO}"
        if not path.startswith(f"{repo}/") and not path.startswith("/blob/"):
            return 404, {"message": "Not Found"}, {}
        rest = path[len(repo):]
        run = d["run"]
        if rest == f"/actions/runs/{RUN_ID}/attempts/{ATTEMPT}":
            if d.get("redirect_attempt"):
                return 302, b"", {"Location": f"{self.base}/blob/elsewhere"}
            return 200, run, {}
        if rest.startswith(f"/actions/runs/{RUN_ID}/attempts/"):
            return 404, {"message": "Not Found"}, {}
        if rest == f"/actions/runs/{RUN_ID}":
            d["run_reads"] = d.get("run_reads", 0) + 1
            latest = d["latest_attempt"]
            # A new attempt that starts while the tool downloads.
            if d.get("new_attempt_after_reads") and d["run_reads"] > d["new_attempt_after_reads"]:
                latest += 1
            return 200, {**run, "run_attempt": latest}, {}
        if rest == "/actions/workflows/nightly.yml":
            return 200, d["workflow"], {}
        if rest.startswith("/compare/"):
            key = rest[len("/compare/"):]
            status = d["compare"].get(key)
            if status is None:
                return 404, {"message": "No common ancestor"}, {}
            return 200, {"status": status, "ahead_by": 3 if status == "ahead" else 0, "commits": []}, {}
        if rest == f"/actions/runs/{RUN_ID}/jobs":
            assert query.get("filter") == ["latest"], query
            return 200, {"total_count": len(d["jobs"]), "jobs": d["jobs"] if page == 1 else []}, {}
        if rest.startswith("/check-runs/") and rest.endswith("/annotations"):
            job_id = int(rest.split("/")[2])
            return 200, d["annotations"].get(job_id, []) if page == 1 else [], {}
        if rest == f"/actions/runs/{RUN_ID}/artifacts":
            name = (query.get("name") or [None])[0]
            listed = [
                {**a, "archive_download_url": a["archive_download_url"]
                 or f"{self.base}{repo}/actions/artifacts/{a['id']}/zip"}
                for a in d["artifacts"] if name is None or a["name"] == name
            ]
            return 200, {"total_count": len(listed), "artifacts": listed if page == 1 else []}, {}
        if rest.startswith("/actions/artifacts/") and rest.endswith("/zip"):
            artifact_id = int(rest.split("/")[3])
            return 302, b"", {"Location": f"{self.base}/blob/{artifact_id}"}
        if path == "/blob/elsewhere":
            return 200, {"message": "followed"}, {}
        if path.startswith("/blob/"):
            return 200, d["blobs"][int(path.split("/")[2])], {}
        return 404, {"message": f"unexpected {path}"}, {}


class AdmitCase(unittest.TestCase):
    def run_tool(self, data: dict, *, run_id: str = str(RUN_ID), attempt: str = str(ATTEMPT)) -> dict:
        fake = FakeGitHub(data)
        self.addCleanup(fake.close)
        tmp = Path(tempfile.mkdtemp(prefix="nightly-sign-admit-"))
        output = tmp / "github-output"
        output.write_text("", encoding="utf-8")
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "GH_TOKEN": "fake-token",
            "GITHUB_API_URL": fake.base,
            "GITHUB_OUTPUT": str(output),
            "GITHUB_STEP_SUMMARY": str(tmp / "summary.md"),
        }
        proc = subprocess.run(
            [sys.executable, "-I", str(TOOL), "--repo", REPO, "--source-run-id", run_id,
             "--source-run-attempt", attempt, "--out", str(tmp / "out")],
            env=env, capture_output=True, text=True, timeout=120, check=False,
        )
        outputs = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines() if "=" in line)
        return {"code": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr, "outputs": outputs,
                "out": tmp / "out", "requests": fake.requests}

    def assert_refused(self, result: dict, reason: str) -> None:
        self.assertEqual(result["code"], 1, result["stdout"] + result["stderr"])
        self.assertEqual(result["outputs"].get("admitted"), "false")
        self.assertIn("refused:", result["stderr"])
        self.assertIn(reason, result["stderr"])
        admission = json.loads((result["out"] / "admission.json").read_text(encoding="utf-8"))
        self.assertEqual(admission["verdict"], "refused")

    def assert_skipped(self, result: dict, reason: str) -> None:
        self.assertEqual(result["code"], 0, result["stdout"] + result["stderr"])
        self.assertEqual(result["outputs"].get("admitted"), "false")
        self.assertIn(f"skipped: ", result["stdout"])
        self.assertIn(reason, result["stdout"])
        self.assertFalse(list(result["out"].glob("*/cmux-prepared-app.tar.gz")))

    def assert_admitted(self, result: dict, data: dict, channel: str, track: str) -> None:
        self.assertEqual(result["code"], 0, result["stdout"] + result["stderr"])
        outputs = result["outputs"]
        self.assertEqual(outputs.get("admitted"), "true")
        self.assertEqual(outputs.get("channel"), channel)
        self.assertEqual(outputs.get("track"), track)
        self.assertEqual(outputs.get("source_head_sha"), HEAD)
        self.assertEqual(json.loads(outputs["variants"]), [v for v in ("universal", "arm64", "x86_64") if v in data["tarballs"]])
        for variant, tarball in data["tarballs"].items():
            self.assertEqual((result["out"] / variant / "cmux-prepared-app.tar.gz").read_bytes(), tarball)
        self.assertFalse(list(result["out"].glob("*/artifact.zip")), "the artifact zip is removed after the check")
        blob_requests = [auth for path, auth in result["requests"] if path.startswith("/blob/")]
        self.assertEqual(len(blob_requests), len(data["tarballs"]))
        self.assertFalse(any(blob_requests), "the token must not go to the blob host")

    # ---------------------------------------------------------------- admitted

    def test_main_run_is_admitted(self) -> None:
        data = scenario("main")
        self.assert_admitted(self.run_tool(data), data, "nightly", "nightly")

    def test_nightly_next_run_on_the_tip_is_admitted(self) -> None:
        data = scenario("nightly-next", ("arm64",))
        data["compare"] = {f"{HEAD}...refs/heads/nightly-next": "identical"}
        self.assert_admitted(self.run_tool(data), data, "nightly", "nightly-next")

    def test_nightly_next_run_behind_the_tip_is_admitted(self) -> None:
        data = scenario("nightly-next", ("arm64",))
        data["compare"] = {f"{HEAD}...refs/heads/nightly-next": "ahead"}
        self.assert_admitted(self.run_tool(data), data, "nightly", "nightly-next")

    def test_rc_run_is_admitted_on_the_rc_channel(self) -> None:
        data = scenario("rc/0.70", ("arm64", "x86_64", "universal"))
        self.assert_admitted(self.run_tool(data), data, "rc", "rc")

    # ---------------------------------------------------------------- refused: digests

    def test_tarball_with_another_sha256_than_its_producer_recorded_is_refused(self) -> None:
        data = scenario("main")
        # The artifact the API serves is internally consistent (its zip digest
        # matches), but its tarball is not the one the prepare job recorded.
        tampered = b"another app" * 1000
        blob = zip_of({"cmux-prepared-app.tar.gz": tampered})
        data["blobs"][300] = blob
        data["artifacts"][0]["digest"] = f"sha256:{hashlib.sha256(blob).hexdigest()}"
        data["artifacts"][0]["size_in_bytes"] = len(blob)
        result = self.run_tool(data)
        self.assert_refused(result, "the sha256 its producing job recorded")
        self.assertFalse((result["out"] / "arm64" / "cmux-prepared-app.tar.gz").exists())

    def test_zip_that_does_not_match_the_api_digest_is_refused(self) -> None:
        data = scenario("main")
        data["artifacts"][0]["digest"] = "sha256:" + "0" * 64
        self.assert_refused(self.run_tool(data), "is not the recorded sha256:")

    def test_artifact_without_an_api_digest_is_refused(self) -> None:
        data = scenario("main")
        data["artifacts"][0]["digest"] = None
        self.assert_refused(self.run_tool(data), "has no recorded sha256 digest")

    def test_producer_without_a_digest_record_is_refused(self) -> None:
        data = scenario("main")
        data["annotations"][200] = [a for a in data["annotations"][200] if a["title"] != "nightly-prepared-app"]
        self.assert_refused(self.run_tool(data), "recorded 0 prepared app digests")

    def test_a_no_op_fallback_leg_takes_the_primary_legs_digest(self) -> None:
        # After a successful primary the fallback leg (prepare-nightly-variant) reuses the
        # primary's upload and records no digest; the primary leg's record is the producer's.
        data = scenario("main")
        record = data["annotations"][200][1]
        data["annotations"][200] = [a for a in data["annotations"][200] if a["title"] != "nightly-prepared-app"]
        data["jobs"].append({"id": 290, "name": "prepare-nightly-variant-primary (arm64)", "conclusion": "success",
                             "run_id": RUN_ID, "head_sha": HEAD, "run_attempt": ATTEMPT})
        data["annotations"][290] = [copy.deepcopy(record)]
        result = self.run_tool(data)
        self.assert_admitted(result, data, "nightly", "nightly")
        admission = json.loads((result["out"] / "admission.json").read_text(encoding="utf-8"))
        self.assertIn({"variant": "arm64", "job_id": 290},
                      [{"variant": v["variant"], "job_id": v["job_id"]} for v in admission["variants"]])

    def test_a_failed_primary_leg_lends_no_digest(self) -> None:
        data = scenario("main")
        record = data["annotations"][200][1]
        data["annotations"][200] = [a for a in data["annotations"][200] if a["title"] != "nightly-prepared-app"]
        data["jobs"].append({"id": 290, "name": "prepare-nightly-variant-primary (arm64)", "conclusion": "failure",
                             "run_id": RUN_ID, "head_sha": HEAD, "run_attempt": ATTEMPT})
        data["annotations"][290] = [copy.deepcopy(record)]
        self.assert_refused(self.run_tool(data), "recorded 0 prepared app digests")

    def test_producer_with_two_digest_records_is_refused(self) -> None:
        data = scenario("main")
        data["annotations"][200].append(copy.deepcopy(data["annotations"][200][1]))
        self.assert_refused(self.run_tool(data), "recorded 2 prepared app digests")

    def test_digest_record_for_another_variant_is_refused(self) -> None:
        data = scenario("main")
        record = data["annotations"][200][1]
        record["message"] = record["message"].replace("variant=arm64", "variant=universal")
        self.assert_refused(self.run_tool(data), "recorded a digest for universal")

    def test_digest_record_naming_another_channel_artifact_is_refused(self) -> None:
        data = scenario("main")
        record = data["annotations"][200][1]
        record["message"] = record["message"].replace("cmux-nightly-", "cmux-rc-")
        self.assert_refused(self.run_tool(data), "not a nightly arm64 prepared app")

    def test_artifact_of_another_run_is_refused(self) -> None:
        data = scenario("main")
        data["artifacts"][0]["workflow_run"]["id"] = RUN_ID + 1
        self.assert_refused(self.run_tool(data), "is not in the source run")

    def test_zip_with_extra_members_is_refused(self) -> None:
        data = scenario("main")
        tarball = data["tarballs"]["arm64"]
        blob = zip_of({"cmux-prepared-app.tar.gz": tarball, "extra.sh": b"#!/bin/sh\n"})
        data["blobs"][300] = blob
        data["artifacts"][0]["digest"] = f"sha256:{hashlib.sha256(blob).hexdigest()}"
        data["artifacts"][0]["size_in_bytes"] = len(blob)
        self.assert_refused(self.run_tool(data), "not only cmux-prepared-app.tar.gz")

    # ---------------------------------------------------------------- refused: identity

    def test_run_of_another_workflow_path_is_refused(self) -> None:
        data = scenario("main")
        data["run"]["path"] = ".github/workflows/nightly-copy.yml"
        result = self.run_tool(data)
        self.assert_refused(result, "not .github/workflows/nightly.yml")
        self.assertFalse(any(path.startswith("/blob/") for path, _ in result["requests"]))

    def test_run_of_another_workflow_id_with_the_same_path_is_refused(self) -> None:
        data = scenario("main")
        data["run"]["workflow_id"] = WORKFLOW_ID + 7
        self.assert_refused(self.run_tool(data), f"is not .github/workflows/nightly.yml ({WORKFLOW_ID})")

    def test_head_sha_not_on_nightly_next_is_refused(self) -> None:
        for status in ("diverged", "behind"):
            with self.subTest(status=status):
                data = scenario("nightly-next", ("arm64",))
                data["compare"] = {f"{HEAD}...refs/heads/nightly-next": status}
                result = self.run_tool(data)
                self.assert_refused(result, f"is not on nightly-next (compare status '{status}')")
                self.assertFalse(any(path.startswith("/blob/") for path, _ in result["requests"]))

    def test_head_sha_unknown_to_the_repository_is_refused(self) -> None:
        data = scenario("nightly-next", ("arm64",))
        data["compare"] = {}
        self.assert_refused(self.run_tool(data), "answered HTTP 404")

    def test_head_sha_not_on_main_is_refused(self) -> None:
        data = scenario("main")
        data["compare"] = {f"{HEAD}...refs/heads/main": "diverged"}
        self.assert_refused(self.run_tool(data), "is not on main")

    def test_fork_head_is_refused(self) -> None:
        data = scenario("main")
        data["run"]["head_repository"] = {"full_name": "someone/cmux"}
        self.assert_refused(self.run_tool(data), "head is in another repository")

    def test_non_publishing_event_is_refused(self) -> None:
        data = scenario("main")
        data["run"]["event"] = "pull_request"
        self.assert_refused(self.run_tool(data), "event 'pull_request' cannot publish")

    def test_attempt_record_for_another_attempt_is_refused(self) -> None:
        data = scenario("main")
        data["run"]["run_attempt"] = 1
        self.assert_refused(self.run_tool(data), "not 38867835181 attempt 2")

    def test_attempt_that_does_not_exist_is_refused(self) -> None:
        self.assert_refused(self.run_tool(scenario("main"), attempt="3"), "answered HTTP 404")

    def test_unpublished_branch_is_refused(self) -> None:
        data = scenario("feature/x")
        self.assert_refused(self.run_tool(data), "does not publish a signed build")

    def test_prepare_job_of_an_unknown_variant_is_refused(self) -> None:
        data = scenario("main")
        data["jobs"][2]["name"] = "prepare-nightly-variant (ppc)"
        self.assert_refused(self.run_tool(data), "unknown variant 'ppc'")

    def test_head_sha_on_a_same_named_tag_but_not_on_the_branch_is_refused(self) -> None:
        data = scenario("nightly-next", ("arm64",))
        # The tag nightly-next contains the SHA; the branch nightly-next does not.
        data["compare"] = {f"{HEAD}...nightly-next": "ahead", f"{HEAD}...refs/tags/nightly-next": "ahead",
                           f"{HEAD}...refs/heads/nightly-next": "diverged"}
        self.assert_refused(self.run_tool(data), "is not on nightly-next (compare status 'diverged')")

    def test_run_that_built_an_app_without_a_prepare_job_is_refused(self) -> None:
        data = scenario("main", ())
        data["jobs"][1]["conclusion"] = "success"
        self.assert_refused(self.run_tool(data), "but has no prepare-nightly-variant job")

    def test_build_only_run_with_skipped_prepare_jobs_is_skipped(self) -> None:
        data = scenario("main", ())
        data["jobs"][1]["conclusion"] = "success"
        # GitHub does not expand a matrix job its `if:` skips: one job, bare name
        # (run 38902061362).
        data["jobs"].append({"id": 400, "name": "prepare-nightly-variant", "conclusion": "skipped",
                             "run_id": RUN_ID, "head_sha": HEAD, "run_attempt": ATTEMPT})
        self.assert_skipped(self.run_tool(data), "prepared no app")

    def test_prepare_jobs_that_disagree_on_publishing_are_refused(self) -> None:
        data = scenario("main")
        record = data["annotations"][201][1]
        record["message"] = record["message"].replace("publish=true", "publish=false")
        self.assert_refused(self.run_tool(data), "disagree on whether the run publishes")

    def test_job_from_a_newer_attempt_is_refused(self) -> None:
        data = scenario("main")
        data["jobs"][2]["run_attempt"] = ATTEMPT + 1
        self.assert_refused(self.run_tool(data), f"is from attempt {ATTEMPT + 1}")

    def test_api_redirect_is_not_followed_with_the_token(self) -> None:
        data = scenario("main")
        data["redirect_attempt"] = True
        result = self.run_tool(data)
        self.assert_refused(result, "answered HTTP 302")
        self.assertFalse(any(path == "/blob/elsewhere" for path, _ in result["requests"]))

    def test_invalid_run_id_is_refused_without_api_calls(self) -> None:
        result = self.run_tool(scenario("main"), run_id="1 2")
        self.assert_refused(result, "invalid source run id")
        self.assertEqual(result["requests"], [])

    # ---------------------------------------------------------------- skipped

    def test_failed_source_run_is_skipped(self) -> None:
        data = scenario("main")
        data["run"]["conclusion"] = "failure"
        self.assert_skipped(self.run_tool(data), "concluded 'failure'")

    def test_superseded_attempt_is_skipped(self) -> None:
        data = scenario("main")
        data["latest_attempt"] = ATTEMPT + 1
        self.assert_skipped(self.run_tool(data), "newer attempt (3)")

    def test_fast_build_is_skipped(self) -> None:
        self.assert_skipped(self.run_tool(scenario("main", ("arm64",), fast="true")), "does not publish")

    def test_run_that_does_not_publish_is_skipped(self) -> None:
        self.assert_skipped(self.run_tool(scenario("main", publish="false")), "does not publish")

    def test_attempt_superseded_during_downloads_is_skipped(self) -> None:
        data = scenario("main")
        data["new_attempt_after_reads"] = 1
        self.assert_skipped(self.run_tool(data), "newer attempt (3) during admission")

    def test_run_that_prepared_no_app_is_skipped(self) -> None:
        data = scenario("main", ())
        self.assert_skipped(self.run_tool(data), "prepared no app")


if __name__ == "__main__":
    unittest.main(verbosity=2)
