# shellcheck shell=bash
# Sourced. Network reads of a git remote that tell "the remote did not answer" from "the remote
# answered, and it has no such ref".
#
# A nightly input runner lost github.com for about 20 s (run 43113697713, 2026-11-11): its
# `git ls-remote ... || true` read the failure as an empty answer, so the notices step reported
# the remote browser host's source tag as missing (it was on origin) and the nightly published
# nothing. scripts/cmux-next/tests/origin-net.test.sh checks these helpers and lints every script
# for a remote read that swallows its own failure.
#
# ORIGIN_NET_TRIES (default 4) attempts, ORIGIN_NET_SLEEP_S (default 3) times the attempt number
# squared between them: 3, 12, 27 s, so a minute-long outage still answers.

# net_retry WHAT COMMAND...: runs COMMAND until it succeeds, ORIGIN_NET_TRIES times; its output is
# the last attempt's. Fails naming WHAT and the network when no attempt succeeds.
net_retry() {
  local what="$1" tries="${ORIGIN_NET_TRIES:-4}" pause="${ORIGIN_NET_SLEEP_S:-3}" attempt status=0
  shift
  for ((attempt = 1; attempt <= tries; attempt++)); do
    if "$@"; then return 0; else status=$?; fi
    if ((attempt < tries)); then
      echo "warn: $what failed (exit $status, try $attempt of $tries); trying again" >&2
      sleep "$((pause * attempt * attempt))"
    fi
  done
  echo "error: $what failed $tries times (last exit $status): the remote did not answer, which is the network or the host, not a missing ref" >&2
  return "$status"
}

# remote_refs DIR REMOTE REF...: `git ls-remote REMOTE REF...` from DIR, retried. Prints the refs
# that exist (nothing when none do) and succeeds only when the remote answered.
remote_refs() {
  local dir="$1" remote="$2"
  shift 2
  net_retry "git ls-remote $remote $*" git -C "$dir" ls-remote "$remote" "$@"
}
