#!/usr/bin/env python3
"""The nightly-next track builds, notarizes and publishes only the arm64 variant.

Two nightly-next runs in a row (37648507383, 37667249069) lost all three DMG
notarizations to Apple's queue. Leo's call: nightly-next ships arm64 only, so
each build waits on one notarization. Main's nightly keeps arm64, x86_64 and
universal, and nightly-next leaves its x86_64, universal and legacy feeds on
their last build (an Intel Mac must never be offered an arm64-only app).
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
TEXT = WORKFLOW.read_text()
FOUR = ["appcast-arm64.xml", "appcast-x86_64.xml", "appcast-universal.xml", "appcast.xml"]


def step(name):
    start = TEXT.index(f"      - name: {name}\n")
    end = TEXT.find("\n      - name:", start + 10)
    return TEXT[start:] if end < 0 else TEXT[start:end]


failures = []

# decide: one variant and one feed on nightly-next, three and four elsewhere.
decide = TEXT[TEXT.index("  decide:\n"):TEXT.index("\n  promote-nightly-next:\n")]
variants = re.search(r"const variants = (.+);", decide)
if not variants or "nightly-next" not in variants.group(1) or "['arm64', 'x86_64', 'universal']" not in variants.group(1):
    failures.append("decide must build only ['arm64'] on the nightly-next track and keep three variants elsewhere")
if "core.setOutput('feeds'" not in decide or "feeds: ${{ steps.decide.outputs.feeds }}" not in TEXT:
    failures.append("decide must output the feeds this track publishes")
if decide.index("const track =") > decide.index("const variants ="):
    failures.append("decide must choose the variants after it knows the track")

# publish: every feed list comes from decide, so nightly-next never touches the
# x86_64, universal or legacy feeds and main's list is unchanged.
for name in ("Guard nightly-next publication", "Upload nightly-next appcasts to R2", "Upload nightly appcasts to R2"):
    body = step(name)
    if "appcast-x86_64.xml" in body or "$NIGHTLY_FEEDS" not in body:
        failures.append(f"{name!r} must loop over $NIGHTLY_FEEDS, not a fixed list")
publish = step("Publish nightly release assets")
if "nightly-next" not in publish or "x86_64" not in publish:
    failures.append("'Publish nightly release assets' must publish only arm64 on nightly-next and all variants elsewhere")
assemble = step("Assemble legacy nightly names")
if "nightly-next" not in assemble:
    failures.append("'Assemble legacy nightly names' must skip the universal legacy names on nightly-next")
notes = step("Prepare nightly release notes and appcast summaries")
if "--feeds" not in notes or "$NIGHTLY_FEEDS" not in notes:
    failures.append("the release notes step must pass --feeds $NIGHTLY_FEEDS")
for name in ("Publish verified nightly release metadata", "Record verified nightly publication"):
    if "x86_64.dmg" in step(name):
        failures.append(f"{name!r} must take its download list from the notes step, which knows the track")

if failures:
    print("FAIL: nightly-next arm64 only\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: nightly-next arm64 only")
