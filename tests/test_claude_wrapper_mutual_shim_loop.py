#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
from pathlib import Path

from node_runtime import ensure_node_on_path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources" / "bin" / "cmux-claude-wrapper"


def write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def load_settings_value(value: str) -> dict:
    if value.lstrip().startswith(("{", "[")):
        return json.loads(value)
    return json.loads(Path(value).read_text(encoding="utf-8"))


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


def test_app_owned_resume_keeps_authorization_across_finite_shim_reentry(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-restore-shim-chain-") as td:
        root = Path(td)
        cmux_shim_dir = root / "tmp" / "cmux-cli-shims" / "surface-restore"
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
export PATH="{cmux_shim_dir}:{real_dir}:/usr/bin:/bin"
exec claude "$@"
""",
        )
        write_executable(
            cmux_shim_dir / "cmux",
            """#!/usr/bin/env bash
if [[ "${1:-}" == "--socket" ]]; then
  shift 2
fi
[[ "${1:-}" == "ping" ]] && exit 1
exit 0
""",
        )
        environment_log = root / "real-env.log"
        arguments_log = root / "real-args.log"
        write_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
printf 'restore=%s\n' "${CMUX_AGENT_RESTORE_LAUNCH-__UNSET__}" > "$FAKE_REAL_ENV_LOG"
printf 'surface=%s\n' "${CMUX_SURFACE_ID-__UNSET__}" >> "$FAKE_REAL_ENV_LOG"
printf '%s\n' "$@" > "$FAKE_REAL_ARGS_LOG"
""",
        )

        session_id = "5b5d0816-ef91-4a8d-8933-68a114787c40"
        socket_path = root / "stale.sock"
        stale_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stale_socket.bind(str(socket_path))
        env = {
            "HOME": str(root / "home"),
            "PATH": f"{cmux_shim_dir}:{foreign_shim_dir}:{real_dir}:/usr/bin:/bin",
            "CMUX_CLAUDE_WRAPPER_SHIM": str(cmux_shim),
            "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(cmux_shim_dir),
            "CMUX_AGENT_RESTORE_LAUNCH": f"claude:{session_id}",
            "CMUX_SOCKET_PATH": str(socket_path),
            "CMUX_SURFACE_ID": "surface:restore-test",
            "FAKE_REAL_ENV_LOG": str(environment_log),
            "FAKE_REAL_ARGS_LOG": str(arguments_log),
        }
        try:
            result = subprocess.run(
                [str(cmux_shim), "--resume", session_id],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        finally:
            stale_socket.close()

        combined_output = result.stdout + result.stderr
        if result.returncode != 0:
            failures.append(f"app-owned finite shim resume failed with {result.returncode}: {combined_output!r}")
            return
        observed_env = dict(line.split("=", 1) for line in environment_log.read_text().splitlines())
        observed_args = arguments_log.read_text().splitlines()
        if observed_env.get("restore") != "__UNSET__":
            failures.append(f"restore marker leaked through finite shim chain: {observed_env!r}")
        if observed_env.get("surface") != "surface:restore-test":
            failures.append(f"finite shim chain lost cmux surface authorization: {observed_env!r}")
        if "--settings" not in observed_args or observed_args[-2:] != ["--resume", session_id]:
            failures.append(f"finite shim chain lost hook settings or resume argv: {observed_args!r}")


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
            settings = load_settings_value(args[settings_index + 1])
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


def test_interactive_spawning_shim_chain_refreshes_claude_pid(failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-claude-interactive-spawn-shim-") as td:
        root = Path(td)
        cmux_shim_dir = root / "tmp" / "cmux-cli-shims" / "surface-spawn"
        foreign_shim_dir = root / "node-shim"
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
        inherited_path = os.environ.get("PATH", "/usr/bin:/bin")
        write_executable(
            foreign_shim_dir / "claude",
            f"""#!/usr/bin/env node
const {{ spawnSync }} = require("node:child_process");
process.env.PATH = "{cmux_shim_dir}:{real_dir}:{inherited_path}";
const child = spawnSync("claude", process.argv.slice(2), {{
  env: process.env,
  encoding: "utf8",
}});
process.stdout.write(child.stdout || "");
process.stderr.write(child.stderr || "");
process.exit(child.status ?? 1);
""",
        )
        write_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
printf 'real_pid=%s\\n' "$$"
printf 'cmux_pid=%s\\n' "${CMUX_CLAUDE_PID:-__unset__}"
printf 'node_options=%s\\n' "${NODE_OPTIONS:-__unset__}"
for arg in "$@"; do
  printf 'arg=%s\\n' "$arg"
done
""",
        )

        socket_path = str(root / "cmux.sock")
        test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            test_socket.bind(socket_path)
            env = {
                "HOME": str(root / "home"),
                "PATH": f"{cmux_shim_dir}:{foreign_shim_dir}:{real_dir}:{inherited_path}",
                "CMUX_CLAUDE_WRAPPER_SHIM": str(cmux_shim),
                "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(cmux_shim_dir),
                "CMUX_SURFACE_ID": "surface-spawn",
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
            failures.append(f"interactive spawning shim chain failed with {result.returncode}: {combined_output!r}")
            return

        lines = result.stdout.splitlines()
        values: dict[str, str] = {}
        args: list[str] = []
        for line in lines:
            if line.startswith("arg="):
                args.append(line.removeprefix("arg="))
            elif "=" in line:
                key, value = line.split("=", 1)
                values[key] = value
        if values.get("real_pid") != values.get("cmux_pid"):
            failures.append(f"expected CMUX_CLAUDE_PID to match real process pid, got: {combined_output!r}")
            return
        node_options = values.get("node_options", "")
        if "--require=" not in node_options or "--max-old-space-size=4096" not in node_options:
            failures.append(f"expected reentry to reinstall cmux NODE_OPTIONS, got: {combined_output!r}")
            return

        settings_indexes = [index for index, arg in enumerate(args) if arg == "--settings"]
        if len(settings_indexes) != 1:
            failures.append(f"expected one --settings arg after spawning shim chain, got: {combined_output!r}")
            return
        settings_index = settings_indexes[0]
        if settings_index + 1 >= len(args):
            failures.append(f"expected --settings value after spawning shim chain, got: {combined_output!r}")
            return
        settings = load_settings_value(args[settings_index + 1])
        hooks = settings.get("hooks", {})
        if len(hooks.get("SessionStart", [])) != 1 or len(hooks.get("Stop", [])) != 3:
            failures.append(f"expected one hook injection after spawning shim chain, got: {settings!r}")


def verify_custom_path_reentry_result(
    result: subprocess.CompletedProcess[str],
    settings_output: Path,
    inherited_path_log: Path,
    failures: list[str],
) -> None:
    combined_output = result.stdout + result.stderr
    if result.returncode != 0:
        failures.append(f"issue #10230 re-entry failed with {result.returncode}: {combined_output!r}")
        return
    if not settings_output.is_file():
        failures.append(f"issue #10230 re-entry never reached the real Claude binary: {combined_output!r}")
        return
    if not inherited_path_log.is_file():
        failures.append("issue #10230 custom launcher did not record its inherited PATH")
        inherited_path_values: list[str] = []
    else:
        inherited_path_values = inherited_path_log.read_text(encoding="utf-8").splitlines()
    if any(value == "true" for value in inherited_path_values):
        failures.append(
            "issue #10230 custom launcher inherited cmux's shim directory on PATH: "
            f"{inherited_path_values!r}"
        )
    try:
        settings = json.loads(settings_output.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        failures.append(f"issue #10230 emitted invalid settings JSON: {exc}")
        return
    hooks = settings.get("hooks")
    if (
        not isinstance(hooks, dict)
        or not isinstance(hooks.get("SessionStart"), list)
        or not isinstance(hooks.get("Stop"), list)
    ):
        failures.append(f"issue #10230 emitted malformed hooks structure: {hooks!r}")
        return
    if len(hooks["SessionStart"]) != 1 or len(hooks["Stop"]) != 3:
        failures.append(
            "issue #10230 re-entry should converge to one cmux hook block, "
            f"got SessionStart={len(hooks['SessionStart'])} "
            f"Stop={len(hooks['Stop'])}: {settings!r}"
        )


def test_custom_path_reentry_converges_to_one_settings_block(failures: list[str]) -> None:
    """A launcher that re-enters the cmux shim once must not duplicate hooks."""
    node_path = ensure_node_on_path()
    if node_path is None:
        failures.append("issue #10230 re-entry requires a Node runtime")
        return
    with tempfile.TemporaryDirectory(prefix="cmux-claude-issue-10230-reentry-") as td:
        root = Path(td)
        cmux_shim_dir = root / "tmp" / "cmux-cli-shims" / "surface-10230"
        launcher_dir = root / "launcher"
        custom_dir = root / "custom"
        real_dir = root / "real-bin"
        for directory in (cmux_shim_dir, launcher_dir, custom_dir, real_dir):
            directory.mkdir(parents=True, exist_ok=True)

        cmux_shim = cmux_shim_dir / "claude"
        shutil.copy2(WRAPPER, cmux_shim)
        cmux_shim.chmod(0o755)

        cmux_bin = cmux_shim_dir / "cmux"
        write_executable(
            cmux_bin,
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

        launch_count = root / "launcher-count"
        inherited_path_log = root / "launcher-inherited-path.log"
        managed_path = (
            f"{cmux_shim_dir}:{launcher_dir}:{real_dir}:"
            f"{Path(node_path).parent}:/usr/bin:/bin"
        )
        write_executable(
            launcher_dir / "resolve-claude",
            f"""#!/usr/bin/env node
const fs = require("node:fs");
const {{ spawnSync }} = require("node:child_process");
const countPath = {json.dumps(str(launch_count))};
const inheritedPathLog = {json.dumps(str(inherited_path_log))};
fs.appendFileSync(inheritedPathLog, `${{(process.env.PATH || "").includes("/cmux-cli-shims/")}}\n`);
const firstHop = !fs.existsSync(countPath);
if (firstHop) fs.writeFileSync(countPath, "1");
// The first lookup intentionally restores the managed path to reproduce a
// downstream launcher that does not know about cmux's shim directory.
process.env.PATH = firstHop
  ? {json.dumps(managed_path)}
  : process.env.PATH.split(":").filter((entry) => !entry.includes("/cmux-cli-shims/")).join(":");
const entries = (process.env.PATH || "").split(":");
const target = entries.map((entry) => `${{entry}}/claude`).find((candidate) =>
  fs.existsSync(candidate) && fs.statSync(candidate).isFile()
);
if (!target) process.exit(127);
const child = spawnSync(target, process.argv.slice(2), {{ env: process.env, encoding: "utf8" }});
process.stdout.write(child.stdout || "");
process.stderr.write(child.stderr || "");
process.exit(child.status ?? 1);
""",
        )

        custom_path = custom_dir / "agent-entry"
        write_executable(
            custom_path,
            """#!/usr/bin/env bash
exec "$CMUX_LAUNCHER" "$@"
""",
        )

        settings_output = root / "settings-output.json"
        write_executable(
            real_dir / "claude",
            """#!/usr/bin/env bash
set -euo pipefail
settings_path=""
while (( $# > 0 )); do
  if [[ "$1" == "--settings" && $# -gt 1 ]]; then
    settings_path="$2"
    shift 2
    continue
  fi
  shift
done
[[ -n "$settings_path" ]] && cp "$settings_path" "$FAKE_SETTINGS_OUTPUT"
""",
        )

        socket_path = root / "cmux.sock"
        test_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            test_socket.bind(str(socket_path))
            inherited_path = os.environ.get("PATH", "/usr/bin:/bin")
            env = {
                "HOME": str(root / "home"),
                "PATH": f"{cmux_shim_dir}:{launcher_dir}:{real_dir}:{inherited_path}",
                "CMUX_CLAUDE_WRAPPER_SHIM": str(cmux_shim),
                "CMUX_CLAUDE_WRAPPER_SHIM_ROOT": str(cmux_shim_dir),
                "CMUX_CUSTOM_CLAUDE_PATH": str(custom_path),
                "CMUX_LAUNCHER": str(launcher_dir / "resolve-claude"),
                "CMUX_SURFACE_ID": "surface-10230",
                "CMUX_SOCKET_PATH": str(socket_path),
                "CMUX_BUNDLED_CLI_PATH": str(cmux_bin),
                "TMPDIR": str(root / "tmp"),
                "FAKE_SETTINGS_OUTPUT": str(settings_output),
            }
            result = subprocess.run(
                [str(cmux_shim), "hello"],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except subprocess.TimeoutExpired:
            failures.append("issue #10230 re-entry timed out instead of converging")
            return
        finally:
            test_socket.close()

        verify_custom_path_reentry_result(result, settings_output, inherited_path_log, failures)


def main() -> int:
    if ensure_node_on_path() is None:
        print("SKIP: node runtime not found; shim fakes exec node")
        return 0
    failures: list[str] = []
    test_wrapper_stops_mutual_foreign_shim_loop(failures)
    test_wrapper_stops_node_based_foreign_shim_loop(failures)
    test_wrapper_stops_indirect_shell_foreign_shim_loop(failures)
    test_wrapper_guard_allows_child_claude_process(failures)
    test_wrapper_allows_finite_layered_foreign_shims(failures)
    test_app_owned_resume_keeps_authorization_across_finite_shim_reentry(failures)
    test_passthrough_real_node_claude_does_not_receive_guard_env(failures)
    test_custom_shim_path_with_colon_is_tracked_as_one_target(failures)
    test_real_shell_claude_launcher_allows_child_claude_process(failures)
    test_custom_shell_wrapper_execing_real_claude_allows_child_claude(failures)
    test_interactive_finite_shim_chain_does_not_duplicate_hooks(failures)
    test_interactive_spawning_shim_chain_refreshes_claude_pid(failures)
    test_custom_path_reentry_converges_to_one_settings_block(failures)
    if failures:
        print("FAIL: claude wrapper mutual shim loop checks failed")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: claude wrapper stops mutual shim loops")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
