#!/usr/bin/env python3
"""reload.sh's live code build keeps CMUX_LIVE_CODE_INTERPOSABLE_LIST one linker argument.

Xcode splits OTHER_LDFLAGS on spaces outside quotes. A fleet step's checkout lives under
"/Library/Application Support/...", so an unquoted list path became two arguments and the relink
failed with "Build input file cannot be found: '/Library/Application'". This runs reload.sh's live
code block alone (no build) and splits its OTHER_LDFLAGS as Xcode does.
"""

import re
import shlex
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELOAD = ROOT / "scripts/reload.sh"


def live_code_block():
    text = RELOAD.read_text()
    start = text.index('if [[ "${CMUX_LIVE_CODE_BUILD:-0}" == "1" ]]; then')
    end = re.compile(r"^fi$", re.M).search(text, start).end()
    return text[start:end]


def other_ldflags(config, listing):
    script = (
        f"BUILD_CONFIGURATION={shlex.quote(config)}; XCODEBUILD_ARGS=(); SCRIPT_DIR={shlex.quote(str(ROOT / 'scripts'))}\n"
        + live_code_block()
        + '\nfor a in "${XCODEBUILD_ARGS[@]}"; do case "$a" in OTHER_LDFLAGS=*) printf "%s" "${a#OTHER_LDFLAGS=}";; esac; done\n'
    )
    env = {"PATH": "/usr/bin:/bin", "CMUX_LIVE_CODE_BUILD": "1", "CMUX_LIVE_CODE_INTERPOSABLE_LIST": listing}
    out = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, check=True)
    return out.stdout


class LiveCodeLdflagsQuotingTests(unittest.TestCase):
    def test_a_list_path_with_spaces_stays_one_argument(self):
        listing = "/Library/Application Support/cmux-build-worker/work/out/interposable.txt"
        for config in ("Release", "Debug"):
            args = shlex.split(other_ldflags(config, listing))
            self.assertIn("-interposable_list", args, config)
            self.assertEqual(args[args.index("-interposable_list") + 2], listing, config)

    def test_no_list_adds_no_interposable_flag(self):
        self.assertNotIn("-interposable_list", shlex.split(other_ldflags("Release", "")))


if __name__ == "__main__":
    unittest.main()
