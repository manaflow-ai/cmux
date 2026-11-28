#!/usr/bin/env python3
"""Exercise the R2 transport and fallback with real ZIP files, without network."""
import hashlib
import importlib.util
import io
import json
import os
import stat
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("r2_artifact", ROOT / "scripts/ci/restore-r2-artifact.py")
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)
measurement_spec = importlib.util.spec_from_file_location(
    "r2_artifact_measurement", ROOT / "scripts/ci/measure-r2-artifact-run.py")
measurement = importlib.util.module_from_spec(measurement_spec)
measurement_spec.loader.exec_module(measurement)


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.destination = Path(self.temp.name) / "products"
        self.zip = self.pack("app-host-products.aar", b"opaque archive with sealed warning log")
        self.calls = []
        self.wrong_run = False
        self.corrupt = False
        self.down = False
        self.expired = False
        self.wrong_digest = False
        self.api_failure = False
        self.identity_failure = False
        self.cache = "fill"
        self.receipt = {}

    def pack(self, name, body):
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w") as archive:
            archive.writestr(name, body)
        return out.getvalue()

    def metadata(self, artifact_id):
        self.calls.append(("metadata", artifact_id))
        if self.api_failure:
            raise subprocess.CalledProcessError(1, ["gh", "api"])
        digest = "f" * 64 if self.wrong_digest else hashlib.sha256(self.zip).hexdigest()
        return {"id": 123, "expired": self.expired, "size_in_bytes": len(self.zip),
                "digest": "sha256:" + digest,
                "workflow_run": {"id": 999 if self.wrong_run else 456}}

    def identity(self, work):
        self.calls.append(("identity", Path(work).name))
        if self.identity_failure:
            raise ValueError("OIDC unavailable")
        return "header.payload.signature"

    def download(self, url, target, size, identity, work):
        self.calls.append(("download", url))
        self.assertEqual(identity, "header.payload.signature")
        if self.down:
            raise TimeoutError("broker unavailable")
        target.write_bytes(b"0" * size if self.corrupt else self.zip)
        return {"cache": self.cache, "broker_wait_seconds": 0.125,
                "transfer_seconds": 0.5, "broker_total_seconds": 0.625,
                "downloaded_bytes": size}

    def restore(self, broker="https://broker.example", repository="manaflow-ai/cmux"):
        self.receipt = {}
        return transport.restore(broker, "123", "456", repository, self.destination,
                                 self.metadata, self.download, self.identity, self.receipt)

    def test_actions_oidc_identity_uses_fixed_issuer_and_secret_config(self):
        work = Path(self.temp.name) / "oidc"
        work.mkdir()
        seen = {}

        def fake_check_output(args, text, timeout):
            self.assertTrue(text)
            self.assertEqual(timeout, 15)
            self.assertNotIn("oidc-request-token", args)
            self.assertIn("--config", args)
            config = Path(args[args.index("--config") + 1])
            seen["mode"] = stat.S_IMODE(config.stat().st_mode)
            seen["config"] = config.read_text()
            seen["url"] = args[-1]
            return '{"value":"header.payload.signature"}'

        environment = {
            "ACTIONS_ID_TOKEN_REQUEST_URL":
                "https://pipelines.actions.githubusercontent.com/oidc?api-version=2.0&audience=old",
            "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "oidc-request-token",
        }
        with patch.dict(os.environ, environment, clear=False), \
             patch.object(transport.subprocess, "check_output", fake_check_output):
            self.assertEqual(transport.actions_identity(work), "header.payload.signature")

        self.assertEqual(seen["mode"], 0o600)
        self.assertIn("Authorization: Bearer oidc-request-token", seen["config"])
        self.assertIn("audience=cmux-ci-artifacts", seen["url"])
        self.assertNotIn("audience=old", seen["url"])

        for host in [
            "pipelines.actions.githubusercontent.com",
            "pipelinesghubeus6.actions.githubusercontent.com",
        ]:
            with self.subTest(host=host), patch.dict(os.environ, {
                "ACTIONS_ID_TOKEN_REQUEST_URL": f"https://{host}/oidc?api-version=2.0",
                "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "oidc-request-token",
            }, clear=False), patch.object(transport.subprocess, "check_output", fake_check_output):
                self.assertEqual(transport.actions_identity(work), "header.payload.signature")

    def test_actions_oidc_identity_rejects_foreign_or_nonstandard_issuer(self):
        work = Path(self.temp.name) / "oidc-invalid"
        work.mkdir()
        for url in [
            "http://pipelines.actions.githubusercontent.com/oidc",
            "https://pipelines.actions.githubusercontent.com:8443/oidc",
            "https://attacker.example/oidc",
            "https://pipelines.actions.githubusercontent.com.attacker.example/oidc",
            "https://secret@pipelines.actions.githubusercontent.com/oidc",
        ]:
            with self.subTest(url=url), patch.dict(os.environ, {
                "ACTIONS_ID_TOKEN_REQUEST_URL": url,
                "ACTIONS_ID_TOKEN_REQUEST_TOKEN": "oidc-request-token",
            }, clear=False), patch.object(transport.subprocess, "check_output") as command:
                with self.assertRaises(ValueError):
                    transport.actions_identity(work)
                command.assert_not_called()

    def test_broker_download_keeps_identity_out_of_argv_and_reports_timing(self):
        work = Path(self.temp.name) / "broker"
        work.mkdir()
        target = work / "artifact.zip"
        seen = {}

        def fake_run(args, check, timeout, capture_output, text):
            self.assertTrue(check)
            self.assertEqual(timeout, 180)
            self.assertTrue(capture_output)
            self.assertTrue(text)
            self.assertNotIn("header.payload.signature", args)
            config = Path(args[args.index("--config") + 1])
            headers = Path(args[args.index("--dump-header") + 1])
            output = Path(args[args.index("--output") + 1])
            seen["mode"] = stat.S_IMODE(config.stat().st_mode)
            seen["config"] = config.read_text()
            headers.write_text("HTTP/1.1 200 OK\r\nX-Cmux-Artifact-Cache: hit\r\n\r\n")
            output.write_bytes(self.zip)
            return subprocess.CompletedProcess(args, 0,
                                               stdout=f"200 0.125 0.625 {len(self.zip)}", stderr="")

        with patch.object(transport.subprocess, "run", fake_run):
            record = transport.download("https://broker.example/artifact", target, len(self.zip),
                                        "header.payload.signature", work)

        self.assertEqual(seen["mode"], 0o600)
        self.assertIn("Authorization: Bearer header.payload.signature", seen["config"])
        self.assertEqual(record["cache"], "hit")
        self.assertEqual(record["broker_wait_seconds"], 0.125)
        self.assertEqual(record["transfer_seconds"], 0.5)
        self.assertEqual(record["downloaded_bytes"], len(self.zip))

    def test_worker_toolchain_only_runs_for_worker_owned_changes(self):
        workflow = (ROOT / ".github/workflows/ci-artifact-transport.yml").read_text()
        self.assertIn("Detect Worker changes", workflow)
        self.assertIn("workers/ci-artifacts", workflow)
        self.assertGreaterEqual(
            workflow.count("if: steps.worker.outputs.run == 'true'"),
            3,
        )
        self.assertIn("fetch-depth: 2", workflow)

    def test_disabled_does_no_network_work(self):
        self.assertFalse(self.restore(""))
        self.assertEqual(self.calls, [])

    def test_opaque_gzip_and_apple_archives_keep_all_bytes_for_existing_validator(self):
        for name in transport.ARCHIVES:
            with self.subTest(name=name):
                self.zip = self.pack(name, b"opaque archive with sealed warning log")
                self.assertTrue(self.restore())
                archive = self.destination / name
                self.assertEqual(archive.read_bytes(), b"opaque archive with sealed warning log")
                archive.unlink()
                self.destination.rmdir()

    def test_corrupt_or_unavailable_broker_falls_back_without_partial_products(self):
        for reason in ["corrupt", "down"]:
            with self.subTest(reason=reason):
                setattr(self, reason, True)
                self.assertFalse(self.restore())
                self.assertFalse(self.destination.exists())
                setattr(self, reason, False)


    def test_expiry_digest_auth_and_github_api_failures_fall_back(self):
        for flag in ["expired", "wrong_digest", "api_failure", "identity_failure"]:
            with self.subTest(flag=flag):
                setattr(self, flag, True)
                self.assertFalse(self.restore())
                self.assertEqual(self.receipt["transport"], "github")
                self.assertEqual(self.receipt["r2_result"], "miss")
                self.assertIn("fallback_reason", self.receipt)
                self.assertFalse(self.destination.exists())
                setattr(self, flag, False)

    def test_success_receipt_distinguishes_fill_and_hit_and_reports_transfer(self):
        for cache in ["fill", "hit"]:
            with self.subTest(cache=cache):
                self.cache = cache
                self.assertTrue(self.restore())
                self.assertEqual(self.receipt["transport"], "r2")
                self.assertEqual(self.receipt["r2_result"], cache)
                self.assertEqual(self.receipt["downloaded_bytes"], len(self.zip))
                self.assertEqual(self.receipt["broker_wait_seconds"], 0.125)
                self.assertEqual(self.receipt["transfer_seconds"], 0.5)
                self.assertIn("outer_restore_seconds", self.receipt)
                archive = next(self.destination.iterdir())
                archive.unlink()
                self.destination.rmdir()

    def test_provider_digest_valid_but_bad_zip_falls_back(self):
        self.zip = b"not a ZIP even though its provider digest matches"
        self.assertFalse(self.restore())
        self.assertFalse(self.destination.exists())

    def test_expected_provider_digest_must_match_metadata(self):
        expected = "sha256:" + hashlib.sha256(self.zip).hexdigest()
        self.assertTrue(transport.restore(
            "https://broker.example", "123", "456", "manaflow-ai/cmux",
            self.destination, self.metadata, self.download, self.identity,
            expected_provider_digest=expected,
        ))
        self.destination.joinpath("app-host-products.aar").unlink()
        self.destination.rmdir()
        self.assertFalse(transport.restore(
            "https://broker.example", "123", "456", "manaflow-ai/cmux",
            self.destination, self.metadata, self.download, self.identity,
            expected_provider_digest="sha256:" + "0" * 64,
        ))
        self.assertFalse(self.destination.exists())

    def test_other_run_or_repository_is_not_reused(self):
        self.wrong_run = True
        self.assertFalse(self.restore())
        self.assertEqual(len(self.calls), 1)
        self.calls.clear()
        self.assertFalse(self.restore(repository="someone/cmux"))
        self.assertEqual(self.calls, [])

    def test_no_tokens_or_insecure_origins_in_broker_configuration(self):
        for url in ["https://secret@broker.example", "http://broker.example", "https://broker.example?token=secret"]:
            self.assertFalse(self.restore(url))
        self.assertEqual(self.calls, [])

    def test_path_escape_and_symlink_members_are_rejected(self):
        self.zip = self.pack("../app-host-products.aar", b"bad")
        self.assertFalse(self.restore())
        self.assertFalse(self.destination.exists())
        member = zipfile.ZipInfo("app-host-products.aar")
        member.create_system = 3
        member.external_attr = 0o120777 << 16
        self.zip = self.pack(member, b"/outside")
        self.assertFalse(self.restore())
        self.assertFalse(self.destination.exists())

    def test_stale_products_are_not_overwritten_by_a_partial_hit(self):
        self.destination.mkdir()
        existing = self.destination / "owner"
        existing.write_text("untouched")
        self.assertFalse(self.restore())
        self.assertEqual(existing.read_text(), "untouched")
        self.assertEqual(list(self.destination.iterdir()), [existing])


class MeasurementTests(unittest.TestCase):
    def test_run_summary_reports_wall_runner_transport_and_byte_evidence(self):
        producer = {
            "id": 1,
            "name": "macOS compile admission",
            "started_at": "2026-09-21T10:00:00Z",
            "completed_at": "2026-09-21T10:10:00Z",
            "steps": [{"name": "Upload compiled app-host test product",
                       "completed_at": "2026-09-21T10:10:00Z"}],
        }
        jobs = [producer]
        records = {}
        for index in range(1, 7):
            job_id = 100 + index
            jobs.append({
                "id": job_id,
                "name": f"app-host unit tests ({index}/6)",
                "started_at": f"2026-09-21T10:{10 + index:02d}:00Z",
                "completed_at": f"2026-09-21T10:{15 + index:02d}:00Z",
                "conclusion": "success",
            })
            records[job_id] = [
                {"_marker": "CMUX_TEST_PRODUCT_TRANSFER", "transport": "github",
                 "artifact_id": "123", "archive_bytes": 90},
                {"_marker": "CMUX_R2_ARTIFACT_ATTEMPT", "fallback_reason": "RuntimeError"},
                {"_marker": "CMUX_TEST_PRODUCT_RESTORE", "route": "github",
                 "elapsed_seconds": 2.5},
            ]
        jobs.append({
            "id": 200,
            "name": "tests-build-and-lag",
            "started_at": "2026-09-21T10:25:00Z",
            "completed_at": "2026-09-21T10:30:00Z",
            "conclusion": "success",
        })
        records[200] = [
            {"_marker": "CMUX_TEST_PRODUCT_TRANSFER", "transport": "r2", "cache": "hit",
             "artifact_id": "123", "downloaded_bytes": 100},
            {"_marker": "CMUX_TEST_PRODUCT_RESTORE", "route": "r2", "r2_result": "hit",
             "elapsed_seconds": 2.0},
        ]

        with patch.object(measurement, "gh_json", return_value={"size_in_bytes": 100}):
            result = measurement.summarize(
                {"id": 999, "html_url": "https://example/run/999", "event": "workflow_dispatch",
                 "status": "completed", "conclusion": "success"},
                jobs, records)

        # Exercise collection too: API names acquired the caller prefix when
        # native jobs moved from ci.yml into its reusable macos workflow.
        prefixed_jobs = [{**job, "name": "macos / " + job["name"]} for job in jobs]
        run = {"id": 999, "html_url": "https://example/run/999", "event": "workflow_dispatch",
               "status": "completed", "conclusion": "success"}
        def api_response(path):
            return run if path == "actions/runs/999" else {"size_in_bytes": 100}
        def job_log(run_id, job_id):
            return "\n".join(record["_marker"] + " " + json.dumps(record) for record in records[job_id])
        with patch.object(measurement, "gh_json", side_effect=api_response), \
             patch.object(measurement, "jobs_for_run", return_value=prefixed_jobs), \
             patch.object(measurement, "log_for_job", side_effect=job_log) as logs:
            prefixed = measurement.collect(999)
        self.assertEqual(logs.call_count, 7)
        for key in ("complete_consumer_set", "consumer_count", "producer_to_last_consumer_seconds",
                    "aggregate_producer_and_consumer_runner_minutes", "transport_counts"):
            self.assertEqual(prefixed[key], result[key], key)
        self.assertEqual(measurement.job_name({"name": "unrelated / macOS compile admission"}),
                         "unrelated / macOS compile admission")

        self.assertTrue(result["complete_consumer_set"])
        self.assertEqual(result["consumer_count"], 7)
        self.assertEqual(result["producer_to_last_consumer_seconds"], 1800.0)
        self.assertEqual(result["artifact_ready_to_last_consumer_seconds"], 1200.0)
        self.assertEqual(result["aggregate_consumer_runner_minutes"], 35.0)
        self.assertEqual(result["aggregate_producer_and_consumer_runner_minutes"], 45.0)
        self.assertEqual(result["transport_counts"], {"r2": 1, "github": 6, "unknown": 0})
        self.assertEqual(result["cache_results"], {"hit": 1})
        self.assertEqual(result["fallback_reasons"], {"RuntimeError": 6})
        self.assertEqual(result["provider_artifact_bytes"], 100)
        self.assertEqual(result["observed_consumer_payload_bytes"], 640)

    def test_marker_parser_ignores_unrelated_and_malformed_lines(self):
        log = (
            'prefix CMUX_TEST_PRODUCT_TRANSFER {"transport":"r2","cache":"fill"}\n'
            "CMUX_TEST_PRODUCT_TRANSFER garbage\n"
            "other output\n"
        )
        self.assertEqual(measurement.marker_records(log), [{
            "transport": "r2", "cache": "fill", "_marker": "CMUX_TEST_PRODUCT_TRANSFER"
        }])


class RestoreReceiptTests(unittest.TestCase):
    def test_exit_receipt_preserves_provenance_and_original_status(self):
        script = (ROOT / "scripts/ci/restore-app-host-test-product.sh").read_text()
        # Execute the actual EXIT handler without performing a native restore.
        prefix = script.split("trap report_restore_measurement EXIT", 1)[0] + "trap report_restore_measurement EXIT\n"
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, "RUNNER_TEMP": directory,
                   "GITHUB_REPOSITORY": "manaflow-ai/cmux", "ARTIFACT_ID": "123",
                   "ARTIFACT_PROVIDER_DIGEST": "sha256:outer", "EXPECTED_SHA256": "inner",
                   "CMUX_PRODUCT_CONTRACT": "contract", "CMUX_PRODUCT_SOURCE_REVISION": "revision",
                   "CMUX_PRODUCT_PRODUCER_RUN_ID": "456", "CMUX_PRODUCT_PRODUCER_RUN_ATTEMPT": "2",
                   "CMUX_PEER_PRODUCT_HIT": "true", "CMUX_PEER_PRODUCT_BYTES": "789"}
            for status in (0, 23):
                result = subprocess.run(["bash", "-c", prefix + f"exit {status}\n"],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, status, result.stderr)
                records = [json.loads(line.split(" ", 1)[1]) for line in result.stdout.splitlines()
                           if line.startswith("CMUX_TEST_PRODUCT_RESTORE ")]
                self.assertEqual(len(records), 1, result.stdout)
                record = records[0]
                self.assertEqual(record["outcome"], "success" if status == 0 else "failure")
                self.assertEqual(record["source_revision"], "revision")
                self.assertEqual(record["producer_run_id"], 456)
                self.assertEqual(record["producer_run_attempt"], 2)
                self.assertEqual(record["provider_digest"], "sha256:outer")
                self.assertEqual(record["route"], "peer")
                self.assertEqual(record["peer_bytes_transferred"], 789)


if __name__ == "__main__":
    unittest.main()
