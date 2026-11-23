#!/usr/bin/env python3
"""The payload advisory guard fails a pinned third-party payload inside a published security advisory."""
import json
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/cmux-next"))
import payload_advisories as pa

# GHSA-cmqw-9r2w-6wv2 as GitHub's repository advisory API returns it (2026-11-16).
PICKER_UXSS = {
    "ghsa_id": "GHSA-cmqw-9r2w-6wv2",
    "cve_id": None,
    "summary": "Universal XSS from website-driven element picker",
    "state": "published",
    "withdrawn_at": None,
    "html_url": "https://github.com/gorhill/uBlock/security/advisories/GHSA-cmqw-9r2w-6wv2",
    "vulnerabilities": [{
        "package": {"ecosystem": "", "name": "uBlock Origin"},
        "patched_versions": "1.75.4",
        "vulnerable_functions": [],
        "vulnerable_version_range": "1.75.2 and lower",
    }],
}
UBO = pa.PAYLOADS[0]


class Ranges(unittest.TestCase):
    def test_and_lower(self):
        self.assertTrue(pa.in_range("1.75.0", "1.75.2 and lower"))
        self.assertTrue(pa.in_range("1.75.2", "1.75.2 and lower"))
        self.assertFalse(pa.in_range("1.75.4", "1.75.2 and lower"))

    def test_operator_clauses_all_hold(self):
        self.assertTrue(pa.in_range("1.70.0", ">= 1.60, < 1.75.4"))
        self.assertFalse(pa.in_range("1.50.0", ">= 1.60, < 1.75.4"))
        self.assertFalse(pa.in_range("1.75.4", ">= 1.60, < 1.75.4"))
        self.assertTrue(pa.in_range("1.75.3", "<= 1.75.3"))

    def test_versions_compare_numerically_and_ignore_trailing_zeros(self):
        self.assertTrue(pa.in_range("1.9.0", "< 1.10"))
        self.assertTrue(pa.in_range("1.75.0", "= 1.75"))

    def test_unreadable_range_falls_back_to_the_newest_patched_release(self):
        self.assertTrue(pa.affected("1.75.0", {"vulnerable_version_range": "all before the fix", "patched_versions": "1.74.9, 1.75.4"}))
        self.assertFalse(pa.affected("1.76.4", {"vulnerable_version_range": "all before the fix", "patched_versions": "1.75.4"}))
        self.assertIsNone(pa.affected("1.76.4", {"vulnerable_version_range": "unknown", "patched_versions": None}))


class Verdicts(unittest.TestCase):
    def test_the_old_1_75_0_pin_is_behind_the_picker_fix(self):
        behind, unreadable = pa.findings(UBO, "1.75.0", [PICKER_UXSS])
        self.assertEqual(len(behind), 1)
        self.assertIn("GHSA-cmqw-9r2w-6wv2", behind[0])
        self.assertIn("fixed in 1.75.4", behind[0])
        self.assertEqual(unreadable, [])

    def test_the_fixed_releases_pass(self):
        for version in ("1.75.4", "1.76.0", "1.76.4"):
            self.assertEqual(pa.findings(UBO, version, [PICKER_UXSS]), ([], []), version)

    def test_a_withdrawn_advisory_is_ignored(self):
        withdrawn = dict(PICKER_UXSS, withdrawn_at="2026-11-16T00:00:00Z")
        self.assertEqual(pa.findings(UBO, "1.75.0", [withdrawn]), ([], []))


class Main(unittest.TestCase):
    def run_main(self, root: Path, advisories: dict) -> int:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(advisories, f)
        try:
            return pa.main(["--root", str(root), "--advisories-json", f.name])
        finally:
            Path(f.name).unlink()

    def checkout_with_ublock(self, version: str) -> Path:
        root = Path(tempfile.mkdtemp(prefix="payload-advisories-"))
        self.addCleanup(shutil.rmtree, root)
        for payload in pa.PAYLOADS:
            src = (ROOT / payload.pin_file).read_text()
            dst = root / payload.pin_file
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(re.sub(r"1\.\d+\.\d+", version, src) if "uBlock" in payload.name else src)
        return root

    def test_exit_1_on_the_old_pin_and_0_on_the_current_one(self):
        self.assertEqual(self.run_main(self.checkout_with_ublock("1.75.0"), {"gorhill/uBlock": [PICKER_UXSS]}), 1)
        self.assertEqual(self.run_main(self.checkout_with_ublock("1.76.4"), {"gorhill/uBlock": [PICKER_UXSS]}), 0)

    def test_this_checkout_is_outside_the_picker_advisory(self):
        self.assertEqual(self.run_main(ROOT, {"gorhill/uBlock": [PICKER_UXSS]}), 0)


class Coverage(unittest.TestCase):
    def test_every_pin_reads_from_its_file(self):
        for payload in pa.PAYLOADS:
            pa.parse_version(pa.read_pin(payload))

    def test_every_fetched_third_party_release_is_watched(self):
        """A fetch or bundle script that downloads another project's GitHub release needs a PAYLOADS entry."""
        watched = {p.pin_file for p in pa.PAYLOADS}
        missing = []
        for script in sorted((ROOT / "scripts/cmux-next").glob("*.sh")):
            if not script.name.startswith(("fetch-", "bundle-")):
                continue
            owners = set(re.findall(r"github\.com/([\w.-]+)/[\w.-]+/releases/download", script.read_text()))
            if owners - {"manaflow-ai"}:
                rel = str(script.relative_to(ROOT))
                if rel not in watched:
                    missing.append(rel)
        self.assertEqual(missing, [], "add a PAYLOADS entry in scripts/cmux-next/payload_advisories.py")


if __name__ == "__main__":
    unittest.main()
