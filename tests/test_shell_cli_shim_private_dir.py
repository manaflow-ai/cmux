#!/usr/bin/env python3
"""Shell integrations keep command shims and state files in private directories.

Each shell writes its claude shim to ${TMPDIR:-/tmp}/cmux-cli-shims/<surface>
unless the app handed it a root, then puts that directory at the front of PATH.
Bash also keeps PR-hint and history scratch files under TMPDIR. A directory
that another user could have created or can write to must not hold anything
the shell later runs or reads, so these cases pre-create unsafe directories and
check that the shell leaves them alone, keeps them off PATH and never runs what
they contain.

The owner check can't be exercised without a second account. Group- or
other-writable directories and symlinks stand in for directories that someone
else controls.
"""

from __future__ import annotations

import contextlib
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INTEGRATION_DIR = REPO_ROOT / "Resources/shell-integration"
SURFACE_ID = "88888888-8888-4888-8888-888888888888"
MARKER_SCRIPT = '#!/bin/sh\nprintf "%s\\n" {name} >> "$CMUX_TEST_MARKERS"\n'

POSIX_DRIVER = r'''
source "$CMUX_TEST_INTEGRATION"
printf 'root=%s\n' "${CMUX_CLAUDE_WRAPPER_SHIM_ROOT:-}"
printf 'shim=%s\n' "${CMUX_CLAUDE_WRAPPER_SHIM:-}"
printf 'path=%s\n' "$PATH"
claude >/dev/null 2>&1
command claude >/dev/null 2>&1
exit 0
'''

FISH_DRIVER = r'''
source "$CMUX_TEST_INTEGRATION"
printf 'root=%s\n' "$CMUX_CLAUDE_WRAPPER_SHIM_ROOT"
printf 'shim=%s\n' "$CMUX_CLAUDE_WRAPPER_SHIM"
printf 'path=%s\n' (string join : -- $PATH)
claude >/dev/null 2>&1
command claude >/dev/null 2>&1
exit 0
'''

BASH_STATE_DRIVER = r'''
source "$CMUX_TEST_INTEGRATION"
printf 'hint=%s\n' "${_CMUX_PR_ACTION_HINT_FILE:-}"
printf 'history=%s\n' "${_CMUX_BASH_HISTORY_LAST_FILE:-}"
_cmux_start_tracked_bg bg_pid /bin/sleep 0
printf 'bgpid=%s\n' "$bg_pid"
set -o history
# history -s replaces this line's own entry, so read it back on the same line.
history -s 'echo private-history'; historycmd="$(_cmux_bash_history_command)"
printf 'historycmd=%s\n' "$historycmd"
exit 0
'''

NONSTICKY_ANCESTOR_POSIX_DRIVER = r'''
source "$CMUX_TEST_INTEGRATION"
old="$TMPDIR/cmux-cli-shims"
/bin/mv "$old" "$TMPDIR/cmux-cli-shims-old"
/bin/mkdir -m 700 "$old"
/bin/mkdir -m 700 "$old/$CMUX_SURFACE_ID"
printf '#!/bin/sh\nprintf "attacker\\n" >> "$CMUX_TEST_MARKERS"\n' > "$old/$CMUX_SURFACE_ID/claude"
/bin/chmod 700 "$old/$CMUX_SURFACE_ID/claude"
claude >/dev/null 2>&1
'''

NONSTICKY_ANCESTOR_FISH_DRIVER = r'''
source "$CMUX_TEST_INTEGRATION"
set old "$TMPDIR/cmux-cli-shims"
/bin/mv "$old" "$TMPDIR/cmux-cli-shims-old"
/bin/mkdir -m 700 "$old"
/bin/mkdir -m 700 "$old/$CMUX_SURFACE_ID"
printf '#!/bin/sh\nprintf "attacker\\n" >> "$CMUX_TEST_MARKERS"\n' > "$old/$CMUX_SURFACE_ID/claude"
/bin/chmod 700 "$old/$CMUX_SURFACE_ID/claude"
claude >/dev/null 2>&1
'''


def shells() -> dict[str, tuple[str, list[str], Path, str]]:
    found: dict[str, tuple[str, list[str], Path, str]] = {}
    bash_integration = INTEGRATION_DIR / "cmux-bash-integration.bash"
    # macOS ships bash 3.2 as /bin/bash; also cover a newer bash when present.
    for bash in dict.fromkeys(filter(None, ["/bin/bash", shutil.which("bash")])):
        found[bash] = (bash, ["--noprofile", "--norc", "-c"], bash_integration, POSIX_DRIVER)
    zsh = shutil.which("zsh") or "/bin/zsh"
    found[zsh] = (zsh, ["-f", "-c"], INTEGRATION_DIR / "cmux-zsh-integration.zsh", POSIX_DRIVER)
    fish = shutil.which("fish")
    if fish is not None:
        found[fish] = (fish, ["--no-config", "-c"], INTEGRATION_DIR / "fish/config.fish", FISH_DRIVER)
    return found


def mode(path: Path) -> int:
    return stat.S_IMODE(path.lstat().st_mode)


def write_script(path: Path, name: str) -> None:
    path.write_text(MARKER_SCRIPT.format(name=name), encoding="utf-8")
    path.chmod(0o755)


class Case:
    """One isolated TMPDIR, HOME and fake app bundle for a single shell run."""

    def __init__(self, base: Path) -> None:
        self.base = base
        self.tmp = base / "tmp"
        self.tmp.mkdir()
        self.tmp.chmod(0o1777)
        self.home = base / "home"
        self.home.mkdir()
        integration = base / "bundle/Resources/shell-integration"
        integration.mkdir(parents=True)
        (base / "bundle/Resources/bin").mkdir()
        self.integration_dir = integration
        self.wrapper = base / "bundle/Resources/bin/cmux-claude-wrapper"
        write_script(self.wrapper, "wrapper")
        self.markers = base / "markers"
        self.state = self.home / ".cmuxterm"
        self.state.mkdir(mode=0o700)
        self.parent = self.state / "cmux-cli-shims"
        self.root = self.parent / SURFACE_ID
        self.env = {
            key: value for key, value in os.environ.items() if not key.startswith("CMUX_")
        }
        self.env.update(
            {
                "HOME": str(self.home),
                "TMPDIR": str(self.tmp),
                "PATH": "/usr/bin:/bin",
                "CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION": "0",
                "CMUX_SHELL_INTEGRATION_DIR": str(integration),
                "CMUX_SOCKET_PATH": "",
                "CMUX_SURFACE_ID": SURFACE_ID,
                "CMUX_TEST_MARKERS": str(self.markers),
                "GHOSTTY_RESOURCES_DIR": "",
            }
        )

    def inherit_root(self, root: Path) -> None:
        self.env["CMUX_CLAUDE_WRAPPER_SHIM_ROOT"] = str(root)
        self.env["CMUX_CLAUDE_WRAPPER_SHIM"] = str(root / "claude")
        self.env["PATH"] = f"{root}:{self.env['PATH']}"

    def run(self, shell: tuple[str, list[str], Path, str], driver: str | None = None) -> dict[str, str]:
        executable, argv, integration, default_driver = shell
        env = dict(self.env, CMUX_TEST_INTEGRATION=str(integration))
        proc = subprocess.run(
            [executable, *argv, driver or default_driver],
            capture_output=True,
            text=True,
            check=False,
            env=env,
            cwd=self.home,
            timeout=30,
        )
        if proc.returncode != 0:
            raise AssertionError(f"{executable} exited {proc.returncode}: {proc.stderr}")
        values: dict[str, str] = {}
        for line in proc.stdout.splitlines():
            key, sep, value = line.partition("=")
            if sep:
                values[key] = value
        values["stderr"] = proc.stderr
        return values

    def marker_lines(self) -> list[str]:
        if not self.markers.exists():
            return []
        return self.markers.read_text(encoding="utf-8").splitlines()


@contextlib.contextmanager
def new_case(prefix: str):
    with tempfile.TemporaryDirectory(prefix=prefix) as td:
        yield Case(Path(td))


class CliShimPrivateDirectory(unittest.TestCase):
    def setUp(self) -> None:
        self.previous_umask = os.umask(0o022)

    def tearDown(self) -> None:
        os.umask(self.previous_umask)

    def for_each_shell(self, scenario, **labels) -> None:
        for name, shell in shells().items():
            with self.subTest(shell=name, **labels), new_case("cmux-shim-private-") as case:
                scenario(shell, case)

    def assert_no_shim(self, case: Case, out: dict[str, str], *unsafe: Path) -> None:
        self.assertEqual(out["root"], "", out)
        self.assertEqual(out["shim"], "", out)
        path = out["path"].split(":")
        for directory in (case.root, *unsafe):
            self.assertNotIn(str(directory), path)
        self.assertNotIn("planted", case.marker_lines())

    def plant_inherited_root(self, case: Case, parent_mode: int, root_mode: int) -> tuple[Path, str]:
        inherited = case.base / "app/cmux-cli-shims" / SURFACE_ID
        inherited.mkdir(parents=True)
        inherited.parent.chmod(parent_mode)
        planted = inherited / "claude"
        write_script(planted, "planted")
        inherited.chmod(root_mode)
        case.inherit_root(inherited)
        return inherited, planted.read_text(encoding="utf-8")

    def test_fresh_root_is_created_private(self) -> None:
        def scenario(shell, case: Case) -> None:
            out = case.run(shell)
            self.assertEqual(out["root"], str(case.root), out)
            self.assertEqual(out["shim"], str(case.root / "claude"), out)
            self.assertIn(str(case.root), out["path"].split(":"), out)
            self.assertEqual(mode(case.parent), 0o700)
            self.assertEqual(mode(case.root), 0o700)
            self.assertTrue((case.root / "claude").is_file())
            # The claude function and a PATH lookup both reach the wrapper.
            self.assertEqual(case.marker_lines(), ["wrapper", "wrapper"])

        self.for_each_shell(scenario)

    def test_shared_shim_parent_is_not_used(self) -> None:
        def scenario(shell, case: Case) -> None:
            case.parent.mkdir()
            case.parent.chmod(0o777)
            out = case.run(shell)
            self.assert_no_shim(case, out, case.parent)
            self.assertFalse(case.root.exists())
            self.assertEqual(mode(case.parent), 0o777)
            # Without a shim, the claude function still runs the bundled wrapper.
            self.assertEqual(case.marker_lines(), ["wrapper"])

        self.for_each_shell(scenario)

    def test_symlinked_shim_parent_is_not_used(self) -> None:
        def scenario(shell, case: Case) -> None:
            elsewhere = case.base / "elsewhere"
            elsewhere.mkdir(mode=0o700)
            case.parent.symlink_to(elsewhere)
            out = case.run(shell)
            self.assert_no_shim(case, out, case.parent, elsewhere)
            self.assertEqual(list(elsewhere.iterdir()), [])

        self.for_each_shell(scenario)

    def test_symlinked_shim_root_is_not_used(self) -> None:
        def scenario(shell, case: Case) -> None:
            elsewhere = case.base / "elsewhere"
            elsewhere.mkdir(mode=0o700)
            case.parent.mkdir(mode=0o700)
            case.root.symlink_to(elsewhere)
            out = case.run(shell)
            self.assert_no_shim(case, out, elsewhere)
            self.assertEqual(list(elsewhere.iterdir()), [])

        self.for_each_shell(scenario)

    def test_writable_inherited_root_falls_back_to_private_root(self) -> None:
        for parent_mode, root_mode in ((0o700, 0o777), (0o777, 0o700), (0o700, 0o720)):
            def scenario(shell, case: Case) -> None:
                inherited, planted = self.plant_inherited_root(case, parent_mode, root_mode)
                out = case.run(shell)
                self.assertEqual(out["root"], str(case.root), out)
                self.assertEqual(out["shim"], str(case.root / "claude"), out)
                self.assertNotIn(str(inherited), out["path"].split(":"), out)
                self.assertEqual((inherited / "claude").read_text(encoding="utf-8"), planted)
                self.assertEqual(case.marker_lines(), ["wrapper", "wrapper"])

            self.for_each_shell(scenario, parent_mode=oct(parent_mode), root_mode=oct(root_mode))

    def test_rejected_inherited_root_without_private_fallback_disables_shim(self) -> None:
        def scenario(shell, case: Case) -> None:
            inherited, planted = self.plant_inherited_root(case, 0o700, 0o777)
            case.parent.mkdir()
            case.parent.chmod(0o777)
            out = case.run(shell)
            self.assert_no_shim(case, out, inherited)
            self.assertEqual((inherited / "claude").read_text(encoding="utf-8"), planted)
            self.assertFalse(case.root.exists())
            self.assertEqual(case.marker_lines(), ["wrapper"])

        self.for_each_shell(scenario)

    def test_private_inherited_root_is_reused(self) -> None:
        def scenario(shell, case: Case) -> None:
            inherited, _ = self.plant_inherited_root(case, 0o700, 0o700)
            out = case.run(shell)
            self.assertEqual(out["root"], str(inherited), out)
            self.assertIn(str(inherited), out["path"].split(":"), out)
            self.assertFalse(case.parent.exists())
            self.assertEqual(case.marker_lines(), ["wrapper", "wrapper"])

        self.for_each_shell(scenario)

    def test_nonsticky_tmpdir_ancestor_replacement_never_runs_planted_shim(self) -> None:
        def scenario(shell, case: Case) -> None:
            # A shared non-sticky ancestor lets another local account rename a
            # checked private child and replace the path before the next command.
            case.tmp.chmod(0o777)
            driver = (
                NONSTICKY_ANCESTOR_FISH_DRIVER
                if "fish" in Path(shell[0]).name
                else NONSTICKY_ANCESTOR_POSIX_DRIVER
            )
            case.run(shell, driver)
            self.assertEqual(case.marker_lines(), ["wrapper"])

        self.for_each_shell(scenario)


class BashStateFilePrivateDirectory(unittest.TestCase):
    def setUp(self) -> None:
        self.previous_umask = os.umask(0o022)

    def tearDown(self) -> None:
        os.umask(self.previous_umask)

    def for_each_bash(self, scenario) -> None:
        for name, shell in shells().items():
            if "bash" not in Path(name).name:
                continue
            with self.subTest(shell=name), new_case("cmux-bash-state-") as case:
                case.env["CMUX_SHELL_INTEGRATION_DIR"] = ""
                scenario(shell, case, case.tmp / f"cmux-bash-{os.geteuid()}")

    def test_state_files_live_in_private_directory(self) -> None:
        def scenario(shell, case: Case, state: Path) -> None:
            out = case.run(shell, BASH_STATE_DRIVER)
            self.assertEqual(os.path.dirname(out["hint"]), str(state), out)
            self.assertEqual(os.path.dirname(out["history"]), str(state), out)
            self.assertEqual(mode(state), 0o700)
            self.assertRegex(out["bgpid"], r"^[0-9]+$")
            self.assertEqual(out["historycmd"], "echo private-history", out)
            self.assertEqual([path.name for path in case.tmp.iterdir()], [state.name])

        self.for_each_bash(scenario)

    def test_shared_state_directory_is_not_used(self) -> None:
        def scenario(shell, case: Case, state: Path) -> None:
            state.mkdir()
            state.chmod(0o777)
            out = case.run(shell, BASH_STATE_DRIVER)
            self.assertEqual(out["hint"], "", out)
            self.assertEqual(out["history"], "", out)
            self.assertEqual(out["historycmd"], "", out)
            self.assertEqual(mode(state), 0o777)
            self.assertEqual(list(state.iterdir()), [])
            self.assertEqual([path.name for path in case.tmp.iterdir()], [state.name])

        self.for_each_bash(scenario)

    def test_symlinked_state_directory_is_not_used(self) -> None:
        def scenario(shell, case: Case, state: Path) -> None:
            elsewhere = case.base / "elsewhere"
            elsewhere.mkdir(mode=0o700)
            state.symlink_to(elsewhere)
            out = case.run(shell, BASH_STATE_DRIVER)
            self.assertEqual(out["hint"], "", out)
            self.assertEqual(out["history"], "", out)
            self.assertEqual(out["historycmd"], "", out)
            self.assertEqual(list(elsewhere.iterdir()), [])

        self.for_each_bash(scenario)


if __name__ == "__main__":
    unittest.main()
