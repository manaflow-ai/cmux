#!/usr/bin/env python3

import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/ubuntu-apt-https.py"


class UbuntuAptHttpsTests(unittest.TestCase):
    def test_runner_sources_keep_repository_policy_while_using_https(self) -> None:
        sources = {
            "sources.list": (
                "deb [arch=amd64 signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] "
                "http://us.archive.ubuntu.com/ubuntu/ jammy main universe\n"
            ),
            "sources.list.d/ubuntu.sources": (
                "Types: deb deb-src\n"
                "URIs: mirror+file:/etc/apt/blacksmith-ubuntu-mirrors.txt\n"
                "Suites: noble noble-updates noble-backports\n"
                "Components: main restricted universe multiverse\n"
                "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n"
                "\n"
                "Types: deb\n"
                "URIs: http://security.ubuntu.com/ubuntu/\n"
                "Suites: noble-security\n"
                "Components: main restricted universe multiverse\n"
                "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n"
            ),
            "sources.list.d/ubuntu.list": (
                "deb http://archive.ubuntu.com/ubuntu noble main\n"
                "deb http://azure.archive.ubuntu.com/ubuntu noble-updates main\n"
            ),
        }
        expected = {
            "sources.list": (
                "deb [arch=amd64 signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] "
                "https://archive.ubuntu.com/ubuntu/ jammy main universe\n"
            ),
            "sources.list.d/ubuntu.sources": (
                "Types: deb deb-src\n"
                "URIs: https://archive.ubuntu.com/ubuntu\n"
                "Suites: noble noble-updates noble-backports\n"
                "Components: main restricted universe multiverse\n"
                "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n"
                "\n"
                "Types: deb\n"
                "URIs: https://security.ubuntu.com/ubuntu/\n"
                "Suites: noble-security\n"
                "Components: main restricted universe multiverse\n"
                "Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n"
            ),
            "sources.list.d/ubuntu.list": (
                "deb https://archive.ubuntu.com/ubuntu noble main\n"
                "deb https://archive.ubuntu.com/ubuntu noble-updates main\n"
            ),
        }
        self.assert_sources(sources, expected)

    def test_other_repositories_and_ignored_files_are_unchanged(self) -> None:
        sources = {
            "sources.list.d/vendors.sources": (
                "Types: deb\n"
                "URIs: https://packages.microsoft.com/ubuntu/24.04/prod\n"
                "Suites: noble\n"
                "Components: main\n"
            ),
            "sources.list.d/custom.list": (
                "deb http://packages.example.com/ubuntu noble main\n"
                "deb http://archive.ubuntu.com/ubuntu-custom noble main\n"
                "deb mirror+file:/etc/apt/blacksmith-ubuntu-mirrors.txt.custom noble main\n"
                "deb https://archive.ubuntu.com/ubuntu noble main\n"
            ),
            "sources.list.d/ubuntu.sources.save": (
                "URIs: http://archive.ubuntu.com/ubuntu\n"
            ),
            "blacksmith-ubuntu-mirrors.txt": "http://mirrors.sonic.net/ubuntu\n",
        }
        self.assert_sources(sources, sources)

    def assert_sources(self, sources: dict[str, str], expected: dict[str, str]) -> None:
        with tempfile.TemporaryDirectory() as directory:
            apt_root = pathlib.Path(directory)
            for name, contents in sources.items():
                path = apt_root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents, encoding="utf-8")

            # A second invocation must leave the same usable source files behind.
            for invocation in range(2):
                result = subprocess.run(
                    [sys.executable, str(SCRIPT), str(apt_root)],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                for name, contents in expected.items():
                    with self.subTest(invocation=invocation, file=name):
                        self.assertEqual(
                            (apt_root / name).read_text(encoding="utf-8"), contents
                        )


if __name__ == "__main__":
    unittest.main()
