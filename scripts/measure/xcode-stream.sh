#!/usr/bin/env bash
# Stream this Mac's installed Xcode (the pool pin, iOS and macOS platforms only) as a gzip -1 tar over plain TCP
# to a fleet Linux host on the tailnet that listens with `nc -l PORT > xcode.tgz`, for a fleet pool job that needs
# the toolchain off a Mac. Prints XCODE_STREAM lines (bytes, seconds, MB/s).
#   cmux-ci run --class exclusive --measurement --label measure --label xcode-27.2 \
#     --script scripts/measure/xcode-stream.sh --ref SHA --arg dest=100.x.y.z:8899 [--arg xcode=27.2] --timeout 7200
set -euo pipefail
dest="" ver="27.2"
for a in "$@"; do case "$a" in dest=*) dest=${a#dest=} ;; xcode=*) ver=${a#xcode=} ;; esac; done
[ -n "$dest" ] || { echo "usage: xcode-stream.sh dest=HOST:PORT [xcode=VER]" >&2; exit 2; }
host=${dest%:*} port=${dest##*:}
app=""
for c in "/Applications/Xcode_$ver.app" "/Applications/Xcode-$ver.app" /Applications/Xcode.app; do
  [ -d "$c" ] && grep -q "<string>$ver" "$c/Contents/version.plist" 2>/dev/null && { app=$c; break; }
done
[ -n "$app" ] || { echo "XCODE_STREAM no Xcode $ver in /Applications" >&2; ls -d /Applications/Xcode* >&2; exit 3; }
echo "XCODE_STREAM app=$app version=$(defaults read "$app/Contents/version.plist" CFBundleShortVersionString) build=$(defaults read "$app/Contents/version.plist" ProductBuildVersion)"
nc -z -G 10 "$host" "$port" || { echo "XCODE_STREAM cannot reach $dest" >&2; exit 4; }
sleep 2  # the probe connection ends the listener's first nc; the receiver restarts it
plat="Contents/Developer/Platforms"
excl=()
for p in AppleTVOS AppleTVSimulator WatchOS WatchSimulator XROS XRSimulator DriverKit; do
  excl+=(--exclude "${app#/Applications/}/$plat/$p.platform")
done
start=$(date +%s)
bytes=$(tar -C /Applications "${excl[@]+"${excl[@]}"}" -cf - "${app#/Applications/}" | gzip -1 | tee >(nc -w 60 "$host" "$port") | wc -c)
secs=$(( $(date +%s) - start ))
echo "XCODE_STREAM bytes=$bytes seconds=$secs mbps=$(( bytes / 1048576 / (secs > 0 ? secs : 1) ))"
