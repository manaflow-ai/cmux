#!/usr/bin/env python3
"""
Regression test: cmux omo must not re-add the legacy oh-my-opencode plugin
when the user's OpenCode config already contains the renamed oh-my-openagent
package, including mixed current/legacy configs left by prior migrations.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli


def make_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def plugin_spec(entry: object) -> str:
    if isinstance(entry, str):
        return entry
    if isinstance(entry, list) and entry and isinstance(entry[0], str):
        return entry[0]
    return ""


def plugin_package_name(entry: object) -> str:
    spec = plugin_spec(entry)
    if spec.startswith(".") or "/" in spec:
        return spec
    return spec.split("@", 1)[0]


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-omo-openagent-") as td:
        root = Path(td)
        fake_bin = root / "bin"
        fake_bin.mkdir()

        user_config_dir = root / ".config" / "opencode"
        user_config_dir.mkdir(parents=True)
        user_config_json = user_config_dir / "opencode.json"
        user_config_json.write_text(
            json.dumps({
                "plugin": [
                    "oh-my-openagent",
                    "oh-my-opencode@2.0.0",
                    "oh-my-openagent@3.17.5",
                    ["oh-my-opencode", "1.0.0"],
                ]
            }),
            encoding="utf-8",
        )

        make_executable(
            fake_bin / "opencode",
            """#!/usr/bin/env bash
set -euo pipefail
printf 'fake opencode invoked\\n' >&2
printf '%s\\n' "${OPENCODE_CONFIG_DIR-}" > "$HOME/opencode-config-dir.log"
""",
        )
        make_executable(
            fake_bin / "bun",
            """#!/usr/bin/env bash
set -euo pipefail
package="${@: -1}"
mkdir -p "node_modules/$package"
""",
        )

        env = os.environ.copy()
        env["HOME"] = str(root)
        env["PATH"] = f"{fake_bin}:{env.get('PATH', '')}"
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        env["CMUX_SOCKET_PATH"] = str(root / "missing.sock")

        run = subprocess.run(
            [cli_path, "omo", "--model", "test"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=20,
        )

        shadow_config_json = root / ".cmuxterm" / "omo-config" / "opencode.json"
        try:
            shadow_config = json.loads(shadow_config_json.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"FAIL: invalid shadow opencode.json: {exc}")
            return 1

        plugins = shadow_config.get("plugin")
        if not isinstance(plugins, list):
            print(f"FAIL: expected shadow plugin list, got {plugins!r}")
            return 1

        package_names = [plugin_package_name(entry) for entry in plugins]
        if "oh-my-opencode" in package_names:
            print(f"FAIL: cmux omo re-added legacy plugin name: {plugins!r}")
            return 1
        specs = [plugin_spec(entry) for entry in plugins]
        openagent_specs = [
            spec for entry, spec in zip(plugins, specs)
            if plugin_package_name(entry) == "oh-my-openagent"
        ]
        if openagent_specs != ["oh-my-openagent@3.17.5"]:
            print(
                "FAIL: cmux omo did not prefer the existing renamed plugin entry; "
                f"got {plugins!r}"
            )
            return 1

        opencode_log = root / "opencode-config-dir.log"
        if not opencode_log.exists():
            print("FAIL: fake opencode was not invoked (opencode-config-dir.log missing)")
            print(f"opencode_log={opencode_log}")
            print(f"exit={run.returncode}")
            print(f"stdout={run.stdout.strip()}")
            print(f"stderr={run.stderr.strip()}")
            return 1
        opencode_log_content = opencode_log.read_text(encoding="utf-8")
        opencode_config_dir = opencode_log_content.strip()
        expected_config_dir = str(root / ".cmuxterm" / "omo-config")
        if opencode_config_dir != expected_config_dir:
            print(
                "FAIL: fake opencode received wrong OPENCODE_CONFIG_DIR; "
                f"expected {expected_config_dir!r}, got {opencode_config_dir!r}"
            )
            return 1

        package_json = root / ".cmuxterm" / "omo-config" / "package.json"
        try:
            package_manifest = json.loads(package_json.read_text(encoding="utf-8"))
        except Exception as exc:
            print(f"FAIL: invalid shadow package.json: {exc}")
            return 1

        dependencies = package_manifest.get("dependencies")
        if not isinstance(dependencies, dict):
            print(f"FAIL: expected shadow dependencies, got {dependencies!r}")
            return 1
        if "oh-my-opencode" in dependencies:
            print(f"FAIL: shadow package manifest still pins legacy package: {dependencies!r}")
            return 1
        if dependencies.get("oh-my-openagent") != "latest":
            print(f"FAIL: shadow package manifest did not request oh-my-openagent: {dependencies!r}")
            return 1

        if run.returncode != 0:
            print("FAIL: cmux omo reached fake opencode but returned non-zero")
            print(f"exit={run.returncode}")
            print(f"opencode_log={opencode_log_content.strip()!r}")
            print(f"stdout={run.stdout.strip()}")
            print(f"stderr={run.stderr.strip()}")
            return 1

    print("PASS: cmux omo preserves oh-my-openagent without legacy plugin loop")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
