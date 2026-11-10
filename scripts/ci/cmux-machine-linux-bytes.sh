#!/usr/bin/env bash
# Settle which bytes a commit's Linux cmux-tui and cmux-tui-hook have in cmux-tui/<sha>/, before
# anything names them. Used by point-machine-channel-early and publish
# (.github/workflows/cmux-tui-artifacts.yml), which can both upload them, from different runs or
# attempts of one commit.
#
# usage: scripts/ci/cmux-machine-linux-bytes.sh early|publish ASSETS
#
# Each of the four objects is write-once, so the first upload of it wins. Publish claims nothing
# and waits for nothing; the early job writes one claim object first (below). For each one ASSETS
# holds:
#   early    first write the commit's claim, cmux-tui/<sha>/early-claim.json, write-once: the
#            sha256 of every binary in ASSETS, as canonical JSON (sorted keys, no times or run ids),
#            so the same four binaries always give the same bytes. When it holds other bytes (another
#            run or attempt with any differing binary got there first), exit 3 before uploading
#            anything: skip, and point-machine-channel moves the channel after publish. When this
#            attempt wrote it or it already holds these bytes, upload the four at once (one after
#            another they took 58 s of the 1.5 min job, run 42654596743: one upload streams at
#            7-9 MB/s). So only attempts with the very same four binaries upload early, and two of
#            those write identical bytes. A conflict on a binary still exits 3; any other failure
#            fails the job. A re-run with the same artifacts holds the claim and fills in missing
#            keys. The claim lives with the binaries, so the bucket prune deletes it with the prefix;
#            nothing lists the prefix or names it, and publish neither reads nor writes it.
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
  files=()
  for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
    for name in cmux-tui cmux-tui-hook; do
      if [[ -f "$assets/$name-$target" ]]; then files+=("$name-$target"); fi
    done
  done
  if ((${#files[@]} == 0)); then exit 0; fi
  skip() {
    echo "::notice title=machine channel waits for publish::cmux-tui/$GITHUB_SHA/$1 holds another build's bytes; point-machine-channel moves the channel after publish"
    exit 3
  }
  # The claim names the whole set: any differing binary gives other bytes.
  python3 -c '
import hashlib, json, os, sys
d, names = sys.argv[1], sys.argv[2:]
def sha(n):
    h = hashlib.sha256()
    with open(os.path.join(d, n), "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
sys.stdout.write(json.dumps({n: sha(n) for n in names}, sort_keys=True, separators=(",", ":")) + "\n")
' "$assets" "${files[@]}" > "$tmp/early-claim.json"
  rc=0
  r2 --write-once --conflict-exit-code 75 --file "$tmp/early-claim.json" --key "cmux-tui/$GITHUB_SHA/early-claim.json" \
    --cache-control "public, max-age=31536000, immutable" || rc=$?
  if [[ $rc == 75 ]]; then skip early-claim.json; fi
  [[ $rc == 0 ]] || exit "$rc"
  pids=()
  for file in "${files[@]}"; do
    r2 --write-once --conflict-exit-code 75 --file "$assets/$file" --key "cmux-tui/$GITHUB_SHA/$file" \
      --cache-control "public, max-age=31536000, immutable" &
    pids+=("$!")
  done
  conflict="" failed=0
  for i in "${!pids[@]}"; do
    rc=0
    wait "${pids[i]}" || rc=$?
    if [[ $rc == 75 ]]; then
      conflict="${files[i]}"
    elif [[ $rc != 0 ]]; then
      echo "::error::uploading ${files[i]} failed (exit $rc)"
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
