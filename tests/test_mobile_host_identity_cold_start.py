#!/usr/bin/env python3
"""Exercise a built identity fixture in private homes with an external hang guard."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


def run_case(executable: str, mode: str) -> dict:
    with tempfile.TemporaryDirectory(prefix="cmux-identity-cold-") as temporary:
        home = str(Path(temporary).resolve())
        bundle_id = "com.cmuxterm.fixture.identity." + uuid.uuid4().hex
        contents = Path(home) / "IdentityColdStartFixture.app" / "Contents"
        binary = contents / "MacOS" / "IdentityColdStartFixture"
        binary.parent.mkdir(parents=True)
        shutil.copy2(executable, binary)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_id,
            "CFBundleExecutable": binary.name,
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        }))
        environment = {
            **os.environ,
            "HOME": home,
            "CFFIXED_USER_HOME": home,
            "XDG_CONFIG_HOME": home + "/.config",
            "CMUX_IDENTITY_FIXTURE_HOME": home,
            "CMUX_IDENTITY_FIXTURE_BUNDLE_ID": bundle_id,
        }
        started = time.monotonic()
        process = subprocess.Popen(
            [str(binary), mode],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        timed_out = False
        try:
            output, _ = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate(timeout=5)
        result = {
            "case": mode,
            "active_elapsed_ms": round((time.monotonic() - started) * 1000, 1),
            "timed_out": timed_out,
            "exit_code": process.returncode,
            "process_reaped": process.poll() is not None,
            "output": output.strip(),
        }
        result["passed"] = not timed_out and process.returncode == 0 and '"result":"passed"' in output
        return result


def main() -> int:
    executable, output_path = sys.argv[1:]
    results = [run_case(executable, mode) for mode in ("fresh", "shared-winner")]
    report = {"cases": results, "passed": all(result["passed"] for result in results)}
    Path(output_path).write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
