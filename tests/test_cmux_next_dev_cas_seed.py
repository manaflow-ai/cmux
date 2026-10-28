#!/usr/bin/env python3
"""The fleet-shared DEV compile cache (scripts/cmux-next/dev_cas_seed.py).

- a packed cache unpacks to the same files and replaces the host's old cache whole;
- a seed holding a link, a path outside the cache or `..` installs nothing;
- a seed replaces a host's cache only when the host has none or the seed is newer;
- a reader takes a record only from a trusted feat-cmux-next run with matching key fields, picks
  the seed of the newest commit whatever order the seeds were uploaded in, and installs nothing
  when that seed is not newer than the host's cache;
- bytes that do not match the record's digest are never installed, a download past the record's
  size is cut off, and a seed that unpacks past its declared size is refused as it streams;
- without the store's URL and token nothing is fetched or published, and a pack without --out
  writes only the host's origin marker;
- the workflow hands the token only to the DEV landing compile, from the next-dev-cas environment.
"""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
SPEC = importlib.util.spec_from_file_location("dev_cas_seed", ROOT / "scripts/cmux-next/dev_cas_seed.py")
seed = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(seed)

REPO, REPO_ID = "manaflow-ai/cmux", "123"
ENV = {"GITHUB_REPOSITORY": REPO, "GITHUB_REPOSITORY_ID": REPO_ID, "GITHUB_RUN_ID": "900",
       "GITHUB_WORKFLOW_REF": f"{REPO}/.github/workflows/cmux-next.yml@refs/heads/feat-cmux-next"}
FIELDS = {"recipe": seed.RECIPE, "xcode": "Xcode 26.6 Build version 17F113", "sdk": "26.5 25F70"}
KEY = seed.key_of(FIELDS)
SHA_A, SHA_B = "a" * 40, "b" * 40


def cat_zstd(directory: Path) -> str:
    """A stand-in zstd that copies (compression is not under test)."""
    path = directory / "zstd"
    path.write_text("#!/bin/sh\nexec cat\n")
    path.chmod(0o755)
    return str(path)


def make_cas(derived_data: Path, payload: str) -> None:
    (derived_data / seed.CAS_DIR / "v1.3").mkdir(parents=True, exist_ok=True)
    (derived_data / seed.CAS_DIR / "v1.3" / "data").write_text(payload)
    (derived_data / seed.CAS_DIR / "v1.3" / "index").write_text(payload[::-1])


def manifest(sha=SHA_B, committed_at=200, run_id=1, digest="0" * 64, size=10, fields=FIELDS, cas_bytes=1000):
    return {"schema": seed.SCHEMA, "key": KEY, "key_fields": fields, "run_id": run_id, "blob_sha256": digest,
            "blob_bytes": size, "cas_bytes": cas_bytes, "source_sha": sha, "committed_at": committed_at}


def fake_curl_bin(directory: Path) -> Path:
    """A curl that ignores its URL and streams the file FAKE_BODY names."""
    path = directory / "curl"
    path.write_text('#!/bin/sh\ncat >/dev/null\nexec cat "$FAKE_BODY"\n')
    path.chmod(0o755)
    return path


def artifact(run_id: int, branch="feat-cmux-next", created="2026-10-28T10:00:00Z") -> dict:
    return {"id": run_id * 10, "name": seed.RECORD_PREFIX + KEY, "expired": False, "created_at": created,
            "archive_download_url": f"https://example/{run_id}",
            "workflow_run": {"id": run_id, "repository_id": REPO_ID, "head_repository_id": REPO_ID,
                             "head_branch": branch}}


class StubApi:
    def __init__(self, artifacts, manifests, failed_runs=()):
        self.artifacts, self.manifests, self.failed = artifacts, manifests, set(failed_runs)
        self.deadline = 10**9

    def left(self):
        return 100.0

    def json(self, path):
        if path.startswith("actions/artifacts"):
            return {"artifacts": self.artifacts}
        run_id = int(path.split("/")[2].split("?")[0])
        if path.endswith(f"runs/{run_id}"):
            return {"id": run_id, "event": "push", "path": ".github/workflows/cmux-next.yml",
                    "head_branch": "feat-cmux-next", "repository": {"full_name": REPO},
                    "head_repository": {"full_name": REPO}}
        conclusion = "failure" if run_id in self.failed else "success"
        return {"jobs": [{"name": "cmux NEXT DEV Release compile (landing)", "status": "completed",
                          "conclusion": conclusion}]}


class SeedTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.env = {**ENV, "CMUX_NEXT_DEV_CAS_ZSTD": cat_zstd(self.root)}

    def test_pack_and_extract_round_trip_replaces_the_old_cache(self):
        writer, reader = self.root / "w", self.root / "r"
        make_cas(writer, "fresh objects")
        make_cas(reader, "old objects")
        (reader / seed.CAS_DIR / "v1.2").mkdir()
        size, digest = seed.pack(writer, self.root / "out", self.env)
        blob = self.root / "out" / seed.BLOB
        self.assertEqual((size, digest), (blob.stat().st_size, hashlib.sha256(blob.read_bytes()).hexdigest()))
        seed.extract(blob, reader, self.env)
        self.assertEqual((reader / seed.CAS_DIR / "v1.3/data").read_text(), "fresh objects")
        self.assertFalse((reader / seed.CAS_DIR / "v1.2").exists(), "the old cache survived beside the seed")
        self.assertEqual(sorted(p.name for p in reader.iterdir()), [seed.CAS_DIR])

    def unsafe_blob(self, add) -> Path:
        blob = self.root / "bad.tar.zst"
        with tarfile.open(blob, "w") as tar:
            add(tar)
        return blob

    def test_a_seed_with_a_link_or_an_outside_path_installs_nothing(self):
        def file(name):
            def add(tar):
                info = tarfile.TarInfo(name)
                info.size = 1
                tar.addfile(info, io.BytesIO(b"x"))
            return add

        def link(tar):
            info = tarfile.TarInfo(f"{seed.CAS_DIR}/v1.3/data")
            info.type, info.linkname = tarfile.SYMTYPE, "/etc/passwd"
            tar.addfile(info)

        for add in (file("elsewhere/x"), file(f"{seed.CAS_DIR}/../x"), file("/abs/x"), link):
            reader = self.root / "reader"
            shutil.rmtree(reader, ignore_errors=True)
            make_cas(reader, "kept")
            with self.assertRaises(seed.Miss):
                seed.extract(self.unsafe_blob(add), reader, self.env)
            self.assertEqual((reader / seed.CAS_DIR / "v1.3/data").read_text(), "kept")
            self.assertFalse((self.root / "x").exists())

    def test_a_seed_replaces_only_a_missing_or_older_cache(self):
        host = self.root / "host"
        record = manifest(SHA_B, committed_at=200)
        self.assertEqual(seed.newer(record, {}, host), "", "a host with no cache takes any seed")
        make_cas(host, "local")
        self.assertEqual(seed.newer(record, {"sha": SHA_A, "committed_at": 100}, host), "")
        self.assertIn("as new as", seed.newer(record, {"sha": SHA_A, "committed_at": 300}, host))
        self.assertIn("already holds", seed.newer(record, {"sha": SHA_B, "committed_at": 1}, host))
        self.assertIn("unknown origin", seed.newer(record, {}, host))

    def find(self, api, marker, host=None):
        host = host or self.root / "host"
        with mock.patch.object(seed.reuse, "read_record", lambda _api, item, _scratch: api.manifests[item["workflow_run"]["id"]]):
            return seed.find_seed(api, KEY, FIELDS, self.env, marker, host, self.root)

    def test_a_reader_takes_only_trusted_matching_records(self):
        api = StubApi([artifact(5, branch="some-pr-branch", created="2026-10-28T12:00:00Z"),
                       artifact(4, created="2026-10-28T11:00:00Z"), artifact(3, created="2026-10-28T10:00:00Z")],
                      {4: manifest(run_id=4, fields={**FIELDS, "xcode": "Xcode 27"}), 3: manifest(run_id=3)})
        record, run_id = self.find(api, {})
        self.assertEqual(run_id, 3, "a pull request branch's record or other key fields were taken")
        failed = StubApi([artifact(3)], {3: manifest(run_id=3)}, failed_runs={3})
        with self.assertRaisesRegex(seed.reuse.Miss, "did not finish successfully"):
            self.find(failed, {})
        with self.assertRaisesRegex(seed.reuse.Miss, "not the DEV compile cache lane"):
            with mock.patch.dict(self.env, {"GITHUB_WORKFLOW_REF": f"{REPO}/.github/workflows/nightly.yml@refs/heads/main"}):
                self.find(api, {})

    def test_the_newest_seed_not_being_newer_installs_nothing(self):
        host = self.root / "host"
        make_cas(host, "local")
        api = StubApi([artifact(4, created="2026-10-28T11:00:00Z"), artifact(3)],
                      {4: manifest(SHA_B, committed_at=200, run_id=4), 3: manifest(SHA_A, committed_at=100, run_id=3)})
        with self.assertRaisesRegex(seed.reuse.Miss, "as new as") as caught:
            self.find(api, {"sha": "c" * 40, "committed_at": 250}, host)
        self.assertIn("run 4", str(caught.exception))
        self.assertNotIn("run 3", str(caught.exception))

    def test_an_older_commit_uploaded_last_does_not_hide_a_newer_seed(self):
        # Landing builds run concurrently: run 6 (commit time 100) publishes after run 5 (commit
        # time 300), so the newest upload is the older cache.
        uploads = [artifact(6, created="2026-10-28T12:00:00Z"), artifact(5, created="2026-10-28T11:00:00Z"),
                   artifact(4, created="2026-10-28T10:00:00Z")]
        manifests = {6: manifest(SHA_A, committed_at=100, run_id=6), 5: manifest(SHA_B, committed_at=300, run_id=5),
                     4: manifest("d" * 40, committed_at=200, run_id=4)}
        api = StubApi(uploads, manifests)
        record, run_id = self.find(api, {}, self.root / "cold")
        self.assertEqual((run_id, record["source_sha"]), (5, SHA_B), "a cold host took an older commit's seed")
        warm = self.root / "warm"
        make_cas(warm, "local")
        record, run_id = self.find(api, {"sha": "c" * 40, "committed_at": 150}, warm)
        self.assertEqual(run_id, 5, "a warm host skipped the newer seed behind an older upload")
        with self.assertRaisesRegex(seed.reuse.Miss, "as new as"):
            self.find(api, {"sha": "c" * 40, "committed_at": 300}, warm)
        same_commit = StubApi(uploads[:2], {6: manifest(SHA_B, committed_at=300, run_id=6),
                                            5: manifest(SHA_B, committed_at=300, run_id=5)})
        self.assertEqual(self.find(same_commit, {}, self.root / "cold2")[1], 6, "seeds of one commit: the later run")

    def restore(self, blob_bytes: bytes, record: dict) -> str:
        host = self.root / "dd"
        make_cas(host, "local")
        marker = self.root / "cas-origin.json"
        marker.write_text(json.dumps({"sha": SHA_A, "committed_at": 100}))

        body = self.root / "body"
        body.write_bytes(blob_bytes)
        fake_curl_bin(self.root)

        env = {**self.env, "CMUX_NEXT_DEV_CAS_URL": "http://store.invalid:8787", "CMUX_NEXT_DEV_CAS_TOKEN": "t",
               "GH_TOKEN": "g"}
        args = seed.argparse.Namespace(derived_data=str(host), build_root=str(self.root / "src"), marker=str(marker),
                                       scratch=str(self.root / "scratch"), timeout=60)
        with mock.patch.object(seed, "key_fields", lambda *_: FIELDS), \
                mock.patch.object(seed, "find_seed", lambda *_: (record, 7)), \
                mock.patch.object(seed.reuse, "Api", lambda *a: StubApi([], {})), \
                mock.patch.dict(os.environ, {"PATH": f"{self.root}:{os.environ['PATH']}", "FAKE_BODY": str(body)}):
            seed.cmd_restore(args, env)
        return (host / seed.CAS_DIR / "v1.3/data").read_text()

    def test_bytes_that_do_not_match_the_record_are_never_installed(self):
        writer = self.root / "w"
        make_cas(writer, "seeded")
        size, digest = seed.pack(writer, self.root / "out", self.env)
        good = (self.root / "out" / seed.BLOB).read_bytes()
        bad = bytearray(good)
        bad[len(bad) // 2] ^= 0xFF
        self.assertEqual(self.restore(bytes(bad), manifest(digest=digest, size=size)), "local")
        self.assertEqual(self.restore(good, manifest(digest=digest, size=size)), "seeded")
        marker = json.loads((self.root / "cas-origin.json").read_text())
        self.assertEqual((marker["sha"], marker["seeded_from_run"]), (SHA_B, 7))

    def test_a_decompressor_that_exits_a_moment_after_its_output_is_a_success(self):
        slow = self.root / "slow-zstd"
        slow.write_text("#!/bin/sh\ncat\nsleep 1\nexit 0\n")
        slow.chmod(0o755)
        failing = self.root / "failing-zstd"
        failing.write_text("#!/bin/sh\ncat\nsleep 1\nexit 3\n")
        failing.chmod(0o755)
        writer, reader = self.root / "w", self.root / "r"
        make_cas(writer, "fresh objects")
        make_cas(reader, "old objects")
        seed.pack(writer, self.root / "out", self.env)
        blob = self.root / "out" / seed.BLOB
        with self.assertRaisesRegex(seed.Miss, "zstd exited 3"):
            seed.extract(blob, reader, {**self.env, "CMUX_NEXT_DEV_CAS_ZSTD": str(failing)})
        self.assertEqual((reader / seed.CAS_DIR / "v1.3/data").read_text(), "old objects")
        seed.extract(blob, reader, {**self.env, "CMUX_NEXT_DEV_CAS_ZSTD": str(slow)})
        self.assertEqual((reader / seed.CAS_DIR / "v1.3/data").read_text(), "fresh objects")

    def test_an_oversized_or_wrong_body_is_cut_off_and_leaves_no_file(self):
        fake_curl_bin(self.root)
        body, dest = self.root / "body", self.root / "dest"
        body.write_bytes(b"x" * (3 << 20))
        digest = hashlib.sha256(body.read_bytes()).hexdigest()
        with mock.patch.dict(os.environ, {"PATH": f"{self.root}:{os.environ['PATH']}", "FAKE_BODY": str(body)}):
            with self.assertRaisesRegex(seed.Miss, "more than the record's"):
                seed.download("http://store.invalid/v1/cache/x", dest, "t", 30, 1 << 20, digest)
            self.assertFalse(dest.exists(), "an oversized download left its partial file")
            with self.assertRaisesRegex(seed.Miss, "do not match"):
                seed.download("http://store.invalid/v1/cache/x", dest, "t", 30, 3 << 20, "0" * 64)
            self.assertFalse(dest.exists())
            seed.download("http://store.invalid/v1/cache/x", dest, "t", 30, 3 << 20, digest)
            self.assertEqual(dest.stat().st_size, 3 << 20)

    def test_a_seed_that_unpacks_past_its_declared_size_is_refused_mid_stream(self):
        env = dict(self.env)
        if shutil.which("zstd"):
            env["CMUX_NEXT_DEV_CAS_ZSTD"] = shutil.which("zstd")  # a real bomb: a few KiB of zstd
        writer, reader = self.root / "w", self.root / "r"
        (writer / seed.CAS_DIR / "v1.3").mkdir(parents=True)
        (writer / seed.CAS_DIR / "v1.3" / "data").write_bytes(b"\0" * (64 << 20))
        make_cas(reader, "kept")
        seed.pack(writer, self.root / "out", env)
        with self.assertRaisesRegex(seed.Miss, "more than its record declares"):
            seed.extract(self.root / "out" / seed.BLOB, reader, env, max_bytes=1 << 20)
        self.assertEqual((reader / seed.CAS_DIR / "v1.3/data").read_text(), "kept")
        self.assertEqual(sorted(p.name for p in reader.iterdir()), [seed.CAS_DIR], "a refused seed left files")
        with self.assertRaisesRegex(seed.reuse.Miss, "cache size"):
            seed.check_record(manifest(run_id=1, cas_bytes=seed.CAS_MAX_BYTES + 1), KEY, FIELDS, 1)

    def test_without_the_store_nothing_is_fetched_or_published(self):
        host = self.root / "dd"
        make_cas(host, "local")
        args = seed.argparse.Namespace(derived_data=str(host), build_root=str(self.root), marker=str(self.root / "m.json"),
                                       scratch=str(self.root / "scratch"), timeout=5)
        with mock.patch.object(seed, "download", side_effect=AssertionError("fetched without a store")):
            seed.cmd_restore(args, self.env)
        (self.root / "pack").mkdir()
        (self.root / "pack/pack.json").write_text(json.dumps({"schema": seed.SCHEMA}))
        with mock.patch.object(seed, "curl", side_effect=AssertionError("published without a store")):
            seed.cmd_publish(seed.argparse.Namespace(pack=str(self.root / "pack"), out=str(self.root / "rec"), timeout=5),
                             self.env)
        self.assertFalse((self.root / "rec").exists())

    def test_the_token_reaches_only_the_dev_landing_compile_from_its_environment(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text())
        users = {}
        for name, job in workflow["jobs"].items():
            for step in job.get("steps", []):
                text = json.dumps(step.get("env", {}))
                if "NEXT_DEV_CAS_TOKEN" in text:
                    users.setdefault(name, []).append(step.get("name"))
        self.assertEqual(list(users), ["dev-landing-compile"])
        job = workflow["jobs"]["dev-landing-compile"]
        self.assertEqual(job["environment"], "${{ vars.CMUX_NEXT_DEV_CAS_URL != '' && 'next-dev-cas' || '' }}")
        self.assertIn("refs/heads/feat-cmux-next", workflow["jobs"]["dev-landing-place"]["if"])


if __name__ == "__main__":
    unittest.main()
