#!/usr/bin/env bash
# Which run's Linux cmux-tui and cmux-tui-hook a commit's cmux-tui/<sha>/ prefix gets, decided by one
# write-once object, so point-machine-channel-early and publish (.github/workflows/cmux-tui-artifacts.yml)
# never wait on each other.
#
# usage: scripts/ci/cmux-machine-linux-claim.sh early|publish ASSETS
#
# The claim is cmux-tui-machine-claims/<sha> in R2, written write-once with "<run id> <unix time>". Each
# run tries to write it before it uploads any Linux binary of the commit; the run whose write lands (or a
# later attempt of that run) owns the Linux bytes:
#   early    exit 0 when this run owns the claim (upload and point), 3 when another run does (skip; that
#            run's publish and point-machine-channel move the channel).
#   publish  before "Build manifest and checksums": when another run owns the claim, wait for its four
#            binaries (it uploads them right after claiming, within the early job's 10 minute timeout)
#            and put the served bytes in ASSETS, so this run's checksums name them and every upload is
#            identical. When this run owns it, a binary the prefix already serves (an earlier attempt's
#            early upload, then "Re-run all jobs" rebuilt it) replaces the rebuilt one the same way.
# Without the claim, a second publisher could claim the prefix between the early job's check and its
# upload, and both runs would wait for a manifest neither can write.
#
# Reads R2_ENDPOINT, AWS_* (R2 credentials), GITHUB_SHA and GITHUB_RUN_ID.
set -euo pipefail
mode=$1 assets=$2
TARGETS=(x86_64-unknown-linux-musl aarch64-unknown-linux-musl)
NAMES=(cmux-tui cmux-tui-hook)
# The early job's timeout (10 min) and a margin: after this, no early upload of the claim's run is in flight.
WAIT_LIMIT=${CMUX_MACHINE_CLAIM_WAIT_SECONDS:-720}
r2() { python3 scripts/ci/upload-r2-object.py --endpoint-url "$R2_ENDPOINT" --bucket cmux-binaries "$@"; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Prints the claim's run id and time; claims it for this run first when nobody has.
claim() {
  printf '%s %s\n' "$GITHUB_RUN_ID" "$(date +%s)" >"$tmp/claim"
  local rc=0
  r2 --write-once --conflict-exit-code 75 --file "$tmp/claim" --key "cmux-tui-machine-claims/$GITHUB_SHA" \
    --cache-control "no-store" --content-type text/plain >&2 || rc=$?
  if [[ $rc == 75 ]]; then
    r2 --key "cmux-tui-machine-claims/$GITHUB_SHA" --download-to "$tmp/claim" >&2
  elif [[ $rc != 0 ]]; then
    exit "$rc"
  fi
  read -r run at <"$tmp/claim"
  [[ "$run" =~ ^[0-9]+$ && "$at" =~ ^[0-9]+$ ]] || { echo "unreadable claim: $(head -c 80 "$tmp/claim")" >&2; exit 1; }
  echo "$run $at"
}

# Copies the served bytes of FILE over ASSETS/FILE (and its -gnu copy); 1 when the prefix has no FILE.
keep_served() {
  local file=$1 name=$2 target=$3 rc=0
  r2 --key "cmux-tui/$GITHUB_SHA/$file" --download-to "$tmp/$file" >/dev/null 2>&1 || rc=$?
  [[ $rc == 0 ]] || return 1
  if ! cmp -s "$tmp/$file" "$assets/$file"; then
    echo "::notice title=machine channel bytes kept::$file: keeping the bytes cmux-tui/${GITHUB_SHA:0:12}/ already serves"
    install -m 755 "$tmp/$file" "$assets/$file"
    local gnu="$assets/$name-${target%-musl}-gnu"
    [[ -f "$gnu" ]] && install -m 755 "$tmp/$file" "$gnu"
  fi
  rm -f "$tmp/$file"
}

claimed="$(claim)"
read -r owner at <<<"$claimed"
case "$mode" in
  early)
    [[ "$owner" == "$GITHUB_RUN_ID" ]] && exit 0
    echo "::notice title=machine channel waits for publish::run $owner claimed the Linux binaries of ${GITHUB_SHA:0:12}; point-machine-channel moves the channel after publish"
    exit 3
    ;;
  publish)
    for target in "${TARGETS[@]}"; do
      for name in "${NAMES[@]}"; do
        file="$name-$target"
        [[ -f "$assets/$file" ]] || continue
        until keep_served "$file" "$name" "$target"; do
          # This run's own claim: nothing else uploads it; another run's: it does, unless its early job ended.
          [[ "$owner" != "$GITHUB_RUN_ID" ]] && (( $(date +%s) - at < WAIT_LIMIT )) || break
          echo "Waiting for run $owner's $file in cmux-tui/${GITHUB_SHA:0:12}/."
          sleep 15
        done
      done
    done
    ;;
  *)
    echo "usage: $0 early|publish ASSETS" >&2
    exit 2
    ;;
esac
