#!/usr/bin/env bash
# The cmux NEXT feed keeps its newest Nightly item beside a new build (nightly.yml publish-nightly
# "Keep the live feed's newest Nightly item beside the new build", and republish-nightly-deltas
# before it revises the feed). The new build's feed alone drops every earlier item, so a
# Nightly-ring app (cmux-next only) is offered nothing while the new build waits on Dev for its
# verdict, and a later pass on that build can never promote it here. Combined as the old feed is
# (nightly_next_ring.py legacy): the new build, the newest cmux-next item, the cmux-next item before
# it and at most five Dev items above it, each tagged from its verdict. With the ring off every item
# is cmux-next: the new build and the one before it, so a launch crash still has a build to roll
# back to.
#
# A live feed that cannot be read stops the publication: going on without it would replace the
# feed with the new build alone and drop the Nightly item for good. Only a 404 (no feed yet)
# starts from the new build's items.
#
# usage: publish-next-feed-keep-nightly.sh FEED... (each read live at $CHANNEL_FEED_BASE/<name>)
# env: DEV_RING (on|off), CHANNEL_FEED_BASE, NIGHTLY_NEXT_VERDICTS_BASE (the verdicts), GITHUB_RUN_ID
set -euo pipefail
mode="${DEV_RING:?}"
case "$mode" in on|off) ;; *) echo "::error::DEV_RING must be on or off, not '$mode'"; exit 1 ;; esac
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
      # Well-formedness only, without namespace processing: a live feed with an unbound cmux:
      # prefix (2026-11-01) is still read here, and the R2 writer declares it on the root.
      if python3 -I -c 'import sys, xml.parsers.expat as X; p = X.ParserCreate(); n = []; p.StartElementHandler = lambda name, attrs: n.append(name == "item"); p.ParseFile(open(sys.argv[1], "rb")); sys.exit(0 if any(n) else 1)' "$live" 2>/dev/null; then
        current=(--current "$live")
      else
        code="answered 200 with no appcast items"
      fi ;;
    404) echo "::notice::no live $name yet; publishing the new build's items alone" ;;
  esac
  if [ "$code" != 200 ] && [ "$code" != 404 ]; then
    # With the ring off the new build is itself the Nightly item: an unreadable feed costs only
    # the earlier build a rollback would serve, so the publication goes on.
    if [ "$mode" = off ]; then
      echo "::warning title=nightly-next feed::could not read the live $name ($code); publishing the new build without the earlier one to roll back to"
    else
      echo "::error title=nightly-next feed::could not read the live $name ($code); publishing it now would drop its Nightly item"
      exit 1
    fi
  fi
  python3 "$ring" legacy --new "$feed" ${current[@]+"${current[@]}"} --out "$feed" --mode "$mode" \
    --verdicts-base "${NIGHTLY_NEXT_VERDICTS_BASE:?}"
done
