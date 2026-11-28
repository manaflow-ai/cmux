#!/usr/bin/env python3
"""The web bundle publish workflow's cas/1 upload, run again over a tree another run published first.

Detector for run 46096014005 (2026-11-28): the patch list `cas/d/<manifest>.json` is named by its
tree, not its bytes (its patches depend on the bases the run held). A later run of the same tree
wrote another list, the write-once upload refused it, `set -e` ended the step, and neither
`cas/m/<manifest>` nor `<key>/cas.json` went up, so the pointer named no `cas`.

The step's own shell runs against a stand-in uploader where every object a run can write with
other bytes (any key that is not a content id under `cas/p/`, `cas/m/`, or a `.zst` patch) already
exists with other bytes. The step must still upload the manifest and keep going to cas.json.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-web-bundle-publish.yml"
STEP = "Upload the cas/1 objects to R2"

# Stands in for python3: the uploader is faked, everything else (`python3 -c`) is the real one.
SHIM = r'''#!/bin/sh
if [ "$1" = "scripts/ci/upload-r2-object.py" ]; then
  shift
  exec "$REAL_PYTHON" "$FAKE_UPLOADER" "$@"
fi
exec "$REAL_PYTHON" "$@"
'''

# Write-once keys a rerun can name with other bytes already exist; the rest upload.
UPLOADER = r'''
import os, re, sys
a = sys.argv[1:]
key = a[a.index("--key") + 1]
code = int(a[a.index("--conflict-exit-code") + 1]) if "--conflict-exit-code" in a else 1
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(key + "\n")
content_id = re.search(r"/cas/(p/[0-9a-f]{64}\.(pack|idx)|m/[0-9a-f]{64})$", key)
if "--write-once" in a and not content_id:
    sys.stderr.write(f"immutable R2 object already exists with a different SHA-256: {key}\n")
    sys.exit(code)
'''


def step_script() -> str:
    jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
    steps = [s for job in jobs.values() for s in job.get("steps", []) if s.get("name") == STEP]
    assert len(steps) == 1, f"one {STEP!r} step, found {len(steps)}"
    return steps[0]["run"]


def main() -> None:
    manifest, pack, key = "a" * 64, "b" * 64, "c" * 64
    with tempfile.TemporaryDirectory() as tmp:
        t = Path(tmp)
        cas = t / "web-cas"
        for sub in ("p", "m", "d"):
            (cas / "objects" / sub).mkdir(parents=True)
        (cas / "objects/p" / f"{pack}.pack").write_bytes(b"pack")
        (cas / "objects/p" / f"{pack}.idx").write_text("{}")
        (cas / "objects/m" / manifest).write_bytes(b"manifest")
        (cas / "objects/d" / f"{'d' * 64}.from-{'e' * 64}.zst").write_bytes(b"patch")
        (cas / "objects/d" / f"{manifest}.json").write_text('{"schema":1,"patches":[]}')
        (cas / "cas.json").write_text(json.dumps({"manifest": manifest, "pack": pack}))
        bin_dir = t / "bin"
        bin_dir.mkdir()
        (bin_dir / "python3").write_text(SHIM)
        (bin_dir / "python3").chmod(0o755)
        (t / "uploader.py").write_text(UPLOADER)
        log = t / "log"
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", REAL_PYTHON=sys.executable,
                   FAKE_UPLOADER=str(t / "uploader.py"), FAKE_LOG=str(log), RUNNER_TEMP=tmp,
                   GITHUB_STEP_SUMMARY=str(t / "summary"), KEY=key, R2_ENDPOINT="https://r2.invalid")
        env.pop("BASH_ENV", None)
        run = subprocess.run(["bash", "-e", "-c", step_script()], cwd=ROOT, env=env,
                             capture_output=True, text=True)
        keys = log.read_text().split() if log.exists() else []
        assert run.returncode == 0, (run.returncode, run.stderr, keys)
        assert f"cmux-next-web/cas/m/{manifest}" in keys, keys
        assert f"cmux-next-web/{key}/cas.json" in keys, keys
        # Order: the list after its patches, the manifest before cas.json (cas.json means all is there).
        assert keys.index(f"cmux-next-web/cas/d/{manifest}.json") > max(
            i for i, k in enumerate(keys) if k.endswith(".zst")), keys
        assert keys.index(f"cmux-next-web/cas/m/{manifest}") < keys.index(f"cmux-next-web/{key}/cas.json"), keys
    print("ok test_web_cas_upload_rerun")


if __name__ == "__main__":
    main()
