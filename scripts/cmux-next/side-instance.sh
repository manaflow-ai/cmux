#!/usr/bin/env bash
# A side instance of cmux NEXT: a copy of an installed app with its own bundle id, so it runs next to
# that app with its own data, socket, daemon, settings and web overlay, never touching the original's.
# try-pr.sh opens pull requests in one by default (docs/cmux-next/hot-reload.md, "Try a pull request").
#
#   side-instance.sh make NAME [--from APP] [--label TEXT] [--live-code] [--neutral-shell] [--swap BUILD]
#                         [--customize] [--keep-icon]
#                                   copy APP (default /Applications/cmux NEXT.app, refused when built
#                                   over 7 days ago; --from takes any build) as NAME; remade
#                                   from another app, it clears the state of the identity it replaces.
#                                   --customize: its customize folder is NAME/customize (CMUX_CUSTOMIZE_DIR
#                                   in its LSEnvironment), not the account's ~/.config/cmux/customize, so a
#                                   measurement's extension saves never reach the Mac's own cmux
#                                   --live-code: a live code build's copy watches live-code/ for
#                                   Swift patches (docs/cmux-next/live-code.md)
#                                   --neutral-shell: its terminals show a `$ ` prompt, never the
#                                   account's `user@host` (hot-verify.py's looks, whose shots and
#                                   video a privacy check reads)
#                                   --swap BUILD: the copy runs BUILD's executable and resource bundles
#                                   (swap-binary.sh build REF BUILD: a commit's Swift built as the
#                                   nightly builds it), sealed like any copy, so it launches cold
#                                   Every copy shows the SIM icon (side-icon/AppIcon-Side.icns: a dark tile
#                                   with an amber SIM band) so it is never taken for the real app in the Dock or
#                                   the app switcher; --keep-icon keeps the original's icon (a look of the icon)
#   side-instance.sh launch NAME [--front] [-- ARGS...]
#                                   open it (behind the front app unless --front); records its pid. Where
#                                   `mac-budget` is on PATH (Leo's laptop), an agent's launch first waits for
#                                   room in the Mac's memory budget (SIDE_INSTANCE_BUDGET_WAIT_S, default 1800)
#                                   and is recorded with its owner and a deadline for the budget's reaper
#   side-instance.sh stop NAME      quit it: the pid launch recorded, then what still runs from the copy
#                                   (its terminal daemon and helpers outlive the app otherwise)
#   side-instance.sh env NAME       the exports that point web-overlay.sh at it (eval "$(... env NAME)")
#   side-instance.sh path NAME      the copy's .app
#   side-instance.sh socket NAME    the copy's control socket (CMUX_NEXT_SOCKET_PATH in its LSEnvironment), for
#                                   `cmux --app-socket` and hot-verify.py: NAME/control.sock, or
#                                   cmux-side-<hash>.sock in the per-user TMPDIR when that is too long for a Unix socket
#   side-instance.sh list           the side instances and whether each runs
#   side-instance.sh remove NAME [--keep-sign-in]
#                                   stop it, then delete the folder make wrote and the state the copy
#                                   kept under its build key (App Support, ~/.acpmux, ~/.cmux/chief:
#                                   the bundle id plus --<CMUX_TAG>, BuildIdentity.key) and its bundle
#                                   id (its preferences, caches and web data). --keep-sign-in sets the
#                                   copy's own Cloud session aside (its credentials.json token stores),
#                                   and the next make of NAME puts it back when it makes the same
#                                   identity (the same bundle id): `cmux app try .` remakes its copy each
#                                   try, and the person signs a copy in once, not every try
#
# NAME is lower case letters, digits and dashes (try-pr.sh uses pr-N). The copy is
# $CMUX_SIDE_ROOT/NAME (default ~/Library/Application Support/cmux-side/NAME) and holds:
#   <label>.app     the copy: bundle id <original>.side-NAME-<hash of the root> (a nightly stays a
#                   nightly, so its web overlay works), named LABEL (default "cmux NAME"), updates
#                   off (no feed, no key), no document types or login items, one URL scheme of its
#                   own for sign-in callbacks (cmux links stay with the original), re-sealed ad hoc
#                   with its unrestricted entitlements (no Keychain group)
#   config/         its cmux-next.json and web-dev.json (CMUX_NEXT_CONFIG_FILE in its LSEnvironment), and
#                   its debug-tunables.json (CMUX_NEXT_DEBUG_TUNABLES_FILE) with Live web reload on, so it
#                   loads its web overlay. A copy of cmux NEXT DEV cannot: the app reads web-dev.json
#                   only under DEV's own bundle id (WebDevOverride.isAvailable); a nightly's copy can.
#   web-overlay/    its web overlay (CMUX_WEB_OVERLAY_DIR), web-slot/ its dev server state
#   live-code/      with --live-code, the folder its live code watcher reads (CMUX_LIVE_CODE_DIR)
# A side instance starts signed out with fresh settings; its own sign-in survives a remake through
# remove --keep-sign-in (as `cmux app try .` remakes it), never another build's. Like every cmux build on the Mac, it shares
# two folders with the others: ~/Library/Application Support/cmux/agent-home (the folder a chat
# with no folder runs in) and its Chat Uploads; everything else it keeps under its own bundle id.
set -euo pipefail

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }
die() { echo "side-instance: $*" >&2; exit 1; }

root="${CMUX_SIDE_ROOT:-$HOME/Library/Application Support/cmux-side}"
# Not under a folder macOS guards with a privacy prompt (Documents, Desktop, Downloads): the copy reads
# its config from the root at launch, macOS holds that read until someone answers a Documents-folder
# prompt (TCC kTCCServiceSystemPolicyDocumentsFolder) nobody sees for a copy, and the app hangs before
# its socket exists. Checked on the path as given, before anything touches it.
for guarded in Documents Desktop Downloads; do
  case "$root/" in
    "$HOME/$guarded/"*) die "CMUX_SIDE_ROOT $root is under ~/$guarded, which macOS guards with a privacy prompt: the copy's launch would wait on that prompt (TCC kTCCServiceSystemPolicyDocumentsFolder) and hang. Use a root outside ~/Documents, ~/Desktop and ~/Downloads (the default is ~/Library/Application Support/cmux-side)" ;;
  esac
done
# The physical path (/tmp and /var are links to /private/...): a process started through
# Launch Services reports its executable by its physical path, and the pid checks compare paths.
mkdir -p "$root"; root="$(cd "$root" && pwd -P)"
# SIDE_INSTANCE_PLISTBUDDY: a stand-in for tests (tests/test_side_instance_remake_clears_old_identity.py).
buddy="${SIDE_INSTANCE_PLISTBUDDY:-/usr/libexec/PlistBuddy}"
# shellcheck source=lib/adhoc-seal.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/adhoc-seal.sh"

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
# PlistBuddy takes the rest of a Set or Add command as the value, spaces and # included (checked
# with "cmux PR #35" and an Application Support path), so VALUE needs no quoting.
plist_set() { # FILE KEY VALUE: set a string key, adding it when missing
  "$buddy" -c "Set :$2 $3" "$1" 2>/dev/null || "$buddy" -c "Add :$2 string $3" "$1"
}

# BUNDLE KEY: delete the state one identity of the copy kept. The app's own roots go by its build key
# (an older marker has none, so the bare id is tried too), the system's by the bundle id.
clear_state() {
  local bundle="$1" key="${2:-$1}" path
  [[ "$bundle" == *.side-"$name"-* && "$key" == "$bundle"* ]] || die "unexpected bundle id $bundle or key $key"
  defaults delete "$bundle" >/dev/null 2>&1 || true
  # cmux/builds: the same roots of a build from before NEXT's own folder (cmux-next/builds).
  for path in "$HOME/Library/Application Support/cmux-next/builds/$key" "$HOME/.acpmux/builds/$key" \
    "$HOME/Library/Application Support/cmux/builds/$key" "$HOME/.cmux/chief/$key" "$HOME/.cmux/chief/$key@"* \
    "$HOME/Library/Application Support/cmux-next/builds/$bundle" "$HOME/.acpmux/builds/$bundle" \
    "$HOME/Library/Application Support/cmux/builds/$bundle" \
    "$HOME/.cmux/chief/$bundle" "$HOME/.cmux/chief/$bundle@"* "$HOME/Library/Preferences/$bundle.plist" \
    "$HOME/Library/Caches/$bundle" "$HOME/Library/HTTPStorages/$bundle" "$HOME/Library/WebKit/$bundle" \
    "$HOME/Library/Saved Application State/$bundle.savedState" "$HOME/Library/Application Support/$bundle" \
    "$HOME/Library/Application Support/cmux-next/$bundle" "$HOME/Library/Application Support/cmux/$bundle"; do
    if [[ -e "$path" ]]; then rm -rf "$path"; fi
  done
}

# A copy's own Cloud session set aside by `remove NAME --keep-sign-in` until the next make of NAME: outside
# $dir, which remove deletes. Only the copy's own file token stores (an ad hoc copy has no Keychain group,
# so the app keeps its session there: CmuxAuthRuntime FallbackTokenStore), never another build's: a copy
# never reuses the NIGHTLY's session (skills/cmux-dev-workflow/references/dev-build-spaces.md).
kept="$root/.kept-sign-in/$name"
# BUNDLE: set the identity's credentials.json files aside in $kept, with the bundle id they belong to.
keep_sign_in() {
  local bundle="$1" base rel file
  [[ "$bundle" == *.side-"$name"-* ]] || die "unexpected bundle id $bundle"
  rm -rf "$kept"
  for base in "$HOME/Library/Application Support/cmux-next/$bundle" "$HOME/Library/Application Support/cmux/$bundle"; do
    [[ -d "$base" ]] || continue
    while IFS= read -r -d '' file; do
      rel="${file#"$HOME/"}"
      (umask 077; mkdir -p "$kept/files/$(dirname "$rel")")
      cp -p "$file" "$kept/files/$rel"
    done < <(find "$base" -name credentials.json -type f -print0)
  done
  if [[ -d "$kept/files" ]]; then
    chmod 700 "$root/.kept-sign-in" "$kept"
    printf '%s\n' "$bundle" >"$kept/bundle"
    echo "$name: kept its sign-in for its next make"
  fi
}
# BUNDLE: put a kept session back when it belongs to BUNDLE; a kept session never goes to another identity.
restore_sign_in() {
  local bundle="$1" file rel
  [[ -f "$kept/bundle" ]] || { rm -rf "$kept"; return 0; }
  if [[ "$(cat "$kept/bundle")" == "$bundle" ]]; then
    while IFS= read -r -d '' file; do
      rel="${file#"$kept/files/"}"
      (umask 077; mkdir -p "$HOME/$(dirname "$rel")")
      cp -p "$file" "$HOME/$rel"
    done < <(find "$kept/files" -type f -print0)
    echo "$name: signed in as before (its own session, kept from its last copy)"
  fi
  rm -rf "$kept"
}

case "$cmd" in
  make)
    # SIDE_INSTANCE_DEFAULT_APP: a stand-in for tests (tests/test_side_instance_stale_default.py).
    from="${SIDE_INSTANCE_DEFAULT_APP:-/Applications/cmux NEXT.app}" label="cmux $name" live="" neutral="" swap="" own_customize="" keep_icon=""
    chosen=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --from) [[ $# -ge 2 ]] || usage 1; from="${2%/}"; chosen=1; shift 2 ;;
        --label) [[ $# -ge 2 ]] || usage 1; label="$2"; shift 2 ;;
        --live-code) live=1; shift ;;
        --neutral-shell) neutral=1; shift ;;
        --customize) own_customize=1; shift ;;
        --keep-icon) keep_icon=1; shift ;;
        --swap) [[ $# -ge 2 ]] || usage 1; swap="$2"; shift 2 ;;
        *) usage 1 ;;
      esac
    done
    [[ -f "$from/Contents/Info.plist" ]] || die "no app at $from"
    # The default app is whatever someone once installed: a fleet Mac's /Applications/cmux NEXT.app was a Safari
    # download of a 2026-10-28 build that nothing updates, and each copy of it read inside ~/Downloads at launch
    # (before the LAUNCH-NO-TCC-PROMPTS fixes of 2026-10-30, #28820), so every new side instance put macOS's
    # Downloads prompt on an unattended screen (cmux20, 2026-11-18). Named with --from, any build is copied (an
    # older one is how a before look is taken).
    if [[ -z "$chosen" && -n "$(find "$from/Contents/Info.plist" -mtime +7 2>/dev/null)" ]]; then
      die "$from was built over 7 days ago, and a copy runs that old code; install a current build there, or name the app with --from (/Applications/cmux NIGHTLY.app, or an older one on purpose)"
    fi
    [[ "$label" =~ ^[A-Za-z0-9\ \#._-]+$ ]] || die "the label takes letters, digits, spaces and # . _ -"
    old_bundle="" old_key=""
    if [[ -f "$marker" ]]; then
      # Its daemon and helpers outlive the app and use the state a new identity clears.
      if running || [[ -n "$(copy_pids)" ]]; then die "$name is running; side-instance.sh stop $name first"; fi
      # The identity this make replaces: a copy remade from another app (a nightly, then a rebuild's
      # DEV build) gets another bundle id or key, and the old one's state would be left behind.
      old_bundle="$(sed -n 's/^bundle=//p' "$marker")" old_key="$(sed -n 's/^key=//p' "$marker")"
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
    # A control socket at a path this script names (LaunchIdentity reads CMUX_NEXT_SOCKET_PATH), so a driver
    # (hot-verify.py, `cmux --app-socket`) finds the copy without reading its process's open files.
    # A Unix socket path is at most 104 bytes on macOS (LC_ALL=C: ${#} counts bytes). Past that, the user's own
    # temp folder (launchd's per-user TMPDIR, mode 0700), never shared /tmp where another user could plant it.
    sock="$dir/control.sock"
    if (( $(LC_ALL=C; printf %s "$sock" | wc -c) > 100 )); then
      private="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)}"
      [[ -n "$private" && -d "$private" ]] || die "no per-user temp folder (TMPDIR) for $name's control socket"
      sock="${private%/}/cmux-side-$(printf %s "$dir" | shasum | cut -c1-12).sock"
      (( $(printf %s "$sock" | wc -c) <= 103 )) || die "$name's control socket path is too long: $sock"
    fi
    plist_set "$plist" LSEnvironment:CMUX_NEXT_SOCKET_PATH "$sock"
    # Chromium's mock keychain (CEFSwitches): the copy has no Keychain group, so the real one only asks for the
    # login keychain's password ("cmux NAME wants to use the ... keychain") on a host where it is locked, a fleet
    # mini's, and the dialog covers every shot.
    plist_set "$plist" LSEnvironment:CMUX_MOCK_KEYCHAIN 1
    # Live web reload (Debug Settings, webDev.override) on in its own tunables file, kept with any
    # other tunable set there; without it the app ignores web-dev.json and shows the bundled pages.
    python3 - "$dir/config/debug-tunables.json" <<'PY'
import json, os, sys
p = sys.argv[1]
try: data = json.load(open(p)) if os.path.exists(p) else {}
except ValueError: data = {}
if not isinstance(data, dict) or not isinstance(data.get("values"), dict): data = {"version": 1, "values": {}}
data.setdefault("version", 1); data["values"]["webDev.override"] = True
json.dump(data, open(p, "w"), indent=2)
PY
    plist_set "$plist" LSEnvironment:CMUX_NEXT_DEBUG_TUNABLES_FILE "$dir/config/debug-tunables.json"
    # A live code build's watcher reads this folder (a patch already there when it starts is never
    # loaded); any other build ignores it.
    if [[ -n "$live" ]]; then
      mkdir -p "$dir/live-code"
      plist_set "$plist" LSEnvironment:CMUX_LIVE_CODE_DIR "$dir/live-code"
    fi
    # Its own customize folder (the daemon reads CMUX_CUSTOMIZE_DIR, cmux-tui-core apps/catalog.rs).
    if [[ -n "$own_customize" ]]; then
      mkdir -p "$dir/customize"
      plist_set "$plist" LSEnvironment:CMUX_CUSTOMIZE_DIR "$dir/customize"
    fi
    # A neutral shell: zsh's default prompt `%n@%m %1~ %#` reads "cmux@cmux23 ~ %" on a fleet mini, and a
    # look's privacy check withholds every shot and the video that shows it. The app points its terminals'
    # zsh at the folder CMUX_CAPTURE_SHELL_HOME names (ZDOTDIR, AppEnvironment.terminalEnvironment), the same
    # hook PR capture slots use (cmuxterm-hq build-fleet/capture-host); the files read no other file.
    rm -rf "$dir/shell-home"
    if [[ -n "$neutral" ]]; then
      mkdir -p "$dir/shell-home"
      printf '%s\n' "# side-instance.sh --neutral-shell: present so zsh never reads the account's ~/.zshenv." \
        >"$dir/shell-home/.zshenv"
      printf '%s\n' "# side-instance.sh --neutral-shell: a prompt with no account or host name." \
        "PROMPT='\$ '" "PS1='\$ '" "RPROMPT=''" "RPS1=''" >"$dir/shell-home/.zshrc"
      plist_set "$plist" LSEnvironment:CMUX_CAPTURE_SHELL_HOME "$dir/shell-home"
    fi
    # Its own icon (Leo, 2026-11-22: "for our 'fake shell offline simulator of the app' type things, maybe we ought
    # to give them different icons?"): the original's icon lives in Assets.car under CFBundleIconName, which macOS
    # prefers, so that key goes and CFBundleIconFile names the SIM icns copied into Resources. The seal below covers it.
    if [[ -z "$keep_icon" ]]; then
      icon="$(dirname "${BASH_SOURCE[0]}")/side-icon/AppIcon-Side.icns"
      if [[ -f "$icon" ]]; then
        mkdir -p "$app/Contents/Resources"
        cp "$icon" "$app/Contents/Resources/AppIcon-Side.icns"
        "$buddy" -c "Delete :CFBundleIconName" "$plist" 2>/dev/null || true
        plist_set "$plist" CFBundleIconFile AppIcon-Side
      else
        echo "side-instance: no SIM icon at $icon, so $name keeps the original's icon" >&2
      fi
    fi
    # --swap: another build's executable and resource bundles in place of the copy's (swap-binary.sh place), before
    # the seal, which covers them too.
    if [[ -n "$swap" ]]; then
      "$(dirname "${BASH_SOURCE[0]}")/swap-binary.sh" place "$app" "$swap" || die "the swap into $name failed"
    fi
    # The seal covers Info.plist (and a swapped binary): re-signed ad hoc, as every copy that has to launch is
    # (lib/adhoc-seal.sh), with the original's unrestricted entitlements only: the copy starts signed out.
    entitlements="$dir/entitlements.plist"
    cmux_adhoc_seal "$app" "$from" "$entitlements" || die "the re-sealed copy does not verify"
    # Launch Services learns the new bundle id now, so the first open finds it.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" 2>/dev/null || true
    version="$("$buddy" -c "Print :CFBundleVersion" "$from/Contents/Info.plist" 2>/dev/null || true)"
    # The key the app names its state roots by (BuildIdentity.key, CmuxNextCompat): the bundle id,
    # plus --<tag> when the bundle ships a CMUX_TAG (cmux NEXT ships cmux-next) other than the
    # tag its id ends in. The id here is already a path component, so no hash is added.
    shipped_tag="$("$buddy" -c "Print :LSEnvironment:CMUX_TAG" "$plist" 2>/dev/null || true)"
    key="$(python3 - "$bundle" "$shipped_tag" <<'PY'
import re, sys
bundle, shipped = sys.argv[1:]
def slug(raw):
    s = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")
    return s or None
suffix = None
for prefix in ("com.cmuxterm.app.nightly", "com.cmuxterm.app.staging", "com.cmuxterm.app.debug", "com.cmuxterm.app.rc", "com.cmuxterm.app"):
    if bundle == prefix: break
    if bundle.startswith(prefix + "."): suffix = bundle[len(prefix) + 1:]; break
tag, own = slug(shipped), suffix and slug(suffix)
print(bundle + ("--" + tag if tag and tag != own else ""))
PY
)"
    printf 'app=%s\nbundle=%s\nkey=%s\nfrom=%s\nversion=%s\nlive=%s\nsocket=%s\n' "$app" "$bundle" "$key" "$from" "$version" "$live" "$sock" >"$marker"
    # The replaced identity's state goes once the new copy is in place (none of its processes run:
    # make refuses while the copy runs, and stop ends what ran from it).
    if [[ -n "$old_bundle" && ( "$old_bundle" != "$bundle" || "${old_key:-$old_bundle}" != "$key" ) ]]; then
      clear_state "$old_bundle" "$old_key"
      echo "$name: cleared the state of its earlier identity $old_bundle"
    fi
    restore_sign_in "$bundle"
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
    # On a Mac with a memory budget for agents' apps (leo-workspace tools/mac_budget.py, linked as mac-budget on
    # Leo's laptop), an agent's copy waits its turn while agents already hold the budget or the Mac is short of
    # memory, and is recorded with its owner and a deadline so the budget's reaper quits it once its owner ends.
    # A Mac without it, and a person's own shell, launch at once. Leo, 2026-11-22, after three agent copies ran his
    # laptop out of memory: "you guys simply need to be less stupid about [his laptop]".
    budget="$(command -v mac-budget 2>/dev/null || true)"
    if [[ -n "$budget" ]]; then
      "$budget" admit --kind side --name "$name" --wait "${SIDE_INSTANCE_BUDGET_WAIT_S:-1800}" --holder-pid $$ \
        || die "$name did not start: the Mac's memory budget for agent apps stayed full (mac-budget status names who holds it)"
    fi
    # -n: a new process even when Launch Services still maps the id elsewhere; -g: behind the front app.
    open_args=(-n); [[ -z "$front" ]] && open_args+=(-g)
    open "${open_args[@]}" "$app" ${args[@]+--args "${args[@]}"}
    exe="$app/Contents/MacOS/$("$buddy" -c "Print :CFBundleExecutable" "$app/Contents/Info.plist")"
    launched=""
    # The newest process whose executable is exactly the copy's (a plain comparison: the path holds
    # spaces and #). Up to 30 s: a first launch waits on the system's scan of the new bundle. It is
    # only recorded here; stop signals the pid recorded in $dir/pid, never a fresh lookup.
    for _ in $(seq 1 300); do
      launched="$(ps -axo pid=,comm= | awk -v e="$exe" '{ p = $1; sub(/^ *[0-9]+ /, ""); if ($0 == e) last = p } END { if (last) print last }')"
      [[ -n "$launched" ]] && break
      /bin/sleep 0.1
    done
    [[ -n "$launched" ]] || die "$name did not start"
    echo "$launched" >"$dir/pid"
    if [[ -n "$budget" ]]; then
      "$budget" record --name "$name" --kind side --app "$app" --pid "$launched" \
        --stop-argv "[\"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")\", \"stop\", \"$name\"]" \
        --stop-env "{\"CMUX_SIDE_ROOT\": \"$root\"}" || true
    fi
    echo "$name: pid $launched"
    ;;
  stop)
    [[ -f "$marker" ]] || { echo "$name is not running"; exit 0; }
    if running; then
      recorded="$(pid_of)"
      kill -TERM "$recorded" 2>/dev/null || true
      for _ in $(seq 1 150); do kill -0 "$recorded" 2>/dev/null || break; /bin/sleep 0.2; done
      kill -0 "$recorded" 2>/dev/null && die "$name (pid $recorded) is still running after 30 s"
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
    if command -v mac-budget >/dev/null 2>&1; then mac-budget release --name "$name" || true; fi
    echo "$name stopped"
    ;;
  env)
    app_of >/dev/null
    printf 'export CMUX_NEXT_CONFIG_FILE=%q CMUX_WEB_OVERLAY_DIR=%q CMUX_WEB_SLOT_STATE_DIR=%q\n' \
      "$dir/config/cmux-next.json" "$dir/web-overlay" "$dir/web-slot"
    ;;
  socket)
    app_of >/dev/null
    sock="$(sed -n 's/^socket=//p' "$marker")"
    [[ -n "$sock" ]] || die "$name was made before side instances named their socket: side-instance.sh make $name again"
    echo "$sock"
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
    keep=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --keep-sign-in) keep=1; shift ;;
        *) usage 1 ;;
      esac
    done
    app_of >/dev/null
    "$0" stop "$name"
    if [[ -n "$keep" ]]; then keep_sign_in "$(sed -n 's/^bundle=//p' "$marker")"; else rm -rf "$kept"; fi
    clear_state "$(sed -n 's/^bundle=//p' "$marker")" "$(sed -n 's/^key=//p' "$marker")"
    rm -rf "$dir"
    echo "$name removed"
    ;;
  *) usage 1 ;;
esac
