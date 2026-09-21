#!/usr/bin/env python3

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/capture_app_host_xcresult.py"


def make_fake_xcrun(root: Path) -> Path:
    fake = root / "xcrun"
    fake.write_text(
        """#!/usr/bin/env python3
import json
import os
import sys

kind = "summary" if "summary" in sys.argv else "tests"
if os.environ.get("FAKE_FAIL_KIND") == kind:
    print(f"{kind} extractor failed", file=sys.stderr)
    raise SystemExit(9)
if os.environ.get("FAKE_INVALID_KIND") == kind:
    print("{invalid-json")
    raise SystemExit(0)
print(json.dumps({"kind": kind, "ok": True}))
""",
        encoding="utf-8",
    )
    fake.chmod(0o755)
    return fake


def run_capture(root: Path, **extra_env: str) -> subprocess.CompletedProcess[str]:
    bundle = root / "attempt.xcresult"
    bundle.mkdir()
    make_fake_xcrun(root)
    env = {
        **os.environ,
        **extra_env,
        "PATH": f"{root}:{os.environ.get('PATH', '')}",
    }
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(bundle)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_valid_json_is_published_atomically():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        completed = run_capture(root)
        assert completed.returncode == 0, completed.stderr
        for kind in ("summary", "tests"):
            output = root / f"attempt.{kind}.json"
            assert output.is_file()
            assert json.loads(output.read_text(encoding="utf-8"))["kind"] == kind
            assert not (root / f"attempt.{kind}.json.tmp").exists()


def test_invalid_json_is_removed_and_error_is_retained():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        completed = run_capture(root, FAKE_INVALID_KIND="summary")
        assert completed.returncode == 1
        assert not (root / "attempt.summary.json").exists()
        assert (root / "attempt.tests.json").is_file()
        error = (root / "attempt.summary.err").read_text(encoding="utf-8")
        assert "typed JSON validation failed" in error


def test_xcresulttool_failure_never_leaves_empty_json():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        completed = run_capture(root, FAKE_FAIL_KIND="tests")
        assert completed.returncode == 1
        assert (root / "attempt.summary.json").is_file()
        assert not (root / "attempt.tests.json").exists()
        assert "tests extractor failed" in (root / "attempt.tests.err").read_text(encoding="utf-8")


if __name__ == "__main__":
    test_valid_json_is_published_atomically()
    test_invalid_json_is_removed_and_error_is_retained()
    test_xcresulttool_failure_never_leaves_empty_json()
    print("ok")
