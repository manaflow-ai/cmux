#!/usr/bin/env python3
"""
Regression test: `cmux omo` points OpenCode at a shadow config dir. Everything
the user keeps in ~/.config/opencode besides the files cmux owns there (agents,
commands, prompt files referenced as {file:./...}) must be visible from the
shadow dir, or user-defined agents and prompts silently stop loading.
https://github.com/manaflow-ai/cmux/issues/14844
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


def run_omo(cli_path: str, root: Path) -> subprocess.CompletedProcess[str]:
    fake_bin = root / "bin"
    fake_bin.mkdir(exist_ok=True)
    make_executable(fake_bin / "opencode", "#!/usr/bin/env bash\nexit 0\n")
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
    # A non-session OMO command still prepares the shadow config.
    return subprocess.run(
        [cli_path, "omo", "models"],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=20,
    )


def make_user_config(root: Path) -> Path:
    user_dir = root / ".config" / "opencode"
    user_dir.mkdir(parents=True)
    (user_dir / "opencode.json").write_text(
        json.dumps({"agent": {"chief": {"prompt": "{file:./prompts/chief.md}"}}}),
        encoding="utf-8",
    )
    (user_dir / "package.json").write_text('{"dependencies": {}}', encoding="utf-8")
    (user_dir / "prompts").mkdir()
    (user_dir / "prompts" / "chief.md").write_text("You are the chief.\n", encoding="utf-8")
    (user_dir / "agents").mkdir()
    (user_dir / "agents" / "reviewer.md").write_text("---\ndescription: reviews\n---\n", encoding="utf-8")
    (user_dir / "commands").mkdir()
    (user_dir / "commands" / "ship.md").write_text("Ship it.\n", encoding="utf-8")
    return user_dir


def check_user_config_is_mirrored(cli_path: str, failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-omo-mirror-") as td:
        root = Path(td)
        user_dir = make_user_config(root)
        run = run_omo(cli_path, root)
        shadow = root / ".cmuxterm" / "omo-config"
        if not (shadow / "opencode.json").exists():
            failures.append(f"shadow opencode.json missing; exit={run.returncode} stderr={run.stderr.strip()}")
            return

        for relative in ["prompts/chief.md", "agents/reviewer.md", "commands/ship.md"]:
            shadow_file = shadow / relative
            if not shadow_file.exists():
                failures.append(f"{relative} is not visible from the shadow config dir")
            elif shadow_file.read_text(encoding="utf-8") != (user_dir / relative).read_text(encoding="utf-8"):
                failures.append(f"{relative} in the shadow dir does not match the user's file")

        # cmux owns these in the shadow dir; they must not become links to the user's copies.
        for owned in ["opencode.json", "package.json"]:
            if (shadow / owned).is_symlink():
                failures.append(f"shadow {owned} was replaced by a link to the user's file")


def check_user_plugins_load_beside_the_session_plugin(cli_path: str, failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-omo-plugins-") as td:
        root = Path(td)
        user_dir = make_user_config(root)
        (user_dir / "plugins").mkdir()
        (user_dir / "plugins" / "notify.js").write_text("export const Notify = async () => ({})\n", encoding="utf-8")
        run = run_omo(cli_path, root)
        shadow_plugins = root / ".cmuxterm" / "omo-config" / "plugins"
        if not (shadow_plugins / "cmux-session.js").exists():
            failures.append(f"cmux session plugin missing from the shadow dir; exit={run.returncode} stderr={run.stderr.strip()}")
        if not (shadow_plugins / "notify.js").exists():
            failures.append("the user's plugins/notify.js is not visible from the shadow config dir")
        # The session plugin is cmux's; it must not leak into the user's own config.
        if (user_dir / "plugins" / "cmux-session.js").exists():
            failures.append("cmux wrote its session plugin into the user's plugins dir")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    failures: list[str] = []
    check_user_config_is_mirrored(cli_path, failures)
    check_user_plugins_load_beside_the_session_plugin(cli_path, failures)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("PASS: cmux omo exposes the user's OpenCode config dir through the shadow config")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
