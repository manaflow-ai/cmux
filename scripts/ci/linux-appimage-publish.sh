#!/usr/bin/env bash
# Build the cmux AppImage of this commit for x86_64 and aarch64 and publish it with its update file
# (cmuxterm-hq docs/rfd/0157-linux-and-windows-releases.md, Packaging; scripts/ci/linux-archive.py does the
# building).
#
#   scripts/ci/linux-appimage-publish.sh BUILT_DIR WORK_DIR
#
# BUILT_DIR holds this run's own build of the musl binaries, the ones the Linux release file was signed
# against. Reads env R2_ENDPOINT and the AWS_* R2 credentials, GITHUB_SHA, GITHUB_RUN_ID, and optionally
# ARCHIVE_SIGNING_KEY (the apt and yum archive's signing subkey): with it and the committed public keyring,
# each AppImage also gets a detached OpenPGP signature (.asc), checked with gpgv before upload.
#
# What a reader can check today without that key: every binary inside the AppImage is the one the
# Ed25519-signed cmux-tui/<commit>/release.json names (linux-archive.py appimage-verify runs on each file
# before upload), and the build is reproducible (fixed times, pinned runtime), so a rebuild gives the same
# bytes.
#
# Layout on files.cmux.com:
#   cmux-tui/<commit>/cmux-<version>-<arch>.AppImage (.asc)          written once
#   linux/appimage/<channel>/cmux-<arch>.AppImage (.asc)             the stable download link
#   linux/appimage/<channel>/cmux-<arch>.AppImage.zsync               the update file, written last
# The .zsync names the per-commit file, never the stable link, so an update in flight never mixes two
# builds. The AppImage's embedded update information names that .zsync (AppImageUpdate, or
# `appimageupdatetool cmux-x86_64.AppImage`, moves it to the newest build in place).
# The channel moves only when the Linux release channel names this commit, so it inherits that channel's
# ordering (an older run finishing late leaves the AppImage channel alone).
set -euo pipefail
built=$1 work=$2
channel=feat-cmux-next
root=$(cd "$(dirname "$0")/../.." && pwd)
archive="$root/scripts/ci/linux-archive.py"
keys="$root/Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json"
keyring_asc="$root/scripts/ci/cmux-archive-keyring.asc"
icon="$root/web/app/apple-icon.png"
files=https://files.cmux.com
# AppImage/type2-runtime: static, needs no libfuse on the host (and runs with APPIMAGE_EXTRACT_AND_RUN=1
# where FUSE is missing).
RUNTIME_TAG=20251108
declare -A RUNTIME_SHA256=(
  [x86_64]=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
  [aarch64]=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444
)
declare -A TARGET=([x86_64]=x86_64-unknown-linux-musl [aarch64]=aarch64-unknown-linux-musl)

mkdir -p "$work" && chmod 700 "$work"
need=()
command -v mksquashfs >/dev/null && command -v unsquashfs >/dev/null || need+=(squashfs-tools)
command -v zsyncmake >/dev/null || need+=(zsync)
if ((${#need[@]})); then
  bash "$root/scripts/ci/timeout.sh" 300 sudo apt-get install -y -qq "${need[@]}" >/dev/null 2>&1 || true
fi
for tool in mksquashfs unsquashfs zsyncmake; do
  command -v "$tool" >/dev/null || { echo "::error::$tool is unavailable (apt-get install ${need[*]})"; exit 1; }
done

sign=0
if [[ -n "${ARCHIVE_SIGNING_KEY:-}" && -f "$keyring_asc" ]]; then
  export GNUPGHOME="$work/gnupg"
  mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
  trap 'gpgconf --kill all 2>/dev/null || true; rm -rf "$GNUPGHOME"' EXIT
  printf '%s\n' "$ARCHIVE_SIGNING_KEY" | gpg --batch --quiet --import
  subkey=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1=="ssb" && $12 ~ /s/ {s=1; next} s && $1=="fpr" {print $10; exit}')
  [[ "$subkey" =~ ^[0-9A-F]{40}$ ]] || { echo "::error::ARCHIVE_SIGNING_KEY holds no signing subkey"; exit 1; }
  gpg --batch --yes --dearmor --output "$work/cmux-archive-keyring.gpg" "$keyring_asc"
  sign=1
else
  echo "::notice::the archive signing key or keyring is missing; the AppImages carry no .asc (their binaries are checked against the signed release file)"
fi

curl -fsS --retry 3 --max-time 60 -o "$work/release.json" "$files/cmux-tui/$GITHUB_SHA/release.json?appimage=$GITHUB_RUN_ID"
version=$(python3 -c 'import base64,json,sys; print(json.loads(base64.b64decode(json.load(open(sys.argv[1]))["payload"]))["version"])' "$work/release.json")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]{14}\.[0-9a-f]{12}$ ]] || { echo "::error::bad release version $version"; exit 1; }

mkdir -p "$work/out"
for arch in x86_64 aarch64; do
  target=${TARGET[$arch]}
  curl -fsSL --retry 3 --max-time 120 -o "$work/runtime-$arch" \
    "https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME_TAG/runtime-$arch"
  name="cmux-$version-$arch.AppImage"
  rm -rf "$work/AppDir-$arch"
  python3 "$archive" appdir --release "$work/release.json" --keys "$keys" --target "$target" \
    --binaries-dir "$built" --icon "$icon" --out "$work/AppDir-$arch"
  python3 "$archive" appimage --appdir "$work/AppDir-$arch" --runtime "$work/runtime-$arch" \
    --runtime-sha256 "${RUNTIME_SHA256[$arch]}" \
    --update-info "zsync|$files/linux/appimage/$channel/cmux-$arch.AppImage.zsync" --out "$work/out/$name"
  rm -rf "$work/AppDir-$arch"
  python3 "$archive" appimage-verify --appimage "$work/out/$name" --release "$work/release.json" --keys "$keys" \
    --target "$target"
  # The update file names the per-commit copy (absolute URL), which never changes once written.
  (cd "$work/out" && zsyncmake -u "$files/cmux-tui/$GITHUB_SHA/$name" -o "cmux-$arch.AppImage.zsync" "$name" >/dev/null)
  if ((sign)); then
    gpg --batch --yes --pinentry-mode loopback --local-user "$subkey!" --digest-algo SHA512 --armor \
      --detach-sign --output "$work/out/$name.asc" "$work/out/$name"
    gpgv --keyring "$work/cmux-archive-keyring.gpg" "$work/out/$name.asc" "$work/out/$name"
  fi
done

upload() { # FILE KEY CACHE-CONTROL MODE...
  local file=$1 key=$2 cache=$3
  shift 3
  python3 "$root/scripts/ci/upload-r2-object.py" --endpoint-url "$R2_ENDPOINT" --bucket cmux-binaries \
    --cache-control "$cache" --file "$file" --key "$key" --conflict-exit-code 9 "$@"
}
immutable="public, max-age=31536000, immutable"
index="public, max-age=60, must-revalidate"
for arch in x86_64 aarch64; do
  name="cmux-$version-$arch.AppImage"
  for f in "$name" "$name.asc"; do
    [[ -f "$work/out/$f" ]] || continue
    rc=0
    upload "$work/out/$f" "cmux-tui/$GITHUB_SHA/$f" "$immutable" --write-once || rc=$?
    # An earlier attempt of this commit wrote it: the build is reproducible, so the bytes must match.
    if [[ $rc == 9 ]]; then
      curl -fsS --retry 3 --max-time 600 -o "$work/published" "$files/cmux-tui/$GITHUB_SHA/$f?appimage=$GITHUB_RUN_ID"
      cmp -s "$work/published" "$work/out/$f" || [[ $f == *.asc ]] || {
        echo "::error::cmux-tui/$GITHUB_SHA/$f is already published with other bytes"; exit 1; }
    elif [[ $rc != 0 ]]; then
      exit "$rc"
    fi
  done
  echo "AppImage ($arch) -> $files/cmux-tui/$GITHUB_SHA/$name" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
done

# Move the channel only to the commit the Linux release channel names now.
curl -fsS --retry 3 --max-time 60 -o "$work/channel.json" "$files/cmux-tui/channels/linux-$channel.json?appimage=$GITHUB_RUN_ID"
named=$(python3 "$root/scripts/cmux-next/web-ota-pointer.py" verify --pointer "$work/channel.json" --keys "$keys" \
  --purpose cmux-linux-release | python3 -c 'import json,sys; print(json.load(sys.stdin)["commit"])') || named=""
if [[ "$named" != "$GITHUB_SHA" ]]; then
  echo "::notice::linux-$channel.json names ${named:-nothing verifiable}, not $GITHUB_SHA; the AppImage channel stays"
  exit 0
fi
for arch in x86_64 aarch64; do
  name="cmux-$version-$arch.AppImage"
  stable="linux/appimage/$channel/cmux-$arch.AppImage"
  upload "$work/out/$name" "$stable" "$index"
  [[ -f "$work/out/$name.asc" ]] && upload "$work/out/$name.asc" "$stable.asc" "$index"
  upload "$work/out/cmux-$arch.AppImage.zsync" "$stable.zsync" "$index"
  echo "AppImage channel $channel ($arch) -> $files/$stable" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
done
