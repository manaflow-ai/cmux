#!/usr/bin/env bash
# The file listing of a cmux DMG's app bundle, for `cmux-bench bundle --host fleet` (scripts/bench/benches/bundle.py).
# Mounts the DMG read-only, stats every file of the .app (launches nothing) and writes
# artifacts/bundle-size.json: {app, dmg, download_bytes, files: [[path, bytes], ...]}.
#
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/bundle-size.sh \
#     --ref <sha> --artifact artifacts/bundle-size.json --arg=dmg=https://files-next.cmux.com/nightly-next/<dmg>
set -euo pipefail

dmg=""
for a in "$@"; do
  case "$a" in
    dmg=*) dmg="${a#dmg=}" ;;
    *) echo "bundle-size: unknown argument $a" >&2; exit 2 ;;
  esac
done
[[ -n "$dmg" ]] || { echo "bundle-size: dmg=URL is required" >&2; exit 2; }

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
out="$root/artifacts"
mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/bundle-size.XXXXXX")"
mnt=""
cleanup() {
  if [[ -n "$mnt" ]]; then hdiutil detach "$mnt" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

echo "BUNDLE host $(hostname -s) macOS $(sw_vers -productVersion) dmg $dmg"
curl -fsSL --proto '=https' --retry 3 --retry-all-errors -o "$work/in.dmg" "$dmg" || { echo "BUNDLE download failed"; exit 3; }
mnt="$work/mnt"; mkdir -p "$mnt"
hdiutil attach -nobrowse -readonly -noverify -mountpoint "$mnt" "$work/in.dmg" >/dev/null || { echo "BUNDLE mount failed"; exit 3; }
app="$(find "$mnt" -maxdepth 1 -name '*.app' -type d | head -1)"
[[ -n "$app" ]] || { echo "BUNDLE no .app in the DMG"; exit 3; }

python3 -I - "$app" "$dmg" "$(stat -f %z "$work/in.dmg")" "$out/bundle-size.json" <<'PY'
import json, os, sys
app, dmg, size, dest = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
name = os.path.basename(app)
files = []
for root, _dirs, names in os.walk(app):
    for n in names:
        p = os.path.join(root, n)
        if not os.path.islink(p):
            files.append([name + "/" + os.path.relpath(p, app), os.lstat(p).st_size])
json.dump({"app": "cmux", "dmg": dmg, "download_bytes": size, "files": files}, open(dest, "w"))
print(f"BUNDLE files={len(files)} total={sum(s for _, s in files)} download={size}")
PY
