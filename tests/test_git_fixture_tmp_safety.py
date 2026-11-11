#!/usr/bin/env python3
"""The git fixture helpers keep their GIT_CONFIG_GLOBAL file where no other user can plant or swap it.

cmux#40871 (Codex F1, security): at 40d04402 scripts/cmux-next/tests/lib/git-fixture.sh used
${TMPDIR:-/tmp}/cmux-git-fixture-$UID-v1.gitconfig, a predictable name in a shared folder, and reused a file
already there. Another user could precreate it, or change it after a test sourced the helper, adding
core.hooksPath: an injected pre-commit hook then ran in every fixture repository. tests/git_fixture_env.py
trusted any inherited CMUX_GIT_FIXTURE_GLOBAL_DIR holding a home.gitconfig. At 131f72ee (cmux#40939's first head)
the names changed but stayed predictable: the shell used ...-$UID-<cksum of the text>.gitconfig and reused a file
whose content matched, and Python reused <sha256 of the text>.gitconfig from any inherited folder. The attacks
here plant both generations of names. Both helpers now write only inside a fresh private folder (mktemp -d /
tempfile.mkdtemp: ours, mode 0700, not a symlink) and remove it at exit, also when the test sets its own EXIT
trap after sourcing the shell helper (33 suite tests did, and each run left its folder behind).
Codex F2: an explicitly empty GIT_CONFIG_GLOBAL (no global config) is kept, not replaced.
Run: python3 -I tests/test_git_fixture_tmp_safety.py
"""
import hashlib
import importlib.util
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "tests" / "git_fixture_env.py"
LIB = ROOT / "scripts/cmux-next/tests/lib/git-fixture.sh"
APP_SIZE_TEST = ROOT / "scripts/cmux-next/tests/check-app-size.test.sh"
_spec = importlib.util.spec_from_file_location("git_fixture_env", HELPER)
git_fixture_env = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(git_fixture_env)

PYTHON_VICTIM = """
import importlib.util, os, subprocess, sys
spec = importlib.util.spec_from_file_location("git_fixture_env", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(os.environ.get("GIT_CONFIG_GLOBAL", "<unset>"))
print(module.fixture_env().get("GIT_CONFIG_GLOBAL", "<unset>"))
if len(sys.argv) > 2:
    repo = module.init_repo(sys.argv[2], "-b", "main")
    subprocess.run(["git", "commit", "-q", "--allow-empty", "-m", "x"], cwd=repo, env=module.fixture_env(),
                   check=True, capture_output=True)
"""

# The name scripts/cmux-next/tests/lib/git-fixture.sh used at 131f72ee, and the text it reused a file for: an
# attacker who knows the victim's HOME computes both. Prints the path, a NUL, then the text.
CKSUM_NAME = r"""
x=${XDG_CONFIG_HOME:-${HOME:+$HOME/.config}}; t=
for p in ${x:+"$x/git/config"} ${HOME:+"$HOME/.gitconfig"}; do t+=$'[include]\n\tpath = "'"$p"$'"\n'; done
t+=$'[maintenance]\n\tauto = false\n[gc]\n\tauto = 0\n[receive]\n\tautogc = false'
printf '%s\0%s' "${TMPDIR:-/tmp}/cmux-git-fixture-$(id -u)-$(printf '%s' "$t" | cksum | tr ' ' -).gitconfig" "$t"
"""

LEFTOVER = "cmux-git-fixture.*"


class SharedTempAttack(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        # The shared temp folder another user can write (sticky and world-writable, like /tmp).
        self.shared = self.root / "shared-tmp"
        self.shared.mkdir()
        self.shared.chmod(0o1777)
        self.marker = self.root / "PWNED"
        hooks = self.root / "evil-hooks"
        hooks.mkdir()
        (hooks / "pre-commit").write_text(f"#!/bin/sh\necho injected > '{self.marker}'\n")
        (hooks / "pre-commit").chmod(0o755)
        self.evil = f"[core]\n\thooksPath = {hooks}\n"
        self.predictable = self.shared / f"cmux-git-fixture-{os.getuid()}-v1.gitconfig"
        (self.root / "home").mkdir()
        # A session with no opt-out of its own: the helper under test must make it.
        self.env = {key: value for key, value in git_fixture_env.fixture_env().items()
                    if not key.startswith("GIT_") and key != "CMUX_GIT_FIXTURE_GLOBAL_DIR"}
        self.env.update(HOME=str(self.root / "home"), TMPDIR=str(self.shared), GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                        GIT_COMMITTER_EMAIL="t@t", EVIL=self.evil, PREDICTABLE=str(self.predictable))
        name, text = subprocess.run(["bash", "-c", CKSUM_NAME], env=self.env, capture_output=True, text=True,
                                    check=True).stdout.split("\0")
        self.checksum_named, self.checksum_text = Path(name), text
        self.env.update(CHECKSUM_NAMED=name)

    def bash(self, script: str, env: dict | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", "-c", script, "_", str(LIB)], env=env or self.env, cwd=self.root,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def assert_private(self, config: str, recorded: str):
        """recorded: the folder's `kind uid mode` as the process saw it while it ran (it is gone after exit)."""
        self.assertNotIn(Path(config), (self.predictable, self.checksum_named))
        self.assertEqual(recorded.split(), ["dir", str(os.getuid()), "700"], f"{config}: {recorded}")

    def test_shell_ignores_a_planted_then_swapped_shared_config(self):
        self.predictable.write_text(self.evil)
        self.predictable.chmod(0o666)
        # 131f72ee reused this file when its content matched, so the plant matches until the swap below.
        self.checksum_named.write_text(self.checksum_text)
        self.checksum_named.chmod(0o666)
        done = self.bash(
            'source "$1" || exit 9\n'
            'printf "%s\\n" "$GIT_CONFIG_GLOBAL" > global-path\n'
            # Ownership and mode of the folder while the shell runs (Linux stat, else BSD stat).
            'd=$(dirname "$GIT_CONFIG_GLOBAL"); [[ -d "$d" && ! -L "$d" ]] && k=dir || k=other\n'
            '{ echo "$k $(stat -c "%u %a" "$d" 2>/dev/null || stat -f "%u %Lp" "$d")"; } > global-stat\n'
            # The other user rewrites the shared file after the test sourced the helper (Codex's repro).
            'printf "%s" "$EVIL" > "$PREDICTABLE" 2>/dev/null || true\n'
            'printf "%s" "$EVIL" > "$CHECKSUM_NAMED" 2>/dev/null || true\n'
            'git_fixture_init -b main repo && cd repo && git commit -q --allow-empty -m x\n')
        self.assertEqual(done.returncode, 0, done.stderr)
        config = (self.root / "global-path").read_text().strip()
        print(f"shell GIT_CONFIG_GLOBAL={config}; hook ran={self.marker.exists()}")
        self.assertFalse(self.marker.exists(), "a hook planted through the shared temp folder ran")
        self.assert_private(config, (self.root / "global-stat").read_text())
        self.assertFalse(Path(config).parent.exists(), "the private folder outlived the shell")

    def test_shell_keeps_an_earlier_exit_trap(self):
        done = self.bash('trap "echo earlier > earlier-ran" EXIT\nsource "$1"\n'
                         'printf "%s\\n" "$GIT_CONFIG_GLOBAL" > global-path\n')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue((self.root / "earlier-ran").exists(), "the helper replaced an existing EXIT trap")
        self.assertFalse(Path((self.root / "global-path").read_text().strip()).parent.exists())

    def leftovers(self) -> list[str]:
        return sorted(path.name for path in self.shared.glob(LEFTOVER))

    def test_shell_cleans_up_although_the_test_sets_its_own_exit_trap_later(self):
        # What 33 suite tests do: source the helper, then `trap cleanup EXIT` of their own.
        cases = {
            "plain": ('trap "echo mine > mine-ran" EXIT', 0),
            "with other signals": ('trap "echo mine > mine-ran" EXIT INT TERM', 0),
            "exits from its trap": ('trap "echo mine > mine-ran; exit 3" EXIT', 3),
            "replaced twice": ('trap "echo first > first-ran" EXIT\ntrap "echo mine > mine-ran" EXIT', 0),
            "runs git in its trap": ('trap "git -C repo status --short && echo mine > mine-ran" EXIT', 0),
        }
        for case, (own_trap, status) in cases.items():
            with self.subTest(case):
                for name in ("mine-ran", "first-ran", "global-path"):
                    (self.root / name).unlink(missing_ok=True)
                subprocess.run(["rm", "-rf", str(self.root / "repo")], check=True)
                done = self.bash('source "$1" || exit 9\n' + own_trap + '\n'
                                 'printf "%s\\n" "$GIT_CONFIG_GLOBAL" > global-path\n'
                                 'git_fixture_init -b main repo\n')
                self.assertEqual(done.returncode, status, done.stderr)
                self.assertTrue((self.root / "mine-ran").exists(), f"{case}: the test's own EXIT trap did not run")
                self.assertFalse((self.root / "first-ran").exists(), f"{case}: a replaced EXIT trap still ran")
                folder = Path((self.root / "global-path").read_text().strip()).parent
                self.assertEqual(folder.parent, self.shared)
                self.assertEqual(self.leftovers(), [], f"{case}: the helper's private folder outlived the shell")

    def test_check_app_size_test_leaves_no_git_fixture_dir(self):
        # The real suite caller: check-app-size.test.sh sources the helper, makes its own mktemp -d, then sets
        # `trap 'rm -rf "$tmp"' EXIT`. At 1af46a70 (cmux#40939) that trap replaced the helper's cleanup and each
        # run left a cmux-git-fixture.* folder in TMPDIR. Its own trap's work is observable too: its tmp.* goes.
        private = self.root / "private-tmp"
        private.mkdir(mode=0o700)
        done = subprocess.run(["bash", str(APP_SIZE_TEST)], env=dict(self.env, TMPDIR=str(private)), cwd=self.root,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL)
        left = sorted(path.name for path in private.iterdir())
        print(f"check-app-size.test.sh exit={done.returncode}; left in TMPDIR={left}")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual([name for name in left if name.startswith("cmux-git-fixture.")], [],
                         "check-app-size.test.sh left the git fixture's private folder behind")
        self.assertEqual(left, [], "check-app-size.test.sh's own EXIT trap did not remove its tmp folder")

    def test_shell_keeps_the_folder_while_a_subshell_sets_and_runs_an_exit_trap(self):
        done = self.bash('source "$1" || exit 9\n'
                         '( trap "true" EXIT; true )\n'
                         'test -f "$GIT_CONFIG_GLOBAL" && echo kept\n'
                         'trap - EXIT\n')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout.strip(), "kept", "a subshell's EXIT trap removed the shell's private folder")
        self.assertEqual(self.leftovers(), [], "`trap - EXIT` kept the helper's private folder")

    def test_shell_keeps_an_explicitly_empty_global_config(self):
        env = dict(self.env, GIT_CONFIG_GLOBAL="")
        done = self.bash('source "$1"\nprintf "[%s]" "${GIT_CONFIG_GLOBAL-unset}"', env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stdout, "[]", "an empty GIT_CONFIG_GLOBAL (no global config) was replaced")

    def python_victim(self, env: dict, repo: bool = True) -> list[str]:
        args = [sys.executable, "-I", "-c", PYTHON_VICTIM, str(HELPER)] + ([str(self.root / "repo")] if repo else [])
        done = subprocess.run(args, env=env, cwd=self.root, capture_output=True, text=True,
                              stdin=subprocess.DEVNULL)
        self.assertEqual(done.returncode, 0, done.stderr)
        return done.stdout.split("\n")[:2]

    def test_python_rejects_an_untrusted_inherited_dir(self):
        cases = {}
        open_dir = self.shared / "world-writable"
        open_dir.mkdir()
        open_dir.chmod(0o777)
        cases["mode 0777"] = open_dir
        readable = self.shared / "group-readable"
        readable.mkdir()
        readable.chmod(0o755)
        cases["mode 0755"] = readable
        private = self.root / "private-target"
        private.mkdir()
        private.chmod(0o700)
        link = self.shared / "link"
        link.symlink_to(private)
        cases["symlink"] = link
        child_env = dict(self.env)
        # 131f72ee's name for the child's config: <sha256 of the text it would write>.gitconfig, reused as found.
        sha_name = None
        if hasattr(git_fixture_env, "global_config_text"):
            text = git_fixture_env.global_config_text(child_env)
            sha_name = hashlib.sha256(text.encode()).hexdigest()[:16] + ".gitconfig"
        for case, folder in cases.items():
            with self.subTest(case):
                (folder / "home.gitconfig").write_text(self.evil)
                if sha_name:
                    (folder / sha_name).write_text(self.evil)
                self.marker.unlink(missing_ok=True)
                subprocess.run(["rm", "-rf", str(self.root / "repo")], check=True)
                loaded, fixture = self.python_victim(dict(self.env, CMUX_GIT_FIXTURE_GLOBAL_DIR=str(folder)))
                print(f"python ({case}) GIT_CONFIG_GLOBAL={loaded}; hook ran={self.marker.exists()}")
                self.assertFalse(self.marker.exists(), f"{case}: a hook planted in the inherited folder ran")
                for config in (loaded, fixture):
                    self.assertNotEqual(Path(config).parent, folder)
                    self.assertNotEqual(Path(config).parent.resolve(), private)

    def test_python_child_reuses_the_parents_private_dir_which_is_removed_at_exit(self):
        child = ("import importlib.util, os, sys\n"
                 "spec = importlib.util.spec_from_file_location('git_fixture_env', sys.argv[1])\n"
                 "module = importlib.util.module_from_spec(spec)\nspec.loader.exec_module(module)\n"
                 "print(os.path.dirname(module.GLOBAL_CONFIG))\n")
        parent = ("import importlib.util, os, stat, subprocess, sys\n"
                  "spec = importlib.util.spec_from_file_location('git_fixture_env', sys.argv[1])\n"
                  "module = importlib.util.module_from_spec(spec)\nspec.loader.exec_module(module)\n"
                  "folder = os.path.dirname(module.GLOBAL_CONFIG)\ninfo = os.lstat(folder)\n"
                  "print(folder)\nprint(stat.S_ISDIR(info.st_mode), info.st_uid == os.getuid(), oct(stat.S_IMODE(info.st_mode)))\n"
                  "print(subprocess.run([sys.executable, '-I', '-c', sys.argv[2], sys.argv[1]], capture_output=True,"
                  " text=True, check=True).stdout.strip())\n")
        done = subprocess.run([sys.executable, "-I", "-c", parent, str(HELPER), child], env=self.env, cwd=self.root,
                              capture_output=True, text=True, stdin=subprocess.DEVNULL)
        self.assertEqual(done.returncode, 0, done.stderr)
        folder, info, child_folder = done.stdout.splitlines()
        self.assertEqual(info, "True True 0o700", folder)
        self.assertEqual(child_folder, folder, "a child did not reuse its parent's private folder")
        self.assertFalse(Path(folder).exists(), "the helper's private folder outlived the process")

    def test_both_helpers_init_a_repo_with_home_unset(self):
        # 8349c18e's shell helper wrote `path = ~/.gitconfig`, which git cannot expand with no HOME: every git
        # call then failed with "could not expand include path" (exit 128).
        env = {key: value for key, value in self.env.items() if key not in ("HOME", "XDG_CONFIG_HOME")}
        done = self.bash('source "$1" || exit 9\ngit_fixture_init -b main repo\n'
                         'git -C repo config --get maintenance.auto\n', env)
        self.assertEqual((done.returncode, done.stdout.strip()), (0, "false"), done.stderr)
        subprocess.run(["rm", "-rf", str(self.root / "repo")], check=True)
        self.python_victim(env)

    def test_python_keeps_an_explicitly_empty_global_config(self):
        loaded, fixture = self.python_victim(dict(self.env, GIT_CONFIG_GLOBAL=""), repo=False)
        self.assertEqual((loaded, fixture), ("", ""))


if __name__ == "__main__":
    unittest.main()
