#!/usr/bin/env python3
"""
Regression test: `cmux omo` points OpenCode at a shadow config dir holding a
copy of the user's opencode.json. Relative references in that copy, such as
{file:./prompts/chief.md}, resolve against the shadow dir, so the files they
name must be visible there. OpenCode already scans the user's real config dir
for agents, commands, modes, plugins, tools, and skills; linking those into the
shadow dir too would load each one twice, and linking package-lock.json would
let OpenCode's npm install in the shadow dir rewrite the user's lockfile.
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


def check_referenced_files_are_mirrored(cli_path: str, failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-omo-mirror-") as td:
        root = Path(td)
        user_dir = make_user_config(root)
        run = run_omo(cli_path, root)
        shadow = root / ".cmuxterm" / "omo-config"
        if not (shadow / "opencode.json").exists():
            failures.append(f"shadow opencode.json missing; exit={run.returncode} stderr={run.stderr.strip()}")
            return

        shadow_prompt = shadow / "prompts" / "chief.md"
        if not shadow_prompt.exists():
            failures.append("prompts/chief.md, referenced as {file:./prompts/chief.md}, is not visible from the shadow config dir")
        elif shadow_prompt.read_text(encoding="utf-8") != (user_dir / "prompts" / "chief.md").read_text(encoding="utf-8"):
            failures.append("prompts/chief.md in the shadow dir does not match the user's file")

        # cmux owns these in the shadow dir; they must not become links to the user's copies.
        for owned in ["opencode.json", "package.json"]:
            if (shadow / owned).is_symlink():
                failures.append(f"shadow {owned} was replaced by a link to the user's file")


def check_auto_discovered_entries_are_not_mirrored(cli_path: str, failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-omo-discovered-") as td:
        root = Path(td)
        user_dir = make_user_config(root)
        for folder, filename in [
            ("plugins", "notify.js"),
            ("plugin", "legacy.js"),
            ("modes", "focus.md"),
            ("tools", "lookup.ts"),
            ("skills", "SKILL.md"),
        ]:
            (user_dir / folder).mkdir(exist_ok=True)
            (user_dir / folder / filename).write_text("// user file\n", encoding="utf-8")
        (user_dir / "package-lock.json").write_text('{"lockfileVersion": 3}', encoding="utf-8")
        run = run_omo(cli_path, root)
        shadow = root / ".cmuxterm" / "omo-config"

        # OpenCode loads these from the user's real config dir already.
        for relative in [
            "agents", "commands", "modes", "tools", "skills", "plugin",
            "plugins/notify.js", "package-lock.json",
        ]:
            if os.path.lexists(shadow / relative):
                failures.append(f"shadow {relative} exists, so OpenCode would load or write it a second time")
        if not (shadow / "plugins" / "cmux-session.js").exists():
            failures.append(f"cmux session plugin missing from the shadow dir; exit={run.returncode} stderr={run.stderr.strip()}")
        if (user_dir / "plugins" / "cmux-session.js").exists():
            failures.append("cmux wrote its session plugin into the user's plugins dir")


def check_removed_user_entries_do_not_leave_dangling_links(cli_path: str, failures: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="cmux-omo-prune-") as td:
        root = Path(td)
        user_dir = make_user_config(root)
        (user_dir / "snippets").mkdir()
        (user_dir / "snippets" / "intro.md").write_text("Hello.\n", encoding="utf-8")
        # Installed packages are shared through a node_modules link that pruning must keep.
        (user_dir / "node_modules" / "oh-my-openagent").mkdir(parents=True)
        run_omo(cli_path, root)
        shadow = root / ".cmuxterm" / "omo-config"

        # The user removes a folder, then launches omo again.
        (user_dir / "snippets" / "intro.md").unlink()
        (user_dir / "snippets").rmdir()
        run = run_omo(cli_path, root)

        if os.path.lexists(shadow / "snippets"):
            failures.append(f"shadow snippets still exists after the user removed it; exit={run.returncode}")
        if not (shadow / "plugins" / "cmux-session.js").exists():
            failures.append("pruning removed the cmux session plugin")
        if not (shadow / "prompts" / "chief.md").exists():
            failures.append("pruning removed a link whose target still exists")
        shadow_node_modules = shadow / "node_modules"
        if not shadow_node_modules.is_symlink() or shadow_node_modules.resolve() != (user_dir / "node_modules").resolve():
            failures.append("pruning dropped the shared node_modules link")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    failures: list[str] = []
    check_referenced_files_are_mirrored(cli_path, failures)
    check_auto_discovered_entries_are_not_mirrored(cli_path, failures)
    check_removed_user_entries_do_not_leave_dangling_links(cli_path, failures)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("PASS: cmux omo exposes referenced config files without duplicating what OpenCode already loads")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
