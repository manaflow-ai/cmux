#!/usr/bin/env python3
"""The cmux hooks pick a working Python on each host; none pins one host's interpreter path.

2026-11-16: a fleet Mac's pre-push gate refused with "PyYAML missing: run
/Users/cmux/.local/python-3.13.15/bin/python3.13 -I -m pip install PyYAML==6.0.3". The install had recorded the
python3 it found on that Mac (python3-path), and the hook ran only that one, whatever else the host had.
scripts/git-hooks/hook_python.sh now tries each candidate in order and takes the first that runs and imports yaml;
with none importing yaml, the first that runs, and the gate's refusal names every candidate it tried. With none that
runs, it returns 1 and the hook refuses with the list and the next step.

Detector for the class (docs/handbook "hardcoded per-host interpreter path" in cmuxterm-hq): HardcodedInterpreterPaths
fails on any tracked script or workflow that names a per-host interpreter (a home folder's python, a versioned
python-3.X.Y install) and on a hook that runs the recorded python3-path without hook_python_pick.
"""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1]
PICKER = SOURCE / "scripts/git-hooks/hook_python.sh"


class HookPythonPickTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cmux-hook-python-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(os.path.realpath(temporary.name))
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()

    def fake(self, name, code, where=None):
        """A stand-in interpreter that answers the probe with exit CODE (0: runs with PyYAML, 4: runs without it,
        3: older than 3.9) and leaves a marker when it runs."""
        path = (where or self.root / "bin") / name
        path.parent.mkdir(parents=True, exist_ok=True)
        marker = self.root / f"ran-{name}"
        path.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\nexit {code}\n", encoding="utf-8")
        path.chmod(0o755)
        return path

    def pick(self, need_yaml, recorded, candidates, roots=()):
        """Runs hook_python_pick with the candidate list replaced; returns (status, HOOK_PYTHON, HOOK_PYTHON_TRIED)."""
        script = (
            "set -euo pipefail\n"
            f"source {shlex.quote(str(PICKER))}\n"
            f"HOOK_PYTHON_CANDIDATES=({' '.join(shlex.quote(str(c)) for c in candidates)})\n"
            "status=0\n"
            f"hook_python_pick {need_yaml} {shlex.quote(str(recorded))} "
            f"{' '.join(shlex.quote(str(r)) for r in roots)} || status=$?\n"
            'printf "%s\\n%s\\n%s\\n" "$status" "$HOOK_PYTHON" "$HOOK_PYTHON_TRIED"\n'
        )
        done = subprocess.run(["bash", "-c", script], text=True, capture_output=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        status, python, tried = done.stdout.split("\n")[:3]
        return int(status), python, tried

    def test_a_recorded_interpreter_that_is_gone_or_lacks_pyyaml_gives_way_to_one_that_has_it(self):
        gone = self.root / "Users/cmux/.local/python-3.13.15/bin/python3.13"
        bare = self.fake("bare-python3", 4)
        good = self.fake("good-python3", 0)
        status, python, tried = self.pick(1, gone, [bare, good])
        self.assertEqual((status, python), (0, str(good)))
        self.assertIn(f"{gone} (missing)", tried)
        self.assertIn(f"{bare} (no PyYAML)", tried)

    def test_the_recorded_interpreter_is_first_and_alone_when_it_works(self):
        recorded = self.fake("recorded-python3", 0)
        other = self.fake("other-python3", 0)
        self.assertEqual(self.pick(1, recorded, [other]), (0, str(recorded), ""))
        self.assertFalse((self.root / "ran-other-python3").exists(), "a candidate after the pick ran")

    def test_with_no_pyyaml_anywhere_the_first_that_runs_is_used_and_every_one_is_named(self):
        old = self.fake("old-python3", 3)
        first = self.fake("first-python3", 4)
        second = self.fake("second-python3", 4)
        status, python, tried = self.pick(1, old, [first, second])
        self.assertEqual((status, python), (0, str(first)))
        self.assertEqual(tried, f"{old} (older than 3.9); {first} (no PyYAML); {second} (no PyYAML)")

    def test_without_the_need_for_pyyaml_one_that_runs_is_enough(self):
        first = self.fake("first-python3", 4)
        self.assertEqual(self.pick(0, first, [self.fake("good-python3", 0)]), (0, str(first), ""))

    def test_none_that_runs_returns_1_with_the_list(self):
        broken = self.fake("broken-python3", 126)
        status, python, tried = self.pick(1, self.root / "nowhere/python3", [broken])
        self.assertEqual((status, python), (1, ""))
        self.assertEqual(tried, f"{self.root / 'nowhere/python3'} (missing); {broken} (does not run: exit 126)")

    def test_a_candidate_in_the_checkout_is_passed_over_without_running(self):
        inside = self.fake("python3", 0, where=self.checkout / "tools")
        link = self.root / "bin" / "linked-python3"
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(inside)
        good = self.fake("good-python3", 0)
        status, python, tried = self.pick(1, link, [inside, good], roots=[self.checkout])
        self.assertEqual((status, python), (0, str(good)))
        self.assertIn(f"{link} -> {inside} (inside the checkout)", tried)
        self.assertFalse((self.root / "ran-python3").exists(), "the checkout's python ran")

    def test_one_interpreter_behind_two_names_is_tried_once(self):
        real = self.fake("real-python3", 4)
        alias = self.root / "bin" / "alias-python3"
        alias.symlink_to(real)
        status, python, tried = self.pick(1, real, [alias])
        self.assertEqual((status, python, tried), (0, str(real), f"{real} (no PyYAML)"))

    def test_the_real_interpreter_answers_the_probe(self):
        # The probe itself, under the interpreter running this test: it runs, so the pick is never empty.
        status, python, _ = self.pick(0, os.path.realpath(os.sys.executable), [self.root / "none"])
        self.assertEqual((status, python), (0, os.path.realpath(os.sys.executable)))


# A per-host interpreter: a home folder's python (/Users/NAME/..., /home/NAME/..., $HOME/.local/python-...), or a
# versioned standalone install (python-3.13.15/bin). One host's path is not another's.
PER_HOST_INTERPRETER = re.compile(
    r"(/Users/[^/\s\"']+/|/home/[^/\s\"']+/|\$HOME/|~/)[^\s\"']*python[0-9.]*\b"
    r"|python-3\.[0-9]+\.[0-9]+/bin")
# Folders whose files run on more than one host: hooks, scripts, workflows.
SCANNED = ("scripts", ".github")
SCANNED_SUFFIXES = {"", ".sh", ".py", ".yml", ".yaml", ".bash", ".zsh"}
# Lines that name such a path on purpose. Each says why; keep it short.
ALLOWED = {
    # The picker's own fallback candidates: tried in order, never the only choice.
    ("scripts/git-hooks/hook_python.sh", 'HOOK_PYTHON_CANDIDATES=("${HOME:-/nonexistent}/.local/bin/python3"'),
}


def tracked(paths):
    done = subprocess.run(["git", "-C", str(SOURCE), "ls-files", "-z", "--", *paths], capture_output=True, check=True)
    return [p for p in done.stdout.decode().split("\0") if p]


class HardcodedInterpreterPaths(unittest.TestCase):
    def test_no_script_or_workflow_names_a_per_host_interpreter(self):
        found = []
        for relative in tracked(SCANNED):
            path = SOURCE / relative
            if path.suffix not in SCANNED_SUFFIXES or not path.is_file() or "/tests/fixtures/" in relative:
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            for number, line in enumerate(text.splitlines(), 1):
                stripped = line.strip()
                if stripped.startswith("#") or not PER_HOST_INTERPRETER.search(line):
                    continue
                if any(relative == file and stripped.startswith(prefix) for file, prefix in ALLOWED):
                    continue
                found.append(f"{relative}:{number}: {stripped[:160]}")
        self.assertEqual(found, [], "an interpreter path that differs per host: pick one at run time "
                                    "(scripts/git-hooks/hook_python.sh), never name one host's")

    def test_the_detector_catches_the_shapes_it_is_for(self):
        for line in ('exec /Users/cmux/.local/python-3.13.15/bin/python3.13 -I x.py',
                     'PY=/home/runner/.pyenv/shims/python3', '"$HOME/.local/bin/python3" -I x.py',
                     'cpython-3.12/../python-3.12.8/bin/python3'):
            with self.subTest(line=line):
                self.assertTrue(PER_HOST_INTERPRETER.search(line))
        for line in ("/usr/bin/python3 -I x.py", "python3 -I x.py", '"$PYTHON3_BIN" -I x.py'):
            with self.subTest(line=line):
                self.assertFalse(PER_HOST_INTERPRETER.search(line))

    def test_the_pre_push_hook_runs_the_recorded_interpreter_only_through_the_picker(self):
        hook = (SOURCE / "scripts/git-hooks/pre-push").read_text(encoding="utf-8")
        self.assertIn('source "$HOOK_DIR/hook_python.sh"', hook)
        self.assertRegex(hook, r'hook_python_pick 1 "\$RECORDED_PYTHON"')
        self.assertIn('PYTHON3_BIN="$HOOK_PYTHON"', hook)
        self.assertNotIn('read -r PYTHON3_BIN', hook, "the recorded path is a candidate, not the only choice")

    def test_the_installer_records_a_picked_interpreter_and_installs_the_picker(self):
        installer = (SOURCE / "scripts/install-git-hooks.sh").read_text(encoding="utf-8")
        self.assertIn("hook_python_pick 1", installer)
        self.assertIn('install -m 0644 scripts/git-hooks/hook_python.sh "$TRUSTED_HOOK_DIR/hook_python.sh"', installer)
        self.assertIn('install -m 0755 scripts/git-hooks/merge_python.sh "$TRUSTED_HOOK_DIR/merge_python.sh"', installer)

    def test_the_pre_commit_hook_runs_the_picked_interpreter(self):
        hook = (SOURCE / "scripts/git-hooks/pre-commit").read_text(encoding="utf-8")
        self.assertIn('source "$HOOK_DIR/hook_python.sh"', hook)
        self.assertIn('hook_python_pick 0 "$RECORDED_PYTHON"', hook)
        self.assertIn('PYTHON3_BIN="$HOOK_PYTHON"', hook)

    def test_no_hook_reads_the_recorded_path_as_its_interpreter(self):
        for path in sorted((SOURCE / "scripts/git-hooks").iterdir()):
            if path.is_file():
                with self.subTest(hook=path.name):
                    self.assertNotIn("read -r PYTHON3_BIN", path.read_text(encoding="utf-8"))

    def test_every_merge_driver_runs_through_the_picker(self):
        installer = (SOURCE / "scripts/install-git-hooks.sh").read_text(encoding="utf-8")
        drivers = re.findall(r"^printf -v (\w+_DRIVER) '([^']*)' \\\n\s*(\S+) ", installer, re.M)
        self.assertGreaterEqual(len(drivers), 5, drivers)
        for name, form, interpreter in drivers:
            with self.subTest(driver=name):
                self.assertTrue(form.startswith("/bin/bash %q %q "), form)
                self.assertEqual(interpreter, '"$TRUSTED_HOOK_DIR/merge_python.sh"')
        self.assertNotRegex(installer, r'"\$PYTHON3_BIN" "\$MERGE_DRIVER_DIR/')


class MergeDriverPythonTests(unittest.TestCase):
    """scripts/git-hooks/merge_python.sh, run the way git runs a driver the install wrote."""

    def test_a_driver_whose_recorded_interpreter_is_gone_runs_under_the_next_candidate(self):
        with tempfile.TemporaryDirectory(prefix="cmux-merge-python-") as name:
            root = Path(os.path.realpath(name))
            hooks, home, work = root / "git" / "cmux-git-hooks", root / "home", root / "work"
            for folder in (hooks, home / ".local/bin", work):
                folder.mkdir(parents=True)
            for script in ("hook_python.sh", "merge_python.sh"):
                (hooks / script).write_bytes((SOURCE / "scripts/git-hooks" / script).read_bytes())
            (hooks / "python3-path").write_text("/Users/cmux/.local/python-3.13.15/bin/python3.13\n")
            ran = root / "ran.txt"
            # Answers the picker's probe as a Python without PyYAML (exit 4), then records how the driver was run.
            fake = home / ".local/bin/python3"
            fake.write_text(f'#!/bin/sh\n[ "$2" = -c ] && exit 4\nprintf "%s\\n" "$@" > {shlex.quote(str(ran))}\n')
            fake.chmod(0o755)
            env = {"PATH": "/usr/bin:/bin", "HOME": str(home)}
            done = subprocess.run(["/bin/bash", str(hooks / "merge_python.sh"), "/drivers/merge-pbxproj.py",
                                   "O", "A", "B", "P"], cwd=work, env=env, text=True, capture_output=True, timeout=60)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(ran.read_text().split("\n")[:-1], ["-I", "/drivers/merge-pbxproj.py", "O", "A", "B", "P"])


if __name__ == "__main__":
    unittest.main()
