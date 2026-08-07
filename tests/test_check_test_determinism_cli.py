#!/usr/bin/env python3
"""Behavior coverage for the test-determinism guard's public CLI."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CHECKER = REPO_ROOT / "scripts/check-test-determinism.py"
LIVE_SOURCE = (
    'export const endpoint = "https://api.example.org/items"; '
    "await fetch(endpoint)\n"
)
CLEAN_SOURCE = 'await fetch("http://127.0.0.1:4321/items")\n'


def run_checker(
    repo_root: Path,
    fixture: Path,
    *,
    allowlist: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    command = [
        sys.executable,
        str(CHECKER),
        "--repo-root",
        str(repo_root),
        "--roots",
        fixture.relative_to(repo_root).as_posix(),
        "--strict",
        "--json",
    ]
    if allowlist is not None:
        command.extend(["--allowlist", str(allowlist)])
    return subprocess.run(
        command,
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def require_json(result: subprocess.CompletedProcess[str]) -> dict[str, object]:
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AssertionError(
            f"checker did not emit JSON\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        ) from error


def main() -> None:
    if not CHECKER.is_file():
        raise AssertionError(f"missing checker: {CHECKER}")

    with tempfile.TemporaryDirectory(prefix="cmux-test-determinism-cli-") as raw_tmp:
        repo_root = Path(raw_tmp)
        fixture_root = repo_root / "tests"
        fixture_root.mkdir()

        live_fixture = fixture_root / "live.ts"
        live_fixture.write_text(LIVE_SOURCE, encoding="utf-8")
        live_result = run_checker(repo_root, live_fixture)
        live_payload = require_json(live_result)
        assert live_result.returncode == 1, (
            "strict mode must reject a live public request\n"
            f"stdout:\n{live_result.stdout}\nstderr:\n{live_result.stderr}"
        )
        assert live_payload["counts"] == {
            "active": 1,
            "suppressed": 0,
            "total": 1,
        }
        active = live_payload["active"]
        assert isinstance(active, list) and active[0]["path"] == "tests/live.ts"
        assert active[0]["rule"] == "live-network-host"

        allowlist = repo_root / "allowlist.tsv"
        allowlist.write_text(
            "tests/live.ts\tlive-network-host\tCLI behavior fixture\n",
            encoding="utf-8",
        )
        allowlisted_result = run_checker(
            repo_root,
            live_fixture,
            allowlist=allowlist,
        )
        allowlisted_payload = require_json(allowlisted_result)
        assert allowlisted_result.returncode == 0, allowlisted_result.stderr
        assert allowlisted_payload["counts"] == {
            "active": 0,
            "suppressed": 1,
            "total": 1,
        }

        clean_fixture = fixture_root / "clean.ts"
        clean_fixture.write_text(CLEAN_SOURCE, encoding="utf-8")
        clean_result = run_checker(repo_root, clean_fixture)
        clean_payload = require_json(clean_result)
        assert clean_result.returncode == 0, clean_result.stderr
        assert clean_payload["counts"] == {
            "active": 0,
            "suppressed": 0,
            "total": 0,
        }


if __name__ == "__main__":
    main()
