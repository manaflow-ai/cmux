#!/usr/bin/env python3
"""scripts/ci/nightly_next_delta_check.py: prune drops deltas R2 does not serve, check fails a feed without deltas.

Also pins the wiring: republish-nightly-deltas checks the script out, and its nightly-next upload step keeps
going past one failed R2 upload, prunes, writes the feed and then runs the check (run 44152453711 lost all five
deltas to one "Connection reset by peer").

    python3 tests/test_nightly_next_delta_check.py
"""
from __future__ import annotations

import importlib.util
import os
import subprocess
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

# Deltas after the feed (docs/ci/nightly-workflow-notes.md#note-31): the publication item is full-only, the deltas
# are built, uploaded and merged into the live item afterwards, and a kept DMG saves the download.
expect("NIGHTLY_NEXT_DELTAS_AFTER_FEED" in nearest and "after-feed" in nearest and "--cache-dir" in nearest
       and "newest --feed-url" in nearest,
       "appcast-with-nearest-deltas.sh has the after-feed mode: still-newest check, cache save, cache use")
expect("NIGHTLY_NEXT_DELTAS_AFTER_FEED: ${{ needs.decide.outputs.one_job == 'true'" in workflow
       and "appcast-with-nearest-deltas.sh after-feed" in workflow
       and "republish-deltas-upload-next-appcasts.sh" in workflow.split("Upload the deltas and give the live item its deltas")[1][:1500]
       and "docs/ci/nightly-workflow-notes.md#note-31" in workflow,
       "nightly-next-one writes the item full-only and revises the live item after the feed")

tmp = Path(tempfile.mkdtemp())
cache, out = tmp / "cache", tmp / "out"
out.mkdir()
for build in (10, 11, 12, 13, 14, 15):
    (tmp / f"cmux-x-arm64-{build}.dmg").write_bytes(b"d" * build)
    previous.save_to_cache(tmp / f"cmux-x-arm64-{build}.dmg", cache, "cmux-x", "arm64", 4)
(tmp / "cmux-x-arm64-99.dmg").write_bytes(b"other")  # not in the cache dir
kept = sorted(p.name for p in cache.iterdir())
expect(kept == [f"cmux-x-arm64-{b}.dmg" for b in (12, 13, 14, 15)], f"the cache keeps the newest 4 builds, has {kept}")
dest = out / "cmux-x-arm64-15.dmg"
msg = previous.from_cache("https://r2/x-15.dmg", dest, cache, served=lambda url: 15)
expect(dest.read_bytes() == b"d" * 15 and "kept copy" in msg, "a kept DMG whose size R2 confirms is used")
bad = out / "cmux-x-arm64-14.dmg"
try:
    previous.from_cache("https://r2/x-14.dmg", bad, cache, served=lambda url: 999)
    expect(False, "a kept DMG whose size R2 contradicts is refused")
except RuntimeError:
    expect(not (cache / "cmux-x-arm64-14.dmg").exists() and not bad.exists(), "a contradicted copy is deleted, not used")
try:
    previous.from_cache("https://r2/x-13.dmg", out / "cmux-x-arm64-13.dmg", cache, served=lambda url: None)
    expect(False, "an unknown R2 length refuses the cache")
except RuntimeError:
    pass
try:
    previous.from_cache("https://r2/x-1.dmg", out / "cmux-x-arm64-1.dmg", cache, served=lambda url: 1)
    expect(False, "an uncached build is not found")
except FileNotFoundError:
    pass
mod.fetch = lambda url: feed(TWO).encode()
expect(mod.main(["newest", "--feed-url", "x", "--build", "300"]) == 0 and mod.main(["newest", "--feed-url", "x", "--build", "200"]) == 1,
       "newest passes only for the feed's newest build")
# published-build's read-back (run 45607031207: a refused publication said it published; the feed stayed put).
expect(mod.main(["published", "--feed-url", "x", "--build", "300"]) == 0, "published passes for the feed's newest build")
expect(mod.main(["published", "--feed-url", "x", "--build", "200"]) == 0,
       "published passes for a build on the feed under a newer one that already went out")
expect(mod.main(["published", "--feed-url", "x", "--build", "400"]) == 1,
       "published fails a build the feed does not list (the feed did not move)")
expect(mod.published(feed(TWO).encode(), 250)[0] == 1, "published fails a build missing between the feed's builds")
expect(mod.published(b"<rss><channel></channel></rss>", 300)[0] == 1, "published fails an empty feed")
merged_file = tmp / "merged.xml"
merged_file.write_text(feed(TWO), encoding="utf-8")
expect(mod.main(["newest", "--feed-file", str(merged_file), "--build", "300"]) == 0
       and mod.main(["newest", "--feed-file", str(merged_file), "--build", "200"]) == 1,
       "newest --feed-file checks the feed about to be written")
upload = (ROOT / "scripts/ci/nightly-steps/republish-deltas-upload-next-appcasts.sh").read_text(encoding="utf-8")
expect(upload.index('newest --feed-file "$live"') < upload.index('"$check" merge'),
       "the after-feed write checks the live snapshot before merge")
expect(upload.index('"$check" merge') < upload.index("write-feed --feed"),
       "the after-feed write merges before write-feed")
expect('DELTAS_ONLY_WHILE_NEWEST: "1"' in (ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8"),
       "nightly-next-one's post-feed upload asks for the still-newest check")
expect(previous.main(["--save", str(tmp / "missing.dmg"), "--cache-dir", str(cache), "--prefix", "cmux-x", "--variant", "arm64"]) == 0,
       "a failed cache save never fails the build")

# If a newer publication already pruned this build, newest must run on the live
# snapshot before merge, whose input requires the build item to exist.
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    tools = root / ".publish-tooling/scripts/ci"
    tools.mkdir(parents=True)
    inputs = root / "nightly-deltas"
    inputs.mkdir()
    (inputs / "appcast-arm64.xml").write_text(feed(""), encoding="utf-8")
    (inputs / "cmux-nightly-next-macos-arm64-200-100.delta").touch()
    (root / "remote.xml").write_text(
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>'
        '<item><sparkle:version>300</sparkle:version></item></channel></rss>', encoding="utf-8")
    (root / "curl").write_text(
        "#!/usr/bin/env python3\n"
        "import pathlib, sys\n"
        "pathlib.Path(sys.argv[sys.argv.index('-o') + 1]).write_bytes(pathlib.Path('remote.xml').read_bytes())\n",
        encoding="utf-8")
    (root / "curl").chmod(0o755)
    (tools / "publish-nightly-next-r2.py").write_text(
        "import sys\n"
        "sys.exit(0)\n", encoding="utf-8")
    (tools / "nightly_next_delta_check.py").write_text(
        "import pathlib, sys\n"
        "pathlib.Path('calls').open('a', encoding='utf-8').write(' '.join(sys.argv[1:]) + '\\n')\n"
        "sys.exit(1 if sys.argv[1] == 'newest' else (99 if sys.argv[1] == 'merge' else 0))\n",
        encoding="utf-8")
    (tools / "nightly-next-guard.py").write_text("", encoding="utf-8")
    step = ROOT / "scripts/ci/nightly-steps/republish-deltas-upload-next-appcasts.sh"
    env = {**os.environ, "PATH": str(root) + os.pathsep + os.environ["PATH"],
           "CHANNEL_FEED_BASE": "https://feed.example", "NIGHTLY_BUILD": "200",
           "DELTAS_ONLY_WHILE_NEWEST": "1", "GITHUB_STEP_SUMMARY": str(root / "summary")}
    subprocess.run(["bash", str(step)], cwd=root, env=env, check=True, capture_output=True)
    calls = (root / "calls").read_text(encoding="utf-8")
    expect("newest --feed-file" in calls and "merge" not in calls,
           "a superseded target is skipped before merge when it is absent from the live feed")

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
