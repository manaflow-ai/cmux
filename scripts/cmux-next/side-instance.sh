#!/usr/bin/env bash
# A side instance of cmux NEXT: a copy of an installed app with its own bundle id, so it runs next to
# that app with its own data, socket, daemon, settings and web overlay, never touching the original's.
# try-pr.sh opens pull requests in one by default (docs/cmux-next/hot-reload.md, "Try a pull request").
#
#   side-instance.sh make NAME [--from APP] [--label TEXT]
#                                   copy APP (default /Applications/cmux NEXT.app) as NAME
#   side-instance.sh launch NAME [--front] [-- ARGS...]
#                                   open it (behind the front app unless --front); records its pid
#   side-instance.sh stop NAME      quit it: the pid launch recorded, then what still runs from the copy
#                                   (its terminal daemon and helpers outlive the app otherwise)
#   side-instance.sh env NAME       the exports that point web-overlay.sh at it (eval "$(... env NAME)")
#   side-instance.sh path NAME      the copy's .app
#   side-instance.sh list           the side instances and whether each runs
#   side-instance.sh remove NAME    stop it, then delete the folder make wrote and the state the copy
#                                   kept under its own bundle id (App Support, ~/.acpmux, ~/.cmux/chief,
#                                   its preferences, caches and web data)
#
# NAME is lower case letters, digits and dashes (try-pr.sh uses pr-N). The copy is
# $CMUX_SIDE_ROOT/NAME (default ~/Library/Application Support/cmux-side/NAME) and holds:
#   <label>.app     the copy: bundle id <original>.side-NAME-<hash of the root> (a nightly stays a
#                   nightly, so its web overlay works), named LABEL (default "cmux NAME"), updates
#                   off (no feed, no key), no document types or login items, one URL scheme of its
#                   own for sign-in callbacks (cmux links stay with the original), re-sealed ad hoc
#                   with its entitlements
#   config/         its cmux-next.json and web-dev.json (CMUX_NEXT_CONFIG_FILE in its LSEnvironment)
#   web-overlay/    its web overlay (CMUX_WEB_OVERLAY_DIR), web-slot/ its dev server state
# A side instance starts signed out with fresh settings; the original's data is never read.
set -euo pipefail

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }
die() { echo "side-instance: $*" >&2; exit 1; }

root="${CMUX_SIDE_ROOT:-$HOME/Library/Application Support/cmux-side}"
buddy=/usr/libexec/PlistBuddy

cmd="${1:-}"; [[ -n "$cmd" ]] || usage 1; shift
[[ "$cmd" == -h || "$cmd" == --help ]] && usage
name=""
if [[ "$cmd" != list ]]; then
  name="${1:-}"; [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || die "NAME must be lower case letters, digits and dashes"
  shift
fi
dir="$root/$name"
marker="$dir/.side-instance"

# The copy's .app, from the marker make wrote.
app_of() { [[ -f "$marker" ]] || die "no side instance $name (side-instance.sh make $name)"; sed -n 's/^app=//p' "$marker"; }
pid_of() { [[ -f "$dir/pid" ]] && cat "$dir/pid" || true; }
# True when the recorded pid is still that copy's process.
running() {
  local pid; pid="$(pid_of)"; [[ -n "$pid" ]] || return 1
  local exe; exe="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
  [[ -n "$exe" && "$exe" == "$(app_of)/Contents/MacOS/"* ]]
}
# Every process running from the copy: the app, its terminal daemon and its helpers.
copy_pids() { local app; app="$(app_of)"; ps -axo pid=,comm= | awk -v p="$app/" 'index($0, p) { print $1 }'; }
plist_set() { # FILE KEY VALUE: set a string key, adding it when missing
  "$buddy" -c "Set :$2 $3" "$1" 2>/dev/null || "$buddy" -c "Add :$2 string $3" "$1"
}

case "$cmd" in
  make)
    from="/Applications/cmux NEXT.app" label="cmux $name"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --from) [[ $# -ge 2 ]] || usage 1; from="${2%/}"; shift 2 ;;
        --label) [[ $# -ge 2 ]] || usage 1; label="$2"; shift 2 ;;
        *) usage 1 ;;
      esac
    done
    [[ -f "$from/Contents/Info.plist" ]] || die "no app at $from"
    [[ "$label" =~ ^[A-Za-z0-9\ \#._-]+$ ]] || die "the label takes letters, digits, spaces and # . _ -"
    if [[ -f "$marker" ]]; then
      if running; then die "$name is running; side-instance.sh stop $name first"; fi
      old="$(app_of)"; if [[ -n "$old" && -d "$old" ]]; then rm -rf "$old"; fi
    elif [[ -e "$dir" ]]; then
      die "$dir exists and is not a side instance"
    fi
    mkdir -p "$dir/config" "$dir/web-overlay" "$dir/web-slot"
    app="$dir/$label.app"
    # A clone on APFS: no extra space until a file changes.
    cp -cR "$from" "$app" 2>/dev/null || { rm -rf "$app"; cp -R "$from" "$app"; }
    plist="$app/Contents/Info.plist"
    original="$("$buddy" -c "Print :CFBundleIdentifier" "$plist")"
    # The root's hash keeps two roots' NAMEs (a measurement's and yours) apart: their data roots
    # follow the bundle id.
    bundle="$original.side-$name-$(printf %s "$root" | shasum | cut -c1-6)"
    scheme="cmux-side-$name-$(printf %s "$root" | shasum | cut -c1-6)"
    plist_set "$plist" CFBundleIdentifier "$bundle"
    plist_set "$plist" CFBundleName "$label"
    plist_set "$plist" CFBundleDisplayName "$label"
    # No updates: the updater stays off without a feed key, so the copy never turns back into the
    # original by updating over itself.
    for key in SUFeedURL SUPublicEDKey CFBundleURLTypes CFBundleDocumentTypes; do
      "$buddy" -c "Delete :$key" "$plist" 2>/dev/null || true
    done
    # Sign-in calls back on a scheme only this copy opens.
    "$buddy" -c "Add :CFBundleURLTypes array" -c "Add :CFBundleURLTypes:0 dict" \
      -c "Add :CFBundleURLTypes:0:CFBundleURLName string $bundle" \
      -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" \
      -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string $scheme" "$plist"
    # Its login items would carry the original's labels.
    rm -rf "$app/Contents/Library/LaunchAgents" "$app/Contents/Library/LaunchDaemons"
    "$buddy" -c "Print :LSEnvironment" "$plist" >/dev/null 2>&1 || "$buddy" -c "Add :LSEnvironment dict" "$plist"
    plist_set "$plist" LSEnvironment:CMUX_NEXT_CONFIG_FILE "$dir/config/cmux-next.json"
    plist_set "$plist" LSEnvironment:CMUX_AUTH_CALLBACK_SCHEME "$scheme"
    # The seal covers Info.plist: re-sign the outer bundle ad hoc, keeping its entitlements (nested
    # code keeps its own signatures), and check it.
    xattr -cr "$app" 2>/dev/null || true
    codesign --force --sign - --timestamp=none --preserve-metadata=entitlements "$app" 2>&1 | grep -v 'replacing existing signature' >&2 || true
    codesign --verify --strict "$app" || die "the re-sealed copy does not verify"
    # Launch Services learns the new bundle id now, so the first open finds it.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" 2>/dev/null || true
    version="$("$buddy" -c "Print :CFBundleVersion" "$from/Contents/Info.plist" 2>/dev/null || true)"
    printf 'app=%s\nbundle=%s\nfrom=%s\nversion=%s\n' "$app" "$bundle" "$from" "$version" >"$marker"
    echo "$name: $app ($bundle)"
    ;;
  launch)
    front="" args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --front) front=1; shift ;;
        --) shift; args=("$@"); break ;;
        *) usage 1 ;;
      esac
    done
    app="$(app_of)"
    if running; then echo "$name already runs (pid $(pid_of))"; exit 0; fi
    # -n: a new process even when Launch Services still maps the id elsewhere; -g: behind the front app.
    open_args=(-n); [[ -z "$front" ]] && open_args+=(-g)
    open "${open_args[@]}" "$app" ${args[@]+--args "${args[@]}"}
    exe="$app/Contents/MacOS/$("$buddy" -c "Print :CFBundleExecutable" "$app/Contents/Info.plist")"
    pid=""
    for _ in $(seq 1 100); do
      pid="$(pgrep -nf "^$exe( |$)" || true)"; [[ -n "$pid" ]] && break
      /bin/sleep 0.1
    done
    [[ -n "$pid" ]] || die "$name did not start"
    echo "$pid" >"$dir/pid"
    echo "$name: pid $pid"
    ;;
  stop)
    [[ -f "$marker" ]] || { echo "$name is not running"; exit 0; }
    if running; then
      pid="$(pid_of)"
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; /bin/sleep 0.2; done
      kill -0 "$pid" 2>/dev/null && die "$name (pid $pid) is still running after 30 s"
    fi
    rm -f "$dir/pid"
    # The daemon and helpers the copy started run from its bundle and outlive it.
    left="$(copy_pids)"
    if [[ -n "$left" ]]; then
      # shellcheck disable=SC2086 # one pid per word
      kill -TERM $left 2>/dev/null || true
      for _ in $(seq 1 75); do [[ -z "$(copy_pids)" ]] && break; /bin/sleep 0.2; done
      if [[ -n "$(copy_pids)" ]]; then die "processes of $name still run: $(copy_pids | tr '\n' ' ')"; fi
    fi
    echo "$name stopped"
    ;;
  env)
    app_of >/dev/null
    printf 'export CMUX_NEXT_CONFIG_FILE=%q CMUX_WEB_OVERLAY_DIR=%q CMUX_WEB_SLOT_STATE_DIR=%q\n' \
      "$dir/config/cmux-next.json" "$dir/web-overlay" "$dir/web-slot"
    ;;
  path)
    app_of
    ;;
  list)
    [[ -d "$root" ]] || exit 0
    for m in "$root"/*/.side-instance; do
      [[ -f "$m" ]] || continue
      name="$(basename "$(dirname "$m")")" dir="$root/$name" marker="$m"
      state=stopped; running && state="running, pid $(pid_of)"
      echo "$name  $(app_of)  ($state)"
    done
    ;;
  remove)
    app_of >/dev/null
    "$0" stop "$name"
    bundle="$(sed -n 's/^bundle=//p' "$marker")"
    # The state the copy kept, all named by its own bundle id (BuildIdentity: the key is the id).
    [[ "$bundle" == *.side-"$name"-* ]] || die "unexpected bundle id $bundle"
    defaults delete "$bundle" >/dev/null 2>&1 || true
    for path in "$HOME/Library/Application Support/cmux/builds/$bundle" "$HOME/.acpmux/builds/$bundle" \
      "$HOME/.cmux/chief/$bundle" "$HOME/.cmux/chief/$bundle@"* "$HOME/Library/Preferences/$bundle.plist" \
      "$HOME/Library/Caches/$bundle" "$HOME/Library/HTTPStorages/$bundle" "$HOME/Library/WebKit/$bundle" \
      "$HOME/Library/Saved Application State/$bundle.savedState"; do
      if [[ -e "$path" ]]; then rm -rf "$path"; fi
    done
    rm -rf "$dir"
    echo "$name removed"
    ;;
  *) usage 1 ;;
esac
