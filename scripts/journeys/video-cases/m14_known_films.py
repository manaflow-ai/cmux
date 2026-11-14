#!/usr/bin/env python3
"""The cmux-ad m14 known films (pixel-perfect, 2026-11-05) for judge_pixel's m14 rows. They read films under
/work/tmp/resize-videos, outside the judge goldens' store, so they are not in the goldens' TRUTH unit tests (the goldens
run every video-cases/test_judge_*.py; a test there reads only pinned files): run them on the VM yourself after a change
to the m14 rules. They skip where the films are not on the machine.

    /work/tmp/bv-venv/bin/python -I scripts/journeys/video-cases/m14_known_films.py
"""
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

import judge_pixel as jp  # noqa: E402
from test_judge_pixel import jp_frames  # noqa: E402

# cmux-ad m14 known films (pixel-perfect, 2026-11-05): ab-s4pin-44ab81a (#35900 head 44ab81aadd96, cmux22, 120 Hz).
KNOWN_RUN = Path("/work/tmp/resize-videos/runs/ab-s4pin-44ab81a-20261105T000715Z-cmux22")
KNOWN_HELD = KNOWN_RUN / "px-keys-held-2-sw-terminals/video/px-keys-held-2-sw-terminals-on-s1"
KNOWN_CLEAN = KNOWN_RUN / "px-keys-rk-3t-sw-terminals/video/px-keys-rk-3t-sw-terminals-on-s1"
# A menu covers rings 2 and 3 of p2's left edge from frame 264 (ring 1 not): R-HARNESS's review of 7cfd91442ece.
KNOWN_COVERED = KNOWN_RUN / "px-keys-lowprompt-jjk-3kz-sw-terminals/video/px-keys-lowprompt-jjk-3kz-sw-terminals-on-s025"


# m18 band (pixel-perfect, STATUS 14660): build 6443b2e9 (commit 09d1234), a slow column drag whose terminal ground runs
# up to 308 px to its pane edge (frames 215-360; pixel-perfect's band_check.py: 133 frames, max 308 px at frame 354).
BAND_RUN = Path("/work/tmp/resize-videos/runs/ab-m28c2-09d1234-20261105T135308Z-cmux23")
BAND_FILM = BAND_RUN / "px-col-drag-2-s1r/video/px-col-drag-2-s1r-s1"


@unittest.skipUnless(Path(f"{BAND_FILM}.mov.scan").is_file(), f"the band film is not on this machine ({BAND_FILM})")
class BandKnownFilmTests(unittest.TestCase):
    """The m18 band known film: the terminal row must fail as `band` in the frames that band_check.py measures (at least
    120 of its 133), with a worst band of at least 300 px."""

    @classmethod
    def setUpClass(cls):
        cls.report = jp.judge(str(BAND_FILM))

    def test_the_band_fails(self):
        for contract in ("m18", "m20"):
            row = self.report[contract]["kinds"]["terminal"]
            self.assertGreaterEqual(row["band"], 120, (contract, row.get("band_ranges")))
            self.assertGreaterEqual(row["worst_px"], 300, contract)


@unittest.skipUnless(Path(f"{KNOWN_HELD}.mov.scan").is_file() and Path(f"{KNOWN_CLEAN}.mov.scan").is_file(),
                     f"the known m14 films are not on this machine ({KNOWN_RUN})")
class M14KnownFilmTests(unittest.TestCase):
    """The Lead's known films for m14: px-keys-held-2 ON x1 (T|P), where the page stays at an old narrow width while its
    pane is wide (frames 411-538: the shell beside it, up to 1504 device px), must fail in every one of those frames; the
    terminals-only px-keys-rk-3t ON x1 (0 failing and 0 late terminal frames under m6) must pass."""

    @classmethod
    def setUpClass(cls):
        cls.held = jp.judge(str(KNOWN_HELD))
        cls.clean = jp.judge(str(KNOWN_CLEAN))

    def test_the_page_at_an_old_narrow_width_fails_in_every_frame(self):
        row = self.held["m14"]["kinds"]["page"]
        missing = set(range(411, 539)) - jp_frames(row["fail_ranges"])
        self.assertEqual(missing, set(), f"frames of the old narrow page that m14 passes: {sorted(missing)[:20]}")
        self.assertGreaterEqual(row["worst_px"], 1000)

    @unittest.skipUnless(Path(f"{KNOWN_COVERED}.mov.scan").is_file(), f"{KNOWN_COVERED} is not on this machine")
    def test_rings_under_a_menu_are_not_a_squeeze(self):
        page = jp.judge(str(KNOWN_COVERED))["m14"]["kinds"]["page"]
        self.assertEqual(page["scaled"], 0, page.get("scaled_ranges"))

    def test_a_clean_terminal_film_passes(self):
        kinds = self.clean["m14"]["kinds"]
        self.assertEqual(set(kinds), {"terminal"})
        self.assertGreater(kinds["terminal"]["judged"], 500)
        self.assertEqual(kinds["terminal"]["fail"], 0, kinds["terminal"].get("fail_ranges"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
