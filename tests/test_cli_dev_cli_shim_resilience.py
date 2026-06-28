#!/usr/bin/env python3
"""
Integration test for dev-cli shim resilience and cleanup-dev-builds logic.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

def run_cmd(args: list[str], env: dict[str, str] | None = None) -> tuple[int, str, str]:
    proc = subprocess.run(
        args,
        text=True,
        capture_output=True,
        check=False,
        env=env,
        timeout=10,
    )
    return proc.returncode, proc.stdout, proc.stderr

def main() -> int:
    # 1. Back up existing marker file if present
    marker_path = Path("/tmp/cmux-last-cli-path")
    marker_backup = Path("/tmp/cmux-last-cli-path.bak-test")
    had_marker = marker_path.exists()
    if had_marker:
        shutil.move(str(marker_path), str(marker_backup))

    try:
        with tempfile.TemporaryDirectory(prefix="cmux-shim-resilience-test-") as td:
            tmp = Path(td)
            home = tmp / "home"
            home.mkdir(parents=True)
            
            # Setup mock DerivedData directories
            derived_data = home / "Library/Developer/Xcode/DerivedData"
            dd_tag1 = derived_data / "cmux-testtag1"
            dd_tag2 = derived_data / "cmux-testtag2"
            dd_tag1.mkdir(parents=True)
            dd_tag2.mkdir(parents=True)
            
            # Put some dummy build files inside to verify size discovery
            (dd_tag1 / "dummy").write_text("hello", encoding="utf-8")
            (dd_tag2 / "dummy").write_text("world", encoding="utf-8")
            
            # Prepare mock environment
            env = os.environ.copy()
            env["HOME"] = str(home)
            
            # Case A: marker file points to a DerivedData path of testtag1
            marker_path.write_text(f"{dd_tag1}/Build/Products/Debug/cmux DEV testtag1.app/Contents/Resources/bin/cmux\n", encoding="utf-8")
            
            # Run cleanup-dev-builds (dry run)
            # testtag1 is the active tag, so it should be skipped. only testtag2 should be listed for deletion.
            code, out, err = run_cmd(["./scripts/cleanup-dev-builds.sh"], env=env)
            if code != 0:
                print("FAIL: cleanup-dev-builds failed")
                print(f"stdout={out}\nstderr={err}")
                return 1
                
            would_delete_sec = out.split("would delete:")[1] if "would delete:" in out else ""
            if "testtag2" not in would_delete_sec:
                print("FAIL: expected testtag2 to be listed for deletion")
                print(f"stdout={out}")
                return 1
                
            if "testtag1" in would_delete_sec:
                print("FAIL: expected active testtag1 (DerivedData layout) to be skipped")
                print(f"stdout={out}")
                return 1

            # Case B: marker file points to /Applications install path of testtag1
            marker_path.write_text("/Applications/cmux DEV testtag1.app/Contents/Resources/bin/cmux\n", encoding="utf-8")
            
            code, out, err = run_cmd(["./scripts/cleanup-dev-builds.sh"], env=env)
            if code != 0:
                print("FAIL: cleanup-dev-builds failed (Applications case)")
                print(f"stdout={out}\nstderr={err}")
                return 1
                
            would_delete_sec_b = out.split("would delete:")[1] if "would delete:" in out else ""
            if "testtag2" not in would_delete_sec_b:
                print("FAIL: expected testtag2 to be listed for deletion (Applications case)")
                print(f"stdout={out}")
                return 1
                
            if "testtag1" in would_delete_sec_b:
                print("FAIL: expected active testtag1 (Applications layout) to be skipped")
                print(f"stdout={out}")
                return 1

    finally:
        # Restore marker file
        if marker_path.exists():
            marker_path.unlink()
        if had_marker:
            shutil.move(str(marker_backup), str(marker_path))

    print("PASS: dev-cli shim active tag detection correctly recognizes both layouts and protects the active tag")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
