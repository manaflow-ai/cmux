#!/usr/bin/env bash
# Sign this run's own Linux build as cmux-tui/<sha>/release.json (cmuxterm-hq
# docs/design/linux-signed-packages.md), with its .deb and .rpm named in it.
#
# usage: scripts/ci/linux-release-sign.sh DIR CHANNEL [--commit-only]
#
# CHANNEL is the payload's channel, feat-cmux-next for every per-commit file (a file is written once and
# verified for its signer's channel). point-machine-channel (a feat-cmux-next push) also moves
# cmux-tui/channels/linux-feat-cmux-next.json. sign-nightly-linux-release (every built feat-cmux-next and
# nightly-next push) passes --commit-only and writes the commit's file alone: the NIGHTLY app ships
# feat-cmux-next commits, and cmux-linux-nightly-follow.sh re-signs linux-nightly.json from that commit's
# release.json. Before this, only point-machine-channel signed one, and a feat push's pending point is
# replaced by a newer one, so the NIGHTLY's commit had none and linux-nightly stayed on 0a6830e6 from
# 2026-11-26 08:46Z.
#
# A commit whose release.json is already published (sign-nightly-linux-release ran first) is not built or
# packaged again: point-machine-channel moves the channel from that file's verified payload, and
# cmux-machine-channel-point.sh keeps its bytes (same build). A second package build could differ by a
# byte and be refused, and the channel would not move.
#
# A bucket writer controls every byte in the bucket, the manifest included, and publish adopts (and
# attests) whatever Linux bytes the prefix already serves, so this signs only bytes equal to this run's
# own build artifacts (GitHub's artifact store, --binaries-dir). Bytes another run uploaded first are not
# signed by this one.
#
# PUBLISH_TREE=success with TREE_KEY (the run that published tree/<key>/) signs the tree's release.json
# too: the payload names the tree's copies and carries tree_key. A tree another run published first
# (other bytes) is refused, and this run signs its own commit's files as before.
#
# Reads GITHUB_SHA, GITHUB_RUN_ID, GITHUB_REPOSITORY, GH_TOKEN, SIGNING_KEY, LINUX_RELEASE_SIGNING_KEY,
# R2_ENDPOINT and the R2 credentials (AWS_*).
set -euo pipefail
lr=$1 channel=$2 mode=${3:-}
case "$mode" in
  "" | --commit-only) ;;
  *) echo "linux-release-sign.sh: unknown option $mode" >&2; exit 2 ;;
esac
keys=Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json
mkdir -p "$lr" && chmod 700 "$lr"
code="$(curl -sS -o "$lr/published.json" -w '%{http_code}' --max-time 60 \
  "https://files.cmux.com/cmux-tui/$GITHUB_SHA/release.json?sign=$GITHUB_RUN_ID" || true)"
if [[ "$code" == 200 ]] && python3 scripts/cmux-next/web-ota-pointer.py verify --pointer "$lr/published.json" \
    --keys "$keys" --purpose cmux-linux-release --channel "$channel" --allow-expired >"$lr/payload.json"; then
  echo "cmux-tui/$GITHUB_SHA/release.json is published; keeping it"
  [[ "$mode" == --commit-only ]] && exit 0
  exec scripts/ci/cmux-machine-channel-point.sh "$lr/payload.json" "$lr"
fi
rm -f "$lr/payload.json"
# The workflow step downloads them first with actions/download-artifact (LINUX_RELEASE_ARTIFACTS), which
# reads the run's artifact store over the runner's own token. gh run download spends the repo
# installation's REST budget: run 45994285415 (80d30ecb, 2026-11-27 12:28Z) got HTTP 403 "API rate limit
# exceeded for installation", this file was never signed, and linux-nightly stayed on 0a6830e6. gh is the
# fallback for a caller without that step, retried past a 403 or a dropped connection.
if [[ -n "${LINUX_RELEASE_ARTIFACTS:-}" ]] && find "$LINUX_RELEASE_ARTIFACTS" -type f -print -quit 2>/dev/null | grep -q .; then
  artifacts=$LINUX_RELEASE_ARTIFACTS
else
  artifacts="$lr/artifacts"
  for attempt in 1 2 3 4; do
    rm -rf "$artifacts"
    gh run download "$GITHUB_RUN_ID" --repo "$GITHUB_REPOSITORY" \
      --pattern "cmux-tui-*-unknown-linux-musl" --dir "$artifacts" && break
    [[ $attempt == 4 ]] && exit 1
    echo "gh run download failed (attempt $attempt); retrying in $((attempt * 60))s" >&2
    sleep "$((attempt * 60))"
  done
fi
mkdir -p "$lr/built" && find "$artifacts" -type f -exec mv -t "$lr/built" {} +
# sequence orders the channel (installers refuse a lower one than they installed): above the published
# pointer's, which a missing or unverifiable pointer leaves at 0.
curl -sS --max-time 60 -o "$lr/current.json" \
  "https://files.cmux.com/cmux-tui/channels/linux-$channel.json?sequence=$GITHUB_RUN_ID" || true
current="$(python3 scripts/cmux-next/web-ota-pointer.py sequence --pointer "$lr/current.json" \
  --keys "$keys" --channel "$channel")"
release=(python3 scripts/ci/cmux-machine-channel.py payload --purpose linux-release
  --channel "$channel" --binaries-dir "$lr/built" --commit "$GITHUB_SHA"
  --committed-at "$(git show -s --format=%ct HEAD)" --min-sequence "$((current + 1))"
  --download-dir "$lr/binaries" --out "$lr/payload.json")
tree=""
if [[ "${PUBLISH_TREE:-}" == success && "${TREE_KEY:-}" =~ ^[0-9a-f]{40}$ ]]; then
  if "${release[@]}" --tree-key "$TREE_KEY"; then
    tree=1
  else
    echo "::warning::tree $TREE_KEY does not serve this run's build; signing $GITHUB_SHA's own files"
  fi
fi
[[ -n "$tree" ]] || "${release[@]}"
rm -rf "$lr/binaries"
# The .deb and .rpm of these binaries, uploaded and named in the payload before it is signed (the file
# is written once, so only its first signing can name them). No archive key needed: the signed release
# file vouches for them. Delivery, not a gate: a failure signs the file without packages.
bash scripts/ci/timeout.sh 600 scripts/ci/linux-packages.sh "$lr/payload.json" "$lr/built" "$lr/packages" ||
  echo "::warning::the .deb and .rpm of $GITHUB_SHA were not built; its release file names none"
scripts/ci/cmux-machine-channel-point.sh "$lr/payload.json" "$lr" $mode
