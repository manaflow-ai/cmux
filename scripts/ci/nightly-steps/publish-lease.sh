#!/usr/bin/env bash
# nightly.yml nightly-next feed writers (publish-nightly, publish-release-notes,
# publish-nightly-identity-legacy): take or release the R2 lease that keeps one
# writer at a time across runs.
#
#   publish-lease.sh lock     waits up to LEASE_WAIT seconds for LEASE_KEY
#   publish-lease.sh unlock   releases it (only while LEASE_OWNER holds it)
#
# A shared concurrency group did this before, but GitHub keeps one pending job
# per group and cancels the older pending one: run 41436891188's publish, which
# carried a fix, was cancelled for a newer run's. The lease never cancels a
# waiter; each job's own order checks (newest wins, refuse a build the feed has
# or passed) still decide what publishes, and run inside the lease.
#
# Reads LEASE_KEY, LEASE_OWNER, LEASE_TTL, LEASE_WAIT, NIGHTLY_NEXT_R2_BUCKET and
# r2_cas.py's R2 credentials (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, R2_ENDPOINT).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LEASE_KEY:?}" "${LEASE_OWNER:?}" "${NIGHTLY_NEXT_R2_BUCKET:?}"
export R2_BUCKET="$NIGHTLY_NEXT_R2_BUCKET"
# The lease lives beside the track's own objects, never in main's bucket or prefixes.
NIGHTLY_NEXT_R2_PREFIX=nightly-next/ python3 "$here/nightly-next-guard.py" r2-key "$R2_BUCKET" "$LEASE_KEY"
case "${1:-}" in
  lock)
    : "${LEASE_TTL:?}" "${LEASE_WAIT:?}"
    echo "Waiting up to ${LEASE_WAIT}s for $LEASE_KEY as $LEASE_OWNER"
    if ! python3 "$here/r2_cas.py" lock --key "$LEASE_KEY" --owner "$LEASE_OWNER" --ttl "$LEASE_TTL" --wait "$LEASE_WAIT"; then
      echo "::error title=Publish lease::another nightly-next writer held $LEASE_KEY for ${LEASE_WAIT}s"
      exit 1
    fi
    echo "Holding $LEASE_KEY as $LEASE_OWNER"
    ;;
  unlock)
    # Two tries; a lease left behind expires after LEASE_TTL on R2's clock, so a
    # failed release only delays the next writer and never fails a publication.
    for _ in 1 2; do
      if python3 "$here/r2_cas.py" unlock --key "$LEASE_KEY" --owner "$LEASE_OWNER"; then
        echo "Released $LEASE_KEY"
        exit 0
      fi
      sleep 5
    done
    echo "::warning title=Publish lease::could not release $LEASE_KEY; it expires on its own"
    ;;
  *)
    echo "usage: publish-lease.sh lock|unlock" >&2
    exit 2
    ;;
esac
