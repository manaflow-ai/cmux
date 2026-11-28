#!/usr/bin/env bash
# stable-next.yml publish: the tested cmux NEXT Stable DMG to R2, then the stable feed.
#
# The DMG goes up write-once (publish-nightly-next-r2.py upload, its key checked by
# nightly-next-guard.py r2-key under the stable prefix). The feed is the new item (tagged
# cmux-next-stable) plus the live feed's two newest earlier builds (stable_next.py merge-feed),
# checked by nightly-next-guard.py appcast, and written only while the live feed still has the
# bytes the merge read (stable_next.py write-feed). The public feed is read back last.
#
# Environment: DMG_NAME, BUILD, STABLE_APPCAST, NIGHTLY_NEXT_R2_BUCKET, NIGHTLY_NEXT_R2_PREFIX
# (nightly-next/stable/), NIGHTLY_NEXT_FEED_BASE (the stable base), R2_ENDPOINT, AWS_* (the
# nightly-next R2 token).
set -euo pipefail
: "${DMG_NAME:?}" "${BUILD:?}" "${STABLE_APPCAST:?}" "${NIGHTLY_NEXT_R2_PREFIX:?}" "${NIGHTLY_NEXT_FEED_BASE:?}"
[ "$NIGHTLY_NEXT_R2_PREFIX" = nightly-next/stable/ ] || { echo "refusing prefix $NIGHTLY_NEXT_R2_PREFIX" >&2; exit 1; }
[ -s "stable-signed/$STABLE_APPCAST" ] || { echo "no signed Sparkle item" >&2; exit 1; }

python3 -I scripts/ci/publish-nightly-next-r2.py upload --file "stable-signed/$DMG_NAME"

work="$(mktemp -d)"
python3 -I - "$NIGHTLY_NEXT_R2_PREFIX$STABLE_APPCAST" "$work/live.xml" "$work/live.sha256" <<'PY'
import hashlib, importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("r2", "scripts/ci/publish-nightly-next-r2.py")
r2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r2)
live = r2.read_live(sys.argv[1])
Path(sys.argv[2]).write_bytes(live or b"")
Path(sys.argv[3]).write_text("absent" if live is None else hashlib.sha256(live).hexdigest())
PY

python3 -I scripts/ci/stable_next.py merge-feed --new "stable-signed/$STABLE_APPCAST" --live "$work/live.xml" \
  --out "$work/$STABLE_APPCAST"
python3 -I scripts/ci/nightly-next-guard.py appcast "$work/$STABLE_APPCAST"
python3 -I scripts/ci/stable_next.py write-feed --feed "$work/$STABLE_APPCAST" --expect-sha256 "$(cat "$work/live.sha256")"

served="$(curl -fsS --retry 5 --retry-all-errors -A cmux-stable-next/1 -H 'Cache-Control: no-cache' \
  "$NIGHTLY_NEXT_FEED_BASE/$STABLE_APPCAST?build=$BUILD" | grep -o -E '<sparkle:version>[0-9]+' | head -1 | sed 's/.*>//')"
[ "$served" = "$BUILD" ] || { echo "the public stable feed serves $served, expected $BUILD" >&2; exit 1; }
echo "cmux NEXT Stable $BUILD is live at $NIGHTLY_NEXT_FEED_BASE/$STABLE_APPCAST"
