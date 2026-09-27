#!/usr/bin/env python3
"""The glaeda LAN peer source for compiled products: eligibility, the digest check, fallbacks and wiring."""

import hashlib
import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


cache = load("node_product_cache", ROOT / "scripts/ci/node_product_cache.py")
peer = load("peer_product_source", ROOT / "scripts/ci/peer_product_source.py")

# Stands in for glaeda-lan-fetch: `product SHA256 DEST`. FAKE_MODE picks the behaviour; FAKE_LOG records
# the arguments and the environment it saw.
FAKE_HELPER = """import json, os, sys, time
log = os.environ.get("FAKE_LOG") or os.path.join(os.path.dirname(sys.argv[0]), "log.json")
mode = open(os.path.join(os.path.dirname(sys.argv[0]), "mode")).read().strip()
json.dump({"argv": sys.argv[1:], "env": dict(os.environ)}, open(log, "w"))
verb, sha, dest = sys.argv[1:4]
payload = open(os.path.join(os.path.dirname(sys.argv[0]), "payload"), "rb").read()
if mode == "hit":
    open(dest, "wb").write(payload); print(json.dumps({"peer": "cmux13s-mac-mini", "source": "lan"})); sys.exit(0)
if mode == "wrong-bytes":
    open(dest, "wb").write(payload + b"tampered"); sys.exit(0)
if mode == "hardlinked":  # keeps a second name for the file it hands over
    open(dest, "wb").write(payload); os.link(dest, dest + ".kept"); sys.exit(0)
if mode == "claims-hit-without-file":
    sys.exit(0)
if mode == "slow":
    time.sleep(30)
sys.exit(3)
"""


class LanProductSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.payload = self._archive()
        self.identity = cache.Identity(
            repository="manaflow-ai/cmux", artifact_id=123, provider_digest="b" * 64,
            archive_digest=hashlib.sha256(self.payload).hexdigest(), product_contract="c" * 64,
            source_revision="a" * 40, producer_run_id=456,
        )
        self.helper_dir = base / "bin"
        self.helper_dir.mkdir()
        self.helper = self.helper_dir / "glaeda-lan-fetch"
        self.helper.write_text(f"#!{sys.executable}\n" + FAKE_HELPER)
        self.helper.chmod(0o755)
        (self.helper_dir / "payload").write_bytes(self.payload)
        self.mode("hit")
        self.destination = base / "job" / "app-host-products"

    def _archive(self):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
            data = b"compiled bytes" * 1000
            info = tarfile.TarInfo("Build/Products/Debug/cmux")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        return buffer.getvalue()

    def mode(self, value):
        (self.helper_dir / "mode").write_text(value)

    def fetch(self, **kwargs):
        return peer.lan_fetch_exact(self.identity, self.destination, self.helper, **kwargs)

    def seen(self):
        return json.loads((self.helper_dir / "log.json").read_text())

    # Eligibility: an owned runner, and a helper no job can rewrite or rename: the file and every
    # directory up to / root-owned and not group- or other-writable. lstat is stubbed so the chain can
    # be described without root.

    HELPER = Path("/Library/Application Support/glaeda/bin/glaeda-lan-fetch")

    def chain(self, **overrides):
        """lstat results for HELPER and its parents: root:wheel 0755, with (uid, mode) overrides by path."""
        entries = {}
        for part in [self.HELPER, *self.HELPER.parents]:
            kind = stat.S_IFREG if part == self.HELPER else stat.S_IFDIR
            entries[str(part)] = (0, kind | 0o755)
        for path, value in overrides.items():
            entries[path] = value
        return entries

    def eligible(self, entries, runner="cmux12s-mac-mini-glaeda-2", euid=501, writable=False):
        def fake_lstat(path):
            key = os.fspath(path)
            if key not in entries:
                raise FileNotFoundError(key)
            uid, mode = entries[key]
            return os.stat_result((mode, 0, 0, 1, uid, 0, 100, 0, 0, 0))
        with mock.patch.object(peer.os, "lstat", fake_lstat), \
                mock.patch.object(peer.os, "geteuid", return_value=euid), \
                mock.patch.object(peer.os, "access", return_value=writable):
            return peer.lan_helper({"RUNNER_NAME": runner}, self.HELPER)

    def test_a_root_owned_chain_is_accepted_on_an_owned_runner(self):
        self.assertEqual(peer.LAN_FETCH_HELPER, self.HELPER)
        self.assertEqual(self.eligible(self.chain()), self.HELPER)
        # /Library/Application Support is root:admin 0755 on macOS: the group does not matter, only root and no write bits.
        self.assertEqual(self.eligible(self.chain(**{"/Library/Application Support": (0, stat.S_IFDIR | 0o755)})), self.HELPER)

    def test_only_owned_runners_use_it(self):
        self.assertIsNone(self.eligible(self.chain(), runner="blacksmith-6vcpu-macos-15-abc"))
        self.assertIsNone(self.eligible(self.chain(), runner=""))
        self.assertIsNone(self.eligible(self.chain(), euid=0))  # a job running as root could replace anything

    def test_a_job_owned_or_writable_link_in_the_chain_is_rejected(self):
        bin_dir = "/Library/Application Support/glaeda/bin"
        rejected = {
            "job-owned parent": self.chain(**{bin_dir: (501, stat.S_IFDIR | 0o755)}),
            "job-owned grandparent": self.chain(**{"/Library/Application Support/glaeda": (501, stat.S_IFDIR | 0o755)}),
            "group-writable parent": self.chain(**{bin_dir: (0, stat.S_IFDIR | 0o775)}),
            "other-writable root": self.chain(**{"/": (0, stat.S_IFDIR | 0o757)}),
            "symlinked parent": self.chain(**{bin_dir: (0, stat.S_IFLNK | 0o755)}),
            "job-owned file": self.chain(**{str(self.HELPER): (501, stat.S_IFREG | 0o755)}),
            "group-writable file": self.chain(**{str(self.HELPER): (0, stat.S_IFREG | 0o775)}),
            "not executable": self.chain(**{str(self.HELPER): (0, stat.S_IFREG | 0o644)}),
            "symlinked file": self.chain(**{str(self.HELPER): (0, stat.S_IFLNK | 0o755)}),
            "missing parent": {k: v for k, v in self.chain().items() if k != bin_dir},
            "missing file": {k: v for k, v in self.chain().items() if k != str(self.HELPER)},
        }
        for why, entries in rejected.items():
            with self.subTest(why=why):
                self.assertIsNone(self.eligible(entries))
        self.assertIsNone(self.eligible(self.chain(), writable=True))  # an ACL grants the job write access

    def test_the_old_job_writable_location_is_not_used(self):
        old = Path("/Users/Shared/cmux-build-fleet/bin/glaeda-lan-fetch")
        entries = {str(p): (0, stat.S_IFDIR | 0o755) for p in old.parents}
        entries["/Users/Shared"] = (0, stat.S_IFDIR | 0o1777)
        entries["/Users/Shared/cmux-build-fleet"] = (501, stat.S_IFDIR | 0o755)
        entries["/Users/Shared/cmux-build-fleet/bin"] = (501, stat.S_IFDIR | 0o755)
        entries[str(old)] = (0, stat.S_IFREG | 0o755)

        def fake_lstat(path):
            uid, mode = entries[os.fspath(path)]
            return os.stat_result((mode, 0, 0, 1, uid, 0, 100, 0, 0, 0))
        with mock.patch.object(peer.os, "lstat", fake_lstat), \
                mock.patch.object(peer.os, "geteuid", return_value=501), \
                mock.patch.object(peer.os, "access", return_value=False):
            self.assertIsNone(peer.lan_helper({"RUNNER_NAME": "m-glaeda"}, old))

    def test_the_output_names_are_a_documented_contract(self):
        source = (ROOT / "scripts/ci/peer_product_source.py").read_text()
        self.assertIn("admissions.jsonl reads", source)
        result = self.fetch()
        self.assertTrue({"source", "lan_status", "lan_seconds", "lan_peer"} <= set(result))
        self.assertEqual((result["source"], result["lan_status"]), ("lan", "hit"))

    # The fetch: the helper's word is never enough; the digest decides.

    def test_a_verified_lan_hit_lands_in_the_canonical_layout(self):
        result = self.fetch()
        self.assertTrue(result["hit"], result)
        self.assertEqual((result["source"], result["lan_peer"]), ("lan", "cmux13s-mac-mini"))
        self.assertEqual(result["bytes_transferred"], len(self.payload))
        self.assertEqual((self.destination / cache.ARCHIVE_NAME).read_bytes(), self.payload)
        seen = self.seen()
        self.assertEqual(seen["argv"][:2], ["product", self.identity.archive_digest])
        self.assertEqual(seen["argv"][3:], ["--max-bytes", str(peer.MAX_OBJECT_BYTES)])
        self.assertNotEqual(Path(seen["argv"][2]).parent, self.destination)  # staged, then renamed

    def test_the_helper_gets_no_job_secrets(self):
        with mock.patch.dict(os.environ, {"GITHUB_TOKEN": "secret", "GH_TOKEN": "secret", "ACTIONS_RUNTIME_TOKEN": "x"}):
            self.fetch()
        env = self.seen()["env"]
        self.assertFalse({"GITHUB_TOKEN", "GH_TOKEN", "ACTIONS_RUNTIME_TOKEN"} & set(env))
        self.assertEqual(env["PATH"], "/usr/bin:/bin")

    def test_bytes_that_do_not_match_the_digest_are_a_miss_whatever_the_helper_says(self):
        for mode in ("wrong-bytes", "claims-hit-without-file", "miss", "hardlinked"):
            with self.subTest(mode=mode):
                self.mode(mode)
                result = self.fetch()
                self.assertFalse(result["hit"], result)
                self.assertFalse(self.destination.exists())
                self.assertEqual(list(self.destination.parent.iterdir()) if self.destination.parent.exists() else [], [])

    def test_a_slow_helper_is_cut_off(self):
        self.mode("slow")
        result = self.fetch(timeout=1)
        self.assertFalse(result["hit"])
        self.assertEqual(result["lan_status"], "error")

    def test_an_occupied_destination_is_never_replaced(self):
        self.destination.mkdir(parents=True)
        result = self.fetch()
        self.assertFalse(result["hit"])

    # The fetch command: LAN first on an owned Mac, then the trusted HTTPS peers as before.

    def run_main(self, env, helper):
        outputs = Path(self.temp.name) / "outputs"
        outputs.unlink(missing_ok=True)
        full = {
            "GITHUB_REPOSITORY": "manaflow-ai/cmux", "ARTIFACT_ID": "123", "ARTIFACT_PROVIDER_DIGEST": "b" * 64,
            "EXPECTED_SHA256": self.identity.archive_digest, "CMUX_PRODUCT_CONTRACT": "c" * 64,
            "CMUX_PRODUCT_SOURCE_REVISION": "a" * 40, "CMUX_PRODUCT_PRODUCER_RUN_ID": "456",
            "GITHUB_OUTPUT": str(outputs), **env,
        }
        with mock.patch.dict(os.environ, full, clear=False), \
                mock.patch.object(peer, "lan_helper", lambda *_a, **_k: helper), \
                mock.patch.object(sys, "argv", ["peer_product_source.py", "fetch", str(self.destination)]), \
                mock.patch("sys.stdout", new=io.StringIO()):
            peer.main()
        return dict(line.split("=", 1) for line in outputs.read_text().splitlines())

    def test_fetch_tries_the_lan_first_and_reports_it(self):
        outputs = self.run_main({"CMUX_ARTIFACT_PEER_URLS": ""}, self.helper)
        self.assertEqual((outputs["hit"], outputs["source"]), ("true", "lan"))
        self.assertIn("lan_seconds", outputs)

    def test_a_lan_miss_falls_through_to_the_existing_sources(self):
        self.mode("miss")
        with mock.patch.object(peer, "fetch_exact", return_value={"status": "miss", "hit": False, "source": ""}) as https:
            outputs = self.run_main({}, self.helper)
        https.assert_called_once()
        self.assertEqual((outputs["hit"], outputs["lan_status"]), ("false", "miss"))
        with mock.patch.object(peer, "fetch_exact", return_value={"status": "miss", "hit": False, "source": ""}) as https:
            outputs = self.run_main({}, None)  # not eligible: no LAN attempt at all
        self.assertEqual(outputs["lan_status"], "unavailable")


class LanSourceClassTests(unittest.TestCase):
    def test_a_lan_object_is_stored_as_peer_and_verified_against_github(self):
        # Old consumers delete entries whose source class they do not know; "lan" stays in metrics only.
        self.assertNotIn("lan", cache.SOURCE_CLASSES)
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            store = cache.Store(base / "cache")
            contract = {"tree": "t"}
            archive = base / "app-host-products.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                for name, value in [
                    (cache.REUSE_RECEIPT, {"contract": contract, "revision": "a" * 40, "run_id": "456", "run_attempt": "1"}),
                    (cache.PRODUCT_RECEIPT, {"revision": "a" * 40, "xcode": "Xcode 26", "architecture": "arm64",
                                             "developer": "/Xcode", "checkout": "/work", "derived": "/derived"}),
                ]:
                    raw = json.dumps(value).encode()
                    info = tarfile.TarInfo(name)
                    info.size = len(raw)
                    tar.addfile(info, io.BytesIO(raw))
            identity = cache.Identity(
                repository="manaflow-ai/cmux", artifact_id=123, provider_digest="b" * 64,
                archive_digest=hashlib.sha256(archive.read_bytes()).hexdigest(),
                product_contract=cache._canonical_contract_key(contract), source_revision="a" * 40,
                producer_run_id=456,
            )
            token = cache.acquire(store, identity, base / "dest", wait=0)["token"]
            asked = []

            def github(ident):
                asked.append(ident.artifact_id)
                return {"id": 123, "expired": False, "digest": "sha256:" + "b" * 64,
                        "workflow_run": {"id": 456}, "created_at": "2026-09-25T00:00:00Z"}

            result = cache.finalize(store, identity, archive, token=token, source_class="lan",
                                    restore_succeeded=True, provider_metadata=github)
            self.assertEqual(result["status"], "published", result)
            metadata = json.loads((store.entry(identity.key()) / cache.METADATA_NAME).read_text())
            self.assertEqual(metadata["source_class"], "peer")
            self.assertEqual(asked, [123])
        source = (ROOT / "scripts/ci/node_product_cache.py").read_text()
        # main(): only "peer" takes the same-run shortcut; a "lan" object may come from another run.
        self.assertIn('same_run_provider_metadata if source_class == "peer" else github_metadata', source)

    def test_restore_reports_the_lan_route(self):
        script = (ROOT / "scripts/ci/restore-app-host-test-product.sh").read_text()
        prefix = script.split("trap report_restore_measurement EXIT", 1)[0] + "trap report_restore_measurement EXIT\n"
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, "RUNNER_TEMP": directory, "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                   "EXPECTED_SHA256": "inner", "CMUX_PRODUCT_CONTRACT": "c", "CMUX_PRODUCT_SOURCE_REVISION": "r",
                   "CMUX_PRODUCT_PRODUCER_RUN_ID": "1", "CMUX_PRODUCT_PRODUCER_RUN_ATTEMPT": "1",
                   "CMUX_PEER_PRODUCT_HIT": "true", "CMUX_PEER_PRODUCT_SOURCE": "lan"}
            result = subprocess.run(["bash", "-c", prefix + "exit 0\n"], env=env, capture_output=True, text=True)
        record = json.loads(next(line.split(" ", 1)[1] for line in result.stdout.splitlines()
                                 if line.startswith("CMUX_TEST_PRODUCT_RESTORE ")))
        self.assertEqual((record["route"], record["peer_source"]), ("lan", "lan"))

    def test_every_consumer_passes_the_lan_source_on(self):
        workflow = (ROOT / ".github/workflows/ci-macos.yml").read_text()
        finalize = ("CMUX_NODE_PRODUCT_SOURCE_CLASS: ${{ steps.peer-products.outputs.hit == 'true' && "
                    "(steps.peer-products.outputs.source == 'lan' && 'lan' || 'peer') || "
                    "(steps.r2-products.outputs.hit == 'true' && 'r2' || 'github') }}")
        self.assertEqual(workflow.count(finalize), 3)
        self.assertEqual(workflow.count("CMUX_PEER_PRODUCT_SOURCE: ${{ steps.peer-products.outputs.source }}"), 3)
        self.assertEqual(workflow.count("scripts/ci/peer_product_source.py fetch"), 3)


if __name__ == "__main__":
    unittest.main()
