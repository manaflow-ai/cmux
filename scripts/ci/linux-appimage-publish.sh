#!/usr/bin/env bash
# Build the cmux AppImage of this commit for x86_64 and aarch64 and publish it with its update file
# (cmuxterm-hq docs/rfd/0157-linux-and-windows-releases.md, Packaging; scripts/ci/linux-archive.py does the
# building).
#
#   scripts/ci/linux-appimage-publish.sh BUILT_DIR WORK_DIR             feat-cmux-next, this commit
#   scripts/ci/linux-appimage-publish.sh - WORK_DIR nightly|stable       the commit that channel names
#
# BUILT_DIR holds this run's own build of the musl binaries, the ones the Linux release file was signed
# against. For nightly and stable (`install.sh --channel`; cmux-linux-nightly-follow.sh points them at an
# older commit than this push) the binaries come from the signed release file's URLs instead, each checked
# against its sha256 (linux-archive.py appdir), and that channel's AppImage embeds its own channel's update
# file, so an AppImage stays on the channel it was downloaded from. A channel AppImage already at the named
# commit is not rebuilt. Reads env R2_ENDPOINT and the AWS_* R2 credentials, GITHUB_SHA, GITHUB_RUN_ID, and optionally
# ARCHIVE_SIGNING_KEY (the apt and yum archive's signing subkey): with it and the committed public keyring,
# each AppImage also gets a detached OpenPGP signature (.asc), checked with gpgv before upload.
#
# What a reader can check today without that key: every binary inside the AppImage is the one the
# Ed25519-signed cmux-tui/<commit>/release.json names (linux-archive.py appimage-verify runs on each file
# before upload), and the build is reproducible (fixed times, pinned runtime), so a rebuild gives the same
# bytes.
#
# Layout on files.cmux.com:
#   cmux-tui/<commit>/cmux-<version>-<arch>.AppImage (.asc)          written once (feat-cmux-next)
#   cmux-tui/<commit>/cmux-<version>-<channel>-<arch>.AppImage (.asc) written once (nightly, stable)
#   linux/appimage/<channel>/cmux-<arch>.AppImage (.asc)             the stable download link
#   linux/appimage/<channel>/cmux-<arch>.AppImage.zsync               the update file, written last
# The .zsync names the per-commit file, never the stable link, so an update in flight never mixes two
# builds. The AppImage's embedded update information names that .zsync (AppImageUpdate, or
# `appimageupdatetool cmux-x86_64.AppImage`, moves it to the newest build in place).
# The channel moves only when the Linux release channel names this commit, so it inherits that channel's
# ordering (an older run finishing late leaves the AppImage channel alone).
set -euo pipefail
built=$1 work=$2 channel=${3:-feat-cmux-next}
case "$channel" in
  feat-cmux-next) [[ "$built" != - ]] || { echo "usage: $0 BUILT_DIR WORK_DIR" >&2; exit 2; } ;;
  nightly | stable) [[ "$built" == - ]] || { echo "usage: $0 - WORK_DIR $channel" >&2; exit 2; } ;;
  *) echo "usage: $0 BUILT_DIR WORK_DIR | $0 - WORK_DIR nightly|stable" >&2; exit 2 ;;
esac
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
channel_commit() { # the commit linux-$channel.json names, verified, or nothing
  curl -fsS --retry 3 --max-time 60 -o "$work/channel.json" \
    "$files/cmux-tui/channels/linux-$channel.json?appimage=${GITHUB_RUN_ID:-0}" || return 0
  python3 "$root/scripts/cmux-next/web-ota-pointer.py" verify --pointer "$work/channel.json" --keys "$keys" \
    --purpose cmux-linux-release | python3 -c 'import json,sys; print(json.load(sys.stdin)["commit"])' || true
}
if [[ "$channel" == feat-cmux-next ]]; then
  commit=$GITHUB_SHA suffix=""
else
  commit=$(channel_commit)
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "::notice::linux-$channel.json names no verifiable commit; no $channel AppImage"; exit 0; }
  suffix="-$channel"
  # Already published for this commit: the channel's update file (written last) names its per-commit copy.
  if curl -fsS --retry 3 --max-time 60 "$files/linux/appimage/$channel/cmux-aarch64.AppImage.zsync?appimage=${GITHUB_RUN_ID:-0}" 2>/dev/null |
    head -c 4096 | grep -aqE "^URL: $files/cmux-tui/$commit/cmux-[^/]*$suffix-aarch64\.AppImage\s*$"; then
    echo "AppImage channel $channel is at $commit already" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
    exit 0
  fi
fi
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

curl -fsS --retry 3 --max-time 60 -o "$work/release.json" "$files/cmux-tui/$commit/release.json?appimage=$GITHUB_RUN_ID"
version=$(python3 -c 'import base64,json,sys; print(json.loads(base64.b64decode(json.load(open(sys.argv[1]))["payload"]))["version"])' "$work/release.json")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]{14}\.[0-9a-f]{12}$ ]] || { echo "::error::bad release version $version"; exit 1; }

if [[ "$built" == - ]]; then # the release file's own musl binaries; appdir checks each sha256
  built="$work/built"
  mkdir -p "$built"
  while read -r url dest; do
    curl -fsSL --retry 3 --max-time 600 -o "$dest" "$url"
  done < <(python3 - "$work/release.json" "$built" <<'PY'
import base64, json, os, sys
targets = json.loads(base64.b64decode(json.load(open(sys.argv[1]))["payload"]))["targets"]
for target in ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl"):
    for name, entry in targets[target].items():
        if name not in ("deb", "rpm") and entry["url"].startswith("https://files.cmux.com/"):
            print(entry["url"], os.path.join(sys.argv[2], os.path.basename(entry["url"])))
PY
  )
fi

mkdir -p "$work/out"
for arch in x86_64 aarch64; do
  target=${TARGET[$arch]}
  curl -fsSL --retry 3 --max-time 120 -o "$work/runtime-$arch" \
    "https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME_TAG/runtime-$arch"
  name="cmux-$version$suffix-$arch.AppImage"
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
  (cd "$work/out" && zsyncmake -u "$files/cmux-tui/$commit/$name" -o "cmux-$arch.AppImage.zsync" "$name" >/dev/null)
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
  name="cmux-$version$suffix-$arch.AppImage"
  for f in "$name" "$name.asc"; do
    [[ -f "$work/out/$f" ]] || continue
    rc=0
    upload "$work/out/$f" "cmux-tui/$commit/$f" "$immutable" --write-once || rc=$?
    # An earlier attempt of this commit wrote it: the build is reproducible, so the bytes must match.
    if [[ $rc == 9 ]]; then
      curl -fsS --retry 3 --max-time 600 -o "$work/published" "$files/cmux-tui/$commit/$f?appimage=$GITHUB_RUN_ID"
      cmp -s "$work/published" "$work/out/$f" || [[ $f == *.asc ]] || {
        echo "::error::cmux-tui/$commit/$f is already published with other bytes"; exit 1; }
    elif [[ $rc != 0 ]]; then
      exit "$rc"
    fi
  done
  echo "AppImage ($arch) -> $files/cmux-tui/$commit/$name" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
done

# Move the channel only to the commit the Linux release channel names now.
named=$(channel_commit)
if [[ "$named" != "$commit" ]]; then
  echo "::notice::linux-$channel.json names ${named:-nothing verifiable}, not $commit; the AppImage channel stays"
  exit 0
fi
for arch in x86_64 aarch64; do
  name="cmux-$version$suffix-$arch.AppImage"
  stable="linux/appimage/$channel/cmux-$arch.AppImage"
  upload "$work/out/$name" "$stable" "$index"
  [[ -f "$work/out/$name.asc" ]] && upload "$work/out/$name.asc" "$stable.asc" "$index"
  upload "$work/out/cmux-$arch.AppImage.zsync" "$stable.zsync" "$index"
  echo "AppImage channel $channel ($arch) -> $files/$stable" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
done
