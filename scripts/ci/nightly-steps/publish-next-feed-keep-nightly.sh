#!/usr/bin/env bash
# The cmux NEXT feed keeps its newest Nightly item beside a new build (nightly.yml publish-nightly
# "Keep the live feed's newest Nightly item beside the new build", and republish-nightly-deltas
# before it revises the feed). The new build's feed alone drops every earlier item, so a
# Nightly-ring app (cmux-next only) is offered nothing while the new build waits on Dev for its
# verdict, and a later pass on that build can never promote it here. Combined as the old feed is
# (nightly_next_ring.py legacy): the new build, the newest cmux-next item and at most five Dev items
# above it, each tagged from its verdict. With the ring off every item is cmux-next and the feed
# is left as it is.
#
# A live feed that cannot be read stops the publication: going on without it would replace the
# feed with the new build alone and drop the Nightly item for good. Only a 404 (no feed yet)
# starts from the new build's items.
#
# usage: publish-next-feed-keep-nightly.sh FEED... (each read live at $CHANNEL_FEED_BASE/<name>)
# env: DEV_RING (on|off), CHANNEL_FEED_BASE, NIGHTLY_NEXT_FEED_BASE (the verdicts), GITHUB_RUN_ID
set -euo pipefail
[ "${DEV_RING:?}" = on ] || { echo "Dev ring off: every item is cmux-next; nothing to keep"; exit 0; }
ring="$(cd "$(dirname "$0")/.." && pwd)/nightly_next_ring.py"
for feed in "$@"; do
  [ -f "$feed" ] || continue
  name="$(basename "$feed")"
  live="${RUNNER_TEMP:-/tmp}/keep-live-$name"
  # A transfer that fails (curl exits nonzero) counts as unreadable whatever status it saw: a
  # truncated 200 body would otherwise merge as a feed without its Nightly item.
  status=0
  code="$(curl -sSL --retry 3 --retry-all-errors -A "cmux-nightly-next-feed/1" -H "Cache-Control: no-cache" \
    -o "$live" -w '%{http_code}' "${CHANNEL_FEED_BASE:?}/${name}?keep=${GITHUB_RUN_ID:-0}")" || status=$?
  if [ "$status" != 0 ] && [ "$code" != 404 ]; then code="curl exit $status, HTTP ${code:-000}"; fi
  current=()
  case "$code" in
    200)
      # A 200 that is not an appcast with items (an empty body or an error page) is unreadable too.
      if ! python3 -I -c 'import sys, xml.etree.ElementTree as E; sys.exit(0 if any(True for _ in E.parse(sys.argv[1]).getroot().iter("item")) else 1)' "$live" 2>/dev/null; then
        echo "::error title=nightly-next feed::the live $name answered 200 with no appcast items; publishing it now would drop its Nightly item"
        exit 1
      fi
      current=(--current "$live") ;;
    404) echo "::notice::no live $name yet; publishing the new build's items alone" ;;
    *) echo "::error title=nightly-next feed::could not read the live $name (HTTP $code); publishing it now would drop its Nightly item"; exit 1 ;;
  esac
  python3 "$ring" legacy --new "$feed" ${current[@]+"${current[@]}"} --out "$feed" --mode on \
    --verdicts-base "${NIGHTLY_NEXT_FEED_BASE:?}"
done
