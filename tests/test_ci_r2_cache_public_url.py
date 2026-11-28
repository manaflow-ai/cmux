"""Every workflow that restores or saves through the R2 cache actions must
declare CI_CACHE_R2_PUBLIC_URL, since r2-cache.sh treats a missing URL as a
miss on restore and saves nothing. The iOS upload workflows lacked it, so
#14180's caches never filled (09-24/25: 0 hits, 344 misses)."""
from __future__ import annotations

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
USES_R2_CACHE = re.compile(
    r"""^\s*(?:-\s+)?uses:\s*["']?\./\.github/actions/cache-(?:restore|save)/?["']?\s*(?:#.*)?$""", re.M
)
DECLARES_URL = re.compile(r"^\s*CI_CACHE_R2_PUBLIC_URL:\s*\S", re.M)


class R2CachePublicUrlTests(unittest.TestCase):
    def test_every_r2_cache_workflow_declares_the_public_url(self):
        users = [p for p in sorted(WORKFLOWS.glob("*.y*ml")) if USES_R2_CACHE.search(p.read_text())]
        self.assertIn(WORKFLOWS / "ios-testflight.yml", users)
        missing = [p.name for p in users if not DECLARES_URL.search(p.read_text())]
        self.assertEqual(missing, [], "workflows using the R2 cache actions without CI_CACHE_R2_PUBLIC_URL")


if __name__ == "__main__":
    unittest.main()
