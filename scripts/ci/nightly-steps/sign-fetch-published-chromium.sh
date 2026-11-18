#!/usr/bin/env bash
# nightly.yml build-sign-notarize-nightly: "Fetch the published Chromium framework" runs `start`, which fetches in
# the background (scripts/ci/background_build.py) beside the steps before signing; "Codesign apps" runs `join`
# (at most 5 min, then the fetch is stopped) and hands the copy to sign-cef.sh as CMUX_CEF_REUSE_FRAMEWORK.
#
#   sign-fetch-published-chromium.sh start|join|fetch <out-dir>
#
# `fetch` copies "Chromium Embedded Framework.framework" out of the DMG the feed serves now (the newest item's
# full archive in $CHANNEL_FEED_BASE's feed for $NIGHTLY_VARIANT) into <out-dir>. sign-cef.sh puts that copy in the new app in place of its
# fresh signature only when both are the same code signed by the same signer, so while the Chromium engine
# (cef-manifest.json) is unchanged every build ships the same framework bytes and each Sparkle delta leaves the
# 270 MB framework out (Lawrence, relayed by Leo: "if chromium version doesn't change, update doesnt have to
# include chromium parts").
#
# Best effort, always exits 0: with no copy, sign-cef.sh signs as before. Every network call is bounded.
set -uo pipefail

mode="${1:-}"
out="${2:?usage: sign-fetch-published-chromium.sh start|join|fetch <out-dir>}"
state="$out.state"
background_build="$(dirname "$0")/../background_build.py"
case "$mode" in
  start)
    python3 "$background_build" start --state "$state" published-chromium -- bash "$0" fetch "$out" ||
      echo "could not start the published Chromium framework fetch"
    exit 0 ;;
  join)
    [[ -d "$state" ]] || exit 0
    python3 "$background_build" join --state "$state" published-chromium --timeout 300 || true
    python3 "$background_build" stop --state "$state" || true
    exit 0 ;;
  fetch) ;;
  *) echo "usage: sign-fetch-published-chromium.sh start|join|fetch <out-dir>" >&2; exit 2 ;;
esac
# The feed names of "Inject nightly identities and metadata", which runs after this starts.
if [[ "${NIGHTLY_VARIANT:?}" == universal ]]; then appcast=appcast.xml; else appcast="appcast-$NIGHTLY_VARIANT.xml"; fi
feed_url="${CHANNEL_FEED_BASE:?}/$appcast"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cef-reuse.XXXXXX")"
mnt="$work/mnt"
attached=""
cleanup() {
  if [[ -n "$attached" ]]; then hdiutil detach -quiet -force "$mnt" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
skip() { echo "no published Chromium framework to reuse: $*"; exit 0; }

curl -fsSL --retry 3 --max-time 60 -A "cmux-cef-reuse/1" -o "$work/feed.xml" "$feed_url" ||
  skip "could not read $feed_url"
# The first item is the build the feed serves; its full archive is the enclosure without sparkle:deltaFrom.
dmg_url="$(python3 -I - "$work/feed.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
for item in ET.parse(sys.argv[1]).getroot().iter("item"):
    for enclosure in item.findall("enclosure"):
        if enclosure.get(SPARKLE + "deltaFrom") is None and enclosure.get("url"):
            print(enclosure.get("url"))
            sys.exit(0)
    break
sys.exit(1)
PY
)" || skip "$feed_url has no full archive"
case "$dmg_url" in https://*) ;; *) skip "the feed's archive is not https: $dmg_url" ;; esac

curl -fsSL --retry 3 --max-time 600 -A "cmux-cef-reuse/1" -o "$work/app.dmg" "$dmg_url" ||
  skip "could not download $dmg_url"
mkdir "$mnt"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$work/app.dmg" ||
  skip "could not attach $dmg_url"
attached=1
framework=""
for candidate in "$mnt"/*.app/Contents/Frameworks/"Chromium Embedded Framework.framework"; do
  if [[ -d "$candidate" ]]; then framework="$candidate"; break; fi
done
[[ -n "$framework" ]] || skip "$dmg_url has no Chromium Embedded Framework.framework"
# Copied aside and moved into place, so <out-dir> never holds half a framework.
ditto "$framework" "$work/copy/Chromium Embedded Framework.framework" || skip "could not copy the framework"
rm -rf "$out"
mv "$work/copy" "$out"
echo "fetched the published Chromium framework of $dmg_url into $out"
