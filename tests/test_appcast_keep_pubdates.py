"""A rewritten nightly appcast keeps each item's first-publish pubDate (scripts/ci/appcast_keep_pubdates.py).

2026-10-26: the nightly-next feed listed 4038033920301, 4037856525201 and 4037632091801, all dated
19:38:52Z, because generate_appcast redates every item each time the delta job rewrites the feed.
"""

from pathlib import Path
import json
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "scripts" / "ci" / "appcast_keep_pubdates.py"
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def feed(items: list[tuple[str, str | None]]) -> str:
    body = ""
    for version, date in items:
        stamp = f"<pubDate>{date}</pubDate>" if date else ""
        body += (f"<item><title>{version}</title>{stamp}<sparkle:version>{version}</sparkle:version>"
                 f'<enclosure url="https://example.invalid/{version}.dmg" length="1"/></item>')
    return ('<?xml version="1.0" encoding="utf-8"?><rss version="2.0" '
            'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
            f"<title>cmux NEXT</title>{body}</channel></rss>")


def dates(path: Path) -> dict[str, str | None]:
    return {item.findtext(f"{S}version"): item.findtext("pubDate") for item in ET.parse(path).getroot().iter("item")}


def run(*args: str) -> None:
    subprocess.run([sys.executable, str(TOOL), *args], check=True, capture_output=True, text=True)


def test_rewriting_the_feed_with_an_existing_item_keeps_its_date() -> None:
    rewritten_at = "Mon, 26 Oct 2026 19:38:52 +0000"
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        published = tmp_path / "published.xml"
        published.write_text(feed([("300", "Mon, 26 Oct 2026 19:36:56 +0000")]), encoding="utf-8")
        uploads = tmp_path / "uploads.json"
        uploads.write_text(json.dumps({"200": "2026-10-26T19:17:36Z", "100": "2026-10-26T18:14:47+00:00"}),
                           encoding="utf-8")
        target = tmp_path / "appcast-arm64.xml"
        # What generate_appcast writes: every item dated this run, one with no date at all, and one
        # build no source knows.
        target.write_text(feed([("300", rewritten_at), ("200", rewritten_at), ("100", None), ("50", rewritten_at)]),
                          encoding="utf-8")

        run(str(target), "--feed", str(published), "--dates", str(uploads))
        assert dates(target) == {
            "300": "Mon, 26 Oct 2026 19:36:56 +0000",
            "200": "Mon, 26 Oct 2026 19:17:36 +0000",
            "100": "Mon, 26 Oct 2026 18:14:47 +0000",
            "50": rewritten_at,
        }

        # A second rewrite (the next build's delta run) redates everything again; the published
        # feed now holds the kept dates, and they survive.
        kept = dates(target)
        republished = tmp_path / "live.xml"
        republished.write_text(target.read_text(encoding="utf-8"), encoding="utf-8")
        later = "Mon, 26 Oct 2026 20:05:00 +0000"
        target.write_text(feed([("400", later), ("300", later), ("200", later)]), encoding="utf-8")
        run(str(target), "--feed", str(republished))
        assert dates(target) == {"400": later, "300": kept["300"], "200": kept["200"]}
        assert len(set(dates(target).values())) == 3


def test_a_published_feed_wins_over_an_upload_time() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        published = tmp_path / "published.xml"
        published.write_text(feed([("300", "Mon, 26 Oct 2026 19:36:56 +0000")]), encoding="utf-8")
        uploads = tmp_path / "uploads.json"
        uploads.write_text(json.dumps({"300": "2026-10-26T19:35:37Z"}), encoding="utf-8")
        target = tmp_path / "appcast.xml"
        target.write_text(feed([("300", "Mon, 26 Oct 2026 20:00:00 +0000")]), encoding="utf-8")
        run(str(target), "--feed", str(published), "--dates", str(uploads))
        assert dates(target) == {"300": "Mon, 26 Oct 2026 19:36:56 +0000"}


if __name__ == "__main__":
    test_rewriting_the_feed_with_an_existing_item_keeps_its_date()
    test_a_published_feed_wins_over_an_upload_time()
    print("PASS: a rewritten appcast keeps each item's first-publish pubDate")
