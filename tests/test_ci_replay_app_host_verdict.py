#!/usr/bin/env python3
"""The replay tool must not invent a missing selector out of shell quoting.

`run-app-host-xcodebuild.sh` records each argument with `printf 'arg=%q\n'`.
Today's test identifiers are bare under `%q`, but a selector carrying a
character it escapes would, under a naive quote strip, come back mangled --
and a mangled selector looks exactly like a test that the batch never
selected. That is the same shape of finding this tool exists to report, so a
parse it cannot do correctly has to fail loudly rather than quietly.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "replay_app_host_verdict.py"

spec = importlib.util.spec_from_file_location("replay_app_host_verdict", SCRIPT)
assert spec and spec.loader
replay = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = replay
spec.loader.exec_module(replay)


def write_meta(body: str) -> Path:
    handle = tempfile.NamedTemporaryFile("w", suffix=".meta", delete=False, encoding="utf-8")
    handle.write(body)
    handle.close()
    return Path(handle.name)


class SelectorsFromMetaTests(unittest.TestCase):
    def test_bare_identifiers_round_trip(self) -> None:
        meta = write_meta(
            "shard=6\n"
            "arg=-xctestrun\n"
            "arg=/tmp/cmux-unit.xctestrun\n"
            "arg=-only-testing:cmuxTests/FooTests/testOne()\n"
            "arg=-only-testing:cmuxTests/BarTests\n"
        )
        self.assertEqual(
            replay.selectors_from_meta(meta),
            ["cmuxTests/FooTests/testOne()", "cmuxTests/BarTests"],
        )

    def test_parenthesised_identifier_matches_printf_q_output(self) -> None:
        """Pin the decoding against what bash actually emits, not an assumption."""
        identifier = "cmuxTests/FooTests/testParameterised(value:)"
        quoted = subprocess.run(
            ["bash", "-c", 'printf "%q" "$1"', "_", f"-only-testing:{identifier}"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        meta = write_meta(f"arg={quoted}\n")
        self.assertEqual(replay.selectors_from_meta(meta), [identifier])

    def test_shell_metacharacters_survive_printf_q(self) -> None:
        """A selector %q must escape still decodes to the original string."""
        identifier = "cmuxTests/FooTests/test a b()"
        quoted = subprocess.run(
            ["bash", "-c", 'printf "%q" "$1"', "_", f"-only-testing:{identifier}"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        self.assertNotEqual(quoted, f"-only-testing:{identifier}", "fixture must be escaped")
        meta = write_meta(f"arg={quoted}\n")
        self.assertEqual(replay.selectors_from_meta(meta), [identifier])

    def test_unparseable_argv_refuses_instead_of_guessing(self) -> None:
        meta = write_meta("arg=-only-testing:cmuxTests/FooTests/'unbalanced\n")
        with self.assertRaises(SystemExit):
            replay.selectors_from_meta(meta)

    def test_ansi_c_quoting_refuses_instead_of_mangling(self) -> None:
        meta = write_meta("arg=$'-only-testing:cmuxTests/FooTests/test\\tOne()'\n")
        with self.assertRaises(SystemExit):
            replay.selectors_from_meta(meta)

    def test_multi_token_argv_refuses_instead_of_taking_the_first(self) -> None:
        """%q emits one token per argument, so two means the record is not %q.

        Reading only the first would drop the rest of the line without a word,
        which is the same silent shrink of the selector set the other refusals
        exist to prevent.
        """
        meta = write_meta("arg=-only-testing:cmuxTests/FooTests -only-testing:cmuxTests/BarTests\n")
        with self.assertRaises(SystemExit):
            replay.selectors_from_meta(meta)


if __name__ == "__main__":
    unittest.main()
