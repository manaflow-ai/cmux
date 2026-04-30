#!/usr/bin/env python3
"""Tests for ``scripts/cmux-with-gateway.sh``.

The wrapper pre-exports LLM gateway env vars (e.g. ``ANTHROPIC_BASE_URL``)
before exec'ing ``cmux``. See ``docs/llm-gateway.md`` for full description.

Run locally — does not require Xcode, the cmux VM, or Bun:

    python3 tests/test_cmux_with_gateway_wrapper.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
WRAPPER = REPO_ROOT / "scripts" / "cmux-with-gateway.sh"

FAKE_CMUX_TEMPLATE = """#!/usr/bin/env bash
# Fake cmux: prints a JSON line so the test can inspect argv + env we care about.
python3 - "$@" <<'PY'
import json, os, sys
out = {
    "argv": sys.argv[1:],
    "env": {k: os.environ.get(k, "") for k in (
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_API_KEY",
        "OPENAI_BASE_URL",
        "OPENAI_API_KEY",
        "GOOGLE_GENERATIVE_AI_BASE_URL",
        "INJECTED",
        "BAD_KEY",
    )},
}
print(json.dumps(out))
PY
"""

SENSITIVE_KEYS = (
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_API_KEY",
    "OPENAI_BASE_URL",
    "OPENAI_API_KEY",
    "GOOGLE_GENERATIVE_AI_BASE_URL",
    "INJECTED",
    "BAD_KEY",
)


def _make_fake_cmux(tmpdir: Path) -> Path:
    bin_dir = tmpdir / "bin"
    bin_dir.mkdir()
    fake = bin_dir / "cmux"
    fake.write_text(FAKE_CMUX_TEMPLATE)
    fake.chmod(0o755)
    return fake


def _write_secure(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(0o600)


def _run_wrapper(
    args: list[str],
    fake_cmux: Path,
    gateway_env: Path | None,
) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["CMUX_BIN"] = str(fake_cmux)
    if gateway_env is not None:
        env["CMUX_GATEWAY_ENV_FILE"] = str(gateway_env)
    for key in SENSITIVE_KEYS:
        env.pop(key, None)
    return subprocess.run(
        ["bash", str(WRAPPER), *args],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def _parse(stdout: str) -> dict:
    last = [line for line in stdout.splitlines() if line.strip()][-1]
    return json.loads(last)


# --- individual tests ---


def test_wrapper_exists_and_is_executable() -> None:
    assert WRAPPER.exists(), "wrapper script missing"
    assert os.access(WRAPPER, os.X_OK), "wrapper is not executable"


def test_exports_keys_from_env_file(tmp: Path) -> None:
    fake_cmux = _make_fake_cmux(tmp)
    gateway_env = tmp / "gateway.env"
    _write_secure(
        gateway_env,
        "ANTHROPIC_BASE_URL=http://localhost:4000\n"
        "ANTHROPIC_API_KEY=sk-test-anthropic\n"
        "OPENAI_BASE_URL=http://localhost:4000/v1\n",
    )
    result = _run_wrapper([], fake_cmux, gateway_env)
    assert result.returncode == 0, result.stderr
    payload = _parse(result.stdout)
    assert payload["env"]["ANTHROPIC_BASE_URL"] == "http://localhost:4000"
    assert payload["env"]["ANTHROPIC_API_KEY"] == "sk-test-anthropic"
    assert payload["env"]["OPENAI_BASE_URL"] == "http://localhost:4000/v1"


def test_forwards_argv(tmp: Path) -> None:
    fake_cmux = _make_fake_cmux(tmp)
    gateway_env = tmp / "gateway.env"
    _write_secure(gateway_env, "ANTHROPIC_BASE_URL=http://x\n")
    result = _run_wrapper(
        ["sessions", "list", "--json"], fake_cmux, gateway_env
    )
    assert result.returncode == 0, result.stderr
    payload = _parse(result.stdout)
    assert payload["argv"] == ["sessions", "list", "--json"]


def test_ignores_comments_and_blank_lines(tmp: Path) -> None:
    fake_cmux = _make_fake_cmux(tmp)
    gateway_env = tmp / "gateway.env"
    _write_secure(
        gateway_env,
        "# top comment\n"
        "\n"
        "ANTHROPIC_BASE_URL=http://localhost:4000\n"
        "   \n"
        "# trailing comment\n",
    )
    result = _run_wrapper([], fake_cmux, gateway_env)
    assert result.returncode == 0, result.stderr
    payload = _parse(result.stdout)
    assert payload["env"]["ANTHROPIC_BASE_URL"] == "http://localhost:4000"


def test_rejects_malformed_lines(tmp: Path) -> None:
    fake_cmux = _make_fake_cmux(tmp)
    gateway_env = tmp / "gateway.env"
    _write_secure(
        gateway_env,
        "ANTHROPIC_BASE_URL=http://localhost:4000\n"
        "this-line-has-no-equals-sign\n"
        "ANTHROPIC_API_KEY=ok\n",
    )
    result = _run_wrapper([], fake_cmux, gateway_env)
    assert result.returncode == 0, result.stderr
    payload = _parse(result.stdout)
    assert payload["env"]["ANTHROPIC_BASE_URL"] == "http://localhost:4000"
    assert payload["env"]["ANTHROPIC_API_KEY"] == "ok"
    assert "ignoring malformed line" in result.stderr


def test_rejects_suspicious_key_names(tmp: Path) -> None:
    fake_cmux = _make_fake_cmux(tmp)
    gateway_env = tmp / "gateway.env"
    _write_secure(
        gateway_env,
        "ANTHROPIC_BASE_URL=http://localhost:4000\n"
        "lowercase_key=ignored\n"
        "BAD-KEY-WITH-DASHES=ignored\n"
        "BAD_KEY=ok\n",
    )
    result = _run_wrapper([], fake_cmux, gateway_env)
    assert result.returncode == 0, result.stderr
    payload = _parse(result.stdout)
    assert payload["env"]["ANTHROPIC_BASE_URL"] == "http://localhost:4000"
    assert payload["env"]["BAD_KEY"] == "ok"
    assert "ignoring suspicious key: lowercase_key" in result.stderr
    assert "ignoring suspicious key: BAD-KEY-WITH-DASHES" in result.stderr


def test_refuses_world_readable_env_file(tmp: Path) -> None:
    fake_cmux = _make_fake_cmux(tmp)
    gateway_env = tmp / "gateway.env"
    gateway_env.write_text("ANTHROPIC_BASE_URL=http://localhost:4000\n")
    gateway_env.chmod(0o644)
    result = _run_wrapper([], fake_cmux, gateway_env)
    assert result.returncode == 2, result.stdout + result.stderr
    assert "refusing to load" in result.stderr


def test_no_env_file_runs_cmux_anyway(tmp: Path) -> None:
    fake_cmux = _make_fake_cmux(tmp)
    missing = tmp / "nonexistent.env"
    result = _run_wrapper([], fake_cmux, missing)
    assert result.returncode == 0, result.stderr
    payload = _parse(result.stdout)
    assert payload["env"]["ANTHROPIC_BASE_URL"] == ""


def test_debug_flag_prints_loaded_keys(tmp: Path) -> None:
    fake_cmux = _make_fake_cmux(tmp)
    gateway_env = tmp / "gateway.env"
    _write_secure(
        gateway_env,
        "ANTHROPIC_BASE_URL=http://localhost:4000\n"
        "OPENAI_BASE_URL=http://localhost:4000/v1\n",
    )
    result = _run_wrapper(["--debug"], fake_cmux, gateway_env)
    assert result.returncode == 0, result.stderr
    assert "ANTHROPIC_BASE_URL" in result.stderr
    assert "OPENAI_BASE_URL" in result.stderr


def test_cmux_bin_not_executable_fails_clearly(tmp: Path) -> None:
    not_executable = tmp / "notcmux"
    not_executable.write_text("#!/bin/sh\necho hi\n")
    not_executable.chmod(0o644)
    gateway_env = tmp / "gateway.env"
    _write_secure(gateway_env, "ANTHROPIC_BASE_URL=http://x\n")
    env = os.environ.copy()
    env["CMUX_BIN"] = str(not_executable)
    env["CMUX_GATEWAY_ENV_FILE"] = str(gateway_env)
    for key in SENSITIVE_KEYS:
        env.pop(key, None)
    result = subprocess.run(
        ["bash", str(WRAPPER)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
    assert "not executable" in result.stderr


# --- driver ---


TESTS = [
    test_wrapper_exists_and_is_executable,
    test_exports_keys_from_env_file,
    test_forwards_argv,
    test_ignores_comments_and_blank_lines,
    test_rejects_malformed_lines,
    test_rejects_suspicious_key_names,
    test_refuses_world_readable_env_file,
    test_no_env_file_runs_cmux_anyway,
    test_debug_flag_prints_loaded_keys,
    test_cmux_bin_not_executable_fails_clearly,
]


def main() -> int:
    passed = 0
    failed: list[tuple[str, str]] = []
    for fn in TESTS:
        name = fn.__name__
        try:
            sig_takes_tmp = "tmp" in fn.__code__.co_varnames
            if sig_takes_tmp:
                with tempfile.TemporaryDirectory() as tmpdir:
                    fn(Path(tmpdir))
            else:
                fn()
            print(f"PASS  {name}")
            passed += 1
        except AssertionError as exc:
            print(f"FAIL  {name}: {exc}")
            failed.append((name, str(exc)))
        except Exception as exc:  # noqa: BLE001
            print(f"ERROR {name}: {exc!r}")
            failed.append((name, repr(exc)))
    total = len(TESTS)
    print(f"\n{passed}/{total} passed")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
