#!/usr/bin/env python3
"""cloud-dev-stack.sh's ensure_helper: which checkout's vm_stack.py and router.mjs end up on the dev VM.

No VM: `ssh` and `scp` are shims on PATH that run the command against a temp directory standing in for the VM's
base (CMUX_DEV_STACK_BASE), and `python3 .../vm_stack.py ...` on the "VM" is only logged. Run directly:
python3 scripts/cmux-next/tests/test_cloud_dev_stack_helper.py
"""
from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/cmux-next/cloud-dev-stack.sh"
HELPER = ROOT / "scripts/cmux-next/cloud-dev-stack/vm_stack.py"
ROUTER = ROOT / "scripts/cmux-next/cloud-dev-stack/router.mjs"

SSH = textwrap.dedent(
    """\
    #!/bin/bash
    # ssh [-o OPT]... HOST CMD...: CMD runs here; the VM helper's own runs are only logged.
    while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) shift; break ;; esac; done
    [ $# -eq 0 ] && exit 0
    case "$1" in python3) echo "$*" >> "$SHIM_LOG"; exit 0 ;; esac
    exec bash -c "$*"
    """
)
SCP = textwrap.dedent(
    """\
    #!/bin/bash
    # scp [-q] [-o OPT]... SRC HOST:DEST
    args=(); while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) args+=("$1"); shift ;; esac; done
    cp "${args[0]}" "${args[1]#*:}"
    """
)


def generation() -> int:
    for line in SCRIPT.read_text().splitlines():
        if line.startswith("HELPER_GENERATION="):
            return int(line.split("=", 1)[1])
    raise AssertionError("cloud-dev-stack.sh names no HELPER_GENERATION")


class EnsureHelper(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="wdev-helper-"))
        self.base = self.tmp / "vm"
        (self.base / "bin").mkdir(parents=True)
        shims = self.tmp / "shims"
        shims.mkdir()
        for name, body in (("ssh", SSH), ("scp", SCP)):
            (shims / name).write_text(body)
            (shims / name).chmod(0o755)
        self.log = self.tmp / "vm-helper.log"
        self.env = {
            **os.environ,
            "PATH": f"{shims}:{os.environ['PATH']}",
            "CMUX_DEV_STACK_BASE": str(self.base),
            "SHIM_LOG": str(self.log),
        }

    def vm(self, router: str, helper: str, generation: int | None) -> None:
        (self.base / "bin/router.mjs").write_text(router)
        (self.base / "bin/vm_stack.py").write_text(helper)
        if generation is not None:
            (self.base / "bin/.generation").write_text(f"{generation}\n")

    def stop(self, copies: str = "merged") -> subprocess.CompletedProcess[str]:
        # `stop` is the lightest command that runs ensure_helper before it asks the VM's helper anything.
        # CMUX_DEV_STACK_HELPER stands in for git: whether this checkout's copies are its base's own.
        return subprocess.run(
            ["bash", str(SCRIPT), "stop", "--tag", "helper-test"],
            env={**self.env, "CMUX_DEV_STACK_HELPER": copies},
            capture_output=True,
            text=True,
            timeout=60,
        )

    def test_an_older_checkout_never_puts_its_router_over_a_newer_one(self) -> None:
        self.vm("// a newer router\n", "# a newer helper\n", generation() + 1)
        r = self.stop()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.base / "bin/router.mjs").read_text(), "// a newer router\n")
        self.assertEqual((self.base / "bin/vm_stack.py").read_text(), "# a newer helper\n")
        self.assertIn("runs newer merged stack copies", r.stderr)
        self.assertNotIn("install", self.log.read_text() if self.log.exists() else "")

    def test_an_older_or_unversioned_vm_copy_is_replaced_and_its_generation_recorded(self) -> None:
        for theirs in (None, generation() - 1, generation()):
            with self.subTest(vm_generation=theirs):
                self.vm("// an old router\n", "# an old helper\n", theirs)
                r = self.stop()
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual((self.base / "bin/router.mjs").read_bytes(), ROUTER.read_bytes())
                self.assertEqual((self.base / "bin/vm_stack.py").read_bytes(), HELPER.read_bytes())
                self.assertEqual((self.base / "bin/.generation").read_text().strip(), str(generation()))
                self.assertIn("vm_stack.py install", self.log.read_text())
                self.log.unlink()


    def test_a_branchs_own_copies_install_and_never_hold_the_vm_against_merged_ones(self) -> None:
        # A PR that changes router.mjs (and bumps HELPER_GENERATION) is tested through review.sh's `stack up`
        # from its own checkout. Its copies install, but the VM records no generation for them: the next up from a
        # base checkout puts the merged copies back (the review of #55907 found the first version left them
        # stuck behind a recorded branch generation).
        self.vm("// merged router\n", "# merged helper\n", generation() + 5)
        r = self.stop(copies="branch")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.base / "bin/router.mjs").read_bytes(), ROUTER.read_bytes())
        self.assertFalse((self.base / "bin/.generation").exists(), "a branch's install records no generation")
        # A base checkout's up now replaces the branch's copies with its own.
        (self.base / "bin/router.mjs").write_text("// the branch's router\n")
        r = self.stop(copies="merged")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.base / "bin/router.mjs").read_bytes(), ROUTER.read_bytes())
        self.assertEqual((self.base / "bin/.generation").read_text().strip(), str(generation()))

    def test_a_leading_zero_generation_reads_as_decimal(self) -> None:
        self.vm("// newer\n", "# newer\n", None)
        (self.base / "bin/.generation").write_text(f"0{generation() + 7}\n")
        r = self.stop()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.base / "bin/router.mjs").read_text(), "// newer\n")

    def test_merged_copies_a_branch_installed_are_recorded_by_the_next_merged_up(self) -> None:
        # The normal flow: a PR's review build installs its copies (no record), then the PR merges as it was. The
        # VM already runs the merged copies; the next up from a base checkout must record their generation, or an
        # older checkout's up rolls the router back (the second review of #55907).
        self.vm(ROUTER.read_text(), HELPER.read_text(), None)
        r = self.stop(copies="merged")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.base / "bin/.generation").read_text().strip(), str(generation()))
        self.assertNotIn("install", self.log.read_text() if self.log.exists() else "", "nothing to install")
        # An older checkout's merged copies now leave them alone.
        older = self.tmp / "older.sh"
        older.write_text(SCRIPT.read_text().replace(f"HELPER_GENERATION={generation()}", f"HELPER_GENERATION={generation() - 1}"))
        (self.tmp / "older-router.mjs").write_text("// an older router\n")
        r = subprocess.run(
            ["bash", "-c", f'sed "s#^router=.*#router={self.tmp}/older-router.mjs#; s#^root=.*#root={ROOT}#" "{older}" > "{older}.run"; bash "{older}.run" stop --tag helper-test'],
            env={**self.env, "CMUX_DEV_STACK_HELPER": "merged"}, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.base / "bin/router.mjs").read_bytes(), ROUTER.read_bytes(), "the older checkout left them")
        self.assertIn("runs newer merged stack copies", r.stderr)

    def test_a_branch_whose_copies_have_merged_reads_as_merged(self) -> None:
        # After a squash merge the author's worktree differs from its old merge base but equals the base's tip.
        src = (ROOT / "scripts/cmux-next/cloud-dev-stack.sh").read_text()
        start = src.index("helper_copies() {")
        fn = src[start:src.index("\n}\n", start) + 3]
        repo = self.tmp / "repo"
        files = ["scripts/cmux-next/cloud-dev-stack/vm_stack.py", "scripts/cmux-next/cloud-dev-stack/router.mjs"]
        def git(*a: str) -> str:
            return subprocess.run(["git", "-C", str(repo), *a], check=True, capture_output=True, text=True).stdout.strip()
        repo.mkdir()
        git("init", "-q")
        for f in files:
            (repo / f).parent.mkdir(parents=True, exist_ok=True)
            (repo / f).write_text("old\n")
        git("add", "-A"); git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "base")
        base = git("rev-parse", "HEAD")
        git("checkout", "-qb", "pr")
        (repo / files[1]).write_text("new\n")
        git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "pr")
        git("checkout", "-q", "--detach", base)
        (repo / files[1]).write_text("new\n")
        git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "squash of pr")
        git("update-ref", "refs/remotes/origin/main", "HEAD")
        git("checkout", "-q", "pr")
        def copies() -> str:
            return subprocess.run(["bash", "-c", f'{fn}\nroot="{repo}" BASE_REF=origin/main; helper_copies'],
                                  env={k: v for k, v in os.environ.items() if k != "CMUX_DEV_STACK_HELPER"},
                                  capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(copies(), "merged", "equal to the base's tip")
        (repo / files[0]).write_text("unmerged\n")
        self.assertEqual(copies(), "branch")

if __name__ == "__main__":
    unittest.main()
