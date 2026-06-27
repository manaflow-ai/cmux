#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def build_mutual_shim_tree(root: Path) -> tuple[Path, dict[str, str]]:
    cmux_shim_dir = root / "tmp" / "cmux-cli-shims" / "surface-loop"
    delimit_primary_dir = root / "home" / ".delimit" / "shims"
    delimit_secondary_dir = root / "home" / ".delimit" / "managed-shims"
    real_dir = root / "real-bin"
    for directory in (cmux_shim_dir, delimit_primary_dir, delimit_secondary_dir, real_dir):
        directory.mkdir(parents=True, exist_ok=True)

    cmux_shim = cmux_shim_dir / "claude"
    shutil.copy2(WRAPPER, cmux_shim)
    cmux_shim.chmod(0o755)

    shim_template = """#!/usr/bin/env bash
printf 'delimit shim hop: %s\\n' "$0" >&2
next_path=""
old_ifs="$IFS"
IFS=:
for entry in ${DELIMIT_MANAGED_PATH:-${PATH:-}}; do
  if [[ "$entry" == "__SHIM_DIR__" ]]; then
    continue
  fi
  if [[ -z "$next_path" ]]; then
    next_path="$entry"
  else
    next_path="$next_path:$entry"
  fi
done
IFS="$old_ifs"
export PATH="$next_path"
exec claude "$@"
"""
    for shim_dir in (delimit_primary_dir, delimit_secondary_dir):
        write_executable(
            shim_dir / "claude",
            shim_template.replace("__SHIM_DIR__", str(shim_dir)),
        )

    write_executable(
        real_dir / "claude",
        """#!/usr/bin/env bash
printf 'real claude %s\\n' "$*"
""",
    )

    managed_path = f"{cmux_shim_dir}:{delimit_primary_dir}:{delimit_secondary_dir}:{real_dir}:/usr/bin:/bin"
    env = {
        "HOME": str(root / "home"),
        "PATH": managed_path,
        "DELIMIT_MANAGED_PATH": managed_path,
        "CMUX_CLAUDE_WRAPPER_SHIM": str(cmux_shim),
        "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(cmux_shim_dir),
    }
    return cmux_shim, env


def test_wrapper_stops_mutual_foreign_shim_loop(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-mutual-shim-loop-") as td:
        claude, env = build_mutual_shim_tree(Path(td))
        try:
            result = subprocess.run(
                [str(claude), "--version"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except subprocess.TimeoutExpired:
            failures.append("mutual shim repro timed out instead of terminating")
            return

        combined_output = result.stdout + result.stderr
        if result.returncode == 0:
            failures.append(f"expected non-zero exit from mutual shim guard, got output: {combined_output!r}")
        if "conflicting `claude` shim" not in combined_output:
            failures.append(f"expected actionable conflicting-shim error, got: {combined_output!r}")
        if "CMUX_CUSTOM_CLAUDE_PATH" not in combined_output:
            failures.append(f"expected CMUX_CUSTOM_CLAUDE_PATH remedy, got: {combined_output!r}")


def test_wrapper_guard_allows_child_claude_process(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-child-reentry-") as td:
        root = Path(td)
        cmux_shim_dir = root / "tmp" / "cmux-cli-shims" / "surface-child"
        real_dir = root / "real-bin"
        for directory in (cmux_shim_dir, real_dir):
            directory.mkdir(parents=True, exist_ok=True)

        cmux_shim = cmux_shim_dir / "claude"
        shutil.copy2(WRAPPER, cmux_shim)
        cmux_shim.chmod(0o755)

        write_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "child" ]]; then
  printf 'child claude ok\\n'
  exit 0
fi
claude child
""",
        )

        env = {
            "HOME": str(root / "home"),
            "PATH": f"{cmux_shim_dir}:{real_dir}:/usr/bin:/bin",
            "CMUX_CLAUDE_WRAPPER_SHIM": str(cmux_shim),
            "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(cmux_shim_dir),
        }
        result = subprocess.run(
            [str(cmux_shim)],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        combined_output = result.stdout + result.stderr
        if result.returncode != 0:
            failures.append(f"child claude launch failed with {result.returncode}: {combined_output!r}")
        if result.stdout.strip() != "child claude ok":
            failures.append(f"expected child claude to run, got: {combined_output!r}")
        if "possible infinite claude shim loop" in combined_output:
            failures.append(f"guard fired for legitimate child claude launch: {combined_output!r}")


def main() -> int:
    failures: list[str] = []
    test_wrapper_stops_mutual_foreign_shim_loop(failures)
    test_wrapper_guard_allows_child_claude_process(failures)
    if failures:
        print("FAIL: claude wrapper mutual shim loop checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: claude wrapper stops mutual shim loops")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
