#!/usr/bin/env python3

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    recorded_path = Path("/tmp/cmux-last-cli-path")
    if recorded_path.exists():
        candidate = recorded_path.read_text(encoding="utf-8").strip()
        if candidate and os.path.exists(candidate) and os.access(candidate, os.X_OK):
            return candidate

    raise RuntimeError(
        "Unable to find cmux CLI binary. Set CMUX_CLI_BIN or run ./scripts/reload.sh --tag <tag> first."
    )


def install_pi_extension(config_dir: Path, cli_path: str | None = None) -> Path:
    env = os.environ.copy()
    env["PI_CODING_AGENT_DIR"] = str(config_dir)
    install = subprocess.run(
        [cli_path or resolve_cmux_cli(), "hooks", "pi", "install", "--yes"],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=20,
    )
    if install.returncode != 0:
        raise RuntimeError(
            f"exit={install.returncode} stdout={install.stdout!r} stderr={install.stderr!r}"
        )

    extension_path = config_dir / "extensions" / "cmux-session.ts"
    if not extension_path.exists():
        raise RuntimeError(f"expected extension at {extension_path}")
    override = os.environ.get("CMUX_TEST_PI_EXTENSION_OVERRIDE")
    if override:
        shutil.copyfile(override, extension_path)
    return extension_path
