"""The Edge feed composer (scripts/ci/edge_feed.py; plans/cmux-next/edge-ring-DESIGN.md, E1)."""

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/edge_feed.py"
sys.path.insert(0, str(SCRIPT.parent))
import edge_feed  # noqa: E402

SIG = "A" * 86 + "=="


def item(build: str, signed: bool = True, channel: str | None = None) -> str:
    signature = f' sparkle:edSignature="{SIG}"' if signed else ""
    tag = f"\n      <sparkle:channel>{channel}</sparkle:channel>" if channel else ""
    return (
        f"    <item>\n      <title>{build}</title>\n      <sparkle:version>{build}</sparkle:version>{tag}\n"
        f'      <enclosure url="https://files-next.cmux.com/nightly-next/edge/{build}.zip" length="1"{signature}/>\n'
        "    </item>\n"
    )


def feed(*items: str) -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" '
        'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n  <channel>\n'
        "    <title>cmux NEXT Edge</title>\n" + "".join(items) + "  </channel>\n</rss>\n"
    )


class EdgeFeedTests(unittest.TestCase):
    def builds(self, text: str) -> list[str]:
        return [edge_feed.build_of(i) for i in edge_feed.items(text)]

    def test_the_new_build_joins_the_feed_newest_first(self) -> None:
        out, kept, dropped = edge_feed.compose(feed(item("300")), feed(item("200"), item("100")), set())
        self.assertEqual(kept, ["300", "200", "100"])
        self.assertEqual(self.builds(out), ["300", "200", "100"])
        self.assertEqual(dropped, [])
        self.assertTrue(out.startswith('<?xml version="1.0"'))
        self.assertTrue(out.endswith("  </channel>\n</rss>\n"))

    def test_at_most_keep_builds_and_pulled_ones_are_dropped(self) -> None:
        current = feed(*(item(str(b)) for b in range(100, 112)))
        out, kept, dropped = edge_feed.compose(feed(item("200")), current, {"111"}, keep=3)
        self.assertEqual(kept, ["200", "110", "109"])
        self.assertIn("111", dropped)
        self.assertNotIn("<sparkle:version>111<", out)

    def test_the_new_builds_copy_wins_and_channel_tags_are_removed(self) -> None:
        new = feed(item("300", channel="cmux-next-dev").replace("<title>300", "<title>fresh"))
        out, _, _ = edge_feed.compose(new, feed(item("300")), set())
        self.assertIn("<title>fresh</title>", out)
        self.assertEqual(out.count("<item>"), 1)
        self.assertNotIn("sparkle:channel", out)

    def test_an_unsigned_or_unversioned_item_refuses_the_whole_feed(self) -> None:
        with self.assertRaises(edge_feed.Refused):
            edge_feed.compose(feed(item("300", signed=False)), feed(item("200")), set())
        with self.assertRaises(edge_feed.Refused):
            edge_feed.compose(feed(item("300")), feed(item("2x0")), set())
        with self.assertRaises(edge_feed.Refused):
            edge_feed.compose(feed(), None, set())

    def test_the_cli_writes_the_feed_and_refuses_without_writing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            d = pathlib.Path(tmp)
            (d / "new.xml").write_text(feed(item("300")))
            (d / "edge.xml").write_text(feed(item("200")))
            (d / "pulled.json").write_text(json.dumps([{"build": "200", "reason": "crash"}]))
            run = subprocess.run(
                [sys.executable, "-I", str(SCRIPT), "compose", "--new", str(d / "new.xml"), "--feed", str(d / "edge.xml"),
                 "--pulled", str(d / "pulled.json"), "--out", str(d / "out.xml")],
                capture_output=True, text=True, check=False)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(json.loads(run.stdout), {"builds": ["300"], "dropped": ["200"]})
            (d / "bad.xml").write_text(feed(item("400", signed=False)))
            run = subprocess.run(
                [sys.executable, "-I", str(SCRIPT), "compose", "--new", str(d / "bad.xml"), "--out", str(d / "out2.xml")],
                capture_output=True, text=True, check=False)
            self.assertEqual(run.returncode, 1)
            self.assertIn("edSignature", run.stderr)
            self.assertFalse((d / "out2.xml").exists())


if __name__ == "__main__":
    unittest.main()
