#!/usr/bin/env bash
# launch-ready.sh's two sides share one bundle id, and cfprefsd keeps app defaults in the console user's real
# ~/Library/Preferences, so a default one side wrote (cmuxNext.launchSnapshotPath.<session>) reached the other
# side's next launch. side_defaults gives each side its own: load clears the bundle and imports that side's plist,
# save exports it. Stand-ins for plutil and defaults keep one store per bundle id in a file.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/a/x.app/Contents" "$root/b/x.app/Contents"
cat >"$root/bin/plutil" <<'STUB'
#!/usr/bin/env bash
echo com.example.shared
STUB
cat >"$root/bin/defaults" <<'STUB'
#!/usr/bin/env bash
store="$DEFAULTS_STORE/$2"
case "$1" in
  delete) rm -f "$store" ;;
  import) cp "$3" "$store" ;;
  export) if [[ -f "$store" ]]; then cp "$store" "$3"; else : >"$3"; fi ;;
  write) echo "$3=$4" >>"$store" ;;
  read) cat "$store" 2>/dev/null || true ;;
esac
STUB
chmod +x "$root/bin/plutil" "$root/bin/defaults"
export PATH="$root/bin:$PATH" DEFAULTS_STORE="$root/store"
mkdir -p "$DEFAULTS_STORE"

cd "$here/../.."
# shellcheck source=../launch-ready.sh
source "$here/launch-ready.sh"
a="$root/a/x.app" b="$root/b/x.app"

# Side a launches and writes its snapshot path; then side b launches.
side_defaults load "$a" "$root/a/defaults.plist"
defaults write com.example.shared snapshot /a/launch-snapshot.json
side_defaults save "$a" "$root/a/defaults.plist"
side_defaults load "$b" "$root/b/defaults.plist"
got="$(defaults read com.example.shared)"
[[ -z "$got" ]] || { echo "launch-ready defaults: side b's first launch read side a's defaults: $got" >&2; exit 1; }
defaults write com.example.shared snapshot /b/launch-snapshot.json
side_defaults save "$b" "$root/b/defaults.plist"

# Side a's next launch reads its own, not side b's.
side_defaults load "$a" "$root/a/defaults.plist"
got="$(defaults read com.example.shared)"
[[ "$got" == "snapshot=/a/launch-snapshot.json" ]] \
  || { echo "launch-ready defaults: side a's relaunch read '$got', want its own snapshot path" >&2; exit 1; }
echo "launch-ready defaults: each side reads only its own"
