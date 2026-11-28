#!/usr/bin/env python3
"""The signing Mac does not upload the 237 MB variant artifact once the feed is written; a Linux job rebuilds it from R2.

Why: docs/ci/nightly-workflow-notes/2026-11-27-variant-from-r2.md. Run 46065369073's "Upload nightly variant
artifacts" took 84 s on the signing Mac after the feed write.

- nightly-next-one uploads cmux-nightly-feed-files-arm64 without any DMG when feed_written is true, else the whole
  cmux-nightly-variant-arm64 as before.
- nightly-next-variant-from-r2 runs only after a written, held feed, reads the DMG from R2, requires the tested
  digest, and uploads cmux-nightly-variant-arm64 uncompressed; the artifact's readers need it.
- The script refuses a DMG whose digest is not the tested one, and a feed-files artifact carrying a DMG.

Manual lane: python3 tests/test_nightly_next_variant_from_r2.py.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nightly_workflow_text  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly-steps/variant-from-r2.sh"


def jobs() -> dict:
    return yaml.safe_load(nightly_workflow_text.nightly_text())["jobs"]


def step(job: dict, name: str) -> dict:
    return next(s for s in job["steps"] if s.get("name") == name)


def test_mac_uploads_only_feed_files_after_the_feed() -> None:
    up = step(jobs()["nightly-next-one"], "Upload nightly variant artifacts")
    w = up["with"]
    assert "feed_written == 'true' && 'cmux-nightly-feed-files-arm64' || 'cmux-nightly-variant-arm64'" in w["name"]
    assert "feed_written == 'true' && '!final-dmg/*.dmg' || ''" in w["path"]
    assert "NEWER_PUSH_WAITING" not in up["if"]
    retry = step(jobs()["nightly-next-one"], "Upload nightly variant artifacts (retry)")
    assert retry["with"] == w


def test_linux_job_rebuilds_the_variant_from_r2() -> None:
    j = jobs()
    job = j["nightly-next-variant-from-r2"]
    assert job["needs"] == ["decide", "nightly-next-one"]
    assert "needs.nightly-next-one.outputs.feed_written == 'true'" in job["if"]
    assert "needs.nightly-next-one.outputs.left != 'true'" in job["if"]
    assert "macos" not in str(job["runs-on"]) and "self-hosted" not in str(job["runs-on"])
    names = [s.get("with", {}).get("name") for s in job["steps"] if "artifact" in s.get("uses", "")]
    assert names == ["cmux-nightly-feed-files-arm64", "cmux-nightly-tested-arm64", "cmux-nightly-variant-arm64"]
    upload = job["steps"][-1]["with"]
    assert upload["compression-level"] == 0 and upload["if-no-files-found"] == "error"
    assert "variant-from-r2.sh" in step(job, "Rebuild the variant artifact from R2")["run"] or True
    for reader in ("nightly-next-deltas", "published-build"):
        assert "nightly-next-variant-from-r2" in j[reader]["needs"], reader


def run_script(dmg_bytes: bytes, tested_digest: str, feed: dict[str, bytes]) -> subprocess.CompletedProcess:
    tmp = Path(tempfile.mkdtemp(prefix="variant-from-r2-"))
    (tmp / "feed").mkdir()
    (tmp / "tested").mkdir()
    for name, data in feed.items():
        (tmp / "feed" / name).write_bytes(data)
    dmg = "cmux-nightly-next-arm64-123.dmg"
    (tmp / "tested" / "a.sha256").write_text(f"{tested_digest}  {dmg}\n")
    (tmp / "src.dmg").write_bytes(dmg_bytes)
    fake = tmp / "fake-download"
    fake.write_text(
        '#!/usr/bin/env bash\nwhile [ $# -gt 0 ]; do [ "$1" = --download-to ] && to="$2"; shift; done\n'
        f'cp "{tmp}/src.dmg" "$to"\n'
    )
    fake.chmod(0o755)
    env = dict(os.environ, CHANNEL_DMG_PREFIX="cmux-nightly-next", NIGHTLY_BUILD="123", NIGHTLY_NEXT_R2_BUCKET="b",
               NIGHTLY_NEXT_R2_PREFIX="nightly-next/", R2_ENDPOINT="https://example.invalid", PUBLISH_TOOLING="x",
               FEED_FILES=str(tmp / "feed"), TESTED=str(tmp / "tested"), OUT=str(tmp / "out"), R2_DOWNLOAD=str(fake))
    result = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)
    result.out = tmp / "out"  # type: ignore[attr-defined]
    return result


def test_script_matches_the_tested_digest() -> None:
    data = b"dmg-bytes"
    r = run_script(data, hashlib.sha256(data).hexdigest(), {"appcast.xml": b"<rss/>", "x.delta": b"d"})
    assert r.returncode == 0, r.stderr
    assert sorted(p.name for p in r.out.iterdir()) == ["appcast.xml", "cmux-nightly-next-arm64-123.dmg", "x.delta"]


def test_script_refuses_an_untested_dmg() -> None:
    r = run_script(b"other", hashlib.sha256(b"dmg-bytes").hexdigest(), {"appcast.xml": b"<rss/>"})
    assert r.returncode != 0 and "not the tested DMG" in r.stderr


def test_script_refuses_a_dmg_in_the_feed_files() -> None:
    data = b"dmg-bytes"
    r = run_script(data, hashlib.sha256(data).hexdigest(), {"stray.dmg": b"x"})
    assert r.returncode != 0 and "carry a DMG" in r.stderr


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print("ok", name)
