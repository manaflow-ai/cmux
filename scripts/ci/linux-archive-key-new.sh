#!/usr/bin/env bash
# Make the OpenPGP archive key of the cmux apt and yum repositories (cmuxterm-hq
# docs/design/linux-signed-packages.md phase 4). Leo, 2026-11-22 (d-fce10e3659 A): create it, "a
# certify-only primary stays out of CI. Only a signing subkey with an expiry sits in the artifacts
# environment."
#
#   scripts/ci/linux-archive-key-new.sh --out DIR [--uid UID] [--expire 2y] [--set-secret] [--repo OWNER/REPO]
#
# DIR (new, mode 700) is the offline half: keep it off every networked machine after this runs.
#   DIR/gnupg/                    the certify-only primary (ed25519, no expiry) and its revocation
#                                 certificate (gnupg/openpgp-revocs.d/); renew or replace the subkey here
#   DIR/ci-signing-subkey.asc     the signing subkey alone (primary stubbed out), what CI imports
#   DIR/signing-subkey.fpr        its fingerprint
#   DIR/cmux-archive-keyring.gpg  the public keyring apt and dnf read (binary; .asc beside it, armored)
# --set-secret stores ci-signing-subkey.asc as CMUX_LINUX_ARCHIVE_SIGNING_KEY in the artifacts
# environment (gh secret set), then deletes the file from DIR. Nothing here is uploaded anywhere else:
# the keyring is published by the workflow from this repository once it is committed (see the end).
set -euo pipefail
out="" uid="cmux archive signing <security@cmux.com>" expire=2y set_secret=0 repo=manaflow-ai/cmux
while (($#)); do
  case "$1" in
    --out) out=$2; shift 2 ;;
    --uid) uid=$2; shift 2 ;;
    --expire) expire=$2; shift 2 ;;
    --set-secret) set_secret=1; shift ;;
    --repo) repo=$2; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "linux-archive-key-new: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ -n "$out" ]] || { echo "linux-archive-key-new: --out DIR is required (the offline half of the key)" >&2; exit 2; }
if [[ -e "$out" ]]; then
  echo "linux-archive-key-new: $out exists; it never overwrites a key" >&2
  exit 1
fi
command -v gpg >/dev/null || { echo "linux-archive-key-new: gpg is required" >&2; exit 1; }
umask 077
mkdir -p "$out/gnupg"
export GNUPGHOME="$out/gnupg"
g() { gpg --batch --quiet --pinentry-mode loopback --passphrase '' "$@"; }
# The primary only certifies: it never signs an index, so it is never needed in CI.
g --quick-gen-key "$uid" ed25519 cert never
primary=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1=="fpr"{print $10; exit}')
[[ "$primary" =~ ^[0-9A-F]{40}$ ]] || { echo "linux-archive-key-new: no primary fingerprint" >&2; exit 1; }
g --quick-add-key "$primary" ed25519 sign "$expire"
subkey=$(gpg --batch --with-colons --list-secret-keys "$primary" | awk -F: '$1=="ssb"{s=1;next} s&&$1=="fpr"{print $10; exit}')
[[ "$subkey" =~ ^[0-9A-F]{40}$ ]] || { echo "linux-archive-key-new: no signing subkey fingerprint" >&2; exit 1; }
printf '%s\n' "$subkey" > "$out/signing-subkey.fpr"
gpg --batch --export "$primary" > "$out/cmux-archive-keyring.gpg"
gpg --batch --armor --export "$primary" > "$out/cmux-archive-keyring.asc"
# `FPR!` exports exactly that subkey; the primary's secret part is replaced by a stub.
gpg --batch --armor --export-secret-subkeys "$subkey!" > "$out/ci-signing-subkey.asc"
gpgconf --kill gpg-agent 2>/dev/null || true
if ((set_secret)); then
  gh secret set CMUX_LINUX_ARCHIVE_SIGNING_KEY --env artifacts --repo "$repo" < "$out/ci-signing-subkey.asc"
  rm -f "$out/ci-signing-subkey.asc"
  echo "stored CMUX_LINUX_ARCHIVE_SIGNING_KEY in $repo's artifacts environment"
fi
cat <<EOF
primary (certify only, offline): $primary
signing subkey (CI, expires $expire): $subkey
offline half: $out (move it off this machine; its revocation certificate is in gnupg/openpgp-revocs.d/)
next: commit $out/cmux-archive-keyring.asc as scripts/ci/cmux-archive-keyring.asc, so the
workflow publishes files.cmux.com/linux/cmux-archive-keyring.gpg from the repository, not from the secret.
EOF
