#!/usr/bin/env python3
"""scripts/ci/egress_new_sites.py fails a change that adds an ungated outbound site, even on a red base.

Run it: python3 tests/test_egress_new_sites.py
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import egress_new_sites  # noqa: E402

RS = "cmux-tui/crates/acpmux/src/fake_site.rs"
GATE_RS = "cmux-tui/crates/cmux-egress/src/fake.rs"


def run(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


class EgressNewSites(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        run(self.repo, "init", "-q")
        run(self.repo, "config", "user.email", "t@example.invalid")
        run(self.repo, "config", "user.name", "t")

    def tearDown(self):
        self.tmp.cleanup()

    def commit(self, files: dict[str, str | None]) -> str:
        for rel, text in files.items():
            path = self.repo / rel
            if text is None:
                run(self.repo, "rm", "-q", rel)
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            run(self.repo, "add", rel)
        run(self.repo, "commit", "-q", "--allow-empty", "-m", "c")
        return run(self.repo, "rev-parse", "HEAD")

    def test_a_new_site_fails_even_when_the_base_already_has_one(self):
        base = self.commit({RS: "fn a() { reqwest::Client::new(); }\n"})
        head = self.commit({RS: "fn a() { reqwest::Client::new(); }\nfn b() { reqwest::Client::builder(); }\n"})
        found = egress_new_sites.new_sites(self.repo, base, head)
        self.assertEqual(len(found), 1, found)
        self.assertIn("1 new reqwest-client", found[0])

    def test_an_untouched_red_base_is_not_the_change(self):
        base = self.commit({RS: "fn a() { reqwest::Client::new(); }\n"})
        head = self.commit({"cmux-tui/crates/acpmux/src/other.rs": "fn c() {}\n"})
        self.assertEqual(egress_new_sites.new_sites(self.repo, base, head), [])

    def test_a_rename_compares_with_the_old_path(self):
        base = self.commit({RS: "fn a() { reqwest::Client::new(); }\n"})
        run(self.repo, "mv", RS, RS.replace("fake_site", "moved_site"))
        run(self.repo, "commit", "-q", "-m", "mv")
        head = run(self.repo, "rev-parse", "HEAD")
        self.assertEqual(egress_new_sites.new_sites(self.repo, base, head), [])

    def test_the_gate_itself_and_comments_are_skipped(self):
        base = self.commit({"README": "x\n"})
        head = self.commit({GATE_RS: "fn g() { reqwest::Client::new(); }\n",
                            RS: "// reqwest::Client::new()\nfn a() {}\n"})
        self.assertEqual(egress_new_sites.new_sites(self.repo, base, head), [])

    def test_main_exits_nonzero_on_a_new_site(self):
        base = self.commit({"README": "x\n"})
        head = self.commit({RS: "fn a() { reqwest::Client::new(); }\n"})
        self.assertEqual(egress_new_sites.main(["--base", base, "--head", head, "--repo", str(self.repo)]), 1)


if __name__ == "__main__":
    unittest.main()
