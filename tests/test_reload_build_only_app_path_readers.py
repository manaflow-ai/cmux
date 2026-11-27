#!/usr/bin/env python3
"""A caller that builds with `reload.sh --build-only` and then reads its `App path:` must pass
`--keep-app PATH`. Without it, reload.sh deletes the bundle it built and prints no App path
(the build-only branch at the end of scripts/reload.sh), so the caller fails after a full build.
cloud-chat-proof.yml's tagged route hit this after a 63 min build."""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
CALL = re.compile(r"reload\.sh(?:[^\n]*\\\n)*[^\n]*")


def build_only_calls(text):
    return [m.group(0) for m in CALL.finditer(text) if "--build-only" in m.group(0)]


class BuildOnlyAppPathReaders(unittest.TestCase):
    def test_every_reader_of_a_build_only_app_path_keeps_the_app(self):
        sources = [*ROOT.glob(".github/workflows/*.yml"), *ROOT.glob("scripts/**/*.sh"), *ROOT.glob("scripts/**/*.py")]
        offenders = []
        for path in sources:
            if path.name == "reload.sh":
                continue
            text = path.read_text(errors="replace")
            if "App path:" not in text:
                continue
            offenders += [f"{path.relative_to(ROOT)}: {call.splitlines()[0].strip()}"
                          for call in build_only_calls(text) if "--keep-app" not in call]
        self.assertEqual(offenders, [], "these read reload.sh's App path after --build-only without --keep-app")

    def test_the_detector_sees_a_continued_call(self):
        self.assertEqual(build_only_calls("./scripts/reload.sh \\\n  --tag t \\\n  --build-only | tee out\n"),
                         ["reload.sh \\\n  --tag t \\\n  --build-only | tee out"])


if __name__ == "__main__":
    unittest.main()
