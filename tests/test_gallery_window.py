"""scripts/cmux-next/gallery-window.py: the person's settings become the gallery query and backdrop."""

import datetime as dt
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/cmux-next/gallery-window.py"
spec = importlib.util.spec_from_file_location("gallery_window", SCRIPT)
gw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gw)

TODAY = dt.date(2026, 11, 4)


class GalleryWindowTests(unittest.TestCase):
    def test_jsonc_comments_and_trailing_commas(self):
        text = '{\n  // theme\n  "appearance": { "theme": "Dracula", /* x */ "url": "http://a//b", },\n}'
        self.assertEqual(json.loads(gw.strip_jsonc(text)), {"appearance": {"theme": "Dracula", "url": "http://a//b"}})

    def test_nested_and_dotted_keys(self):
        self.assertEqual(gw.setting({"appearance": {"density": "comfortable"}}, "appearance.density"), "comfortable")
        self.assertEqual(gw.setting({"appearance.density": "compact"}, "appearance.density"), "compact")
        self.assertIsNone(gw.setting({}, "appearance.density"))

    def test_theme_pair_follows_the_system_side(self):
        self.assertEqual(gw.pick_theme("light:Alabaster,dark:Dracula", dark=True), "Dracula")
        self.assertEqual(gw.pick_theme("light:Alabaster,dark:Dracula", dark=False), "Alabaster")
        self.assertEqual(gw.pick_theme("Nord", dark=False), "Nord")

    def test_app_theme_wins_over_terminal_theme_and_ghostty(self):
        settings = {"appearance": {"appTheme": "Nord", "theme": "Dracula"}}
        self.assertEqual(gw.resolve_appearance(settings, {"theme": "X"}, True, TODAY)["query"]["theme"], "Nord")
        follow = {"appearance": {"appTheme": "followTerminal"}}
        self.assertEqual(gw.resolve_appearance(follow, {"theme": "Builtin Dark"}, True, TODAY)["query"]["theme"], "Builtin Dark")

    def test_one_theme_shows_its_own_side_and_a_pair_follows_the_system(self):
        one = gw.resolve_appearance({"appearance": {"theme": "Alabaster"}}, {}, True, TODAY)["query"]
        self.assertNotIn("colorScheme", one)
        pair = gw.resolve_appearance({"appearance": {"theme": "light:A,dark:B"}}, {}, False, TODAY)["query"]
        self.assertEqual((pair["theme"], pair["colorScheme"]), ("A", "light"))

    def test_five_densities_map_to_the_galleries_two(self):
        for value, expected in (("ultraCompact", "compact"), ("cozy", "compact"), ("spacious", "comfortable")):
            query = gw.resolve_appearance({"appearance": {"density": value}}, {}, True, TODAY)["query"]
            self.assertEqual(query["density"], expected)

    def test_opaque_window_needs_no_host_backdrop(self):
        resolved = gw.resolve_appearance({}, {}, True, TODAY)
        self.assertEqual(resolved["backdrop"], {"kind": "opaque"})
        self.assertNotIn("backdrop", resolved["query"])

    def test_painting_uses_the_bundled_art_and_the_theme_tint(self):
        resolved = gw.resolve_appearance({"appearance": {"background": "munch-scream"}}, {}, True, TODAY)
        self.assertEqual(resolved["backdrop"]["kind"], "art")
        self.assertTrue(Path(resolved["backdrop"]["image"]).is_file())
        self.assertEqual(resolved["query"]["backdrop"], "host")
        self.assertNotIn("tint", resolved["query"])

    def test_translucent_window_is_glass_at_its_opacity(self):
        resolved = gw.resolve_appearance({}, {"background-opacity": "0.7", "background-blur": "macos-glass-regular"}, False, TODAY)
        self.assertEqual(resolved["backdrop"], {"kind": "glass"})
        self.assertEqual(resolved["query"]["tint"], "0.7")
        self.assertEqual(resolved["appearance"], "light")

    def test_file_and_desktop_pictures(self):
        file_pick = gw.resolve_appearance({"appearance": {"background": "file:/Users/me/p.png"}}, {}, True, TODAY)
        self.assertEqual(file_pick["backdrop"], {"kind": "art", "image": "/Users/me/p.png"})
        desktop = gw.resolve_appearance({"appearance": {"background": "desktop"}}, {}, True, TODAY)
        self.assertEqual(desktop["backdrop"], {"kind": "desktop"})

    def test_daily_reads_the_apps_rotation(self):
        work = gw.daily_art(TODAY)
        self.assertIsNotNone(work)
        self.assertIsNotNone(gw.art_file(work))
        self.assertNotEqual(work, gw.daily_art(TODAY + dt.timedelta(days=1)))

    def test_print_spec_opens_one_window_per_size(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "cmux-next.json"
            config.write_text('{"appearance": {"theme": "Dracula", "density": "comfortable"}}')
            out = subprocess.run(
                [sys.executable, str(SCRIPT), "--entry", "agent-pane.composer", "--sizes", "narrow,900x600",
                 "--config", str(config), "--gallery", "http://127.0.0.1:4178/gallery/#/agent-pane.composer",
                 "--print-spec"],
                capture_output=True, text=True, check=True,
            )
        spec = json.loads(out.stdout)
        self.assertEqual([(s["width"], s["height"]) for s in spec["stages"]], [(420, 720), (900, 600)])
        url = spec["stages"][0]["url"]
        self.assertTrue(url.startswith("http://127.0.0.1:4178/gallery/frame.html?entry=agent-pane.composer"), url)
        self.assertIn("theme=Dracula", url)
        self.assertIn("density=comfortable", url)
        self.assertEqual(spec["loopSeconds"], 1.5)


if __name__ == "__main__":
    unittest.main()
