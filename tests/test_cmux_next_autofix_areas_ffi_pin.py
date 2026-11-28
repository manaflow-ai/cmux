"""A CCmuxAppFFI re-pin turns on the action-exports repair for every caller of autofix-areas.sh.

The action exports are written from the Rust catalog in the pinned CCmuxAppFFI. The bot re-pin
cmux#59703 changed only Package.swift and app-ffi-pin.json; the pull request autofix lists its
diff alone (base autofix adds base-autofix-ffi-pin.sh's pseudo path), read actions=false
(run 45908783930, 2026-11-26), never regenerated the exports, and the pull request failed its
own exports judge ("this change leaves action exports stale", job 140212026183).
"""

from __future__ import annotations

import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AREAS = ROOT / "scripts/cmux-next/autofix-areas.sh"


def areas(*paths: str) -> dict[str, str]:
    out = subprocess.run(["bash", str(AREAS)], cwd=ROOT, input="".join(p + "\n" for p in paths),
                         check=True, capture_output=True, text=True).stdout
    return dict(line.split("=", 1) for line in out.split())


class AutofixAreasFfiPin(unittest.TestCase):
    def test_the_pin_file_alone_turns_on_the_action_exports(self) -> None:
        # cmux#59703's diff.
        got = areas("Packages/macOS/CmuxNext/Package.swift", "Packages/macOS/CmuxNext/app-ffi-pin.json")
        self.assertEqual(got["actions"], "true")

    def test_the_base_autofix_pseudo_path_still_does(self) -> None:
        self.assertEqual(areas("Packages/macOS/CmuxNext/Package.swift#CCmuxAppFFI")["actions"], "true")

    def test_the_rest_of_package_swift_is_not_an_action_input(self) -> None:
        # About 13 Package.swift changes a day; a Mac regeneration takes about 40 minutes.
        self.assertEqual(areas("Packages/macOS/CmuxNext/Package.swift")["actions"], "false")

    def test_a_pin_file_elsewhere_is_not(self) -> None:
        self.assertEqual(areas("docs/app-ffi-pin.json")["actions"], "false")


if __name__ == "__main__":
    unittest.main()
