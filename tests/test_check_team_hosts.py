#!/usr/bin/env python3
"""scripts/ci/check_team_hosts.py: a new team host in cmux-tui or OptChat product code fails,
the known ones (the baseline) pass, and tests, fixtures and docs are exempt."""
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("check_team_hosts", ROOT / "scripts/ci/check_team_hosts.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def repo(files: dict[str, str]) -> Path:
    root = Path(tempfile.mkdtemp())
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    for rel, text in files.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
    return root


class TeamHosts(unittest.TestCase):
    def test_a_new_team_host_in_product_code_fails_and_known_ones_pass(self):
        root = repo({
            "Native/OptChat/x/src/gate.rs": 'const URL: &str = "http://cmux-lawrences-mac-mini:31415";\n',
            "cmux-tui/crates/y/src/ip.rs": 'let a = "100.89.225.106"; let b = "x.tail137216.ts.net";\n',
            "cmux-tui/crates/y/tests/z.rs": 'let a = "100.89.225.106";\n',
            "cmux-tui/crates/y/src/z_tests.rs": 'let a = "cmux-lawrences-mac-mini";\n',
            "Native/OptChat/x/README.md": "the team subrouter at cmux-lawrences-mac-mini\n",
            "Native/OptChat/x/measure/m.py": 'URL = "http://100.89.225.106:31415"\n',
            "other/src/a.rs": 'const U: &str = "cmux-lawrences-mac-mini";\n',
        })
        found = check.counts(root)
        self.assertEqual(found, {"Native/OptChat/x/src/gate.rs": 1, "cmux-tui/crates/y/src/ip.rs": 2})
        self.assertEqual(len(check.problems(found, {})), 2)
        self.assertEqual(check.problems(found, dict(found)), [])
        self.assertEqual(len(check.problems(found, {"cmux-tui/crates/y/src/ip.rs": 1})), 2)

    def test_the_repository_has_no_new_team_host(self):
        self.assertEqual(subprocess.run([sys.executable, str(ROOT / "scripts/ci/check_team_hosts.py")]).returncode, 0)


if __name__ == "__main__":
    unittest.main()
