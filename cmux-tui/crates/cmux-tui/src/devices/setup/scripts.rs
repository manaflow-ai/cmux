//! The remote scripts `cmux device setup|start` runs: fixed text; data goes on stdin.

use super::*;

/// What the target is: OS, CPU (`uname -m`), user, who is at the screen, the installed NIGHTLY build, whether it
/// runs: its control socket answers the bundled CLI (a socket connect; nothing lists processes).
pub(super) const PROBE: &str = r#"os=$(uname -s); echo "os=$os"; echo "uid=$(id -u)"; echo "user=$(id -un)"
[ "$os" = Darwin ] || exit 0
echo "arch=$(uname -m)"
echo "console=$(stat -f%Su /dev/console 2>/dev/null)"
echo "version=$(defaults read '/Applications/cmux NIGHTLY.app/Contents/Info' CFBundleVersion 2>/dev/null)"
case "$('/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux' version --json 2>/dev/null)" in *'"app_error":null'*) echo running=1 ;; *) echo running=0 ;; esac"#;

/// Installs a NIGHTLY DMG. Stdin: the URL, its length, the Team ID, one per line. Refuses when
/// the app runs (checked again before the swap); everything temporary is under one mktemp -d.
pub(super) const INSTALL: &str = r#"set -u
APP='/Applications/cmux NIGHTLY.app'
fail() { echo "error=$1"; exit 1; }
IFS= read -r url; IFS= read -r length; IFS= read -r team
case "$url" in
  https://files-next.cmux.com/nightly-next/*.dmg|https://github.com/manaflow-ai/cmux/releases/download/nightly-next/*.dmg) ;;
  *) fail 'the DMG is not a nightly-next download' ;;
esac
case "$length" in ''|*[!0-9]*) fail 'the feed length is not a number' ;; esac
case "$team" in ''|*[!A-Z0-9]*) fail 'the Team ID is not one' ;; esac
running() { case "$("$APP/Contents/Resources/bin/cmux" version --json 2>/dev/null)" in *'"app_error":null'*) return 0 ;; esac; return 1; }
running && fail 'cmux NIGHTLY is running; it is never replaced while it runs'
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmux-nightly.XXXXXX") || fail 'mktemp failed'
mnt="$tmp/mnt"; new=''
cleanup() { hdiutil detach -quiet "$mnt" >/dev/null 2>&1; [ -n "$new" ] && rm -rf "$new"; rm -rf "$tmp"; }
trap cleanup EXIT
curl -fsSL --proto '=https' --max-time 900 -o "$tmp/app.dmg" -- "$url" || fail 'the download failed'
size=$(stat -f%z "$tmp/app.dmg")
[ "$size" = "$length" ] || fail "downloaded $size bytes, the feed says $length"
mkdir "$mnt" || fail 'mkdir failed'
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$tmp/app.dmg" >/dev/null 2>&1 || fail 'hdiutil attach failed'
src=''
for candidate in "$mnt"/*.app; do [ -d "$candidate" ] && { src=$candidate; break; }; done
[ -n "$src" ] || fail 'the DMG holds no app'
[ "$(defaults read "$src/Contents/Info" CFBundleIdentifier 2>/dev/null)" = com.cmuxterm.app.nightly ] || fail 'the DMG app is not cmux NIGHTLY'
codesign --verify --deep --strict "$src" >/dev/null 2>&1 || fail 'codesign --verify --deep --strict refused it'
spctl -a -t exec "$src" >/dev/null 2>&1 || fail 'Gatekeeper (spctl -a -t exec) refused it'
got=$(codesign -dv --verbose=2 "$src" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[ "$got" = "$team" ] || fail "its Team ID $got is not $team"
new="/Applications/.cmux NIGHTLY.app.new.$$"
ditto "$src" "$new" || fail 'ditto into /Applications failed'
running && fail 'cmux NIGHTLY started meanwhile; it is never replaced while it runs'
if [ -d "$APP" ]; then
  old="/Applications/.cmux NIGHTLY.app.old.$$"
  mv "$APP" "$old" || fail 'cannot move the old app aside'
  mv "$new" "$APP" || { mv "$old" "$APP"; fail 'cannot move the new app in'; }
  rm -rf "$old"
else
  mv "$new" "$APP" || fail 'cannot move the new app in'
fi
new=''
echo "installed=$(defaults read "$APP/Contents/Info" CFBundleVersion 2>/dev/null)""#;

/// Writes the keepalive LaunchAgent (its content on stdin) when it differs, and loads it when
/// this user has the GUI session; else it loads at the next login.
pub(super) const KEEPALIVE: &str = r#"set -u
label=com.cmuxterm.app.nightly.keepalive
dir="$HOME/Library/LaunchAgents"; f="$dir/$label.plist"
mkdir -p "$dir" || { echo 'error=cannot make ~/Library/LaunchAgents'; exit 1; }
tmp=$(mktemp "$dir/.keepalive.XXXXXX") || { echo 'error=mktemp failed'; exit 1; }
cat > "$tmp"
if [ -f "$f" ] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; file=same; else mv "$tmp" "$f" || { rm -f "$tmp"; echo 'error=cannot write the plist'; exit 1; }; file=written; fi
echo "file=$file"
uid=$(id -u)
if [ "$(stat -f%Su /dev/console 2>/dev/null)" != "$(id -un)" ]; then echo load=next-login; exit 0; fi
if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
  if [ "$file" = same ]; then echo load=loaded; exit 0; fi
  launchctl bootout "gui/$uid/$label" >/dev/null 2>&1
fi
if launchctl bootstrap "gui/$uid" "$f" >/dev/null 2>&1; then echo load=bootstrapped; else echo load=failed; fi"#;

/// [`KEEPALIVE`] without writing: whether the file there is this content (stdin).
pub(super) const KEEPALIVE_CHECK: &str = r#"f="$HOME/Library/LaunchAgents/com.cmuxterm.app.nightly.keepalive.plist"
if [ ! -f "$f" ]; then echo file=missing; elif cmp -s - "$f"; then echo file=same; else echo file=differs; fi"#;

/// Up to 30 s for the app's control socket: `ready=1` once the bundled CLI's `version --json`
/// reads the app with no error, else `ready=0`.
macro_rules! ready_wait {
    () => {
        r#"i=0
while [ $i -lt 30 ]; do
  case "$("$CLI" version --json 2>/dev/null)" in *'"app_error":null'*) echo ready=1; exit 0 ;; esac
  i=$((i+1)); sleep 1
done
echo ready=0"#
    };
}

/// Starts NIGHTLY in this user's GUI session, then waits up to 30 s for its control socket
/// (the bundled CLI's `version --json` reads the app with no error).
pub(super) const START: &str = concat!(
    r#"APP='/Applications/cmux NIGHTLY.app'; CLI="$APP/Contents/Resources/bin/cmux"
[ -d "$APP" ] || { echo 'error=cmux NIGHTLY is not installed'; exit 1; }
launchctl asuser "$(id -u)" open -g -j -a "$APP" >/dev/null 2>&1 || { echo 'error=open failed'; exit 1; }
"#,
    ready_wait!()
);

/// [`START`]'s wait alone, after the target's acpmux opened NIGHTLY (`cmux app launch --on`).
pub(super) const READY: &str = concat!(
    r#"CLI='/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux'
"#,
    ready_wait!()
);

/// Whether the target's app is signed in: the exit code, then what `whoami --json` printed.
pub(super) const WHOAMI: &str = r#"CLI='/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux'
[ -x "$CLI" ] || { echo rc=127; exit 0; }
out=$("$CLI" whoami --json 2>&1); echo "rc=$?"; printf '%s\n' "$out""#;

/// Redeems a sign-in handoff code (on stdin, never argv or env) in the target's app.
pub(super) const REDEEM: &str = r#"CLI='/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux'
out=$("$CLI" auth handoff redeem --json 2>&1); echo "rc=$?"; printf '%s\n' "$out""#;

/// cmux Remote's status on the target (the grants and Share This Mac).
pub(super) const SHARE_STATUS: &str = r#"CLI='/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux'
"$CLI" remote-host status --json 2>&1"#;

/// Opens the System Settings pane of one grant (its name on stdin) on the target's screen.
/// Opening a pane grants nothing.
pub(super) const OPEN_SETTINGS: &str = r#"CLI='/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux'
IFS= read -r grant
case "$grant" in accessibility|screen-recording) ;; *) exit 2 ;; esac
"$CLI" remote-host open-settings "$grant" >/dev/null 2>&1"#;

/// The keepalive LaunchAgent: every 5 minutes (and at login), open NIGHTLY in the background
/// when its control socket does not answer the bundled CLI. It never kills anything.
pub(crate) fn keepalive_plist() -> String {
    let check = "case \"$('/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux' version --json \
                 2&gt;/dev/null)\" in *'\"app_error\":null'*) ;; \
                 *) open -g -j -a '/Applications/cmux NIGHTLY.app' ;; esac";
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>{KEEPALIVE_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/sh</string>
		<string>-c</string>
		<string>{check}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>300</integer>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
"#
    )
}
