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

    def stop(self) -> subprocess.CompletedProcess[str]:
        # `stop` is the lightest command that runs ensure_helper before it asks the VM's helper anything.
        return subprocess.run(
            ["bash", str(SCRIPT), "stop", "--tag", "helper-test"], env=self.env, capture_output=True, text=True, timeout=60
        )

    def test_an_older_checkout_never_puts_its_router_over_a_newer_one(self) -> None:
        self.vm("// a newer router\n", "# a newer helper\n", generation() + 1)
        r = self.stop()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.base / "bin/router.mjs").read_text(), "// a newer router\n")
        self.assertEqual((self.base / "bin/vm_stack.py").read_text(), "# a newer helper\n")
        self.assertIn("runs a newer stack helper and router", r.stderr)
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


if __name__ == "__main__":
    unittest.main()
