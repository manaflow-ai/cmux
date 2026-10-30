#!/usr/bin/env bash
# Behavioral test for scripts/ci/generate-nightly-deltas.sh, the
# generate-nightly-deltas job of nightly.yml.
#
# Sparkle downloads a delta only when the installed build is one of the delta
# bases in the newest appcast item; any other Mac downloads the full DMG (221 MB
# for nightly-next arm64 on 2026-10-21). nightly-next ships many builds a day,
# and the job used to diff from one base (the build just before), so a Mac that
# missed a single build paid the full download. Macs check hourly and builds
# land every 20-40 minutes, so a running Mac is usually 1-3 builds behind; a Mac
# that slept overnight or over a weekend is a day or more behind. The job must
# offer deltas from the three newest earlier builds of the same track plus the
# newest one at least 24 hours old and the newest one at least 72 hours old.
#
# The script runs with a fake gh serving a release listing, a fake swift, and
# fake Sparkle tools (SPARKLE_TOOLS_DIR). The fake generate_appcast writes one
# delta per base up to --maximum-deltas, the way the real tool does, so the
# test checks the job's own choices: which builds it fetches, how many deltas
# it asks for, the release asset names and the revised feed. The fixture DMGs
# never mount, so hdiutil, prebuild_sparkle_deltas.sh and the key filter leave
# every decision to generate_appcast on macOS and Linux alike.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci/generate-nightly-deltas.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmux-nightly-deltas.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

PREFIX="cmux-nightly-next-macos"
NEW=108
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/tools" "$TMP_DIR/input"

digest() { printf 'sha256:%s' "$(printf 'fixture-%s' "$1" | shasum -a 256 | cut -d' ' -f1)"; }
asset() { # id name hours-ago
  printf '{"id":%s,"name":"%s","state":"uploaded","apiUrl":"https://api.example.invalid/assets/%s","digest":"%s","createdAt":"%s"}' \
    "$1" "$2" "$1" "$(digest "$1")" \
    "$(python3 -c 'import datetime, sys; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$3")"
}
# Eight earlier arm64 builds (100-107, uploaded 120 hours to 20 minutes ago),
# this build, a newer one, another architecture, the legacy-identity DMG and an
# existing delta.
{
  printf '{"assets":['
  sep=""
  id=0
  while read -r name hours; do
    id=$((id + 1))
    printf '%s%s' "$sep" "$(asset "$id" "$name" "$hours")"
    sep=","
  done <<LIST
$PREFIX-arm64-100.dmg 120
$PREFIX-arm64-101.dmg 80
$PREFIX-arm64-102.dmg 50
$PREFIX-arm64-103.dmg 26
$PREFIX-arm64-104.dmg 5
$PREFIX-arm64-105.dmg 1.5
$PREFIX-arm64-106.dmg 0.8
$PREFIX-arm64-107.dmg 0.3
$PREFIX-arm64-$NEW.dmg 0.1
$PREFIX-arm64-109.dmg 0
$PREFIX-x86_64-107.dmg 0.3
$PREFIX-nightlyid-arm64-107.dmg 0.3
$PREFIX-arm64-107-106.delta 0.3
$PREFIX-arm64.dmg 0.1
LIST
  printf ']}\n'
} > "$TMP_DIR/release.json"

cat > "$TMP_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "$CMUX_TEST_CALL_LOG"
case "$1 $2" in
  "release view") cat "$CMUX_TEST_RELEASE_JSON" ;;
  "api "*) url="${*: -1}"; printf 'fixture-%s' "${url##*/}" ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
EOF
cat > "$TMP_DIR/bin/swift" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "fixture-public-key"
EOF
# generate_appcast <options> <archives>: one item per archive; the newest item
# lists a delta from each of the --maximum-deltas newest older archives, named
# and linked as the real tool does ("<app name><new>-<old>.delta").
cat > "$TMP_DIR/tools/generate_appcast" <<'EOF'
#!/usr/bin/env python3
import email.utils, pathlib, re, sys, urllib.parse
args = sys.argv[1:]
archives = pathlib.Path(args[-1])
prefix = args[args.index("--download-url-prefix") + 1]
maximum = int(args[args.index("--maximum-deltas") + 1]) if "--maximum-deltas" in args else 0
builds = sorted((int(re.search(r"-(\d+)\.dmg$", p.name).group(1)), p.name) for p in archives.glob("*.dmg"))
new, new_name = builds[-1]
deltas = ""
for old, _ in sorted(builds[:-1], reverse=True)[:maximum]:
    name = f"cmux NEXT{new}-{old}.delta"
    (archives / name).write_bytes(b"delta")
    deltas += (f'<enclosure url="{prefix}{urllib.parse.quote(name)}" sparkle:deltaFrom="{old}" '
               f'length="5" type="application/octet-stream" sparkle:edSignature="sig-{old}"/>')
items = []
for build, name in reversed(builds):
    extra = f"<sparkle:deltas>{deltas}</sparkle:deltas>" if build == new and deltas else ""
    # Like the real tool, date each item by its archive's modification time.
    stamp = email.utils.formatdate((archives / name).stat().st_mtime)
    items.append(f"<item><title>{build}</title><pubDate>{stamp}</pubDate><sparkle:version>{build}</sparkle:version>"
                 f"<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>"
                 f'<enclosure url="{prefix}{name}" length="3" type="application/octet-stream" sparkle:edSignature="sig-{build}"/>'
                 f"{extra}</item>")
(archives / "appcast.xml").write_text(
    '<?xml version="1.0" encoding="utf-8"?><rss version="2.0" '
    'xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT</title>'
    + "".join(items) + "</channel></rss>")
EOF
for tool in sign_update BinaryDelta; do
  printf '#!/usr/bin/env bash\necho "fake %s must not run" >&2\nexit 1\n' "$tool" > "$TMP_DIR/tools/$tool"
done
chmod +x "$TMP_DIR/bin"/* "$TMP_DIR/tools"/*

printf 'fixture-dmg' > "$TMP_DIR/input/$PREFIX-arm64-$NEW.dmg"
cat > "$TMP_DIR/input/appcast-arm64.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT</title><item><sparkle:channel>cmux-next</sparkle:channel><pubDate>Mon, 26 Oct 2026 19:36:56 +0000</pubDate><sparkle:version>$NEW</sparkle:version><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><enclosure url="https://github.com/manaflow-ai/cmux/releases/download/nightly-next/$PREFIX-arm64-$NEW.dmg" length="11" type="application/octet-stream" sparkle:edSignature="sig"/><description>New: the fixture changelog</description></item></channel></rss>
EOF

run_script() { # out-dir
  : > "$CMUX_TEST_CALL_LOG"
  PATH="$TMP_DIR/bin:$PATH" \
  SPARKLE_TOOLS_DIR="$TMP_DIR/tools" \
  SPARKLE_PRIVATE_KEY="" \
  GH_TOKEN=fixture-token \
  GITHUB_REPOSITORY=manaflow-ai/cmux \
  CHANNEL_RELEASE_TAG=nightly-next \
  CHANNEL_DMG_PREFIX="$PREFIX" \
  NIGHTLY_VARIANT=arm64 \
  NIGHTLY_BUILD="$NEW" \
  TRACK=nightly-next \
  NEXT_SPARKLE_PRIVATE_KEY=fixture-private-key \
  SPARKLE_CHANNEL=cmux-next \
    "$SCRIPT" "$TMP_DIR/input/$PREFIX-arm64-$NEW.dmg" "$TMP_DIR/input/appcast-arm64.xml" "$1" \
    > "$1.log" 2>&1 || { cat "$1.log" >&2; fail "the delta script failed"; }
}
export CMUX_TEST_CALL_LOG="$TMP_DIR/calls.log"
export CMUX_TEST_RELEASE_JSON="$TMP_DIR/release.json"

run_script "$TMP_DIR/out"
expected_bases="107 106 105 103 101"
fetched="$(grep -c '^gh api' "$CMUX_TEST_CALL_LOG" || true)"
[ "$fetched" -eq 5 ] || fail "expected five earlier builds to be fetched, got $fetched downloads"
for old in $expected_bases; do
  [ -s "$TMP_DIR/out/$PREFIX-arm64-$NEW-$old.delta" ] || fail "no release asset for the delta from build $old"
done
actual="$(cd "$TMP_DIR/out" && ls ./*.delta | sed -E 's/.*-([0-9]+)\.delta$/\1/' | sort -rn | tr '\n' ' ' | sed 's/ $//')"
[ "$actual" = "$expected_bases" ] || fail "delta bases are '$actual', expected '$expected_bases'"

python3 - "$TMP_DIR/out/appcast-arm64.xml" "$NEW" "$PREFIX" "$expected_bases" <<'PY' || fail "the revised feed does not offer the deltas"
import sys
import xml.etree.ElementTree as ET
path, new, prefix, bases = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split()
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(path).getroot().iter("item")
newest = next(item for item in items if item.findtext(f"{S}version") == new)
offered = {}
for enclosure in newest.iter("enclosure"):
    base = enclosure.get(f"{S}deltaFrom")
    if base is None:
        continue
    url = enclosure.get("url")
    want = f"https://github.com/manaflow-ai/cmux/releases/download/nightly-next/{prefix}-arm64-{new}-{base}.delta"
    assert url == want, f"delta from {base} is linked as {url}, expected {want}"
    assert enclosure.get(f"{S}edSignature"), f"delta from {base} is unsigned"
    offered[base] = url
assert sorted(offered) == sorted(bases), f"newest item offers deltas from {sorted(offered)}, expected {sorted(bases)}"
assert newest.findtext("description") == "New: the fixture changelog", "the changelog was not carried"
for item in ET.parse(path).getroot().iter("item"):
    assert [c.text for c in item.findall(f"{S}channel")] == ["cmux-next"], "an item lacks the cmux-next channel"
PY

# Each item keeps the pubDate of its own first publish (2026-10-26: every item of the live feed
# was dated the minute of the latest delta run): this build's from the full feed it was published
# with, each earlier build's from its release asset upload time.
python3 - "$TMP_DIR/out/appcast-arm64.xml" "$NEW" "$CMUX_TEST_RELEASE_JSON" "$PREFIX" <<'PY' || fail "the revised feed redated its items"
import datetime, email.utils, json, re, sys
import xml.etree.ElementTree as ET
path, new, listing, prefix = sys.argv[1:]
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
uploaded = {}
for asset in json.load(open(listing))["assets"]:
    m = re.fullmatch(re.escape(prefix) + r"-arm64-(\d+)\.dmg", asset["name"])
    if m:
        moment = datetime.datetime.fromisoformat(asset["createdAt"].replace("Z", "+00:00"))
        uploaded[m.group(1)] = email.utils.format_datetime(moment)
dates = {item.findtext(f"{S}version"): item.findtext("pubDate") for item in ET.parse(path).getroot().iter("item")}
assert dates[new] == "Mon, 26 Oct 2026 19:36:56 +0000", f"this build is dated {dates[new]}, not its first publish"
earlier = {v: d for v, d in dates.items() if v != new}
assert earlier, "the revised feed lists no earlier build"
for version, date in earlier.items():
    assert date == uploaded[version], f"build {version} is dated {date}, expected its upload time {uploaded[version]}"
assert len(set(dates.values())) == len(dates), f"items share a pubDate: {dates}"
PY

# A track's first build has nothing to diff from: the full feed stays as is.
printf '{"assets":[%s]}\n' "$(asset 1 "$PREFIX-arm64-$NEW.dmg" 0)" > "$TMP_DIR/release.json"
run_script "$TMP_DIR/first"
cmp -s "$TMP_DIR/input/appcast-arm64.xml" "$TMP_DIR/first/appcast-arm64.xml" || fail "a first build changed the full feed"
[ -z "$(cd "$TMP_DIR/first" && ls ./*.delta 2>/dev/null)" ] || fail "a first build produced deltas"

echo "PASS: nightly deltas come from the three newest earlier builds and a 24 h and a 72 h old one, signed, named per track, in the feed, each item keeping its first-publish date"
