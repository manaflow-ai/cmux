#!/usr/bin/env bash
# Publishes one smoked cmux VM image snapshot as a compressed qcow2 with its sha256 (RFD 0100 step 6), the second
# format beside the Freestyle snapshot chain. Both cloud-vm-image-bake.yml (input qcow2) and cloud-vm-image-roll.yml
# (every rolled image, in a job beside promote) run it.
#
#   SNAPSHOT=sh-... TAG=ci-<run>-<attempt> OUT_DIR=dir FREESTYLE_API_KEY=... \
#   AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... R2_ENDPOINT=https://<acct>.r2.cloudflarestorage.com \
#   R2_BUCKET=cmux-fleet-artifacts scripts/ci/vm-image-qcow2-publish.sh
#
# One VM booted from SNAPSHOT tars its root filesystem to R2 through a presigned PUT (qcow2-export.ts; the guest never
# holds the R2 key). This runner downloads it, checks its sha256, builds the qcow2 (vm-image-qcow2.sh) and uploads
# cmux-vm-image/TAG/cmux-vm-TAG.qcow2 and .qcow2.sha256 to the private bucket (no r2.dev, no custom domain): a host
# fetches them with presigned GET URLs. Writes OUT_DIR/qcow2.json and a summary line. The export VM is recorded in
# OUT_DIR/resources.tsv; the caller's cleanup (images/cmux-vm/cleanup.ts --ledger) deletes it if this dies.
# No R2 credentials: a warning and exit 0, nothing exported.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${SNAPSHOT:?SNAPSHOT (sh-...) is required}" "${TAG:?TAG is required}" "${OUT_DIR:?OUT_DIR is required}"
: "${R2_BUCKET:=cmux-fleet-artifacts}"
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ] || [ -z "${R2_ENDPOINT:-}" ]; then
  echo "::warning title=qcow2 export::no R2 credentials in this run; nothing exported"
  exit 0
fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

missing=""
for t in qemu-img mkfs.ext4 fakeroot zstd; do command -v "$t" >/dev/null || missing=1; done
if [ -n "$missing" ]; then
  # A pool runner's package lists can be stale or empty: refresh them before the install.
  sudo -n apt-get update -qq >/dev/null
  sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-utils e2fsprogs fakeroot zstd >/dev/null
fi

prefix="cmux-vm-image/$TAG"
presign() { python3 "$root/scripts/ci/r2-presign.py" --endpoint-url "$R2_ENDPOINT" --bucket "$R2_BUCKET" --key "$prefix/$1" --method "$2" --expires 7200; }

# Probe the key first, from this runner: a key that cannot write this bucket fails here in seconds, with R2's reason,
# not after the export VM has spent minutes on the tarball (roll 45690843632: 403 on the guest's PUT).
probe="$(mktemp)"; printf probe > "$probe"
probe_code="$(curl -sS -T "$probe" -o "$probe.out" -w '%{http_code}' "$(presign probe PUT)" || echo curl-failed)"
case "$probe_code" in
  2??) ;;
  *) echo "::error title=qcow2 export::R2 probe PUT to $R2_BUCKET/$prefix/probe returned $probe_code: $(head -c 600 "$probe.out" 2>/dev/null)"; rm -f "$probe" "$probe.out"; exit 1;;
esac
rm -f "$probe" "$probe.out"

(cd "$root/web" && QCOW2_ROOTFS_PUT_URL="$(presign rootfs.tar.zst PUT)" \
  bun ../images/cmux-vm/qcow2-export.ts --snapshot "$SNAPSHOT" --tag "$TAG" --out-dir "$OUT_DIR") | tee "$OUT_DIR/qcow2-export.out"
read -r _ tar_sha _ < <(grep '^ROOTFS_TAR ' "$OUT_DIR/qcow2-export.out" | tail -1)

work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/qcow2-$TAG"
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
curl -fsS --retry 5 --retry-all-errors -o "$work/rootfs.tar.zst" "$(presign rootfs.tar.zst GET)"
echo "$tar_sha  $work/rootfs.tar.zst" | sha256sum -c -
name="cmux-vm-$TAG.qcow2"
bash "$root/scripts/ci/vm-image-qcow2.sh" --rootfs-tar "$work/rootfs.tar.zst" --out "$work/$name" | tee -a "$OUT_DIR/qcow2-export.out"
rm -f "$work/rootfs.tar.zst"
curl -fsS --retry 5 --retry-all-errors -T "$work/$name" "$(presign "$name" PUT)"
curl -fsS --retry 5 --retry-all-errors -T "$work/$name.sha256" "$(presign "$name.sha256" PUT)"
cp "$work/$name.sha256" "$OUT_DIR/"
read -r _ _ digest bytes < <(grep '^QCOW2 ' "$OUT_DIR/qcow2-export.out" | tail -1)
jq -n --arg tag "$TAG" --arg snapshot "$SNAPSHOT" --arg bucket "$R2_BUCKET" --arg key "$prefix/$name" \
  --arg sha256 "$digest" --argjson bytes "$bytes" --arg rootfs "$prefix/rootfs.tar.zst" --arg rootfs_sha256 "$tar_sha" \
  '{tag: $tag, snapshot_id: $snapshot, bucket: $bucket, qcow2: {key: $key, sha256_key: ($key + ".sha256"), sha256: $sha256, bytes: $bytes}, rootfs_tar: {key: $rootfs, sha256: $rootfs_sha256}}' \
  > "$OUT_DIR/qcow2.json"
cat "$OUT_DIR/qcow2.json"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### qcow2 image"
    echo "- \`$R2_BUCKET/$prefix/$name\` (private; fetch with a presigned GET), $bytes bytes, sha256 \`$digest\`, from snapshot \`$SNAPSHOT\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi
