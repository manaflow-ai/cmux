"""Behavioral coverage for the guest-side codex hook-trust probe."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "devbox-codex-hook-trust.py"

# Stands in for `cmux-tui agent codex-wrapper`: execs the first codex on PATH
# with the hook flags, the way the real wrapper does.
WRAPPER = """#!/bin/sh
[ "$1 $2" = "agent codex-wrapper" ] || exit 64
[ -n "$CMUX_TUI_SOCKET" ] && [ -n "$CMUX_TUI_TERMINAL_ID" ] || exit 65
exec codex %s
"""

# Stands in for `codex <argv> app-server`: answers hooks/list from the
# statuses given on the command line, after the injected flags.
CODEX = """#!%s
import json, sys
args = sys.argv[1:]
assert args[-1] == "app-server", args
statuses = [a.split("=", 1)[1] for a in args if a.startswith("status=")]
for line in sys.stdin:
    message = json.loads(line)
    if message.get("id") == 1:
        print(json.dumps({"id": 1, "result": {}}), flush=True)
    elif message.get("id") == 2:
        assert message["params"]["cwds"], message
        data = [{"cwd": message["params"]["cwds"][0], "hooks": [
            {"key": "k%%d" %% i, "trustStatus": s} for i, s in enumerate(statuses)]}]
        print(json.dumps({"id": 2, "result": {"data": data}}), flush=True)
"""


class CodexHookTrustTests(unittest.TestCase):
    def run_probe(self, wrapper_args):
        with tempfile.TemporaryDirectory() as tmp:
            wrapper = os.path.join(tmp, "cmux-tui")
            codex = os.path.join(tmp, "codex-real")
            with open(wrapper, "w") as handle:
                handle.write(WRAPPER % wrapper_args)
            with open(codex, "w") as handle:
                handle.write(CODEX % sys.executable)
            os.chmod(wrapper, 0o755)
            os.chmod(codex, 0o755)
            return subprocess.run(
                [sys.executable, str(SCRIPT), "--wrapper", wrapper, "--socket", "/tmp/s.sock", "--codex", codex,
                 "--cwd", tmp, "--timeout", "10", "--label", "probe"],
                capture_output=True, text=True, timeout=30,
            )

    def test_every_hook_trusted_passes(self):
        result = self.run_probe("--enable hooks status=trusted status=trusted")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("probe-ok 2", result.stdout)

    def test_an_untrusted_injected_hook_fails(self):
        result = self.run_probe("--enable hooks status=trusted status=untrusted")
        self.assertEqual(result.returncode, 1)
        self.assertIn("1 of 2 hooks need review", result.stderr)
        self.assertIn("untrusted k1", result.stderr)

    def test_a_wrapper_that_injects_nothing_fails(self):
        result = self.run_probe("status=trusted")
        self.assertEqual(result.returncode, 1)
        self.assertIn("injected no hooks", result.stderr)

    def test_no_hooks_listed_fails(self):
        result = self.run_probe("--enable hooks")
        self.assertEqual(result.returncode, 1)
        self.assertIn("0 of 0 hooks", result.stderr)


if __name__ == "__main__":
    unittest.main()
