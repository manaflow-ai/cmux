#!/usr/bin/env python3
"""The complexity gate must enumerate every production web source, including
paths Git would otherwise C-quote.

`git ls-files` honours core.quotePath (default true), so a tracked path holding
a non-ASCII or control character is printed quoted and escaped:

    "web/app/\\303\\251.ts"     for web/app/é.ts
    "web/app/a\\tb.ts"          for web/app/a<TAB>b.ts

A quoted entry no longer starts with `web/`, so isProductionSource() rejects it
and the file is silently exempt from a required check forever. Reading the file
list with -z removes the quoting entirely.

The tests drive the real check-complexity.mjs against scratch repositories. The
script statically imports TypeScript, which is not installed for the workflow
guards, so each scratch repo carries a tiny stub that satisfies the one code
path these tests reach: the broad-suppression scan, which prints the repository
path of every file the gate decided to scan. Those printed paths are the
observable proof that enumeration found the file.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
import git_fixture_env  # noqa: F401  (disables git auto maintenance)

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "web" / "scripts" / "check-complexity.mjs"
RUNTIME = shutil.which("bun") or shutil.which("node")

ACCENTED = "app/é.ts"
TABBED = "app/a\tb.ts"
PLAIN = "app/plain.ts"

SUPPRESSED_SOURCE = "// oxlint-disable complexity\nexport const value = 1;\n"
CLEAN_SOURCE = "export const value = 1;\n"

OXLINTRC = json.dumps({"rules": {"complexity": ["error", {"max": 20, "variant": "classic"}]}}, indent=2) + "\n"

# Enough of the TypeScript surface for assertNoBroadComplexitySuppressions to
# report the leading line comment of each scanned file.
TYPESCRIPT_STUB = """
export const ScriptKind = { JS: 1, JSX: 2, TS: 3, TSX: 4 };
export const ScriptTarget = { Latest: 99 };
export const LanguageVariant = { Standard: 0, JSX: 1 };
export const SyntaxKind = { EndOfFileToken: 1, SingleLineCommentTrivia: 2, MultiLineCommentTrivia: 3 };

export function createSourceFile(fileName, text) {
  return { fileName, text };
}

export function createScanner(target, skipTrivia, variant, text) {
  const comment = text.startsWith("//") ? text.split("\\n", 1)[0] : "";
  let emitted = false;
  return {
    scan() {
      if (comment && !emitted) {
        emitted = true;
        return SyntaxKind.SingleLineCommentTrivia;
      }
      return SyntaxKind.EndOfFileToken;
    },
    getTokenText: () => comment,
    getTokenPos: () => 0,
  };
}

export function getLineAndCharacterOfPosition() {
  return { line: 0, character: 0 };
}
"""

BASELINE_ENTRY = f"{ACCENTED}\t{'0' * 64}\tFunction has a complexity of 21. Maximum allowed is 20.\n"


@unittest.skipUnless(RUNTIME, "neither bun nor node is available")
class SourceEnumerationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"

    def git(self, *args: str) -> str:
        return subprocess.check_output(
            [
                "git",
                "-c", "user.name=CI",
                "-c", "user.email=ci@example.test",
                "-c", "core.hooksPath=/dev/null",
                *args,
            ],
            cwd=self.root,
            text=True,
            stderr=subprocess.PIPE,
        ).strip()

    def write(self, relative: str, contents: str) -> None:
        target = self.root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents, encoding="utf-8")

    def build_repo(self, sources: dict[str, str], *, baseline: str = "") -> None:
        """A scratch repository shaped like the parts of web/ the gate reads."""
        self.root.mkdir(parents=True)
        self.write("web/oxlint-complexity-baseline.txt", baseline)
        self.write("web/.oxlintrc.json", OXLINTRC)
        self.write("web/node_modules/typescript/index.js", TYPESCRIPT_STUB)
        self.write(
            "web/node_modules/typescript/package.json",
            json.dumps({"name": "typescript", "version": "0.0.0", "type": "module", "main": "index.js"}) + "\n",
        )
        self.write("web/scripts/check-complexity.mjs", SCRIPT.read_text(encoding="utf-8"))
        for relative, contents in sources.items():
            self.write(f"web/{relative}", contents)
        self.git("init", "-q")
        # The default; set explicitly so a contributor's global config cannot
        # hide the quoting this test exists to defend against.
        self.git("config", "core.quotePath", "true")
        self.git("add", "-A")
        self.git("commit", "-qm", "scratch")

    def run_gate(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                RUNTIME,
                str(self.root / "web" / "scripts" / "check-complexity.mjs"),
                "--repo-root", str(self.root),
                "--tool-root", str(self.root),
            ],
            cwd=self.root,
            text=True,
            capture_output=True,
        )

    def test_quoted_paths_are_scanned(self) -> None:
        self.build_repo(
            {
                PLAIN: SUPPRESSED_SOURCE,
                ACCENTED: SUPPRESSED_SOURCE,
                TABBED: SUPPRESSED_SOURCE,
            }
        )
        self.assertTrue(self.git("ls-files", "--", "web").count('"'), "git must quote these paths for the test to mean anything")

        result = self.run_gate()
        output = result.stdout + result.stderr
        self.assertIn("broad complexity suppressions are not allowed", output, output)
        for relative in (PLAIN, ACCENTED, TABBED):
            self.assertIn(f"web/{relative}:1", output, f"the gate never scanned web/{relative}\n{output}")

    def test_untracked_quoted_paths_are_scanned(self) -> None:
        self.build_repo({PLAIN: SUPPRESSED_SOURCE})
        self.write(f"web/{ACCENTED}", SUPPRESSED_SOURCE)

        result = self.run_gate()
        output = result.stdout + result.stderr
        self.assertIn(f"web/{ACCENTED}:1", output, f"the gate never scanned the untracked web/{ACCENTED}\n{output}")

    def test_a_repo_whose_only_source_is_quoted_is_not_reported_empty(self) -> None:
        self.build_repo({ACCENTED: CLEAN_SOURCE}, baseline=BASELINE_ENTRY)

        result = self.run_gate()
        output = result.stdout + result.stderr
        self.assertNotIn("no production web files", output, output)
        # Enumeration succeeded, so the gate got as far as running Oxlint, which
        # this scratch repo deliberately does not install.
        self.assertIn("could not start oxlint", output, output)


if __name__ == "__main__":
    unittest.main()
