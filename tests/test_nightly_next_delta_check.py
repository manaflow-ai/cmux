#!/usr/bin/env python3
"""scripts/ci/nightly_next_delta_check.py: prune drops deltas R2 does not serve, check fails a feed without deltas.

Also pins the wiring: republish-nightly-deltas checks the script out, and its nightly-next upload step keeps
going past one failed R2 upload, prunes, writes the feed and then runs the check (run 44152453711 lost all five
deltas to one "Connection reset by peer").

    python3 tests/test_nightly_next_delta_check.py
"""
from __future__ import annotations

import importlib.util
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly_next_delta_check.py"
UPLOAD = ROOT / "scripts/ci/nightly-steps/republish-deltas-upload-next-appcasts.sh"
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
spec = importlib.util.spec_from_file_location("nightly_next_delta_check", SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

R2 = "https://files-next.cmux.com/nightly-next/"
GH = "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/"


def feed(deltas: str) -> str:
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <item>
            <sparkle:version>300</sparkle:version>
            <enclosure url="{R2}cmux-nightly-next-macos-arm64-300.dmg" length="243065005" type="application/octet-stream" sparkle:edSignature="full"/>{deltas}
        </item>
        <item>
            <sparkle:version>200</sparkle:version>
            <enclosure url="{R2}cmux-nightly-next-macos-arm64-200.dmg" length="242849835" type="application/octet-stream" sparkle:edSignature="older"/>
        </item>
    </channel>
</rss>
"""


def delta(base: str, source: int, length: int) -> str:
    return (f'\n                <enclosure url="{base}cmux-nightly-next-macos-arm64-300-{source}.delta" '
            f'sparkle:version="300" sparkle:deltaFrom="{source}" length="{length}" '
            f'type="application/octet-stream" sparkle:edSignature="sig{source}"/>')


TWO = f"\n            <sparkle:deltas>{delta(R2, 200, 13614990)}{delta(GH, 100, 16436842)}\n            </sparkle:deltas>"
ONLY_GH = f"\n            <sparkle:deltas>{delta(GH, 100, 16436842)}\n            </sparkle:deltas>"

failures: list[str] = []


def expect(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "appcast-arm64.xml"
    path.write_text(feed(TWO), encoding="utf-8")
    kept, dropped = mod.prune(path, R2)
    text = path.read_text(encoding="utf-8")
    expect(kept == [f"{R2}cmux-nightly-next-macos-arm64-300-200.delta"], f"prune kept {kept}")
    expect(dropped == [f"{GH}cmux-nightly-next-macos-arm64-300-100.delta"], f"prune dropped {dropped}")
    expect("300-100.delta" not in text and "300-200.delta" in text and "<sparkle:deltas>" in text,
           "prune must drop only the delta R2 does not serve")
    expect(text.count('sparkle:edSignature="full"') == 1, "prune must leave the full enclosure as it was")

    path.write_text(feed(ONLY_GH), encoding="utf-8")
    mod.prune(path, R2)
    expect("<sparkle:deltas>" not in path.read_text(encoding="utf-8"), "prune must drop an emptied sparkle:deltas")

served = {f"{R2}cmux-nightly-next-macos-arm64-300-200.delta": 13614990}
status, lines = mod.check(feed(f"\n            <sparkle:deltas>{delta(R2, 200, 13614990)}\n            </sparkle:deltas>")
                          .encode(), 300, 1, served.get)
expect(status == 0, f"a served delta passes: {lines}")
expect(any("13.6 MB" in line and "5.6%" in line for line in lines), f"check prints the size against the full: {lines}")

status, lines = mod.check(feed("").encode(), 300, 1, served.get)
expect(status == 1, "the detector fails a newest item with no deltas (every Mac downloads 243 MB)")

status, lines = mod.check(feed(f"\n            <sparkle:deltas>{delta(R2, 200, 13614990)}\n            </sparkle:deltas>")
                          .encode(), 300, 1, lambda url: None)
expect(status == 1, "the detector fails a delta R2 does not serve")

status, lines = mod.check(feed("").encode(), 250, 1, served.get)
expect(status == 0 and "notice" in lines[0], "a newer build on the feed owns its deltas: notice, not red")

# keep-item: generate_appcast's items for the earlier archives go; the new build's item keeps its deltas.
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "appcast-arm64.xml"
    path.write_text(feed(TWO), encoding="utf-8")
    expect(mod.keep_item(path, 300) == 1, "keep-item drops the one earlier item")
    text = path.read_text(encoding="utf-8")
    expect("<sparkle:version>200</sparkle:version>" not in text and "300-200.delta" in text,
           "keep-item keeps only build 300's item, with its deltas")
    expect(mod.newest_item(text.encode()) is not None, "keep-item leaves a parsable feed")

# merge: the tail's older bases join the live item; a base the live item lists stays as published.
live = feed(f"\n            <sparkle:deltas>{delta(R2, 200, 13614990)}\n            </sparkle:deltas>")
generated = feed(f"\n            <sparkle:deltas>{delta(GH, 200, 99)}{delta(GH, 50, 34367026)}\n            </sparkle:deltas>")
merged, added = mod.merge(live, generated, 300)
expect(added == ["50"], f"merge adds only the new base: {added}")
expect('length="13614990"' in merged and 'length="99"' not in merged, "merge keeps the published nearest delta")
item = mod.newest_item(merged.encode())
expect(len(item.findall(f"{mod.S}deltas/enclosure")) == 2, "the merged item lists both deltas")
merged, added = mod.merge(feed(""), generated, 300)
expect(len(mod.newest_item(merged.encode()).findall(f"{mod.S}deltas/enclosure")) == 2,
       "merge adds a sparkle:deltas to a live item without one")

# The bases: the live feed's builds and the builds its newest item's deltas start from.
prev_spec = importlib.util.spec_from_file_location("previous", ROOT / "scripts/ci/nightly_next_previous_dmgs.py")
previous = importlib.util.module_from_spec(prev_spec)
prev_spec.loader.exec_module(previous)
expect(previous.earlier_builds(feed(TWO).encode(), 400) == [300, 200, 100],
       "the bases are the feed's items and their deltas' sources, newest first")
expect(previous.earlier_builds(feed(TWO).encode(), 300) == [200, 100], "only builds below the new one")

nearest = (ROOT / "scripts/ci/nightly-steps/appcast-with-nearest-deltas.sh").read_text(encoding="utf-8")
expect("keep-item" in nearest and "full_only" in nearest and 'NIGHTLY_NEXT_NEAREST_DELTA_BASES:-3' in nearest,
       "the publication builds deltas from the 3 nearest builds, keeps its own item, falls back to full-only")
workflow = WORKFLOW.read_text(encoding="utf-8")
expect("appcast-with-nearest-deltas.sh" in workflow and "Check the published feed offers deltas" in workflow,
       "nightly-next-one builds the nearest deltas and the detector runs after the feed write")
download = (ROOT / "scripts/ci/nightly-steps/publish-next-download.sh").read_text(encoding="utf-8")
expect(".delta" in download and "prune" in download, "the publication uploads its deltas to R2 before the feed")
one_job = (ROOT / "scripts/ci/nightly-steps/one-job.sh").read_text(encoding="utf-8")
expect('-"$NIGHTLY_BUILD"-*.delta' in one_job, "one-job.sh hands on only this build's deltas")
expect("NIGHTLY_DELTAS_NEAREST_SHIPPED" in workflow and "RECENT_BASES=0" in (ROOT / "scripts/ci/generate-nightly-deltas.sh").read_text(encoding="utf-8"),
       "the nightly-next tail builds only the older bases")
sparkle = (ROOT / "scripts/sparkle_generate_appcast.sh").read_text(encoding="utf-8")
expect("SPARKLE_TOOLS_CACHE_DIR" in sparkle, "the Sparkle tools are cached on the Mac")

upload = UPLOAD.read_text(encoding="utf-8")
expect('if ! python3 "$r2" upload' in upload, "one failed R2 upload must not drop every delta")
prune_at, write_at, check_at = (upload.find('"$check" prune'), upload.find("write-feed"), upload.find('"$check" check'))
expect(0 <= prune_at < write_at < check_at, "prune before the feed write, the detector after it")
expect("scripts/ci/nightly_next_delta_check.py" in WORKFLOW.read_text(encoding="utf-8"),
       "republish-nightly-deltas must check out nightly_next_delta_check.py")

if failures:
    print("\n".join(f"FAIL: {f}" for f in failures))
    sys.exit(1)
print("PASS")
