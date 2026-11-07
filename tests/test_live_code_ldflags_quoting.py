#!/usr/bin/env python3
"""A live code build keeps CMUX_LIVE_CODE_INTERPOSABLE_LIST one linker argument.

Xcode splits OTHER_LDFLAGS on spaces outside quotes. A fleet step's checkout lives under
"/Library/Application Support/...", so an unquoted list path became two arguments and the relink
failed with "Build input file cannot be found: '/Library/Application'". This calls the shared
live_code_xcodebuild_args (scripts/live-code/lib/xcodebuild-args.sh, which reload.sh, build.sh and
the nightly's live code variant all use) and splits its OTHER_LDFLAGS as Xcode does. No build.
"""

import shlex
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "scripts/live-code/lib/xcodebuild-args.sh"


def other_ldflags(config, listing):
    script = (
        f"source {shlex.quote(str(LIB))}\n"
        'live_code_xcodebuild_args "$1" "$2" | while IFS= read -r a; do '
        'case "$a" in OTHER_LDFLAGS=*) printf "%s" "${a#OTHER_LDFLAGS=}";; esac; done\n'
    )
    out = subprocess.run(["bash", "-c", script, "args", config, listing], cwd=ROOT,
                         env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True, check=True)
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
