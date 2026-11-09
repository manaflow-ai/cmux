#!/usr/bin/env bash
# Settle which bytes a commit's Linux cmux-tui and cmux-tui-hook have in cmux-tui/<sha>/, before
# anything names them. Used by point-machine-channel-early and publish
# (.github/workflows/cmux-tui-artifacts.yml), which can both upload them, from different runs or
# attempts of one commit.
#
# usage: scripts/ci/cmux-machine-linux-bytes.sh early|publish ASSETS
#
# Each of the four objects is write-once, so the first upload of it wins; there is nothing else to
# claim or wait for. For each one ASSETS holds:
#   early    upload one of them (the x86_64 cmux-tui-hook) alone: it is the claim. Exit 3 when it holds
#            other bytes (another run or attempt got there first: skip, and point-machine-channel
#            moves the channel after publish), before any other upload. Only an attempt that holds
#            the claim (it wrote it, or it already held these same bytes) uploads the other three,
#            all at once (one after another the four took 58 s of the 1.5 min job, run
#            42654596743: one upload streams at 7-9 MB/s). So two early jobs never mix, as with the
#            old one-after-another order: a loser of the claim uploads nothing. A conflict on one
#            of the other three still exits 3, and any other failure fails the job.
#   publish  upload it; when it holds other bytes, read them back and put them in ASSETS (and its
#            -gnu copy), so "Build manifest and checksums" names the bytes the prefix serves and
#            every later upload is identical. A read that fails stops the job before any checksums
#            or manifest are written: only bytes read whole from R2 replace this run's.
#
# Reads R2_ENDPOINT, AWS_* (R2 credentials) and GITHUB_SHA.
set -euo pipefail
mode=$1 assets=$2
[[ "$mode" == early || "$mode" == publish ]] || { echo "usage: $0 early|publish ASSETS" >&2; exit 2; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
r2() { python3 scripts/ci/upload-r2-object.py --endpoint-url "$R2_ENDPOINT" --bucket cmux-binaries "$@"; }

if [[ "$mode" == early ]]; then
  # The claim comes first: the x86_64 hook, the smallest of the four (4.9 MB against 158-178 MB),
  # so the other three start a few seconds in.
  files=()
  for file in cmux-tui-hook-x86_64-unknown-linux-musl cmux-tui-x86_64-unknown-linux-musl \
    cmux-tui-hook-aarch64-unknown-linux-musl cmux-tui-aarch64-unknown-linux-musl; do
    if [[ -f "$assets/$file" ]]; then files+=("$file"); fi
  done
  if ((${#files[@]} == 0)); then exit 0; fi
  up() { r2 --write-once --conflict-exit-code 75 --file "$assets/$1" --key "cmux-tui/$GITHUB_SHA/$1" \
    --cache-control "public, max-age=31536000, immutable"; }
  skip() {
    echo "::notice title=machine channel waits for publish::cmux-tui/$GITHUB_SHA/$1 holds another build's bytes; point-machine-channel moves the channel after publish"
    exit 3
  }
  # The claim, alone. Losing it ends the job before any other upload, as the old order did.
  rc=0
  up "${files[0]}" || rc=$?
  if [[ $rc == 75 ]]; then skip "${files[0]}"; fi
  [[ $rc == 0 ]] || exit "$rc"
  # This attempt holds the claim: the other three at once.
  pids=()
  for file in "${files[@]:1}"; do
    up "$file" &
    pids+=("$!")
  done
  conflict="" failed=0
  for i in "${!pids[@]}"; do
    rc=0
    wait "${pids[i]}" || rc=$?
    if [[ $rc == 75 ]]; then
      conflict="${files[i + 1]}"
    elif [[ $rc != 0 ]]; then
      echo "::error::uploading ${files[i + 1]} failed (exit $rc)"
      failed=$rc
    fi
  done
  [[ $failed == 0 ]] || exit "$failed"
  if [[ -n "$conflict" ]]; then skip "$conflict"; fi
  exit 0
fi

for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
  for name in cmux-tui cmux-tui-hook; do
    file="$name-$target"
    [[ -f "$assets/$file" ]] || continue
    key="cmux-tui/$GITHUB_SHA/$file"
    rc=0
    r2 --write-once --conflict-exit-code 75 --file "$assets/$file" --key "$key" \
      --cache-control "public, max-age=31536000, immutable" || rc=$?
    [[ $rc == 0 ]] && continue
    [[ $rc == 75 ]] || exit "$rc"
    rc=0
    r2 --key "$key" --download-to "$tmp/$file" || rc=$?
    if [[ $rc != 0 || ! -s "$tmp/$file" ]]; then
      echo "::error title=machine channel bytes unread::$key holds other bytes and could not be read (exit $rc); re-run publish"
      exit 1
    fi
    echo "::notice title=machine channel bytes kept::$file: keeping the bytes $key already serves"
    install -m 755 "$tmp/$file" "$assets/$file"
    gnu="$assets/$name-${target%-musl}-gnu"
    [[ -f "$gnu" ]] && install -m 755 "$tmp/$file" "$gnu"
    rm -f "$tmp/$file"
  done
done
