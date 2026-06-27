#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import socket
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


def test_wrapper_stops_node_based_foreign_shim_loop(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-node-mutual-shim-loop-") as td:
        root = Path(td)
        cmux_shim_dir = root / "tmp" / "cmux-cli-shims" / "surface-node-loop"
        node_primary_dir = root / "home" / ".node-shim" / "primary"
        node_secondary_dir = root / "home" / ".node-shim" / "secondary"
        real_dir = root / "real-bin"
        for directory in (cmux_shim_dir, node_primary_dir, node_secondary_dir, real_dir):
            directory.mkdir(parents=True, exist_ok=True)

        cmux_shim = cmux_shim_dir / "claude"
        shutil.copy2(WRAPPER, cmux_shim)
        cmux_shim.chmod(0o755)

        node_shim_template = """#!/usr/bin/env node
const { spawnSync } = require("node:child_process");
process.stderr.write(`node shim hop: ${process.argv[1]}\\n`);
const managedPath = process.env.NODE_SHIM_MANAGED_PATH || process.env.PATH || "";
process.env.PATH = managedPath
  .split(":")
  .filter((entry) => entry !== "__SHIM_DIR__")
  .join(":");
const child = spawnSync("claude", process.argv.slice(2), {
  env: process.env,
  stdio: "inherit",
});
process.exit(child.status ?? 1);
"""
        for shim_dir in (node_primary_dir, node_secondary_dir):
            write_executable(
                shim_dir / "claude",
                node_shim_template.replace("__SHIM_DIR__", str(shim_dir)),
            )

        write_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
printf 'real claude %s\\n' "$*"
""",
        )

        inherited_path = os.environ.get("PATH", "/usr/bin:/bin")
        managed_path = f"{cmux_shim_dir}:{node_primary_dir}:{node_secondary_dir}:{real_dir}:{inherited_path}"
        env = {
            "HOME": str(root / "home"),
            "PATH": managed_path,
            "NODE_SHIM_MANAGED_PATH": managed_path,
            "CMUX_CLAUDE_WRAPPER_SHIM": str(cmux_shim),
            "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(cmux_shim_dir),
        }
        try:
            result = subprocess.run(
                [str(cmux_shim), "--version"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except subprocess.TimeoutExpired:
            failures.append("node mutual shim repro timed out instead of terminating")
            return

        combined_output = result.stdout + result.stderr
        if result.returncode == 0:
            failures.append(f"expected non-zero exit from node mutual shim guard, got output: {combined_output!r}")
        if "conflicting `claude` shim" not in combined_output:
            failures.append(f"expected actionable node conflicting-shim error, got: {combined_output!r}")


def test_wrapper_stops_indirect_shell_foreign_shim_loop(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-indirect-mutual-shim-loop-") as td:
        root = Path(td)
        cmux_shim_dir = root / "tmp" / "cmux-cli-shims" / "surface-indirect-loop"
        shell_primary_dir = root / "home" / ".indirect-shim" / "primary"
        shell_secondary_dir = root / "home" / ".indirect-shim" / "secondary"
        real_dir = root / "real-bin"
        for directory in (cmux_shim_dir, shell_primary_dir, shell_secondary_dir, real_dir):
            directory.mkdir(parents=True, exist_ok=True)

        cmux_shim = cmux_shim_dir / "claude"
        shutil.copy2(WRAPPER, cmux_shim)
        cmux_shim.chmod(0o755)

        shell_shim_template = """#!/usr/bin/env bash
next_path=""
old_ifs="$IFS"
IFS=:
for entry in ${INDIRECT_SHIM_MANAGED_PATH:-${PATH:-}}; do
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
cmd=${CLAUDE_BIN:-claude}
exec "$cmd" "$@"
"""
        for shim_dir in (shell_primary_dir, shell_secondary_dir):
            write_executable(
                shim_dir / "claude",
                shell_shim_template.replace("__SHIM_DIR__", str(shim_dir)),
            )

        write_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
printf 'real claude %s\\n' "$*"
""",
        )

        inherited_path = os.environ.get("PATH", "/usr/bin:/bin")
        managed_path = f"{cmux_shim_dir}:{shell_primary_dir}:{shell_secondary_dir}:{real_dir}:{inherited_path}"
        env = {
            "HOME": str(root / "home"),
            "PATH": managed_path,
            "INDIRECT_SHIM_MANAGED_PATH": managed_path,
            "CMUX_CLAUDE_WRAPPER_SHIM": str(cmux_shim),
            "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(cmux_shim_dir),
        }
        try:
            result = subprocess.run(
                [str(cmux_shim), "--version"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except subprocess.TimeoutExpired:
            failures.append("indirect shell mutual shim repro timed out instead of terminating")
            return

        combined_output = result.stdout + result.stderr
        if result.returncode == 0:
            failures.append(f"expected non-zero exit from indirect shell shim guard, got output: {combined_output!r}")
        if "conflicting `claude` shim" not in combined_output:
            failures.append(f"expected actionable indirect-shell conflicting-shim error, got: {combined_output!r}")


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
            """#!/usr/bin/env node
const { spawnSync } = require("node:child_process");
if (process.argv[2] === "child") {
  process.stdout.write("child claude ok\\n");
  process.exit(0);
}
const command = ["cl", "aude"].join("");
const child = spawnSync(command, ["child"], {
  env: process.env,
  encoding: "utf8",
});
if (child.error) {
  process.stderr.write(`${child.error.message}\\n`);
  process.exit(1);
}
process.stdout.write(child.stdout || "");
process.stderr.write(child.stderr || "");
process.exit(child.status ?? 1);
""",
        )

        inherited_path = os.environ.get("PATH", "/usr/bin:/bin")
        env = {
            "HOME": str(root / "home"),
            "PATH": f"{cmux_shim_dir}:{real_dir}:{inherited_path}",
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


def test_wrapper_allows_finite_layered_foreign_shims(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-finite-shim-chain-") as td:
        root = Path(td)
        cmux_shim_dir = root / "tmp" / "cmux-cli-shims" / "surface-finite"
        shim_a_dir = root / "foreign-a"
        shim_b_dir = root / "foreign-b"
        real_dir = root / "real-bin"
        for directory in (cmux_shim_dir, shim_a_dir, shim_b_dir, real_dir):
            directory.mkdir(parents=True, exist_ok=True)

        cmux_shim = cmux_shim_dir / "claude"
        shutil.copy2(WRAPPER, cmux_shim)
        cmux_shim.chmod(0o755)

        shim_template = """#!/usr/bin/env bash
next_path=""
old_ifs="$IFS"
IFS=:
for entry in ${PATH:-}; do
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
        for shim_dir in (shim_a_dir, shim_b_dir):
            write_executable(
                shim_dir / "claude",
                shim_template.replace("__SHIM_DIR__", str(shim_dir)),
            )

        write_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
printf 'real claude reached %s\\n' "$*"
""",
        )

        env = {
            "HOME": str(root / "home"),
            "PATH": f"{cmux_shim_dir}:{shim_a_dir}:{shim_b_dir}:{real_dir}:/usr/bin:/bin",
            "CMUX_CLAUDE_WRAPPER_SHIM": str(cmux_shim),
            "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(cmux_shim_dir),
        }
        result = subprocess.run(
            [str(cmux_shim), "--version"],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        combined_output = result.stdout + result.stderr
        if result.returncode != 0:
            failures.append(f"finite shim chain failed with {result.returncode}: {combined_output!r}")
        if result.stdout.strip() != "real claude reached --version":
            failures.append(f"expected finite shim chain to reach real claude, got: {combined_output!r}")
        if "possible infinite claude shim loop" in combined_output:
            failures.append(f"guard fired for finite shim chain: {combined_output!r}")


def test_passthrough_real_node_claude_does_not_receive_guard_env(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-passthrough-guard-env-") as td:
        root = Path(td)
        cmux_shim_dir = root / "tmp" / "cmux-cli-shims" / "surface-passthrough"
        foreign_shim_dir = root / "foreign-shim"
        real_dir = root / "real-bin"
        for directory in (cmux_shim_dir, foreign_shim_dir, real_dir):
            directory.mkdir(parents=True, exist_ok=True)

        cmux_shim = cmux_shim_dir / "claude"
        shutil.copy2(WRAPPER, cmux_shim)
        cmux_shim.chmod(0o755)

        write_executable(
            foreign_shim_dir / "claude",
            f"""#!/usr/bin/env bash
next_path=""
old_ifs="$IFS"
IFS=:
for entry in ${{PATH:-}}; do
  if [[ "$entry" == "{foreign_shim_dir}" ]]; then
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
""",
        )

        write_executable(
            real_dir / "claude",
            """#!/usr/bin/env node
const upperGuard = process.env.CMUX_CLAUDE_WRAPPER_REEXEC_GUARD ?? "__unset__";
const upperTargets = process.env.CMUX_CLAUDE_WRAPPER_REEXEC_TARGETS ?? "__unset__";
const lowerGuard = process.env.cmux_claude_wrapper_reexec_guard ?? "__unset__";
const lowerTargets = process.env.cmux_claude_wrapper_reexec_targets ?? "__unset__";
const surface = process.env.CMUX_SURFACE_ID ?? "__unset__";
process.stdout.write(
  `upperGuard=${upperGuard}\\n` +
  `upperTargets=${upperTargets}\\n` +
  `lowerGuard=${lowerGuard}\\n` +
  `lowerTargets=${lowerTargets}\\n` +
  `surface=${surface}\\n`
);
""",
        )

        inherited_path = os.environ.get("PATH", "/usr/bin:/bin")
        env = {
            "HOME": str(root / "home"),
            "PATH": f"{cmux_shim_dir}:{foreign_shim_dir}:{real_dir}:{inherited_path}",
            "CMUX_CLAUDE_WRAPPER_SHIM": str(cmux_shim),
            "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(cmux_shim_dir),
            "CMUX_SOCKET_PATH": str(root / "missing.sock"),
            "CMUX_SURFACE_ID": "surface-passthrough",
        }
        result = subprocess.run(
            [str(cmux_shim), "--version"],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        expected = "\n".join(
            [
                "upperGuard=__unset__",
                "upperTargets=__unset__",
                "lowerGuard=__unset__",
                "lowerTargets=__unset__",
                "surface=__unset__",
            ]
        )
        output = result.stdout.strip()
        combined_output = result.stdout + result.stderr
        if result.returncode != 0:
            failures.append(f"passthrough real node claude failed with {result.returncode}: {combined_output!r}")
        if output != expected:
            failures.append(f"expected passthrough cleanup output {expected!r}, got: {combined_output!r}")


def test_custom_shim_path_with_colon_is_tracked_as_one_target(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-custom-shim-target-") as td:
        root = Path(td)
        cmux_shim_dir = root / "tmp" / "cmux-cli-shims" / "surface-custom-colon"
        custom_shim_dir = root / "custom:shim"
        real_dir = root / "real-bin"
        for directory in (cmux_shim_dir, custom_shim_dir, real_dir):
            directory.mkdir(parents=True, exist_ok=True)

        cmux_shim = cmux_shim_dir / "claude"
        shutil.copy2(WRAPPER, cmux_shim)
        cmux_shim.chmod(0o755)

        custom_shim = custom_shim_dir / "claude"
        write_executable(
            custom_shim,
            f"""#!/usr/bin/env bash
printf 'custom colon shim hop\\n' >&2
export PATH="{cmux_shim_dir}:{real_dir}:/usr/bin:/bin"
exec claude "$@"
""",
        )

        write_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
printf 'real claude %s\\n' "$*"
""",
        )

        env = {
            "HOME": str(root / "home"),
            "PATH": f"{cmux_shim_dir}:{real_dir}:/usr/bin:/bin",
            "CMUX_CLAUDE_WRAPPER_SHIM": str(cmux_shim),
            "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(cmux_shim_dir),
            "CMUX_CUSTOM_CLAUDE_PATH": str(custom_shim),
        }
        try:
            result = subprocess.run(
                [str(cmux_shim), "--version"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except subprocess.TimeoutExpired:
            failures.append("custom shim path with colon timed out instead of terminating")
            return

        combined_output = result.stdout + result.stderr
        if result.returncode == 0:
            failures.append(f"expected non-zero exit from custom shim loop guard, got: {combined_output!r}")
        if combined_output.count("custom colon shim hop") != 1:
            failures.append(f"expected repeated custom shim target to be detected after one hop, got: {combined_output!r}")
        if "conflicting `claude` shim" not in combined_output:
            failures.append(f"expected actionable custom-shim error, got: {combined_output!r}")


def test_real_shell_claude_launcher_allows_child_claude_process(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-real-shell-launcher-") as td:
        root = Path(td)
        cmux_shim_dir = root / "tmp" / "cmux-cli-shims" / "surface-shell-launcher"
        real_dir = root / "real-bin"
        package_dir = real_dir / "node_modules" / "@anthropic-ai" / "claude-code"
        for directory in (cmux_shim_dir, package_dir):
            directory.mkdir(parents=True, exist_ok=True)

        cmux_shim = cmux_shim_dir / "claude"
        shutil.copy2(WRAPPER, cmux_shim)
        cmux_shim.chmod(0o755)

        write_executable(
            real_dir / "claude",
            f"""#!/usr/bin/env bash
exec node "{package_dir}/cli.js" "$@"
""",
        )
        write_executable(
            package_dir / "cli.js",
            """#!/usr/bin/env node
const { spawnSync } = require("node:child_process");
if (process.argv[2] === "child") {
  const guard = process.env.cmux_claude_wrapper_reexec_guard ?? "__unset__";
  const targets = process.env.cmux_claude_wrapper_reexec_targets ?? "__unset__";
  process.stdout.write(`child shell launcher ok guard=${guard} targets=${targets}\\n`);
  process.exit(0);
}
const command = ["cl", "aude"].join("");
const child = spawnSync(command, ["child"], {
  env: process.env,
  encoding: "utf8",
});
if (child.error) {
  process.stderr.write(`${child.error.message}\\n`);
  process.exit(1);
}
process.stdout.write(child.stdout || "");
process.stderr.write(child.stderr || "");
process.exit(child.status ?? 1);
""",
        )

        inherited_path = os.environ.get("PATH", "/usr/bin:/bin")
        env = {
            "HOME": str(root / "home"),
            "PATH": f"{cmux_shim_dir}:{real_dir}:{inherited_path}",
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
            failures.append(f"real shell claude launcher failed with {result.returncode}: {combined_output!r}")
        expected = "child shell launcher ok guard=__unset__ targets=__unset__"
        if result.stdout.strip() != expected:
            failures.append(f"expected real shell launcher child output {expected!r}, got: {combined_output!r}")
        if "possible infinite claude shim loop" in combined_output:
            failures.append(f"guard fired for real shell claude launcher child: {combined_output!r}")


def test_custom_shell_wrapper_execing_real_claude_allows_child_claude(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-custom-real-wrapper-") as td:
        root = Path(td)
        cmux_shim_dir = root / "tmp" / "cmux-cli-shims" / "surface-custom-real"
        custom_dir = root / "custom-bin"
        real_dir = root / "real-bin"
        for directory in (cmux_shim_dir, custom_dir, real_dir):
            directory.mkdir(parents=True, exist_ok=True)

        cmux_shim = cmux_shim_dir / "claude"
        shutil.copy2(WRAPPER, cmux_shim)
        cmux_shim.chmod(0o755)

        custom_wrapper = custom_dir / "claude-wrapper"
        write_executable(
            custom_wrapper,
            f"""#!/usr/bin/env bash
export CLAUDE_CUSTOM_WRAPPER_SEEN=1
exec "{real_dir}/claude" "$@"
""",
        )
        write_executable(
            real_dir / "claude",
            """#!/usr/bin/env node
const { spawnSync } = require("node:child_process");
if (process.argv[2] === "child") {
  const guard = process.env.cmux_claude_wrapper_reexec_guard ?? "__unset__";
  const targets = process.env.cmux_claude_wrapper_reexec_targets ?? "__unset__";
  const wrapperSeen = process.env.CLAUDE_CUSTOM_WRAPPER_SEEN ?? "__unset__";
  process.stdout.write(`custom child ok guard=${guard} targets=${targets} wrapper=${wrapperSeen}\\n`);
  process.exit(0);
}
const command = ["cl", "aude"].join("");
const child = spawnSync(command, ["child"], {
  env: process.env,
  encoding: "utf8",
});
if (child.error) {
  process.stderr.write(`${child.error.message}\\n`);
  process.exit(1);
}
process.stdout.write(child.stdout || "");
process.stderr.write(child.stderr || "");
process.exit(child.status ?? 1);
""",
        )

        inherited_path = os.environ.get("PATH", "/usr/bin:/bin")
        env = {
            "HOME": str(root / "home"),
            "PATH": f"{cmux_shim_dir}:{real_dir}:{inherited_path}",
            "CMUX_CLAUDE_WRAPPER_SHIM": str(cmux_shim),
            "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(cmux_shim_dir),
            "CMUX_CUSTOM_CLAUDE_PATH": str(custom_wrapper),
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
            failures.append(f"custom shell wrapper failed with {result.returncode}: {combined_output!r}")
        expected = "custom child ok guard=__unset__ targets=__unset__ wrapper=1"
        if result.stdout.strip() != expected:
            failures.append(f"expected custom shell wrapper child output {expected!r}, got: {combined_output!r}")
        if "possible infinite claude shim loop" in combined_output:
            failures.append(f"guard fired for custom shell wrapper child: {combined_output!r}")


def test_interactive_finite_shim_chain_does_not_duplicate_hooks(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-interactive-finite-shim-") as td:
        root = Path(td)
        cmux_shim_dir = root / "tmp" / "cmux-cli-shims" / "surface-interactive"
        foreign_shim_dir = root / "foreign-shim"
        real_dir = root / "real-bin"
        for directory in (cmux_shim_dir, foreign_shim_dir, real_dir):
            directory.mkdir(parents=True, exist_ok=True)

        cmux_shim = cmux_shim_dir / "claude"
        shutil.copy2(WRAPPER, cmux_shim)
        cmux_shim.chmod(0o755)

        write_executable(
            cmux_shim_dir / "cmux",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
if [[ "${1:-}" == "ping" ]]; then
  exit 0
fi
exit 0
""",
        )
        write_executable(
            foreign_shim_dir / "claude",
            f"""#!/usr/bin/env bash
export PATH="{cmux_shim_dir}:{real_dir}:/usr/bin:/bin"
exec claude "$@"
""",
        )
        write_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
for arg in "$@"; do
  printf '%s\\n' "$arg"
done
""",
        )

        socket_path = str(root / "cmux.sock")
        test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            test_socket.bind(socket_path)
            env = {
                "HOME": str(root / "home"),
                "PATH": f"{cmux_shim_dir}:{foreign_shim_dir}:{real_dir}:/usr/bin:/bin",
                "CMUX_CLAUDE_WRAPPER_SHIM": str(cmux_shim),
                "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(cmux_shim_dir),
                "CMUX_SURFACE_ID": "surface-interactive",
                "CMUX_SOCKET_PATH": socket_path,
            }
            result = subprocess.run(
                [str(cmux_shim)],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        finally:
            test_socket.close()

        combined_output = result.stdout + result.stderr
        if result.returncode != 0:
            failures.append(f"interactive finite shim chain failed with {result.returncode}: {combined_output!r}")
            return

        args = result.stdout.splitlines()
        settings_indexes = [index for index, arg in enumerate(args) if arg == "--settings"]
        if len(settings_indexes) != 1:
            failures.append(f"expected one --settings arg after finite shim chain, got: {args!r}")
            return
        settings_index = settings_indexes[0]
        if settings_index + 1 >= len(args):
            failures.append(f"expected --settings value after finite shim chain, got: {args!r}")
            return
        try:
            settings = json.loads(args[settings_index + 1])
        except Exception as exc:  # noqa: BLE001 - simple test harness
            failures.append(f"expected JSON --settings value, got {args[settings_index + 1]!r}: {exc}")
            return

        hooks = settings.get("hooks", {})
        session_start = hooks.get("SessionStart", [])
        stop = hooks.get("Stop", [])
        if len(session_start) != 1 or len(stop) != 3:
            failures.append(
                "expected one cmux hook injection after finite shim chain, "
                f"got SessionStart={len(session_start)} Stop={len(stop)} settings={settings!r}"
            )


def main() -> int:
    failures: list[str] = []
    test_wrapper_stops_mutual_foreign_shim_loop(failures)
    test_wrapper_stops_node_based_foreign_shim_loop(failures)
    test_wrapper_stops_indirect_shell_foreign_shim_loop(failures)
    test_wrapper_guard_allows_child_claude_process(failures)
    test_wrapper_allows_finite_layered_foreign_shims(failures)
    test_passthrough_real_node_claude_does_not_receive_guard_env(failures)
    test_custom_shim_path_with_colon_is_tracked_as_one_target(failures)
    test_real_shell_claude_launcher_allows_child_claude_process(failures)
    test_custom_shell_wrapper_execing_real_claude_allows_child_claude(failures)
    test_interactive_finite_shim_chain_does_not_duplicate_hooks(failures)
    if failures:
        print("FAIL: claude wrapper mutual shim loop checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: claude wrapper stops mutual shim loops")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
