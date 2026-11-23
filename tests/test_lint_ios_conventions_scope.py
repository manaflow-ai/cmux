#!/usr/bin/env python3
"""`--files-from` grades only files inside the lint's own roots.

scripts/lint-ios-package-conventions.sh is the iOS line's lint: the mobile packages and the iOS
app shell (its SCOPES), not the macOS app's packages. Each scan is given those roots, but the
`--files-from` path (what `namespace autofix` runs on a pull request's changed Swift files)
replaced them with the whole list, so a changed macOS file was graded by iOS conventions and the
job went red on declarations the base already has: cmux#48267 on
Packages/macOS/CmuxNext/.../TunableStore.swift's `static let shared` and `Mutex(State())`.

Run: python3 -I tests/test_lint_ios_conventions_scope.py"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LINT = "scripts/lint-ios-package-conventions.sh"
HELPERS = [LINT, "scripts/lint_swift_namespaces.py", "scripts/swift_source_mask.py"]
# The declarations #48267 was held on: a singleton accessor (ERROR singleton) and a lock (ERROR lock).
VIOLATING_SOURCE = """\
public final class Store: Sendable {
    public static let shared = Store()
    private let state = Mutex(State())
}
"""


class FilesFromScope(unittest.TestCase):
    def lint(self, files):
        """The real lint over `files` in a scratch tree shaped like the repository.

        The iOS package directory always exists, whether or not a listed file is in it: the lint
        builds its roots (SCOPES) from the directories it finds, as it does in a checkout."""
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / "scripts").mkdir()
        for helper in HELPERS:
            shutil.copy(ROOT / helper, tmp / helper)
        os.chmod(tmp / LINT, 0o755)
        for name in ("lint-ios-package-conventions-baseline.txt",
                     "lint-namespace-types-baseline.txt", "lint-namespace-types-ratchet.txt"):
            (tmp / "scripts" / name).write_text("")
        ios_package = tmp / "Packages/iOS/CmuxMobileCore/Sources/CmuxMobileCore"
        ios_package.mkdir(parents=True)
        for path, text in files.items():
            target = tmp / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        listing = tmp / "files.txt"
        listing.write_text("".join(f"{path}\n" for path in files))
        done = subprocess.run(["bash", LINT, "--files-from", str(listing)],
                              cwd=tmp, capture_output=True, text=True)
        return done.returncode, done.stdout + done.stderr

    def test_a_macos_package_file_is_not_graded_by_ios_conventions(self):
        _, out = self.lint({"Packages/iOS/CmuxMobileCore/Sources/CmuxMobileCore/Keep.swift": "",
                            "Packages/macOS/CmuxNext/Sources/CmuxNextTunables/Store.swift": VIOLATING_SOURCE})
        self.assertNotIn("ERROR   singleton", out, out)
        self.assertNotIn("ERROR   lock", out, out)

    def test_the_same_declarations_in_an_ios_package_still_fail(self):
        code, out = self.lint({"Packages/iOS/CmuxMobileCore/Sources/CmuxMobileCore/Store.swift": VIOLATING_SOURCE})
        self.assertIn("ERROR   singleton", out, out)
        self.assertIn("ERROR   lock", out, out)
        self.assertEqual(code, 1, out)

    def test_a_list_with_nothing_in_scope_passes(self):
        code, out = self.lint({"Packages/macOS/CmuxNext/Sources/CmuxNextTunables/Store.swift": VIOLATING_SOURCE})
        self.assertEqual(code, 0, out)
        self.assertNotIn("FAIL:", out, out)


if __name__ == "__main__":
    unittest.main()
