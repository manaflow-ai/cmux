import copy
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
import shutil
import sys
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/ci/app_host_layer_transport.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("transport", SCRIPT)
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)


def zipped(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        for name, data in files.items():
            archive.writestr(name, data)
    return output.getvalue()


class Provider:
    def __init__(self):
        self.run = {"id": 123, "run_attempt": 2, "head_sha": "a" * 40,
                    "path": ".github/workflows/ci.yml", "event": "workflow_dispatch",
                    "head_repository": {"full_name": "org/repo"}}
        self.attempt = {"id": 123, "run_attempt": 2, "run_started_at": "2026-09-20T12:00:00Z"}
        self.artifacts = {}
        self.data = {}
        self.downloaded = []

    def register(self, ident, files):
        data = zipped(files)
        self.data[ident] = data
        self.artifacts[ident] = {"id": ident, "expired": False, "expires_at": "2099-01-01T00:00:00Z",
                                 "created_at": "2026-09-20T12:01:00Z", "workflow_run": {"id": 123},
                                 "size_in_bytes": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest()}
        return {"artifact_id": ident, "artifact_digest": self.artifacts[ident]["digest"]}

    def get(self, path):
        if path == "actions/runs/123":
            return copy.deepcopy(self.run)
        if path == "actions/runs/123/attempts/2":
            return copy.deepcopy(self.attempt)
        if path.startswith("actions/artifacts/"):
            return copy.deepcopy(self.artifacts[int(path.rsplit("/", 1)[1])])
        raise AssertionError(f"unexpected endpoint: {path}")

    def download(self, ident, path, limit):
        self.downloaded.append(ident)
        if len(self.data[ident]) > limit:
            raise ValueError("stream limit exceeded")
        path.write_bytes(self.data[ident])


class LayerTransportTests(unittest.TestCase):
    def setUp(self):
        self.output = io.StringIO()
        capture = contextlib.redirect_stdout(self.output)
        capture.__enter__()
        self.addCleanup(capture.__exit__, None, None, None)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.api = Provider()
        self.identity = {"source_sha": "a" * 40, "workflow_run_id": "123", "workflow_run_attempt": "2",
                         "toolchain": {"xcode": "26.3", "architecture": "arm64", "developer": "/Xcode"}}
        self.expected = t.producer("org/repo", self.identity, "a" * 40)
        self.manifest = {"schema": "cmux.app-host-layers", "version": 1, "profile": "app-host-full",
                         "identity": self.identity, "required_layers": list(t.NAMES), "directories": [], "layers": []}
        receipts = []
        for ident, name in enumerate(t.NAMES, 10):
            data = (name + " immutable archive").encode()
            archive = name + ".aar"
            (self.root / archive).write_bytes(data)
            self.manifest["layers"].append({"name": name, "archive": archive,
                                            "sha256": hashlib.sha256(data).hexdigest(), "size": len(data), "entries": []})
            receipts.append({"name": name} | self.api.register(ident, {archive: data}))
        (self.root / t.MANIFEST).write_text(json.dumps(self.manifest))
        t.publish_index(self.api, self.root, receipts, self.identity, self.expected)
        self.index = json.loads((self.root / t.INDEX).read_text())
        self.reference = self.index_artifact()
        self.destination = self.root / "consumer"
        self.restores = []

    def index_artifact(self, extras=None):
        files = {t.INDEX: json.dumps(self.index).encode(), t.MANIFEST: (self.root / t.MANIFEST).read_bytes()}
        files.update(extras or {})
        return self.api.register(50, files)

    def assemble(self, manifest, destination, identity):
        self.restores.append(identity)
        self.assertEqual(identity, self.identity)
        for name in t.NAMES:
            self.assertEqual((manifest.parent / (name + ".aar")).read_bytes(), (self.root / (name + ".aar")).read_bytes())
        self.assertFalse(destination.exists())
        (destination / "Build/Products").mkdir(parents=True)
        (destination / "Build/Products/complete").write_text("all four verified")

    def restore(self, callback=None):
        t.restore_remote(self.api, self.reference, self.identity, self.expected,
                         self.destination, callback or self.assemble)

    def test_oversized_compressed_canonical_manifest_is_rejected_before_assembly(self):
        data = json.dumps(self.manifest).encode() + b" " * t.MAX_INDEX
        self.index["manifest"].update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(t.INDEX, json.dumps(self.index))
            archive.writestr(t.MANIFEST, data)
        self.api.data[50] = output.getvalue()
        self.api.artifacts[50].update(size_in_bytes=len(output.getvalue()), digest="sha256:" + hashlib.sha256(output.getvalue()).hexdigest())
        self.reference["artifact_digest"] = self.api.artifacts[50]["digest"]
        with self.assertRaisesRegex(ValueError, "manifest exceeds limit"):
            self.restore()
        self.assertFalse(self.destination.exists())
        self.assertEqual(self.api.downloaded, [50])

    def test_malformed_index_cli_falls_back_without_adopting_destination(self):
        # Test the CLI fallback boundary, including ZIP reader exceptions that
        # are raised before the later exact-member extraction checks.
        for mutation in ("array", "encrypted", "unsupported-compression"):
            with self.subTest(mutation=mutation):
                self.index = [] if mutation == "array" else json.loads((self.root / t.INDEX).read_text())
                self.reference = self.index_artifact()
                if mutation != "array":
                    data = bytearray(self.api.data[50])
                    local = data.index(b"PK\x03\x04")
                    central = data.index(b"PK\x01\x02")
                    if mutation == "encrypted":
                        data[local + 6] |= 1
                        data[central + 8] |= 1
                    else:
                        data[local + 8:local + 10] = (99).to_bytes(2, "little")
                        data[central + 10:central + 12] = (99).to_bytes(2, "little")
                    self.api.data[50] = bytes(data)
                    self.api.artifacts[50]["digest"] = "sha256:" + hashlib.sha256(data).hexdigest()
                    self.reference["artifact_digest"] = self.api.artifacts[50]["digest"]
                output = self.root / (mutation + ".output")
                envfile = self.root / (mutation + ".env")
                with mock.patch.object(t, "current_identity", return_value=self.identity), mock.patch.object(t, "GitHub", return_value=self.api), \
                        mock.patch.dict(t.os.environ, {"GITHUB_REPOSITORY": "org/repo", "CMUX_RUN_HEAD_SHA": "a" * 40,
                                                     "GITHUB_OUTPUT": str(output), "GITHUB_ENV": str(envfile)}), \
                        mock.patch.object(sys, "argv", [str(SCRIPT), "restore", str(self.destination), "--index-id", "50", "--index-digest", self.reference["artifact_digest"]]):
                    t.main()
                self.assertEqual(output.read_text(), "hit=false\n")
                self.assertFalse(envfile.exists())
                self.assertFalse(self.destination.exists())

    def test_roundtrip_downloads_exact_pinned_ids_and_all_four_layers(self):
        self.restore()
        self.assertEqual(self.api.downloaded, [50, 10, 11, 12, 13])
        self.assertEqual((self.destination / "Build/Products/complete").read_text(), "all four verified")
        transfers = [json.loads(line.split(" ", 1)[1]) for line in self.output.getvalue().splitlines()
                     if line.startswith("CMUX_APP_HOST_LAYER_TRANSFER ")]
        self.assertEqual([row["layer"] for row in transfers], ["index", *t.NAMES])
        self.assertTrue(all(row["result"] == "success" and row["expected_zip_bytes"] > 0 for row in transfers))

    def test_expired_wrong_origin_or_prior_attempt_artifact_is_rejected(self):
        original = copy.deepcopy(self.api.artifacts[10])
        mutations = [{"expired": True}, {"workflow_run": {"id": 999}},
                     {"created_at": "2026-09-20T11:59:59Z"}, {"expires_at": "2020-01-01T00:00:00Z"},
                     {"digest": "sha256:" + "f" * 64}, {"size_in_bytes": original["size_in_bytes"] + 1}]
        for change in mutations:
            with self.subTest(change=change):
                self.api.artifacts[10] = original | change
                with self.assertRaises((ValueError, TypeError)):
                    self.restore()
                self.assertFalse(self.destination.exists())
        self.assertEqual(self.restores, [])

    def test_restarted_or_foreign_producer_is_rejected_before_download(self):
        original = copy.deepcopy(self.api.run)
        for change in ({"run_attempt": 3}, {"head_sha": "b" * 40},
                       {"head_repository": {"full_name": "fork/repo"}}, {"event": "push"}):
            with self.subTest(change=change):
                self.api.run = original | change
                with self.assertRaises(ValueError):
                    self.restore()
        self.assertEqual(self.api.downloaded, [])

    def test_provider_zip_corruption_is_rejected_before_assembly(self):
        data = self.api.data[10]
        self.api.data[10] = data[:-1] + bytes([data[-1] ^ 1])
        with self.assertRaises(ValueError):
            self.restore()
        self.assertEqual(self.restores, [])
        failed = json.loads(self.output.getvalue().splitlines()[-1].split(" ", 1)[1])
        self.assertEqual((failed["layer"], failed["artifact_id"], failed["result"]), ("app-cli", 10, "failure"))
        self.assertIn("elapsed_seconds", failed)

    def test_valid_provider_digest_does_not_replace_inner_archive_digest(self):
        reference = self.api.register(10, {"app-cli.aar": b"wrong inner contents"})
        self.index["layers"][0].update(reference, artifact_size=self.api.artifacts[10]["size_in_bytes"])
        self.reference = self.index_artifact()
        with self.assertRaises(ValueError):
            self.restore()
        self.assertEqual(self.restores, [])

    def test_missing_duplicate_or_partial_layers_are_rejected(self):
        original = copy.deepcopy(self.index)
        variants = [original["layers"][:-1], original["layers"][:-1] + [original["layers"][0]]]
        for layers in variants:
            with self.subTest(layers=layers):
                self.index = original | {"layers": layers}
                self.reference = self.index_artifact()
                with self.assertRaises(ValueError):
                    self.restore()
        self.assertEqual(self.restores, [])

    def test_index_identity_mismatch_cannot_select_other_source(self):
        self.index["identity"] = self.identity | {"source_sha": "b" * 40}
        self.reference = self.index_artifact()
        with self.assertRaises(ValueError):
            self.restore()
        self.assertEqual(self.restores, [])

    def test_index_extra_member_never_escapes_staging(self):
        self.reference = self.index_artifact({"../escape": b"bad"})
        with self.assertRaises(ValueError):
            self.restore()
        self.assertFalse((self.root / "escape").exists())

    def test_nonempty_consumer_is_preserved(self):
        self.destination.mkdir()
        (self.destination / "sentinel").write_text("preserve")
        with self.assertRaises(ValueError):
            self.restore()
        self.assertEqual((self.destination / "sentinel").read_text(), "preserve")
        self.assertEqual(self.api.downloaded, [])

    def test_assembler_failure_leaves_consumer_absent_for_legacy_fallback(self):
        def fail(manifest, destination, identity):
            (manifest.parent / "partial").write_text("must not publish")
            raise ValueError("local archive validation failed")
        with self.assertRaises(ValueError):
            self.restore(fail)
        self.assertFalse(self.destination.exists())
        self.assertFalse(list(self.root.glob("app-host-layer-fetch-*")))
        failed = json.loads(self.output.getvalue().splitlines()[-1].split(" ", 1)[1])
        self.assertEqual(failed["result"], "failure")

    def test_even_empty_consumer_is_not_adopted(self):
        self.destination.mkdir()
        with self.assertRaises(ValueError):
            self.restore()
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_inner_manifest_is_digest_pinned(self):
        (self.root / t.MANIFEST).write_text(json.dumps(self.manifest) + " ")
        self.reference = self.index_artifact()
        with self.assertRaises(ValueError):
            self.restore()
        self.assertEqual(self.restores, [])

    @unittest.skipUnless(shutil.which("aa"), "Apple Archive requires macOS")
    def test_real_archive_transport_and_assembly_preserve_complete_tree(self):
        import app_host_layered_products as local
        derived = self.root / "real-producer"
        products = derived / "Build/Products"
        files = {"Debug/cmux DEV.app/Contents/MacOS/cmux": b"app",
                 "Debug/cmux DEV.app/Contents/_CodeSignature/CodeResources": b"sealed entries",
                 "Debug/cmux DEV.app/Contents/PlugIns/cmuxTests.xctest/test": b"tests",
                 "Debug/F.framework/Versions/A/F": b"runtime",
                 "Debug/helper.o": b"diagnostics", "Debug/cmux": b"cli", "cmux-unit.xctestrun": b"manifest"}
        for name, value in files.items():
            path = products / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(value)
        (products / "Debug/cmux").chmod(0o755)
        (products / "Debug/F.framework/Versions/Current").symlink_to("A")
        output = self.root / "real-layers"
        local.pack(derived, output, self.identity)
        receipts = [{"name": name} | self.api.register(ident, {name + ".aar": (output / (name + ".aar")).read_bytes()})
                    for ident, name in enumerate(t.NAMES, 10)]
        t.publish_index(self.api, output, receipts, self.identity, self.expected)
        self.root = output
        self.index = json.loads((output / t.INDEX).read_text())
        self.reference = self.index_artifact()
        self.restore(local.restore)
        self.assertEqual(local.inventory(derived), local.inventory(self.destination))

    def test_warning_log_restores_real_bytes_and_rejects_changed_evidence(self):
        import reuse_app_host_products as reuse
        products = self.destination / "Build/Products"
        products.mkdir(parents=True)
        log = b"source.swift:1:1: warning: preserve this warning\n"
        (products / reuse.BUILD_LOG).write_bytes(log)
        (products / reuse.RECEIPT).write_text(json.dumps({"build_log_sha256": hashlib.sha256(log).hexdigest()}))
        t.restore_warning_log(self.destination)
        self.assertEqual((self.destination / reuse.BUILD_LOG).read_bytes(), log)
        (self.destination / reuse.BUILD_LOG).unlink()
        (products / reuse.BUILD_LOG).write_bytes(b"Build succeeded without warnings\n")
        with self.assertRaises(ValueError):
            t.restore_warning_log(self.destination)
        self.assertFalse((self.destination / reuse.BUILD_LOG).exists())


if __name__ == "__main__":
    unittest.main()
