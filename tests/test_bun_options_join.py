#!/usr/bin/env python3
"""scripts/lib/bun-options.sh joins each spaced preload flag in BUN_OPTIONS to its path.

Bun reads `--preload PATH` (a space, not `=`) in BUN_OPTIONS as a script name, so every subcommand
but `bun run` fails with 'Script not found "install"'. A login-file block that adds a Claude Code
preload did this on a Mac (2026-11-22) and broke `cmux app try .`, whose web-overlay.sh runs
`bun install --frozen-lockfile`. The lib rewrites the value in the form bun reads as meant; the
scripts that install with bun source it.
"""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "scripts/lib/bun-options.sh"
SOURCED_BY = [
    "scripts/cmux-next/web-overlay.sh",
    "scripts/cmux-next/build-web-bundles.sh",
    "scripts/build-webviews-app.sh",
]
CASES = {
    "--preload /h/p.js": "--preload=/h/p.js",
    "-r /h/p.js": "--preload=/h/p.js",
    "--smol --preload /h/p.js --preload=/h/q.js": "--smol --preload=/h/p.js --preload=/h/q.js",
    "--require /x.js --import /y.js": "--require=/x.js --import=/y.js",
    "--preload=/h/p.js": "--preload=/h/p.js",
    "--preload /h/*.js": "--preload=/h/*.js",
    "--preload": "--preload",
    "--preload --smol": "--preload --smol",
}


def joined(shell, value):
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin")}
    if value is not None:
        env["BUN_OPTIONS"] = value
    out = subprocess.run([shell, "-c", f'set -eu; . "{LIB}"; printf "%s|%s" "${{BUN_OPTIONS-unset}}" "$-"'],
                         capture_output=True, text=True, env=env, timeout=30, check=True).stdout
    options, flags = out.split("|", 1)
    if "f" in flags:
        raise AssertionError(f"{shell}: the lib left globbing off")
    return options


class BunOptionsJoinTests(unittest.TestCase):
    def shells(self):
        return [s for s in ("sh", "bash", "dash") if shutil.which(s)]

    def test_spaced_preload_flags_are_joined_in_every_shell(self):
        for shell in self.shells():
            for value, want in CASES.items():
                with self.subTest(shell=shell, value=value):
                    self.assertEqual(joined(shell, value), want)
            self.assertEqual(joined(shell, None), "unset", "an unset BUN_OPTIONS stays unset")
            self.assertEqual(joined(shell, ""), "")

    def test_same_answer_as_web_lint_prepush(self):
        spec = importlib.util.spec_from_file_location("web_lint_prepush", ROOT / "scripts/web_lint_prepush.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module  # dataclasses look their module up
        spec.loader.exec_module(module)
        for value in CASES:
            with self.subTest(value=value):
                self.assertEqual(joined("sh", value), module.bun_options_joined(value))

    def test_a_bun_that_refuses_the_spaced_form_installs_after_the_lib(self):
        with tempfile.TemporaryDirectory(prefix="bun-options-join-") as tmp:
            fake = Path(tmp) / "bun"
            fake.write_text('#!/bin/sh\ncase " $BUN_OPTIONS " in *" --preload "*) echo "error: Script not found \\"$1\\"" >&2; exit 1 ;; esac\n'
                            'echo installed\n')
            fake.chmod(0o755)
            env = {"PATH": f"{tmp}:/usr/bin:/bin", "BUN_OPTIONS": "--preload /h/p.js"}
            before = subprocess.run(["sh", "-c", "bun install"], capture_output=True, text=True, env=env, timeout=30)
            self.assertNotEqual(before.returncode, 0)
            after = subprocess.run(["sh", "-c", f'. "{LIB}"; bun install'], capture_output=True, text=True, env=env,
                                   timeout=30)
            self.assertEqual((after.returncode, after.stdout.strip()), (0, "installed"), after.stderr)

    def test_the_install_scripts_source_it_before_any_bun_call(self):
        for rel in SOURCED_BY:
            with self.subTest(script=rel):
                lines = (ROOT / rel).read_text().splitlines()
                source = next((i for i, line in enumerate(lines) if line == '. "$ROOT/scripts/lib/bun-options.sh"'), None)
                self.assertIsNotNone(source, f"{rel} does not source scripts/lib/bun-options.sh")
                first_bun = next((i for i, line in enumerate(lines)
                                  if not line.lstrip().startswith("#") and "bun " in line), len(lines))
                self.assertLess(source, first_bun, f"{rel} runs bun before it sources the lib")


if __name__ == "__main__":
    unittest.main()
