"""The macOS cross legs built on Linux take the same uncapped runner as the fat musl legs.

On a cmux-linux slot (memory.max 14 GiB) the kernel OOM-killed the acpmux lib rustc of the
aarch64-apple-darwin cross leg 4 times (cmux-tui-artifacts run 46179078616, job 141088848848),
so no cmux-tui tree published. The musl legs already moved to LINUX_FAT_RUNNER (#65149).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cmux-tui-build-package.yml"


def matrix_script() -> str:
    text = WORKFLOW.read_text()
    m = re.search(r"python3 <<'PY' >> \"\$GITHUB_OUTPUT\"\n(.*?)\n\s*PY\n", text, re.S)
    assert m, "matrix heredoc not found"
    lines = m.group(1).splitlines()
    indent = min(len(l) - len(l.lstrip()) for l in lines if l.strip())
    return "\n".join(l[indent:] for l in lines)


def run(fat: str, darwin_builder: str = "linux") -> list[dict]:
    env = dict(
        os.environ,
        MACOS_RUNNER="mac-pool",
        LINUX_RUNNER="cmux-linux",
        LINUX_FAT_RUNNER=fat,
        LINUX_ARM64_RUNNER="arm",
        DARWIN_BUILDER=darwin_builder,
        PACKAGE_NPM="false",
        PACKAGE_PYPI="false",
        BUILD_AGENT_PLUGIN="false",
        TARGET_SET="all",
        LTO="fat",
        ARTIFACT_PREFIX="cmux-tui",
        VERIFY_LINUX_ARM64="false",
    )
    out = subprocess.run([sys.executable, "-c", matrix_script()], env=env, check=True, capture_output=True, text=True).stdout
    line = next(l for l in out.splitlines() if l.startswith("matrix="))
    return json.loads(line.removeprefix("matrix="))["include"]


class DarwinOnLinuxFatRunner(unittest.TestCase):
    def test_nightly_path_darwin_cross_legs_take_the_fat_runner(self) -> None:
        legs = {t["target"]: t["runner"] for t in run("cmux-gcp-nightly-jit-x64")}
        self.assertEqual(legs["aarch64-apple-darwin"], "cmux-gcp-nightly-jit-x64")
        self.assertEqual(legs["x86_64-unknown-linux-musl"], "cmux-gcp-nightly-jit-x64")

    def test_without_a_fat_runner_darwin_cross_legs_keep_the_linux_pool(self) -> None:
        legs = {t["target"]: t["runner"] for t in run("")}
        self.assertEqual(legs["aarch64-apple-darwin"], "cmux-linux")

    def test_native_mac_builder_keeps_the_mac_runner(self) -> None:
        legs = {t["target"]: t["runner"] for t in run("cmux-gcp-nightly-jit-x64", darwin_builder="mac")}
        self.assertEqual(legs["aarch64-apple-darwin"], "mac-pool")


if __name__ == "__main__":
    unittest.main()
