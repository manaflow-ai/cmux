#!/usr/bin/env bash
# nightly.yml nightly-next feed writers (publish-nightly, publish-release-notes,
# publish-nightly-identity-legacy): take or release the R2 lease that keeps one
# writer at a time across runs.
#
#   publish-lease.sh lock     waits up to LEASE_WAIT seconds for LEASE_KEY, then
#                             starts a heartbeat that renews it every LEASE_RENEW
#                             seconds (for at most LEASE_MAX_HOLD seconds)
#   publish-lease.sh unlock   stops the heartbeat and releases the lease (only
#                             while LEASE_OWNER holds it)
#
# The TTL is short (LEASE_TTL, on R2's clock): a holder that dies without its
# release step (a lost runner) blocks the next writer for one TTL, not a whole
# job timeout, because its heartbeat dies with it. The runner's job-end orphan
# cleanup ends the heartbeat (it carries the job's RUNNER_TRACKING_ID); the
# heartbeat also stops on its own when the job's Runner.Worker exits or after
# LEASE_MAX_HOLD seconds, so a runner that loses its job cannot keep it alive.
#
# A shared concurrency group did this before, but GitHub keeps one pending job
# per group and cancels the older pending one: run 41436891188's publish, which
# carried a fix, was cancelled for a newer run's. The lease never cancels a
# waiter; each job's own order checks (newest wins, refuse a build the feed has
# or passed) still decide what publishes, and run inside the lease.
#
# Reads LEASE_KEY, LEASE_OWNER, LEASE_TTL, LEASE_WAIT, LEASE_RENEW, LEASE_MAX_HOLD,
# NIGHTLY_NEXT_R2_BUCKET, RUNNER_TEMP and r2_cas.py's R2 credentials
# (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, R2_ENDPOINT).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LEASE_KEY:?}" "${LEASE_OWNER:?}" "${NIGHTLY_NEXT_R2_BUCKET:?}"
export R2_BUCKET="$NIGHTLY_NEXT_R2_BUCKET"
# The lease lives beside the track's own objects, never in main's bucket or prefixes.
NIGHTLY_NEXT_R2_PREFIX=nightly-next/ python3 "$here/nightly-next-guard.py" r2-key "$R2_BUCKET" "$LEASE_KEY"
# One heartbeat per key and owner; the lock and release steps of a job find the same file.
pid_file="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/publish-lease-$(basename "$LEASE_KEY" .json)-${LEASE_OWNER}.pid"
case "${1:-}" in
  lock)
    : "${LEASE_TTL:?}" "${LEASE_WAIT:?}" "${LEASE_RENEW:?}" "${LEASE_MAX_HOLD:?}"
    echo "Waiting up to ${LEASE_WAIT}s for $LEASE_KEY as $LEASE_OWNER"
    if ! python3 "$here/r2_cas.py" lock --key "$LEASE_KEY" --owner "$LEASE_OWNER" --ttl "$LEASE_TTL" --wait "$LEASE_WAIT" \
        --renew-every "$LEASE_RENEW" --max-hold "$LEASE_MAX_HOLD" --pid-file "$pid_file"; then
      echo "::error title=Publish lease::another nightly-next writer held $LEASE_KEY for ${LEASE_WAIT}s"
      exit 1
    fi
    echo "Holding $LEASE_KEY as $LEASE_OWNER (TTL ${LEASE_TTL}s, renewed every ${LEASE_RENEW}s by PID $(cat "$pid_file"))"
    ;;
  unlock)
    # Two tries; a lease left behind expires LEASE_TTL after its last renewal on
    # R2's clock, so a failed release only delays the next writer and never
    # fails a publication.
    status=0
    for _ in 1 2; do
      status=0
      python3 "$here/r2_cas.py" unlock --key "$LEASE_KEY" --owner "$LEASE_OWNER" --pid-file "$pid_file" || status=$?
      case "$status" in
        0) echo "Released $LEASE_KEY"; break ;;
        4) echo "Nothing to release: $LEASE_KEY is not held by $LEASE_OWNER (never taken, already released, or expired and taken)"; break ;;
      esac
      sleep 5
    done
    if [ -f "${pid_file%.pid}.log" ]; then
      echo "Heartbeat log:"
      tail -n 20 "${pid_file%.pid}.log"
    fi
    if [ "$status" = 0 ] || [ "$status" = 4 ]; then
      exit 0
    fi
    echo "::warning title=Publish lease::could not release $LEASE_KEY; it expires on its own"
    ;;
  *)
    echo "usage: publish-lease.sh lock|unlock" >&2
    exit 2
    ;;
esac
