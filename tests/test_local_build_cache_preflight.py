#!/usr/bin/env python3
"""Offline cache fixtures: no native build, network access, or credentials."""
from concurrent.futures import ThreadPoolExecutor
from io import BytesIO
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("preflight", ROOT / "scripts/local-build-cache-preflight.py")
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        (self.repo / preflight.LOCKFILE).parent.mkdir(parents=True)
        (self.repo / preflight.LOCKFILE).write_bytes(b"abc")
        self.cache = self.root / "cache"
        self.destination = self.root / "mutable"
        self.deadline = time.monotonic() + 20
        self.key = preflight.spm_key(self.repo / preflight.LOCKFILE)
        self.archive = self.root / "seed.tar.gz"
        with tarfile.open(self.archive, "w:gz") as bundle:
            for name, data in (("checkouts/package/file.swift", b"source"),
                               ("workspace-state.json", b'{"old":"/old/checkout"}')):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                bundle.addfile(info, BytesIO(data))
        self.urls = []

    def tearDown(self):
        preflight.writable_tree(self.root, True)
        self.temporary.cleanup()

    def fetch_exact(self, url, output, deadline, limit=preflight.MAX_ARCHIVE):
        self.urls.append(url)
        if url.endswith(self.key + ".tar.gz"):
            shutil.copyfile(self.archive, output)
            return True
        return False

    def seed(self, destination=None):
        return preflight.seed_spm(self.repo, destination or self.destination, self.cache,
                                  "https://example.invalid", "macOS-ARM64", self.deadline, allow_network=True)

    def test_actions_single_file_hash_vector(self):
        self.assertEqual(self.key, "spm-4f8b42c22dd3729b519ba6f68d2da7cc5b2d606d05daed5ad5128cc03e6c6358")

    def test_exact_seed_and_isolated_reuse(self):
        with patch.object(preflight, "fetch", side_effect=self.fetch_exact):
            first = self.seed()
        self.assertEqual((first["status"], first["match"]), ("hit", "exact"))
        self.assertFalse((self.destination / "workspace-state.json").exists())
        (self.destination / "checkouts/package/file.swift").write_text("caller edit")
        with patch.object(preflight, "fetch", side_effect=AssertionError("must reuse local seed")):
            second = self.seed(self.root / "second")
        self.assertEqual(second["transport"], "local-seed")
        self.assertEqual((self.root / "second/checkouts/package/file.swift").read_text(), "source")
        seed = next(self.cache.rglob("SourcePackages"))
        self.assertEqual((seed / "checkouts/package/file.swift").read_text(), "source")
        self.assertEqual(seed.stat().st_mode & 0o222, 0)
        self.assertEqual(list(self.cache.rglob("archive.*")), [])

    def test_nonempty_destination_is_untouched(self):
        self.destination.mkdir()
        (self.destination / "workspace-state.json").write_text("native warm state")
        with patch.object(preflight, "fetch", side_effect=AssertionError("must preserve native state")):
            result = self.seed()
        self.assertEqual(result["status"], "existing")
        self.assertEqual((self.destination / "workspace-state.json").read_text(), "native warm state")

    def test_symlink_destination_is_untouched(self):
        target = self.root / "target"
        target.mkdir()
        self.destination.symlink_to(target, target_is_directory=True)
        with patch.object(preflight, "fetch", side_effect=AssertionError("must not follow destination link")):
            self.assertEqual(self.seed()["status"], "existing")
        self.assertEqual(list(target.iterdir()), [])

    def test_prefix_seed_records_actual_key_and_sanitizes(self):
        fallback = "spm-" + "0" * 64
        def fetch(url, output, deadline, limit=preflight.MAX_ARCHIVE):
            self.urls.append(url)
            if url.endswith("latest/spm-"):
                output.write_text(fallback)
                return True
            if url.endswith(fallback + ".tar.gz"):
                shutil.copyfile(self.archive, output)
                return True
            return False
        with patch.object(preflight, "fetch", side_effect=fetch):
            result = self.seed()
        self.assertEqual(result["match"], "prefix")
        self.assertEqual(result["matched_key"], fallback)
        self.assertFalse((self.destination / "workspace-state.json").exists())

    def test_invalid_pointer_cannot_escape_namespace(self):
        def fetch(url, output, deadline, limit=preflight.MAX_ARCHIVE):
            self.urls.append(url)
            if url.endswith("latest/spm-"):
                output.write_text("../../other.tar.gz")
                return True
            return False
        with patch.object(preflight, "fetch", side_effect=fetch):
            self.assertEqual(self.seed()["status"], "miss")
        self.assertFalse(any(".." in url for url in self.urls))
        self.assertFalse(self.destination.exists())

    def test_escaping_tar_member_is_rejected_without_install(self):
        with tarfile.open(self.archive, "w:gz") as bundle:
            info = tarfile.TarInfo("../../escape")
            info.size = 4
            bundle.addfile(info, BytesIO(b"evil"))
        with patch.object(preflight, "fetch", side_effect=self.fetch_exact):
            with self.assertRaises(RuntimeError):
                self.seed()
        self.assertFalse(self.destination.exists())
        self.assertFalse((self.root / "escape").exists())
        self.assertEqual(list(self.cache.rglob("receipt.json")), [])

    def test_archive_cannot_write_through_escaping_symlink(self):
        with tarfile.open(self.archive, "w:gz") as bundle:
            link = tarfile.TarInfo("outside")
            link.type, link.linkname = tarfile.SYMTYPE, str(self.root)
            bundle.addfile(link)
            info = tarfile.TarInfo("outside/escape")
            info.size = 4
            bundle.addfile(info, BytesIO(b"evil"))
        with patch.object(preflight, "fetch", side_effect=self.fetch_exact):
            with self.assertRaises(RuntimeError):
                self.seed()
        self.assertFalse((self.root / "escape").exists())

    def test_expansion_budget_rejects_archive(self):
        limited = self.root / "limited-worker.py"
        limited.write_text(Path(preflight.__file__).read_text().replace("MAX_EXPANDED = 16 * 1024**3", "MAX_EXPANDED = 1"))
        with patch.object(preflight, "fetch", side_effect=self.fetch_exact), \
                patch.object(preflight, "__file__", str(limited)):
            with self.assertRaises(RuntimeError):
                self.seed()
        self.assertFalse(self.destination.exists())

    def test_concurrent_callers_share_one_seed_with_private_copies(self):
        with patch.object(preflight, "fetch", side_effect=self.fetch_exact), ThreadPoolExecutor(2) as pool:
            results = list(pool.map(self.seed, (self.root / "a", self.root / "b")))
        self.assertEqual([r["status"] for r in results], ["hit", "hit"])
        self.assertEqual(sum(url.endswith(".tar.gz") for url in self.urls), 1)
        (self.root / "a/checkouts/package/file.swift").write_text("a")
        self.assertEqual((self.root / "b/checkouts/package/file.swift").read_text(), "source")

    def test_existing_ghostty_is_preserved_without_verification_claim(self):
        (self.repo / "GhosttyKit.xcframework").mkdir()
        (self.repo / "GhosttyKit.xcframework/Info.plist").write_text("native")
        with patch.object(preflight.subprocess, "check_output", side_effect=AssertionError("no probes")):
            result = preflight.seed_ghostty(self.repo, self.cache, self.deadline, allow_network=True)
        self.assertFalse(result["verified_install"])
        self.assertEqual(result["status"], "existing")

    def test_ghostty_reuses_only_its_verified_immutable_link(self):
        revision, checksum = "a" * 40, "b" * 64
        (self.repo / "scripts").mkdir()
        (self.repo / "scripts/ghosttykit-checksums.txt").write_text(revision + " " + checksum + "\n")
        original_run = preflight.run
        def download(command, deadline, *, env=None, cwd=None):
            if "--internal-worker" in command:
                return original_run(command, deadline, env=env, cwd=cwd)
            if command[:2] == ["xcrun", "ranlib"]:
                archive = Path(command[2])
                self.assertTrue(archive.stat().st_mode & 0o200)
                archive.write_bytes(b"indexed")
                return
            self.assertEqual(env["GHOSTTY_SHA"], revision)
            self.assertEqual(env["GHOSTTYKIT_DOWNLOAD_RETRIES"], "0")
            output = Path(env["GHOSTTYKIT_OUTPUT_DIR"])
            output.mkdir()
            (output / "macos-arm64").mkdir()
            (output / "macos-arm64/ghostty-internal.a").write_bytes(b"unindexed")
            (output / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries":[{
                "SupportedPlatform":"macos", "LibraryIdentifier":"macos-arm64",
                "LibraryPath":"ghostty-internal.a"}]}))
        with patch.object(preflight.subprocess, "check_output", side_effect=[revision, ""]), \
                patch.object(preflight, "run", side_effect=download) as helper:
            result = preflight.seed_ghostty(self.repo, self.cache, self.deadline, allow_network=True)
        self.assertTrue(result["verified_install"])
        self.assertEqual(sum(call.args[0][0] == "bash" for call in helper.call_args_list), 1)
        self.assertEqual((self.repo / "GhosttyKit.xcframework/macos-arm64/ghostty-internal.a").read_bytes(), b"indexed")
        self.assertTrue((self.repo / "GhosttyKit.xcframework").is_symlink())
        with patch.object(preflight.subprocess, "check_output", side_effect=[revision, ""]), \
                patch.object(preflight, "run", side_effect=AssertionError("must not redownload")):
            result = preflight.seed_ghostty(self.repo, self.cache, self.deadline, allow_network=True)
        self.assertTrue(result["verified_install"])
        self.assertEqual(result["materialization"], "existing-immutable-link")
        with patch.object(preflight.subprocess, "check_output", side_effect=[revision, " M source.zig"]):
            result = preflight.seed_ghostty(self.repo, self.cache, self.deadline, allow_network=True)
        self.assertFalse(result["verified_install"])
        newer, newer_checksum = "c" * 40, "d" * 64
        (self.repo / "scripts/ghosttykit-checksums.txt").write_text(newer + " " + newer_checksum + "\n")
        with patch.object(preflight.subprocess, "check_output", side_effect=[newer, ""]), \
                patch.object(preflight, "run", side_effect=AssertionError("must preserve existing destination")):
            changed = preflight.seed_ghostty(self.repo, self.cache, self.deadline, allow_network=True)
        self.assertFalse(changed["verified_install"])
        self.assertIn(checksum, str((self.repo / "GhosttyKit.xcframework").resolve()))

    def test_no_disk_headroom_does_not_start_download(self):
        with patch.object(preflight.shutil, "disk_usage", return_value=shutil._ntuple_diskusage(10, 9, 1)), \
                patch.object(preflight, "run", side_effect=AssertionError("no download when disk is full")):
            self.assertFalse(preflight.fetch("https://example.invalid", self.root / "output", self.deadline))
        self.assertFalse((self.root / "output").exists())

    def test_small_real_http_restore_and_second_local_hit(self):
        public = self.root / "public"
        objects = public / "v1/macOS-ARM64/objects"
        objects.mkdir(parents=True)
        shutil.copyfile(self.archive, objects / (self.key + ".tar.gz"))
        class QuietHandler(SimpleHTTPRequestHandler):
            def log_message(self, *_args):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(public)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = "http://127.0.0.1:" + str(server.server_port)
            result = preflight.seed_spm(self.repo, self.destination, self.cache, url,
                                        "macOS-ARM64", self.deadline, allow_network=True)
            self.assertEqual(result["transport"], "r2")
            self.assertEqual((self.destination / "checkouts/package/file.swift").read_text(), "source")
            with patch.object(preflight, "fetch", side_effect=AssertionError("second caller needs no HTTP")):
                result = preflight.seed_spm(self.repo, self.root / "second", self.cache, url,
                                            "macOS-ARM64", self.deadline, allow_network=True)
            self.assertEqual(result["transport"], "local-seed")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_https_fetch_forbids_protocol_downgrade(self):
        output = self.root / "download"
        def fake_run(command, *_args, **_kwargs):
            self.assertEqual(command[command.index("--proto-redir") + 1], "=https")
            self.assertEqual(command[command.index("--proto") + 1], "=https")
            output.write_bytes(b"compressed fixture")
        with patch.object(preflight, "run", side_effect=fake_run):
            self.assertTrue(preflight.fetch("https://cache.example/object.tar.gz", output, self.deadline))

    def test_busy_lock_uses_deadline_worker_without_polling(self):
        from types import SimpleNamespace
        lock = self.root / "busy.lock"
        with lock.open("a") as owner:
            preflight.fcntl.flock(owner, preflight.fcntl.LOCK_EX)
            def no_polling(*_args):
                raise AssertionError("polling")
            with patch.object(preflight, "time", SimpleNamespace(monotonic=time.monotonic, sleep=no_polling)):
                with self.assertRaises(TimeoutError):
                    with preflight.locked(lock, time.monotonic() + .15):
                        self.fail("acquired a held lock")
        with preflight.locked(lock, self.deadline):
            pass

    def test_timeout_kills_downloader_descendants(self):
        import select
        ready_read, ready_write = os.pipe()
        gate_read, gate_write = os.pipe()
        real_popen = subprocess.Popen
        child = f"import os; os.write({ready_write}, b'ready'); os.read({gate_read}, 1)"
        parent = (f"import os,subprocess; p=subprocess.Popen([{os.sys.executable!r},'-c',{child!r}], "
                  f"pass_fds=({ready_write},{gate_read})); os.close({ready_write}); p.wait()")
        def start_ready(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            os.close(ready_write)
            self.assertTrue(select.select([ready_read], [], [], 5)[0], "descendant never started")
            self.assertEqual(os.read(ready_read, 5), b"ready")
            wait = process.wait
            calls = 0
            def timeout_once(*args, **kwargs):
                nonlocal calls
                calls += 1
                if calls == 1:
                    raise subprocess.TimeoutExpired("ready helper", 0)
                return wait(*args, **kwargs)
            process.wait = timeout_once
            return process
        try:
            with patch.object(preflight.subprocess, "Popen", side_effect=start_ready):
                with self.assertRaises(TimeoutError):
                    preflight.run([os.sys.executable, "-c", parent], self.deadline,
                                  pass_fds=(ready_write, gate_read))
            # Only the blocked descendant owns the write end. EOF proves it
            # exited; a surviving descendant would keep this pipe open.
            self.assertTrue(select.select([ready_read], [], [], 5)[0], "descendant survived timeout")
            self.assertEqual(os.read(ready_read, 1), b"")
        finally:
            for fd in (ready_read, ready_write, gate_read, gate_write):
                try:
                    os.close(fd)
                except OSError:
                    pass

    def test_slow_copy_fallback_cannot_finish_after_deadline(self):
        source = self.root / "source"
        source.mkdir()
        (source / "file").write_text("payload")
        slow = self.root / "slow-copy-worker.py"
        slow.write_text(Path(preflight.__file__).read_text().replace(
            "shutil.copytree(source, destination, symlinks=True)",
            "time.sleep(1); shutil.copytree(source, destination, symlinks=True)"))
        original_run, original_copy = preflight.run, shutil.copytree
        def no_apfs(command, deadline, **kwargs):
            if command[0] == "cp":
                raise RuntimeError("clone unavailable")
            return original_run(command, deadline, **kwargs)
        def slow_in_process(*args, **kwargs):
            time.sleep(1)
            return original_copy(*args, **kwargs)
        started = time.monotonic()
        with patch.object(preflight.platform, "system", return_value="Darwin"), \
                patch.object(preflight, "run", side_effect=no_apfs), \
                patch.object(preflight, "__file__", str(slow)), \
                patch.object(preflight.shutil, "copytree", side_effect=slow_in_process):
            with self.assertRaises(TimeoutError):
                preflight.clone(source, self.destination, time.monotonic() + .1)
        self.assertLess(time.monotonic() - started, .8)
        self.assertFalse((self.destination / "file").exists())

    def test_slow_single_tar_member_cannot_finish_after_deadline(self):
        with tarfile.open(self.archive, "w:gz") as bundle:
            member = tarfile.TarInfo("only")
            member.size = 4
            bundle.addfile(member, BytesIO(b"data"))
        self.destination.mkdir()
        slow = self.root / "slow-extract-worker.py"
        slow.write_text(Path(preflight.__file__).read_text().replace(
            'bundle.extract(member, destination, filter="data")',
            'time.sleep(1); bundle.extract(member, destination, filter="data")'))
        original_extract = tarfile.TarFile.extract
        def slow_in_process(*args, **kwargs):
            time.sleep(1)
            return original_extract(*args, **kwargs)
        started = time.monotonic()
        with patch.object(preflight, "__file__", str(slow)), \
                patch.object(tarfile.TarFile, "extract", side_effect=slow_in_process):
            with self.assertRaises(TimeoutError):
                preflight.unpack(self.archive, "tar.gz", self.destination, time.monotonic() + .1)
        self.assertLess(time.monotonic() - started, .8)
        self.assertFalse((self.destination / "only").exists())

    def test_curl_transfer_timeout_retains_actionable_reason(self):
        with patch.object(preflight, "run", side_effect=preflight.CommandFailed("curl", 28)):
            with self.assertRaisesRegex(TimeoutError, "transfer timeout"):
                preflight.fetch("https://example.invalid", self.root / "archive", self.deadline)

    def test_deadline_miss_writes_receipt_and_never_compiles(self):
        receipt = self.root / "receipt.json"
        with patch.object(preflight, "seed_spm", side_effect=TimeoutError("budget exhausted")), \
                patch.object(preflight, "seed_ghostty", return_value={"status":"existing"}):
            self.assertEqual(preflight.main(["--repo", str(self.repo), "--cache-root", str(self.cache),
                                            "--source-packages-dir", str(self.destination), "--receipt", str(receipt)]), 0)
        result = json.loads(receipt.read_text())
        self.assertEqual(result["swiftpm"]["status"], "miss")
        self.assertEqual(result["compiler_cache"], "not_restored")

    def test_reload_hook_uses_effective_profile_destination(self):
        text = (ROOT / "scripts/reload.sh").read_text()
        start = text.index('# Managed profiles already supply their own SourcePackages path.')
        end = text.index('# CI can verify/download', start)
        hook = text[start:end]
        fake = self.root / "python3"
        fake.write_text('#!/bin/sh\nif [ "$1" = "-" ]; then exit 1; fi\nprintf "%s\\n" "$@" > "$TRACE"\n')
        fake.chmod(0o755)
        trace = self.root / "args"
        env = dict(os.environ, PATH=str(self.root)+os.pathsep+os.environ['PATH'], TRACE=str(trace),
                   CMUX_SOURCE_PACKAGES_DIR=str(self.root/'glaeda-managed'), RELOAD_LOG=str(self.root/'reload.log'),
                   GITHUB_ACTIONS="false", CMUX_LOCAL_CACHE_PREFLIGHT="1")
        subprocess.run(["bash", "-c", "set -euo pipefail\n"+hook], env=env, cwd=self.repo, check=True)
        self.assertIn(str(self.root/'glaeda-managed'), trace.read_text().splitlines())
        self.assertIn("--local-only", trace.read_text().splitlines())
        self.assertNotIn("--warm", trace.read_text().splitlines())
        trace.unlink()
        env['GITHUB_ACTIONS']='true'
        subprocess.run(["bash", "-c", "set -euo pipefail\n"+hook], env=env, cwd=self.repo, check=True)
        self.assertFalse(trace.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
