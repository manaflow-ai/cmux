#!/usr/bin/env bash
# Build the .deb and .rpm of this commit and publish the signed apt and yum repositories (cmuxterm-hq
# docs/design/linux-signed-packages.md phase 4; scripts/ci/linux-archive.py does the building).
#
#   scripts/ci/linux-archive-publish.sh BUILT_DIR WORK_DIR
#
# BUILT_DIR holds this run's own build of the musl binaries (the ones the Linux release file was signed
# against). Reads env ARCHIVE_SIGNING_KEY (secret CMUX_LINUX_ARCHIVE_SIGNING_KEY: the signing subkey alone,
# linux-archive-key-new.sh), R2_ENDPOINT and the AWS_* R2 credentials, GITHUB_SHA, GITHUB_RUN_ID.
#
# Nothing is published, with a warning, while the secret is unset or scripts/ci/cmux-archive-keyring.asc
# (the public keyring, committed from the offline half) is missing: an index no committed key verifies
# would teach nobody anything. Every index is checked with gpgv against that committed keyring before
# upload, so a secret that is not the published key's subkey publishes nothing.
#
# Layout on files.cmux.com:
#   cmux-tui/<commit>/cmux_<version>_<arch>.deb, cmux-<version>-1.<arch>.rpm   written once
#   linux/apt/pool/<channel>/*.deb, linux/apt/dists/<channel>/...                the apt repository
#   linux/rpm/<channel>/*.rpm, linux/rpm/<channel>/repodata/...                  the yum repository
#   linux/cmux-archive-keyring.gpg                                               the public keyring
# This first slice lists the newest build alone (the design keeps 20) and is re-signed by each push, not a
# daily job yet; Valid-Until is 7 days.
set -euo pipefail
built=$1 work=$2
channel=feat-cmux-next
root=$(cd "$(dirname "$0")/../.." && pwd)
archive="$root/scripts/ci/linux-archive.py"
keys="$root/Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json"
keyring_asc="$root/scripts/ci/cmux-archive-keyring.asc"
NFPM_VERSION=2.49.0
declare -A NFPM_SHA256=(
  [x86_64]=2afaa5ffb5e3493402e31e7c67a5a1fb42133e3f66fc315ca0051934125561c7
  [aarch64]=d4eee71839e92c68cbd3b101640bad32d2856fc551acae0635be9118e48c9d9c
)

if [[ -z "${ARCHIVE_SIGNING_KEY:-}" ]]; then
  echo "::warning::CMUX_LINUX_ARCHIVE_SIGNING_KEY is not set; the apt and yum repositories are not published"
  exit 0
fi
if [[ ! -f "$keyring_asc" ]]; then
  echo "::warning::scripts/ci/cmux-archive-keyring.asc is not committed; the apt and yum repositories are not published"
  exit 0
fi
mkdir -p "$work" && chmod 700 "$work"
export GNUPGHOME="$work/gnupg"
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
trap 'gpgconf --kill all 2>/dev/null || true; rm -rf "$GNUPGHOME"' EXIT
printf '%s\n' "$ARCHIVE_SIGNING_KEY" | gpg --batch --quiet --import
# The one signing-capable secret subkey this home holds (the primary's secret is a stub).
subkey=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1=="ssb" && $12 ~ /s/ {s=1; next} s && $1=="fpr" {print $10; exit}')
[[ "$subkey" =~ ^[0-9A-F]{40}$ ]] || { echo "::error::CMUX_LINUX_ARCHIVE_SIGNING_KEY holds no signing subkey"; exit 1; }
gpg --batch --yes --dearmor --output "$work/cmux-archive-keyring.gpg" "$keyring_asc"

arch=$(uname -m)
[[ -n "${NFPM_SHA256[$arch]:-}" ]] || { echo "::error::no pinned nfpm for $arch"; exit 1; }
nfpm_arch=$([[ $arch == aarch64 ]] && echo arm64 || echo x86_64)
curl -fsSL --retry 3 --max-time 300 -o "$work/nfpm.tgz" \
  "https://github.com/goreleaser/nfpm/releases/download/v$NFPM_VERSION/nfpm_${NFPM_VERSION}_Linux_${nfpm_arch}.tar.gz"
echo "${NFPM_SHA256[$arch]}  $work/nfpm.tgz" | sha256sum -c --quiet
mkdir -p "$work/nfpm" && tar -xzf "$work/nfpm.tgz" -C "$work/nfpm" nfpm
nfpm="$work/nfpm/nfpm"
rpm_repo=1
if ! command -v createrepo_c >/dev/null; then
  bash "$(dirname "${BASH_SOURCE[0]}")/timeout.sh" 300 sudo apt-get install -y -qq createrepo-c >/dev/null 2>&1 || true
fi
command -v createrepo_c >/dev/null || { echo "::warning::createrepo_c is unavailable; the yum repository is not published"; rpm_repo=0; }

curl -fsS --retry 3 --max-time 60 -o "$work/release.json" "https://files.cmux.com/cmux-tui/$GITHUB_SHA/release.json?archive=$GITHUB_RUN_ID"
mkdir -p "$work/deb" "$work/rpm"
for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
  python3 "$archive" nfpm-config --release "$work/release.json" --keys "$keys" --target "$target" \
    --binaries-dir "$built" --out "$work/nfpm-$target.json"
  "$nfpm" package --config "$work/nfpm-$target.json" --packager deb --target "$work/deb/"
  ((rpm_repo)) && "$nfpm" package --config "$work/nfpm-$target.json" --packager rpm --target "$work/rpm/"
done

upload() { # FILE KEY CACHE-CONTROL MODE...
  local file=$1 key=$2 cache=$3
  shift 3
  python3 "$root/scripts/ci/upload-r2-object.py" --endpoint-url "$R2_ENDPOINT" --bucket cmux-binaries \
    --cache-control "$cache" --file "$file" --key "$key" --conflict-exit-code 9 "$@"
}
immutable="public, max-age=31536000, immutable"
index="public, max-age=60, must-revalidate"
# A package of this commit already published (an earlier attempt) is kept and listed as is: its name holds
# the version, so an installer that asked for it by name keeps getting the same bytes.
for pkg in "$work"/deb/*.deb "$work"/rpm/*.rpm; do
  [[ -f "$pkg" ]] || continue
  name=$(basename "$pkg")
  rc=0
  upload "$pkg" "cmux-tui/$GITHUB_SHA/$name" "$immutable" --write-once || rc=$?
  if [[ $rc == 9 ]]; then
    curl -fsS --retry 3 --max-time 600 -o "$pkg" "https://files.cmux.com/cmux-tui/$GITHUB_SHA/$name?archive=$GITHUB_RUN_ID"
  elif [[ $rc != 0 ]]; then
    exit "$rc"
  fi
done

repo="$work/repo"
python3 "$archive" apt-repo --debs "$work/deb" --channel "$channel" --out "$repo/apt" --key-id "$subkey"
gpgv --keyring "$work/cmux-archive-keyring.gpg" "$repo/apt/dists/$channel/InRelease"
gpgv --keyring "$work/cmux-archive-keyring.gpg" "$repo/apt/dists/$channel/Release.gpg" "$repo/apt/dists/$channel/Release"
if ((rpm_repo)); then
  python3 "$archive" rpm-repo --rpms "$work/rpm" --channel "$channel" --out "$repo/rpm" --key-id "$subkey"
  gpgv --keyring "$work/cmux-archive-keyring.gpg" "$repo/rpm/$channel/repodata/repomd.xml.asc" \
    "$repo/rpm/$channel/repodata/repomd.xml"
fi

# Packages first, then the indexes that name them, the signed ones last: a reader never gets an index
# naming a file not there yet.
upload "$work/cmux-archive-keyring.gpg" linux/cmux-archive-keyring.gpg "$index" --content-type application/pgp-keys
for pkg in "$repo"/apt/pool/"$channel"/*.deb; do
  upload "$pkg" "linux/apt/pool/$channel/$(basename "$pkg")" "$immutable" --write-once
done
for rel in main/binary-amd64/Packages main/binary-amd64/Packages.gz main/binary-arm64/Packages \
           main/binary-arm64/Packages.gz Release.gpg Release InRelease; do
  upload "$repo/apt/dists/$channel/$rel" "linux/apt/dists/$channel/$rel" "$index"
done
echo "apt repository -> https://files.cmux.com/linux/apt $channel main" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
if ((rpm_repo)); then
  for pkg in "$repo"/rpm/"$channel"/*.rpm; do
    upload "$pkg" "linux/rpm/$channel/$(basename "$pkg")" "$immutable" --write-once
  done
  for meta in "$repo"/rpm/"$channel"/repodata/*; do
    [[ $(basename "$meta") == repomd.xml* ]] && continue
    upload "$meta" "linux/rpm/$channel/repodata/$(basename "$meta")" "$index"
  done
  upload "$repo/rpm/$channel/repodata/repomd.xml" "linux/rpm/$channel/repodata/repomd.xml" "$index"
  upload "$repo/rpm/$channel/repodata/repomd.xml.asc" "linux/rpm/$channel/repodata/repomd.xml.asc" "$index"
  echo "yum repository -> https://files.cmux.com/linux/rpm/$channel" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi
