#!/usr/bin/env bash
# Shared retry loop for the CDN-backed Gatekeeper assessment.
#
# A notarization ticket can be Accepted before Gatekeeper's CDN knows about it.
# Callers set SPCTL_TOOL and may override the propagation budget through the
# CMUX_GATEKEEPER_ASSESS_* environment variables.

GATEKEEPER_ASSESS_ATTEMPTS="${GATEKEEPER_ASSESS_ATTEMPTS:-${CMUX_GATEKEEPER_ASSESS_ATTEMPTS:-80}}"
GATEKEEPER_ASSESS_DELAY_SECONDS="${GATEKEEPER_ASSESS_DELAY_SECONDS:-${CMUX_GATEKEEPER_ASSESS_DELAY_SECONDS:-15}}"

assess_with_gatekeeper() {
  local target="$1" attempt=1
  while :; do
    if "${SPCTL_TOOL:-spctl}" -a -vv --ignore-cache --no-cache --type execute "$target"; then
      return 0
    fi
    if [ "$attempt" -eq 1 ]; then
      echo "Gatekeeper propagation budget: $GATEKEEPER_ASSESS_ATTEMPTS attempts x ${GATEKEEPER_ASSESS_DELAY_SECONDS}s (about $((GATEKEEPER_ASSESS_ATTEMPTS * GATEKEEPER_ASSESS_DELAY_SECONDS / 60)) minutes)"
    fi
    if [ "$attempt" -ge "$GATEKEEPER_ASSESS_ATTEMPTS" ]; then
      echo "Gatekeeper still rejects $target after $attempt attempts" >&2
      return 3
    fi
    echo "Gatekeeper rejected $target (attempt $attempt/$GATEKEEPER_ASSESS_ATTEMPTS); ticket may not have propagated yet, retrying in ${GATEKEEPER_ASSESS_DELAY_SECONDS}s"
    attempt=$((attempt + 1))
    sleep "$GATEKEEPER_ASSESS_DELAY_SECONDS"
  done
}
