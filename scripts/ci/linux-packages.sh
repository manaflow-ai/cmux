#!/usr/bin/env bash
# Build the .deb and .rpm of this run's Linux release and name them in its payload, before it is signed
# (cmuxterm-hq docs/design/linux-signed-packages.md section 2: "Every file an installer fetches is in it").
#
#   scripts/ci/linux-packages.sh PAYLOAD BUILT_DIR WORK_DIR
#
# PAYLOAD is the unsigned payload of cmux-machine-channel.py payload --purpose linux-release, BUILT_DIR this
# run's own build of the musl binaries it names. Each package goes up write-once under the prefix the
# payload's binaries sit in (cmux-tui/<commit>/ or cmux-tui/tree/<key>/), named by the payload's sequence and
# architecture (scripts/ci/linux-archive.py packages); only once every one is up is PAYLOAD replaced by the
# payload naming them, so a signed release file never names a package that is not there. Any failure leaves
# PAYLOAD as it was (the release file is signed without packages) and exits non-zero for the caller's warning.
#
# This needs no archive key: the packages are delivery for `install-static.sh --system`, verified through
# the Ed25519-signed release file. The signed apt and yum repositories (linux-archive-publish.sh) take these
# same files, and stay gated on the OpenPGP archive key. Reads R2_ENDPOINT and the AWS_* R2 credentials.
set -euo pipefail
payload=$1 built=$2 work=$3
root=$(cd "$(dirname "$0")/../.." && pwd)
NFPM_VERSION=2.49.0
declare -A NFPM_SHA256=(
  [x86_64]=2afaa5ffb5e3493402e31e7c67a5a1fb42133e3f66fc315ca0051934125561c7
  [aarch64]=d4eee71839e92c68cbd3b101640bad32d2856fc551acae0635be9118e48c9d9c
)
mkdir -p "$work" && chmod 700 "$work"

nfpm=${NFPM:-}
if [[ -z "$nfpm" ]]; then
  arch=$(uname -m)
  [[ -n "${NFPM_SHA256[$arch]:-}" ]] || { echo "::error::no pinned nfpm for $arch"; exit 1; }
  nfpm_arch=$([[ $arch == aarch64 ]] && echo arm64 || echo x86_64)
  curl -fsSL --retry 3 --max-time 300 -o "$work/nfpm.tgz" \
    "https://github.com/goreleaser/nfpm/releases/download/v$NFPM_VERSION/nfpm_${NFPM_VERSION}_Linux_${nfpm_arch}.tar.gz"
  echo "${NFPM_SHA256[$arch]}  $work/nfpm.tgz" | sha256sum -c --quiet
  mkdir -p "$work/nfpm" && tar -xzf "$work/nfpm.tgz" -C "$work/nfpm" nfpm
  nfpm="$work/nfpm/nfpm"
fi

python3 "$root/scripts/ci/linux-archive.py" packages --payload "$payload" --binaries-dir "$built" \
  --nfpm "$nfpm" --work "$work/packages" --out "$work/payload.json" >"$work/uploads.tsv"

# Written once: a package of this sequence already there (an earlier attempt of this signing) must be
# these bytes, or the payload would name a sha256 the bucket does not serve.
while IFS=$'\t' read -r file key; do
  rc=0
  python3 "$root/scripts/ci/upload-r2-object.py" --endpoint-url "$R2_ENDPOINT" --bucket cmux-binaries \
    --cache-control "public, max-age=31536000, immutable" --file "$file" --key "$key" \
    --conflict-exit-code 9 --write-once || rc=$?
  if [[ $rc == 9 ]]; then
    curl -fsS --retry 3 --max-time 600 -o "$work/existing" "https://files.cmux.com/$key?packages=${GITHUB_RUN_ID:-0}"
    cmp -s "$work/existing" "$file" || { echo "::error::$key already holds other bytes"; exit 1; }
    rm -f "$work/existing"
  elif [[ $rc != 0 ]]; then
    exit "$rc"
  fi
  echo "package -> https://files.cmux.com/$key" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
done <"$work/uploads.tsv"
mv -f "$work/payload.json" "$payload"
rm -rf "$work/packages" "$work/nfpm" "$work/nfpm.tgz"
