#!/usr/bin/env python3
"""
Verify the compiled Swift ArgumentParser command inventory matches the CLI spec.

This does not inspect Swift source. The candidate binary prints its internal
ArgumentParser-backed inventory, and the test compares that runtime output to
docs/cli-contract.md.
"""

from __future__ import annotations

import glob
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates = [
        path
        for path in glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux"))
        if os.path.exists(path) and os.access(path, os.X_OK)
    ]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def load_documented_command_forms() -> set[str]:
    module_path = repo_root() / "tests" / "test_cli_golden_contract.py"
    spec = importlib.util.spec_from_file_location("cli_golden_contract", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return set(module.documented_command_forms())


def load_compiled_inventory(cli_path: str) -> set[str]:
    env = os.environ.copy()
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    proc = subprocess.run(  # noqa: S603
        [cli_path, "__argument-parser-inventory", "--verify", "--json"],
        text=True,
        capture_output=True,
        check=False,
        timeout=20.0,
        env=env,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            "inventory command failed\n"
            f"stdout={proc.stdout!r}\n"
            f"stderr={proc.stderr!r}"
        )
    payload = json.loads(proc.stdout)
    if payload.get("verified") is not True:
        raise RuntimeError(f"inventory did not report verified=true: {payload!r}")
    forms = payload.get("forms")
    if not isinstance(forms, list) or not all(isinstance(item, str) for item in forms):
        raise RuntimeError(f"inventory forms are malformed: {forms!r}")
    return set(forms)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
        documented = load_documented_command_forms()
        compiled = load_compiled_inventory(cli_path)
    except (RuntimeError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FAIL: {exc}")
        return 1

    missing = sorted(documented - compiled)
    extra = sorted(compiled - documented)
    if missing or extra:
        print("FAIL: CLI ArgumentParser inventory does not match docs/cli-contract.md")
        if missing:
            print("")
            print("Documented but missing from compiled inventory:")
            for item in missing:
                print(f"  {item}")
        if extra:
            print("")
            print("Compiled but missing from docs/cli-contract.md:")
            for item in extra:
                print(f"  {item}")
        return 1

    print(f"PASS: CLI ArgumentParser inventory matches docs for {len(documented)} command forms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
