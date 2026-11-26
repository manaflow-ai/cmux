#!/usr/bin/env bash
# Turns a cmux VM image's root filesystem into a compressed qcow2 disk and its sha256, the second format of the
# layered image beside the Freestyle snapshot chain, for hosts that run agent VMs themselves (libvirt, Proxmox,
# plain QEMU/KVM). Usage:
#
#   vm-image-qcow2.sh --rootfs-tar ROOTFS.tar[.zst] --out NAME.qcow2 [--size-mib N] [--label L]
#   vm-image-qcow2.sh --raw DISK.raw --out NAME.qcow2
#
# --rootfs-tar: a tarball of the guest's root filesystem (qcow2-export.ts writes one with numeric owners, xattrs
# and ACLs). It is unpacked and written into a new ext4 filesystem (mkfs.ext4 -d) inside one fakeroot session,
# so owners and modes survive on a runner that is not root. The filesystem is sized from the tree (used bytes
# plus a quarter plus 1 GiB, at least 2 GiB) unless --size-mib says otherwise; the host grows it at create
# (qemu-img resize, then resize2fs in the guest). It is a bare filesystem with no partition table or boot loader:
# a host boots it with direct kernel boot (the guest's own /boot/vmlinuz and initrd, root=/dev/vda).
# --raw: an existing raw disk image, converted as is.
#
# Writes NAME.qcow2 (zlib-compressed clusters, qemu-img convert -c) and NAME.qcow2.sha256 in `sha256sum` format
# (`<hex>  NAME.qcow2`), so `sha256sum -c NAME.qcow2.sha256` verifies it in the same directory. Prints
# `QCOW2 <path> <sha256> <bytes>` last. Needs qemu-img (qemu-utils), and for --rootfs-tar mkfs.ext4 (e2fsprogs),
# fakeroot and zstd when the tarball is compressed.
set -euo pipefail

die() { echo "vm-image-qcow2: $*" >&2; exit 2; }

rootfs_tar="" raw="" out="" size_mib="" label="cmux-rootfs"
while [ $# -gt 0 ]; do
  case "$1" in
    --rootfs-tar) rootfs_tar="${2:?}"; shift 2 ;;
    --raw) raw="${2:?}"; shift 2 ;;
    --out) out="${2:?}"; shift 2 ;;
    --size-mib) size_mib="${2:?}"; shift 2 ;;
    --label) label="${2:?}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$out" ] || die "--out is required"
case "$out" in *.qcow2) ;; *) die "--out must end in .qcow2" ;; esac
if [ -n "$rootfs_tar" ] && [ -n "$raw" ]; then die "give --rootfs-tar or --raw, not both"; fi
[ -n "$rootfs_tar" ] || [ -n "$raw" ] || die "give --rootfs-tar or --raw"
command -v qemu-img >/dev/null || die "qemu-img not found (apt-get install qemu-utils)"

out_dir="$(cd "$(dirname "$out")" && pwd)"
out="$out_dir/$(basename "$out")"
work="$(mktemp -d "${TMPDIR:-/tmp}/vm-image-qcow2.XXXXXX")"
trap 'chmod -R u+rwX "$work" 2>/dev/null || true; rm -rf "$work"' EXIT

if [ -n "$rootfs_tar" ]; then
  [ -f "$rootfs_tar" ] || die "no such tarball: $rootfs_tar"
  command -v mkfs.ext4 >/dev/null || die "mkfs.ext4 not found (apt-get install e2fsprogs)"
  command -v fakeroot >/dev/null || die "fakeroot not found (apt-get install fakeroot)"
  decompress="cat"
  case "$rootfs_tar" in
    *.zst) command -v zstd >/dev/null || die "zstd not found"; decompress="zstd -dc" ;;
    *.gz) decompress="gzip -dc" ;;
  esac
  raw="$work/rootfs.raw"
  # One fakeroot session for the unpack and the mkfs: the owners tar records exist only in fakeroot's database.
  WORK="$work" TARBALL="$rootfs_tar" DECOMPRESS="$decompress" SIZE_MIB="$size_mib" LABEL="$label" \
    fakeroot -- bash -euo pipefail -c '
      mkdir "$WORK/root"
      $DECOMPRESS "$TARBALL" | tar -x --numeric-owner --xattrs --acls -p -f - -C "$WORK/root"
      if [ -z "$SIZE_MIB" ]; then
        used_kib="$(du -s -k --apparent-size "$WORK/root" | cut -f1)"
        SIZE_MIB=$(( used_kib / 1024 * 5 / 4 + 1024 ))
        [ "$SIZE_MIB" -ge 2048 ] || SIZE_MIB=2048
      fi
      truncate -s "${SIZE_MIB}M" "$WORK/rootfs.raw"
      mkfs.ext4 -q -F -L "$LABEL" -E root_owner=0:0 -d "$WORK/root" "$WORK/rootfs.raw"
    '
  rm -rf "$work/root" 2>/dev/null || { chmod -R u+rwX "$work/root"; rm -rf "$work/root"; }
fi
[ -f "$raw" ] || die "no such raw image: $raw"

tmp_out="$work/$(basename "$out")"
qemu-img convert -q -c -f raw -O qcow2 -o compression_type=zlib "$raw" "$tmp_out"
qemu-img check -q "$tmp_out"
qemu-img compare -q -f raw -F qcow2 "$raw" "$tmp_out"
mv -f "$tmp_out" "$out"

digest="$(sha256sum "$out" | cut -d' ' -f1)"
printf '%s  %s\n' "$digest" "$(basename "$out")" > "$out.sha256"
bytes="$(stat -c %s "$out")"
echo "QCOW2 $out $digest $bytes"
