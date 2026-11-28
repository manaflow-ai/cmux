#!/usr/bin/env bash
# host-artifacts.sh: build and publish what a new cmux-vmd host installs at boot, so a GCE microVM host
# provisions itself (cmuxterm-hq build-fleet/microvm-host/provision.sh) with nobody's ssh or tailnet.
#
#   host-artifacts.sh bundle --bins DIR --out DIR [--rootfs-tar ROOTFS.tar.zst]
#   host-artifacts.sh publish --out DIR --rev REV
#   host-artifacts.sh rootfs ROOTFS.tar.zst GUEST_BIN OUT.ext4.zst   (the rootfs step alone; tests use it)
#
# bundle lays out, with a manifest.json of every file's sha256 and bytes:
#   bin/cmux-vmd                     from --bins (cargo build --release -p cmux-vmd)
#   bin/firecracker                  the pinned Firecracker release below, its tarball's sha256 checked
#   images/autocloud/vmlinux         the pinned Firecracker CI guest kernel (virtio-vsock built in), sha256 checked
#   images/autocloud/rootfs.ext4.zst the rolled cmux VM image's root filesystem (cloud-vm-image-roll.yml's qcow2
#                                    job writes cmux-vm-image/<tag>/rootfs.tar.zst), as ext4 with cmux-vmd-guest
#                                    (from --bins) at /usr/local/bin and enabled as cmux-vmd-guest.service
#   autocloud-template.sh            scripts/cmux-vmd/autocloud-template.sh, which bakes the autocloud templates
# Without --rootfs-tar the bundle has no images/autocloud/rootfs.ext4.zst (a pull request's dry run).
#
# publish uploads the bundle to R2 at $R2_BUCKET/$PREFIX/REV/ (default cmux-fleet-artifacts/cmux-vmd), checks each
# object back, then writes $PREFIX/latest.json ({rev, prefix, manifest}) last, so a host never reads a half upload.
# Needs AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and R2_ENDPOINT (https://<account>.r2.cloudflarestorage.com).
# The bucket is private: a host reads it with a read-only key (cmuxterm-hq secret cmux-cache-reader-r2-read).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Pins. tests/test_cmux_vmd_host_artifacts.py keeps them well formed.
FIRECRACKER_VERSION="v1.18.0"
FIRECRACKER_TGZ_SHA256="1ac8eec866dd5eea14efecf6323e22b23eea24054545338a5b34bc5bca6623cd"
VMLINUX_URL="https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.15/x86_64/vmlinux-6.1.155"
VMLINUX_SHA256="e20e46d0c36c55c0d1014eb20576171b3f3d922260d9f792017aeff53af3d4f2"
# The guest disk grows to autocloud-template.sh's DISK_GIB at bake; this is only the free room the image ships with.
ROOTFS_FREE_MIB="${ROOTFS_FREE_MIB:-2048}"

die() { echo "host-artifacts: $*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

fetch() { # URL OUT SHA256
  curl -fsSL --retry 5 --retry-all-errors -o "$2" "$1"
  local got; got="$(sha "$2")"
  [ "$got" = "$3" ] || die "$1: sha256 $got, pinned $3"
}

# The guest agent's unit: cmux-vmd waits on its vsock ping after every boot (host.rs vsock::wait_ready).
GUEST_UNIT='[Unit]
Description=cmux-vmd guest agent (vsock port 52)
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target cmux-host.service

[Service]
ExecStart=/usr/local/bin/cmux-vmd-guest
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target'

rootfs_ext4() { # TARBALL GUEST_BIN OUT
  local tarball="$1" guest="$2" out="$3" work
  for t in mkfs.ext4 fakeroot zstd; do command -v "$t" >/dev/null || die "$t not found (apt-get install e2fsprogs fakeroot zstd)"; done
  work="$(mktemp -d "${TMPDIR:-/tmp}/host-artifacts.XXXXXX")"
  # One fakeroot session for unpack, inject and mkfs: the tarball's owners live only in fakeroot's database.
  WORK="$work" TARBALL="$tarball" GUEST="$guest" UNIT="$GUEST_UNIT" FREE_MIB="$ROOTFS_FREE_MIB" \
    fakeroot -- bash -euo pipefail -c '
      r="$WORK/root"; mkdir "$r"
      zstd -dc "$TARBALL" | tar -x --numeric-owner --xattrs --acls -p -f - -C "$r"
      [ -x "$r/sbin/init" ] || [ -L "$r/sbin/init" ] || { echo "host-artifacts: rootfs has no /sbin/init" >&2; exit 1; }
      install -D -m 0755 -o 0 -g 0 "$GUEST" "$r/usr/local/bin/cmux-vmd-guest"
      install -d -m 0755 "$r/etc/systemd/system/multi-user.target.wants"
      printf "%s\n" "$UNIT" > "$r/etc/systemd/system/cmux-vmd-guest.service"
      chown 0:0 "$r/etc/systemd/system/cmux-vmd-guest.service"
      ln -sfn ../cmux-vmd-guest.service "$r/etc/systemd/system/multi-user.target.wants/cmux-vmd-guest.service"
      # The image mounts / by label (cloudimg-rootfs on the Ubuntu cloud base): give the ext4 the label it names.
      label="$(awk '\''$2 == "/" && $1 ~ /^LABEL=/ {sub(/^LABEL=/, "", $1); print $1; exit}'\'' "$r/etc/fstab" 2>/dev/null || true)"
      [ -n "$label" ] || label=cmux-rootfs
      used_kib="$(du -s -k --apparent-size "$r" | cut -f1)"
      size_mib=$(( used_kib / 1024 * 5 / 4 + FREE_MIB ))
      truncate -s "${size_mib}M" "$WORK/rootfs.ext4"
      mkfs.ext4 -q -F -L "$label" -E root_owner=0:0 -d "$r" "$WORK/rootfs.ext4"
      echo "ROOTFS label=$label size_mib=$size_mib"
    '
  chmod -R u+rwX "$work/root" 2>/dev/null || true
  rm -rf "$work/root"
  zstd -q -T0 -10 -f -o "$out" "$work/rootfs.ext4"
  rm -f "$work/rootfs.ext4"
  rmdir "$work"
}

bundle() {
  local bins="" out="" rootfs_tar=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --bins) bins="${2:?}"; shift 2 ;;
      --out) out="${2:?}"; shift 2 ;;
      --rootfs-tar) rootfs_tar="${2:?}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$bins" ] && [ -n "$out" ] || die "bundle needs --bins DIR --out DIR"
  for b in cmux-vmd cmux-vmd-guest; do [ -x "$bins/$b" ] || die "no executable $bins/$b"; done
  mkdir -p "$out/bin" "$out/images/autocloud"
  install -m 0755 "$bins/cmux-vmd" "$out/bin/cmux-vmd"

  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/host-artifacts-fc.XXXXXX")"
  fetch "https://github.com/firecracker-microvm/firecracker/releases/download/$FIRECRACKER_VERSION/firecracker-$FIRECRACKER_VERSION-x86_64.tgz" \
    "$tmp/fc.tgz" "$FIRECRACKER_TGZ_SHA256"
  tar -xzf "$tmp/fc.tgz" -C "$tmp" "release-$FIRECRACKER_VERSION-x86_64/firecracker-$FIRECRACKER_VERSION-x86_64"
  install -m 0755 "$tmp/release-$FIRECRACKER_VERSION-x86_64/firecracker-$FIRECRACKER_VERSION-x86_64" "$out/bin/firecracker"
  rm -rf "$tmp"
  fetch "$VMLINUX_URL" "$out/images/autocloud/vmlinux" "$VMLINUX_SHA256"
  install -m 0755 "$root/scripts/cmux-vmd/autocloud-template.sh" "$out/autocloud-template.sh"

  local rootfs_sha=""
  if [ -n "$rootfs_tar" ]; then
    [ -f "$rootfs_tar" ] || die "no such tarball: $rootfs_tar"
    rootfs_sha="$(sha "$rootfs_tar")"
    rootfs_ext4 "$rootfs_tar" "$bins/cmux-vmd-guest" "$out/images/autocloud/rootfs.ext4.zst"
  fi

  (cd "$out" && find . -type f ! -name manifest.json | sed 's|^\./||' | LC_ALL=C sort | while read -r f; do
     printf '%s\t%s\t%s\n' "$f" "$(sha "$f")" "$(stat -c %s "$f")"
   done) | jq -R -s --arg fc "$FIRECRACKER_VERSION" --arg kernel "$VMLINUX_URL" --arg rootfs_sha "$rootfs_sha" \
       --arg source_sha "${GITHUB_SHA:-$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)}" \
       --arg rootfs_key "${ROOTFS_KEY:-}" '
    {schema: 1, source_sha: $source_sha, firecracker: $fc, kernel: $kernel,
     rootfs_tar: (if $rootfs_sha == "" then null else {key: $rootfs_key, sha256: $rootfs_sha} end),
     files: [split("\n")[] | select(length > 0) | split("\t") | {path: .[0], sha256: .[1], bytes: (.[2] | tonumber)}]}' \
    > "$out/manifest.json"
  cat "$out/manifest.json"
}

publish() {
  local out="" rev=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="${2:?}"; shift 2 ;;
      --rev) rev="${2:?}"; shift 2 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -f "$out/manifest.json" ] || die "no $out/manifest.json (run bundle first)"
  [[ "$rev" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad --rev '$rev'"
  : "${R2_BUCKET:=cmux-fleet-artifacts}" "${PREFIX:=cmux-vmd}"
  [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] && [ -n "${R2_ENDPOINT:-}" ] \
    || die "publish needs AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and R2_ENDPOINT"
  # No rootfs: published anyway (the host installs the daemon and the tunnel, and logs that it has no image).
  jq -e '.files | map(.path) | index("images/autocloud/rootfs.ext4.zst")' "$out/manifest.json" >/dev/null \
    || echo "::warning title=cmux-vmd host artifacts::the bundle has no rootfs; hosts get the daemon but no autocloud image"
  presign() { python3 "$root/scripts/ci/r2-presign.py" --endpoint-url "$R2_ENDPOINT" --bucket "$R2_BUCKET" --key "$1" --method "$2" --expires 7200; }
  local dir="$PREFIX/$rev" f check code
  check="$(mktemp)"
  # A key that cannot write this bucket fails here with R2's reason, before any upload (the qcow2 export's
  # cmux-next-vm-image-dev key gets 403 AccessDenied on cmux-fleet-artifacts).
  printf probe > "$check"
  code="$(curl -sS -T "$check" -o "$check.out" -w '%{http_code}' "$(presign "$PREFIX/probe" PUT)" || echo curl-failed)"
  case "$code" in
    2??) rm -f "$check.out" ;;
    *) die "R2 probe PUT to $R2_BUCKET/$PREFIX/probe returned $code: $(head -c 600 "$check.out" 2>/dev/null)" ;;
  esac
  while read -r f want; do
    curl -fsS --retry 5 --retry-all-errors -T "$out/$f" "$(presign "$dir/$f" PUT)"
    curl -fsS --retry 5 --retry-all-errors -o "$check" "$(presign "$dir/$f" GET)"
    [ "$(sha "$check")" = "$want" ] || die "$dir/$f read back with another sha256"
    echo "PUT $R2_BUCKET/$dir/$f $want"
  done < <(jq -r '.files[] | "\(.path) \(.sha256)"' "$out/manifest.json")
  rm -f "$check"
  curl -fsS --retry 5 --retry-all-errors -T "$out/manifest.json" "$(presign "$dir/manifest.json" PUT)"
  jq -n --arg rev "$rev" --arg prefix "$dir" --arg sha "$(sha "$out/manifest.json")" \
    '{schema: 1, rev: $rev, prefix: $prefix, manifest: ($prefix + "/manifest.json"), manifest_sha256: $sha}' > "$out/latest.json"
  curl -fsS --retry 5 --retry-all-errors -T "$out/latest.json" "$(presign "$PREFIX/latest.json" PUT)"
  echo "LATEST $R2_BUCKET/$PREFIX/latest.json -> $dir"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { echo "### cmux-vmd host artifacts"
      echo "- \`$R2_BUCKET/$dir/\` (private; hosts read it with a read-only key), latest at \`$R2_BUCKET/$PREFIX/latest.json\`"
      jq -r '.files[] | "- `\(.path)` \(.bytes) bytes, sha256 `\(.sha256)`"' "$out/manifest.json"; } >> "$GITHUB_STEP_SUMMARY"
  fi
}

case "${1:-}" in
  bundle) shift; bundle "$@" ;;
  publish) shift; publish "$@" ;;
  rootfs) shift; [ $# -eq 3 ] || die "rootfs TARBALL GUEST_BIN OUT"; rootfs_ext4 "$@" ;;
  *) die "usage: host-artifacts.sh bundle --bins DIR --out DIR [--rootfs-tar F] | publish --out DIR --rev REV" ;;
esac
