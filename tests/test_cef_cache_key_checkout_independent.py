#!/usr/bin/env python3
"""The CEF build caches are keyed by content, never by the checkout path.

merge-cef-universal.sh (the lipo-merged universal framework, ~0.67 GiB) and
build-cef-shim.sh (the shim, whose build keys also name embed-cef.sh's universal
shim) hashed `shasum -a 256 <absolute path>`, whose output holds the path. A
fleet step checks out under /Users/cmux/cmux-ci-bench/steps/<job>/, so no later
step reused an entry: on 2026-10-31 the perf mini cmux20 held 44 merged
frameworks in ~/Library/Caches/cmux. Two checkouts with identical inputs must
get, and reuse, the same entry.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MERGE = ROOT / "scripts/cmux-next/merge-cef-universal.sh"
SHIM = ROOT / "scripts/cmux-next/build-cef-shim.sh"
FW = "Chromium Embedded Framework.framework"


def write(path: Path, text: str, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    if mode is not None:
        path.chmod(mode)


def fake_dist(path: Path, sha: str) -> Path:
    """A verified CEF dist with no Mach-O files, so the merge needs no lipo."""
    write(path / FW / "Resources" / "icudtl.dat", "same in both arches\n")
    write(path / ".verified", sha)
    write(path / "CMUX-ARTIFACT.json", '{"version": "fake"}\n')
    return path


def checkout(base: Path, name: str) -> Path:
    """A copy of the scripts and shim sources under a step-like path."""
    repo = base / "steps" / name / "src"
    write(repo / "scripts/cmux-next/merge-cef-universal.sh", MERGE.read_text(encoding="utf-8"), 0o755)
    write(repo / "scripts/cmux-next/build-cef-shim.sh", SHIM.read_text(encoding="utf-8"), 0o755)
    write(repo / "Packages/macOS/CmuxNext/CEFShim/src/shim_process.mm", "// shim\n")
    write(repo / "Packages/macOS/CmuxNext/CEFShim/include/shim.h", "// header\n")
    write(repo / "Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h", "// abi\n")
    return repo


def toolchain_stubs(bin_dir: Path) -> None:
    """xcrun, clang++, libtool and sysctl stand-ins: each tool writes its -o output."""
    write(bin_dir / "xcrun", textwrap.dedent(f"""\
        #!/bin/sh
        case "$*" in
          *--find*) echo "{bin_dir}/clang++" ;;
          *--show-sdk-path*) echo /nonexistent/sdk ;;
          *) exit 1 ;;
        esac
        """), 0o755)
    writer = textwrap.dedent("""\
        #!/bin/sh
        [ "$1" = --version ] && { echo 'Apple clang version 17.0.0 (stub)'; exit 0; }
        while [ $# -gt 0 ]; do
          if [ "$1" = -o ]; then : > "$2"; chmod +x "$2"; fi
          shift
        done
        """)
    write(bin_dir / "clang++", writer, 0o755)
    write(bin_dir / "libtool", writer, 0o755)
    write(bin_dir / "sysctl", "#!/bin/sh\necho 2\n", 0o755)


class CefCacheKeyIsCheckoutIndependent(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="cef-cache-key-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def merge(self, repo: Path, arm: Path, x86: Path, cache: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", str(repo / "scripts/cmux-next/merge-cef-universal.sh"), str(arm), str(x86),
                               str(cache)], capture_output=True, text=True, timeout=120)

    def test_merged_framework_is_reused_from_another_checkout(self):
        arm = fake_dist(self.tmp / "cef/146.0-arm64", "a" * 64)
        x86 = fake_dist(self.tmp / "cef/146.0-x86_64", "b" * 64)
        cache = self.tmp / "cef/universal"
        first = self.merge(checkout(self.tmp, "job-1"), arm, x86, cache)
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.merge(checkout(self.tmp, "job-2"), arm, x86, cache)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first.stdout.splitlines()[-1], second.stdout.splitlines()[-1])
        self.assertNotIn("merging", second.stderr, "the second checkout merged again instead of reusing")
        self.assertEqual(sorted(p.name for p in cache.iterdir() if not p.name.startswith(".")),
                         [Path(first.stdout.splitlines()[-1]).name])

    def shim(self, repo: Path, cef: Path, cache: Path) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ, PATH=f"{self.tmp / 'bin'}{os.pathsep}{os.environ.get('PATH', '')}",
                   CMUX_CEF_ARCH="arm64")
        return subprocess.run(["bash", str(repo / "scripts/cmux-next/build-cef-shim.sh"), str(cef), str(cache)],
                              capture_output=True, text=True, timeout=120, env=env)

    def test_shim_build_is_reused_from_another_checkout(self):
        toolchain_stubs(self.tmp / "bin")
        cef = fake_dist(self.tmp / "cef/146.0-arm64", "a" * 64)
        write(cef / "libcef_dll/wrapper.cc", "// wrapper\n")
        cache = self.tmp / "cef/shim"
        first = self.shim(checkout(self.tmp, "job-1"), cef, cache)
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.shim(checkout(self.tmp, "job-2"), cef, cache)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first.stdout.splitlines()[-1], second.stdout.splitlines()[-1])
        self.assertNotIn("building CEF shim", second.stderr, "the second checkout rebuilt instead of reusing")


if __name__ == "__main__":
    unittest.main()
