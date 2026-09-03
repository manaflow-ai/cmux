#!/usr/bin/env bash
# Bake the Alpine root filesystem that cmux ships for Linux on this iPhone.
#
# The image is a plain Alpine 3.24 x86 (i386) root filesystem tarball with the
# cmux tool set installed and the cmux profile applied. Docker emulates 32-bit
# Linux so apk can run the real package installs; the resulting tarball is
# converted to an iSH fakefs on the device at first launch.
#
# Output: build/ish-rootfs/<asset>.tar.gz, its SHA-256, and a refreshed
# Packages/iOS/CmuxLocalLinux/Sources/CmuxLocalLinux/Resources/alpine-rootfs.json
# manifest. With --publish the tarball is uploaded as a GitHub release asset on
# manaflow-ai/ish, and scripts/build-ish-ios.sh downloads it from there by URL
# and digest. Never publish to a repository outside the manaflow-ai org.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSIDE="$ROOT/scripts/ish-rootfs/bake-inside.sh"
OUT_DIR="$ROOT/build/ish-rootfs"
MANIFEST="$ROOT/Packages/iOS/CmuxLocalLinux/Sources/CmuxLocalLinux/Resources/alpine-rootfs.json"

ALPINE_TAG="${CMUX_ROOTFS_ALPINE_TAG:-3.24}"
IMAGE_VERSION="${CMUX_ROOTFS_IMAGE_VERSION:-$(date -u +%Y.%m.%d)}"
PI_PACKAGE="${CMUX_ROOTFS_PI_PACKAGE:-@earendil-works/pi-coding-agent@0.84.4}"
RELEASE_REPO="${CMUX_ROOTFS_RELEASE_REPO:-manaflow-ai/ish}"
PUBLISH=0

usage() {
    cat <<'USAGE'
Usage: scripts/bake-ish-rootfs.sh [--publish] [--version YYYY.MM.DD]

Options:
  --publish          Upload the tarball as a release asset on manaflow-ai/ish
                     (tag cmux-rootfs-<version>) and point the manifest at it.
  --version <v>      Image version (default: today's UTC date).
  --help             Show this help.

Environment:
  CMUX_ROOTFS_ALPINE_TAG      Docker alpine image tag (default 3.24).
  CMUX_ROOTFS_PI_PACKAGE      npm spec installed by `cmux-linux add node`.
  CMUX_ROOTFS_RELEASE_REPO    Release repository (must be in manaflow-ai).
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --publish) PUBLISH=1 ;;
        --version) shift; IMAGE_VERSION="${1:?--version needs a value}" ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; echo "bake-ish-rootfs: unknown option: $1" >&2; exit 64 ;;
    esac
    shift
done

die() { echo "bake-ish-rootfs: $*" >&2; exit 1; }

[[ "$IMAGE_VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}[a-z]?$ ]] || die "version must look like 2026.09.02 or 2026.09.02b"
[[ "$RELEASE_REPO" == manaflow-ai/* ]] || die "release repository must be in the manaflow-ai org"
command -v docker >/dev/null 2>&1 || die "docker is required"
[[ -x "$INSIDE" ]] || die "missing $INSIDE"
if (( PUBLISH )); then
    command -v gh >/dev/null 2>&1 || die "gh is required for --publish"
fi

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print tolower($1)}'
    else
        sha256sum "$1" | awk '{print tolower($1)}'
    fi
}

alpine_release="$(docker run --rm --platform linux/386 "alpine:$ALPINE_TAG" cat /etc/alpine-release)"
[[ "$alpine_release" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected Alpine release: $alpine_release"

ASSET="alpine-rootfs-${alpine_release}-x86-cmux-${IMAGE_VERSION}.tar.gz"
TAG="cmux-rootfs-${IMAGE_VERSION}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cmux-ish-rootfs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/out" "$OUT_DIR"

echo "baking Alpine $alpine_release x86 image $IMAGE_VERSION"
docker run --rm --platform linux/386 \
    -e "CMUX_ROOTFS_IMAGE_VERSION=$IMAGE_VERSION" \
    -e "CMUX_ROOTFS_PI_PACKAGE=$PI_PACKAGE" \
    -v "$ROOT/scripts/ish-rootfs:/bake:ro" \
    -v "$WORK/out:/out" \
    "alpine:$ALPINE_TAG" sh /bake/bake-inside.sh

mv -f "$WORK/out/rootfs.tar.gz" "$OUT_DIR/$ASSET"
mv -f "$WORK/out/packages.json" "$OUT_DIR/$ASSET.packages.json"
digest="$(sha256_file "$OUT_DIR/$ASSET")"
echo "asset:  $OUT_DIR/$ASSET"
echo "sha256: $digest"

source_url="https://github.com/$RELEASE_REPO/releases/download/$TAG/$ASSET"
if (( PUBLISH )); then
    if gh release view "$TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
        die "release $TAG already exists on $RELEASE_REPO; pick a new --version"
    fi
    gh release create "$TAG" --repo "$RELEASE_REPO" --prerelease \
        --title "cmux Alpine rootfs $IMAGE_VERSION (Alpine $alpine_release x86)" \
        --notes "Alpine Linux $alpine_release x86 root filesystem with the cmux tool set for Linux on this iPhone. Built by scripts/bake-ish-rootfs.sh in manaflow-ai/cmux. SHA-256 $digest." \
        "$OUT_DIR/$ASSET" "$OUT_DIR/$ASSET.packages.json"
    echo "published: $source_url"
fi

python3 - "$MANIFEST" "$OUT_DIR/$ASSET.packages.json" "$digest" "$source_url" "$alpine_release" "$IMAGE_VERSION" "$PI_PACKAGE" <<'PY'
import json
import sys

manifest_path, packages_path, digest, source, alpine_release, image_version, pi_package = sys.argv[1:]
baked = json.load(open(packages_path, encoding="utf-8"))
manifest = {
    "format": "Alpine Linux root filesystem tarball; converted to an iSH fakefs on the device at first launch",
    "version": f"Alpine Linux {alpine_release} with cmux tool set {image_version}",
    "image_version": image_version,
    "architecture": "x86",
    "source": source,
    "base_image": f"docker.io/library/alpine:{alpine_release.rsplit('.', 1)[0]} (linux/386)",
    "generated_by": "scripts/bake-ish-rootfs.sh",
    "archive": "alpine-rootfs.tar.gz",
    "sha256": digest,
    "packages": baked["packages"],
    "optional_tool_sets": baked["optional_tool_sets"],
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY
echo "manifest: $MANIFEST"
cat <<EOM

Next: pin the new image in scripts/build-ish-ios.sh:
  DEFAULT_ROOTFS_URL="$source_url"
  DEFAULT_ROOTFS_SHA256="$digest"
EOM
