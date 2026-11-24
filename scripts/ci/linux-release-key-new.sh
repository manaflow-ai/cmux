#!/usr/bin/env bash
# Create the dedicated Linux release key (cmuxterm-hq docs/design/linux-signed-packages.md section 3,
# decision d-b0cab51bbc) and store its private half only as the CMUX_LINUX_RELEASE_SIGNING_KEY secret of
# the artifacts environment. Run once by someone who can set that secret (a repo admin); the private
# key is written to a mode-700 temp dir, piped to `gh secret set`, and deleted. Nothing else keeps it.
#
# Prints the public half as the two lines the rotation adds (web-update-keys.json and channel.rs KEYS;
# the installers are generated from web-update-keys.json). Order is free: CI signs with the new key only
# once web-update-keys.json lists it (web-ota-pointer.py sign --extra-key skips an unlisted one), and
# verifiers take any one listed signature, so Linux release files carry both through the overlap.
#
# usage: scripts/ci/linux-release-key-new.sh [--set-secret] [--repo OWNER/REPO]
#   without --set-secret: print the public half and discard the private one (a dry run)
set -euo pipefail
set_secret="" repo=manaflow-ai/cmux
while [[ $# -gt 0 ]]; do
  case "$1" in
    --set-secret) set_secret=1 ;;
    --repo) repo=$2; shift ;;
    *) echo "unknown option $1; next: scripts/ci/linux-release-key-new.sh [--set-secret] [--repo OWNER/REPO]" >&2; exit 2 ;;
  esac
  shift
done
dir="$(mktemp -d)"; chmod 700 "$dir"
trap 'rm -rf "$dir"' EXIT
openssl genpkey -algorithm ed25519 -out "$dir/key.pem" 2>/dev/null
raw_b64="$(openssl pkey -in "$dir/key.pem" -pubout -outform DER | tail -c 32 | base64)"
key_id="$(printf '%s' "$raw_b64" | base64 -d | sha256sum | cut -c1-16)"
if [[ -n "$set_secret" ]]; then
  gh secret set CMUX_LINUX_RELEASE_SIGNING_KEY --env artifacts --repo "$repo" < "$dir/key.pem"
  echo "CMUX_LINUX_RELEASE_SIGNING_KEY set in $repo (environment artifacts)."
else
  echo "dry run: the private key is discarded; add --set-secret to store it."
fi
cat <<OUT
Add to Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json "keys":
  {"id": "$key_id", "ed25519": "$raw_b64", "added": "$(date -u +%F)"}
Add to cmux-tui/crates/cmux-host/src/updater/channel.rs KEYS:
  ("$key_id", "$raw_b64"),
OUT
