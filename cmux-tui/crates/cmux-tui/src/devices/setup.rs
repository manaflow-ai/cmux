//! `cmux device setup|start` (Leo, 2026-11-14: "i dont wanna open up cmux nightly myself :(
//! agents need to be able to help set up and propagate the app for me :("): install, keep
//! running and start cmux NIGHTLY on a Mac that is already the person's, over the ssh route
//! its acpmux peer (or ssh config Host) gives, with acpmux's [`Remote`].
//!
//! Steps, in order: `reach`, `app`, `login-item`, `start`, `sign-in`, `share`, `agents`. Every remote
//! script is a fixed string; data goes on stdin. Nothing here quits, kills, relaunches or
//! replaces a running app, uses sudo, or turns sharing on: Share This Mac and device access
//! stay a person's click (hq#11046). A credential goes only over the ssh channel's stdin.

use std::process::Stdio;
use std::sync::LazyLock;

use acpmux::cli::hosts::{Remote, RemoteOut, SshRemote};
use regex::Regex;
use serde::Serialize;
use serde_json::{Value, json};

use super::model::{self, Device, Kind, Listing, Sources, Via};

/// The app this sets up, on the target Mac.
pub(crate) const APP: &str = "/Applications/cmux NIGHTLY.app";
/// The NIGHTLY Sparkle feed the asking side reads.
pub(crate) const FEED: &str = "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml";
/// The only places a NIGHTLY DMG may come from (scripts/fuzz/macos-matrix/onboarding/nightly.py).
pub(crate) const DMG_PREFIXES: [&str; 2] = [
    "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/",
    "https://files-next.cmux.com/nightly-next/next/",
];
/// The feed channels a Nightly app is offered: none, `cmux-next-stable`, `cmux-next`. Any other
/// (a Dev ring, Canary) is never installed.
const NIGHTLY_CHANNELS: [Option<&str>; 3] = [None, Some("cmux-next-stable"), Some("cmux-next")];
/// The LaunchAgent that brings a closed NIGHTLY back.
pub(crate) const KEEPALIVE_LABEL: &str = "com.cmuxterm.app.nightly.keepalive";
/// The Team ID cmux releases are signed with (scripts/ci/nightly-next-legacy-identity.sh), used
/// when the asking side has no installed NIGHTLY to read it from (a Linux machine).
const RELEASE_TEAM: &str = "7WLXT3NR37";

// ---------------------------------------------------------------------------------------------
// The feed

/// The NIGHTLY to install: the feed's newest build offered to Nightly apps.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Nightly {
    pub build: u64,
    pub url: String,
    pub length: u64,
}

static ITEM: LazyLock<Option<Regex>> = LazyLock::new(|| Regex::new(r"(?s)<item>.*?</item>").ok());
static VERSION: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>").ok());
static CHANNEL: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"<sparkle:channel>\s*([^<]*?)\s*</sparkle:channel>").ok());
static ENCLOSURE: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(r#"<enclosure\s[^>]*?url="([^"]+\.dmg)"[^>]*?length="(\d+)"[^>]*>"#).ok()
});

/// nightly.py's `pick`: the newest item offered to Nightly apps (never a Dev-ring or Canary
/// build) with a DMG and a length; its DMG must be under [`DMG_PREFIXES`].
pub(crate) fn pick(feed: &str) -> Result<Nightly, String> {
    let (Some(items), Some(version), Some(enclosures), Some(channels)) =
        (ITEM.as_ref(), VERSION.as_ref(), ENCLOSURE.as_ref(), CHANNEL.as_ref())
    else {
        return Err("the feed patterns did not compile".into());
    };
    let best = items
        .find_iter(feed)
        .filter_map(|item| {
            let item = item.as_str();
            let build = version.captures(item)?.get(1)?.as_str().parse::<u64>().ok()?;
            let enclosure = enclosures.captures(item)?;
            let channel = channels.captures(item).and_then(|c| c.get(1)).map(|c| c.as_str());
            if !NIGHTLY_CHANNELS.contains(&channel) {
                return None;
            }
            let url = enclosure.get(1)?.as_str().to_owned();
            let length = enclosure.get(2)?.as_str().parse::<u64>().ok()?;
            Some(Nightly { build, url, length })
        })
        .max_by(|a, b| (a.build, &a.url, a.length).cmp(&(b.build, &b.url, b.length)))
        .ok_or("the NIGHTLY feed has no item with a DMG offered to Nightly apps")?;
    if !allowed_dmg(&best.url) {
        return Err(format!("{} is not a nightly-next download", best.url));
    }
    Ok(best)
}

fn allowed_dmg(url: &str) -> bool {
    DMG_PREFIXES.iter().any(|prefix| url.starts_with(prefix))
        && !url.contains(['\n', '\r', '\'', '"', ' ', '\\'])
}

// ---------------------------------------------------------------------------------------------
// The scripts (fixed text; data on stdin)

/// What the target is: OS, user, who is at the screen, the installed NIGHTLY build, whether it
/// runs: its control socket answers the bundled CLI (a socket connect; nothing lists processes).
const PROBE: &str = r#"os=$(uname -s); echo "os=$os"; echo "uid=$(id -u)"; echo "user=$(id -un)"
[ "$os" = Darwin ] || exit 0
echo "console=$(stat -f%Su /dev/console 2>/dev/null)"
echo "version=$(defaults read '/Applications/cmux NIGHTLY.app/Contents/Info' CFBundleVersion 2>/dev/null)"
case "$('/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux' version --json 2>/dev/null)" in *'"app_error":null'*) echo running=1 ;; *) echo running=0 ;; esac"#;

/// Installs a NIGHTLY DMG. Stdin: the URL, its length, the Team ID, one per line. Refuses when
/// the app runs (checked again before the swap); everything temporary is under one mktemp -d.
const INSTALL: &str = r#"set -u
APP='/Applications/cmux NIGHTLY.app'
fail() { echo "error=$1"; exit 1; }
IFS= read -r url; IFS= read -r length; IFS= read -r team
case "$url" in
  https://files-next.cmux.com/nightly-next/next/*.dmg|https://github.com/manaflow-ai/cmux/releases/download/nightly-next/*.dmg) ;;
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
const KEEPALIVE: &str = r#"set -u
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
const KEEPALIVE_CHECK: &str = r#"f="$HOME/Library/LaunchAgents/com.cmuxterm.app.nightly.keepalive.plist"
if [ ! -f "$f" ]; then echo file=missing; elif cmp -s - "$f"; then echo file=same; else echo file=differs; fi"#;

/// Starts NIGHTLY in this user's GUI session, then waits up to 30 s for its control socket
/// (the bundled CLI's `version --json` reads the app with no error).
const START: &str = r#"APP='/Applications/cmux NIGHTLY.app'; CLI="$APP/Contents/Resources/bin/cmux"
[ -d "$APP" ] || { echo 'error=cmux NIGHTLY is not installed'; exit 1; }
launchctl asuser "$(id -u)" open -g -j -a "$APP" >/dev/null 2>&1 || { echo 'error=open failed'; exit 1; }
i=0
while [ $i -lt 30 ]; do
  case "$("$CLI" version --json 2>/dev/null)" in *'"app_error":null'*) echo ready=1; exit 0 ;; esac
  i=$((i+1)); sleep 1
done
echo ready=0"#;

/// Whether the target's app is signed in: the exit code, then what `whoami --json` printed.
const WHOAMI: &str = r#"CLI='/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux'
[ -x "$CLI" ] || { echo rc=127; exit 0; }
out=$("$CLI" whoami --json 2>&1); echo "rc=$?"; printf '%s\n' "$out""#;

/// Redeems a sign-in handoff code (on stdin, never argv or env) in the target's app.
const REDEEM: &str = r#"CLI='/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux'
out=$("$CLI" auth handoff redeem --json 2>&1); echo "rc=$?"; printf '%s\n' "$out""#;

/// cmux Remote's status on the target (the grants and Share This Mac).
const SHARE_STATUS: &str = r#"CLI='/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux'
"$CLI" remote-host status --json 2>&1"#;

/// Opens the System Settings pane of one grant (its name on stdin) on the target's screen.
/// Opening a pane grants nothing.
const OPEN_SETTINGS: &str = r#"CLI='/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux'
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

// ---------------------------------------------------------------------------------------------
// Steps and their lines

/// A step's outcome.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum StepState {
    Ok,
    Changed,
    Warn,
    Fail,
    Skip,
}

impl StepState {
    fn word(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Changed => "changed",
            Self::Warn => "warn",
            Self::Fail => "fail",
            Self::Skip => "skip",
        }
    }
}

/// One step's line: `{"device","step","state","detail","fix"}` with `--json`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Line {
    pub step: &'static str,
    pub state: StepState,
    pub detail: String,
    pub fix: String,
}

impl Line {
    pub(crate) fn json(&self, device: &str) -> Value {
        json!({"device": device, "step": self.step, "state": self.state,
               "detail": self.detail, "fix": self.fix})
    }

    pub(crate) fn human(&self) -> String {
        let mut text = format!("  {:<10} {:<7} {}", self.step, self.state.word(), self.detail);
        if !self.fix.is_empty() {
            text.push_str(&format!("\n  {:<10} {:<7} fix: {}", "", "", self.fix));
        }
        text
    }
}

/// One device's run.
#[derive(Clone, Debug, Default)]
pub(crate) struct Run {
    pub device: String,
    pub lines: Vec<Line>,
    /// What changed, in the summary's words (`app 1->2`, `login-item`, `started`, `signed in`).
    pub changed: Vec<String>,
}

impl Run {
    pub(crate) fn failed(&self) -> Vec<&'static str> {
        self.lines.iter().filter(|l| l.state == StepState::Fail).map(|l| l.step).collect()
    }

    pub(crate) fn summary(&self) -> String {
        let failed = self.failed();
        let changed = if self.changed.is_empty() {
            "nothing changed".to_owned()
        } else {
            format!("changed {}", self.changed.join(", "))
        };
        let warned = self.lines.iter().filter(|l| l.state == StepState::Warn).count();
        let mut text = format!("{}: {changed}", self.device);
        if warned > 0 {
            text.push_str(&format!(", {warned} to look at"));
        }
        if !failed.is_empty() {
            text.push_str(&format!(", failed: {}", failed.join(", ")));
        }
        text
    }

    pub(crate) fn summary_json(&self) -> Value {
        json!({"device": self.device, "summary": self.summary(), "changed": self.changed,
               "failed": self.failed()})
    }
}

/// What `start` runs and what `setup` runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Mode {
    Setup,
    Start,
}

/// Why a verb of this cmux on the asking side did not answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum AskError {
    /// This cmux has no such verb yet (`auth handoff`, `remote-host agents`).
    Unsupported,
    Failed(String),
}

/// What the asking side does: read the feed, read its own app's Team ID, mint a sign-in code,
/// and read or turn on the account's agents permission.
pub(crate) trait Asking {
    fn feed(&self) -> Result<String, String>;
    /// The Team ID of this machine's installed NIGHTLY, when there is one.
    fn team_id(&self) -> Option<String>;
    /// `cmux auth handoff mint --json`'s code. It never reaches a line or argv.
    fn mint_handoff(&self) -> Result<String, AskError>;
    /// Whether "My agents can turn screen sharing and control on my machines" is on
    /// (`cmux remote-host agents status --json`).
    fn agents_allowed(&self) -> Result<bool, AskError>;
    /// Asks this machine's cmux app to turn it on, `remote.confirm {"action":"allow_agents",
    /// "on":true}`, and gives the app's answer or error ([`allow_answer`] reads it). The app
    /// always asks the person. Only for `--allow-agents`.
    fn allow_agents(&self) -> Result<Value, Value>;
}

/// The account's standing permission, in the words the share helper's setting uses.
pub(crate) const AGENTS_POLICY: &str =
    "My agents can turn screen sharing and control on my machines";

/// The `agents` step: reports the agents permission, and turns it on only with `allow`
/// (`--allow-agents`, or the app's `allow_agents`).
pub(crate) fn share_policy_step(asking: &dyn Asking, allow: bool, dry_run: bool) -> Line {
    if allow && dry_run {
        return agents_line(
            StepState::Skip,
            format!("dry run: would turn on \"{AGENTS_POLICY}\""),
            "",
        );
    }
    if allow {
        return allow_answer(asking.allow_agents());
    }
    match asking.agents_allowed() {
        Ok(true) => agents_line(StepState::Ok, format!("\"{AGENTS_POLICY}\" is on"), ""),
        Ok(false) => agents_line(
            StepState::Ok,
            format!("\"{AGENTS_POLICY}\" is off"),
            "cmux device setup DEVICE --allow-agents",
        ),
        Err(AskError::Unsupported) => {
            agents_line(StepState::Skip, format!("\"{AGENTS_POLICY}\" needs a newer cmux"), "")
        }
        Err(AskError::Failed(why)) => {
            agents_line(StepState::Warn, format!("cannot read \"{AGENTS_POLICY}\": {why}"), "")
        }
    }
}

fn agents_line(state: StepState, detail: String, fix: &str) -> Line {
    Line { step: "agents", state, detail, fix: fix.to_owned() }
}

/// The app's answer to `remote.confirm {"action":"allow_agents","on":true}` as the `agents`
/// line. On: `{"ok":true,"agents_may_share":true}`. The person said no:
/// `{"ok":false,"declined":true}`, a warn. Signed out: `invalid_params`, a warn. An app that
/// has no such action (it answers `invalid_params` "action must be ...") or no
/// `remote.confirm` at all (`method_not_found`) needs a newer cmux. Nothing here is a fail:
/// the Mac is set up either way.
pub(crate) fn allow_answer(answer: Result<Value, Value>) -> Line {
    match answer {
        Ok(value) if value["agents_may_share"].as_bool() == Some(true) => {
            agents_line(StepState::Changed, format!("\"{AGENTS_POLICY}\" is on"), "")
        }
        Ok(value) if value["declined"].as_bool() == Some(true) => agents_line(
            StepState::Warn,
            format!("\"{AGENTS_POLICY}\" stays off: you said no in cmux"),
            "",
        ),
        Ok(value) => agents_line(
            StepState::Warn,
            format!("cmux did not turn on \"{AGENTS_POLICY}\": {value}"),
            "",
        ),
        Err(error) => {
            let code = error["code"].as_str().unwrap_or("");
            let message = error["message"].as_str().unwrap_or("");
            if code == "method_not_found"
                || (code == "invalid_params" && message.starts_with("action must be"))
            {
                agents_line(
                    StepState::Warn,
                    format!("turning on \"{AGENTS_POLICY}\" needs a newer cmux"),
                    "",
                )
            } else if code == "invalid_params" {
                agents_line(
                    StepState::Warn,
                    format!("cannot turn on \"{AGENTS_POLICY}\": sign in to cmux"),
                    "sign in to cmux on this computer",
                )
            } else {
                let why = if message.is_empty() { code } else { message };
                agents_line(
                    StepState::Warn,
                    format!("cannot turn on \"{AGENTS_POLICY}\": {why}"),
                    "open cmux on this computer",
                )
            }
        }
    }
}

/// The target's facts, as [`PROBE`] printed them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Probe {
    os: String,
    user: String,
    console: String,
    version: String,
    running: bool,
}

impl Probe {
    fn parse(text: &str) -> Self {
        let mut probe = Self::default();
        for line in text.lines() {
            let Some((key, value)) = line.split_once('=') else { continue };
            let value = value.trim().to_owned();
            match key.trim() {
                "os" => probe.os = value,
                "user" => probe.user = value,
                "console" => probe.console = value,
                "version" => probe.version = value,
                "running" => probe.running = value == "1",
                _ => {}
            }
        }
        probe
    }

    fn gui(&self) -> bool {
        !self.user.is_empty() && self.console == self.user
    }

    fn build(&self) -> Option<u64> {
        self.version.parse().ok()
    }
}

/// The `key=` value of a script's output.
fn field<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    text.lines().find_map(|line| line.strip_prefix(key)?.strip_prefix('=')).map(str::trim)
}

fn last_line(text: &str) -> String {
    text.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or_default().trim().to_owned()
}

/// What a failed script said: its `error=` line, else its last stderr line.
fn said(out: &RemoteOut) -> String {
    field(&out.stdout, "error").map(str::to_owned).unwrap_or_else(|| {
        let text = last_line(&out.stderr);
        if text.is_empty() { "it exited with an error".into() } else { text }
    })
}

/// Whether a cmux CLI's answer says it does not know the verb (an older cmux).
fn unknown_verb(text: &str) -> bool {
    let text = text.to_ascii_lowercase();
    ["unknown", "unrecognized", "no such command", "not a cmux command"]
        .iter()
        .any(|word| text.contains(word))
}

fn exec(remote: &dyn Remote, script: &str, stdin: Option<&[u8]>) -> RemoteOut {
    remote.exec(script, stdin).unwrap_or_else(|error| RemoteOut {
        ok: false,
        stdout: String::new(),
        stderr: format!("{error:#}"),
    })
}

/// Runs `cmux device setup` (or `start`) on one Mac. `emit` sees each line as it is made.
pub(crate) fn run_device(
    name: &str,
    remote: &dyn Remote,
    asking: &dyn Asking,
    mode: Mode,
    dry_run: bool,
    emit: &mut dyn FnMut(&Line),
) -> Run {
    let mut run = Run { device: name.to_owned(), ..Run::default() };
    let mut push = |run: &mut Run, step, state, detail: String, fix: String| {
        let line = Line { step, state, detail, fix };
        emit(&line);
        run.lines.push(line);
    };

    // 1. reach
    let out = exec(remote, PROBE, None);
    if !out.ok {
        push(
            &mut run,
            "reach",
            StepState::Fail,
            format!("cannot reach {} over ssh: {}", remote.host(), said(&out)),
            format!(
                "check that `ssh {} true` logs in with a key, or add it again: cmux device add {name}",
                remote.host()
            ),
        );
        return run;
    }
    let mut probe = Probe::parse(&out.stdout);
    if probe.os != "Darwin" {
        let os = if probe.os.is_empty() { "an unknown OS".to_owned() } else { probe.os.clone() };
        push(&mut run, "reach", StepState::Skip, format!("not a Mac ({os})"), String::new());
        return run;
    }
    let at_screen = if probe.gui() {
        format!("{} is logged in", probe.user)
    } else if probe.console.is_empty() || probe.console == "root" {
        "nobody is logged in".to_owned()
    } else {
        format!("{} is at the screen", probe.console)
    };
    push(
        &mut run,
        "reach",
        StepState::Ok,
        format!("{} as {}; {at_screen}", remote.host(), probe.user),
        String::new(),
    );

    // 2. app
    if mode == Mode::Setup {
        let (state, detail, fix) = app_step(name, remote, asking, &mut probe, dry_run, &mut run);
        push(&mut run, "app", state, detail, fix);
    }

    // 3. login-item
    let (state, detail, fix) = login_item_step(name, remote, dry_run, &mut run);
    push(&mut run, "login-item", state, detail, fix);

    // 4. start
    let (state, detail, fix) = start_step(name, remote, &mut probe, dry_run, &mut run);
    push(&mut run, "start", state, detail, fix);
    if mode == Mode::Start {
        return run;
    }

    // 5. sign-in, 6. share: they ask the running app.
    if probe.running {
        let (state, detail, fix) = sign_in_step(name, remote, asking, dry_run, &mut run);
        push(&mut run, "sign-in", state, detail, fix);
        let (state, detail, fix) = share_step(name, remote, dry_run);
        push(&mut run, "share", state, detail, fix);
    } else {
        for step in ["sign-in", "share"] {
            push(
                &mut run,
                step,
                StepState::Skip,
                format!("cmux NIGHTLY is not running on {name}"),
                String::new(),
            );
        }
    }
    run
}

type Outcome = (StepState, String, String);

fn app_step(
    name: &str,
    remote: &dyn Remote,
    asking: &dyn Asking,
    probe: &mut Probe,
    dry_run: bool,
    run: &mut Run,
) -> Outcome {
    let installed = probe.build();
    let newest = match asking.feed().and_then(|feed| pick(&feed)) {
        Ok(newest) => newest,
        Err(why) => {
            let state = if installed.is_some() { StepState::Warn } else { StepState::Fail };
            return (state, format!("cannot read the NIGHTLY feed: {why}"), String::new());
        }
    };
    let old = if probe.version.is_empty() { "none".to_owned() } else { probe.version.clone() };
    if installed.is_some_and(|build| build >= newest.build) {
        return (StepState::Ok, format!("NIGHTLY {old} is current"), String::new());
    }
    if probe.running {
        // Never quit, kill, relaunch or replace a running app. No released cmux CLI verb asks
        // the app's updater to check now (`updates.check` is a control-socket method only).
        return (
            StepState::Warn,
            format!("running {old}, Sparkle updates it to {}", newest.build),
            String::new(),
        );
    }
    if dry_run {
        return (
            StepState::Skip,
            format!("dry run: would install NIGHTLY {} (now {old})", newest.build),
            String::new(),
        );
    }
    let team = asking.team_id().unwrap_or_else(|| RELEASE_TEAM.to_owned());
    let stdin = format!("{}\n{}\n{team}\n", newest.url, newest.length);
    let out = exec(remote, INSTALL, Some(stdin.as_bytes()));
    if !out.ok {
        return (
            StepState::Fail,
            format!("installing NIGHTLY {} failed: {}", newest.build, said(&out)),
            format!("install cmux NIGHTLY on {name} by hand, then run this again"),
        );
    }
    let now = field(&out.stdout, "installed").unwrap_or_default().to_owned();
    let now = if now.is_empty() { newest.build.to_string() } else { now };
    probe.version.clone_from(&now);
    run.changed.push(format!("app {old}->{now}"));
    (StepState::Changed, format!("installed NIGHTLY {now} (was {old})"), String::new())
}

fn login_item_step(name: &str, remote: &dyn Remote, dry_run: bool, run: &mut Run) -> Outcome {
    let plist = keepalive_plist();
    if dry_run {
        let out = exec(remote, KEEPALIVE_CHECK, Some(plist.as_bytes()));
        return match field(&out.stdout, "file") {
            Some("same") => {
                (StepState::Ok, "the keepalive LaunchAgent is in place".into(), String::new())
            }
            Some(what) => (
                StepState::Skip,
                format!("dry run: would write the keepalive LaunchAgent (it is {what})"),
                String::new(),
            ),
            None => (
                StepState::Warn,
                format!("cannot read the LaunchAgent: {}", said(&out)),
                String::new(),
            ),
        };
    }
    let out = exec(remote, KEEPALIVE, Some(plist.as_bytes()));
    if !out.ok {
        return (
            StepState::Fail,
            format!("cannot write the keepalive LaunchAgent: {}", said(&out)),
            String::new(),
        );
    }
    let written = field(&out.stdout, "file") == Some("written");
    let load = field(&out.stdout, "load").unwrap_or_default();
    if written {
        run.changed.push("login-item".into());
    }
    let state = if written { StepState::Changed } else { StepState::Ok };
    match load {
        "failed" => (
            StepState::Warn,
            "the keepalive LaunchAgent is written but launchctl did not load it".into(),
            format!("it loads at the next login on {name}"),
        ),
        "next-login" => (
            state,
            format!("the keepalive LaunchAgent loads at the next login on {name}"),
            String::new(),
        ),
        _ => (
            state,
            if written {
                "wrote and loaded the keepalive LaunchAgent (a closed NIGHTLY comes back within 5 min)"
                    .into()
            } else {
                "the keepalive LaunchAgent is in place".into()
            },
            String::new(),
        ),
    }
}

fn start_step(
    name: &str,
    remote: &dyn Remote,
    probe: &mut Probe,
    dry_run: bool,
    run: &mut Run,
) -> Outcome {
    if probe.running {
        return (StepState::Ok, "cmux NIGHTLY is running".into(), String::new());
    }
    if !probe.gui() {
        return (
            StepState::Warn,
            format!("nobody is logged in on {name}; it starts at next login"),
            String::new(),
        );
    }
    if dry_run {
        return (StepState::Skip, "dry run: would start cmux NIGHTLY".into(), String::new());
    }
    let out = exec(remote, START, None);
    if !out.ok {
        return (
            StepState::Fail,
            format!("cannot start cmux NIGHTLY: {}", said(&out)),
            format!("cmux device setup {name}"),
        );
    }
    probe.running = true;
    run.changed.push("started".into());
    if field(&out.stdout, "ready") == Some("1") {
        (StepState::Changed, "started cmux NIGHTLY; it answers".into(), String::new())
    } else {
        (
            StepState::Warn,
            "started cmux NIGHTLY, but it did not answer within 30 s".into(),
            String::new(),
        )
    }
}

/// The sign-in step: asks the target's app whether it is signed in and, when not, hands this
/// side's session over (part 2's `cmux auth handoff mint|redeem`): the code goes only on the
/// ssh channel's stdin.
pub(crate) fn sign_in_step(
    name: &str,
    remote: &dyn Remote,
    asking: &dyn Asking,
    dry_run: bool,
    run: &mut Run,
) -> (StepState, String, String) {
    let newer = || {
        (
            StepState::Warn,
            format!("sign in on {name}: sign-in handoff needs a newer cmux"),
            format!("sign in to cmux on {name}"),
        )
    };
    let out = exec(remote, WHOAMI, None);
    let rc = field(&out.stdout, "rc").unwrap_or("?");
    let answer = out.stdout.lines().skip(1).collect::<Vec<_>>().join("\n");
    if rc == "0" {
        let who = serde_json::from_str::<Value>(&answer)
            .ok()
            .and_then(|v| {
                ["email", "login", "user"].iter().find_map(|k| v[*k].as_str().map(str::to_owned))
            })
            .unwrap_or_else(|| "someone".into());
        return (StepState::Ok, format!("signed in as {who}"), String::new());
    }
    if !answer.contains("not_signed_in") {
        return (
            StepState::Warn,
            format!("cannot ask whether cmux on {name} is signed in: {}", last_line(&answer)),
            String::new(),
        );
    }
    if dry_run {
        return (StepState::Skip, format!("dry run: would sign in on {name}"), String::new());
    }
    let code = match asking.mint_handoff() {
        Ok(code) => code,
        Err(AskError::Unsupported) => return newer(),
        Err(AskError::Failed(why)) => {
            return (
                StepState::Warn,
                format!("sign in on {name}: {why}"),
                "sign in to cmux on this computer first".into(),
            );
        }
    };
    let out = exec(remote, REDEEM, Some(format!("{code}\n").as_bytes()));
    let rc = field(&out.stdout, "rc").unwrap_or("?");
    let answer = out.stdout.lines().skip(1).collect::<Vec<_>>().join("\n");
    if rc == "0" {
        run.changed.push("signed in".into());
        return (StepState::Changed, format!("signed in cmux on {name}"), String::new());
    }
    if rc == "2" || unknown_verb(&answer) {
        return newer();
    }
    (StepState::Warn, format!("sign in on {name}: {}", last_line(&answer)), String::new())
}

/// The grants cmux Remote needs, as `remote-host status` names them and as a person reads them.
const GRANTS: [(&str, &str, &str); 2] = [
    ("accessibility", "accessibility", "Accessibility"),
    ("screen_recording", "screen-recording", "Screen Recording"),
];

fn share_step(name: &str, remote: &dyn Remote, dry_run: bool) -> Outcome {
    let out = exec(remote, SHARE_STATUS, None);
    let status = serde_json::from_str::<Value>(out.stdout.trim()).ok().filter(|_| out.ok);
    let Some(status) = status else {
        return (
            StepState::Warn,
            format!("cannot read cmux Remote on {name}: {}", said(&out)),
            String::new(),
        );
    };
    // `cmux remote-host status --json` prints the daemon's data, maybe in an `{ok, data}` envelope.
    let status =
        if status.get("data").is_some_and(Value::is_object) { &status["data"] } else { &status };
    let host = &status["host"];
    let shared = ["shared", "sharing", "on"]
        .iter()
        .find_map(|key| host["screen"][*key].as_bool())
        .or_else(|| status["screen"]["shared"].as_bool());
    let sharing = match shared {
        Some(true) => "Share This Mac is on",
        Some(false) => "Share This Mac is off",
        None => "Share This Mac: unknown",
    };
    let permissions = &host["permissions"];
    if permissions.is_null() {
        return (
            StepState::Warn,
            format!(
                "{sharing}; cmux Remote did not report its grants ({})",
                status["state"].as_str().unwrap_or("not running")
            ),
            String::new(),
        );
    }
    let missing: Vec<(&str, &str)> = GRANTS
        .iter()
        .filter(|(key, _, _)| permissions[*key].as_bool() != Some(true))
        .map(|(_, arg, title)| (*arg, *title))
        .collect();
    if missing.is_empty() {
        return (
            StepState::Ok,
            format!("{sharing}; Accessibility and Screen Recording are allowed"),
            String::new(),
        );
    }
    let titles = missing.iter().map(|(_, title)| *title).collect::<Vec<_>>().join(" and ");
    if !dry_run {
        for (grant, _) in &missing {
            let _ = exec(remote, OPEN_SETTINGS, Some(format!("{grant}\n").as_bytes()));
        }
    }
    (
        StepState::Warn,
        format!(
            "{sharing}; missing {titles}{}",
            if dry_run { "" } else { " (its System Settings pane is open there)" }
        ),
        format!("on {name}, allow cmux Remote under Privacy & Security > {titles}"),
    )
}

// ---------------------------------------------------------------------------------------------
// Which devices, and their routes

/// The ssh destination of a device: its acpmux peer's `ssh://` URL, else a Host of the ssh
/// config with its name. Err names why there is none.
pub(crate) fn route(device: &Device, sources: &Sources) -> Result<String, String> {
    let peers = sources.peers["peers"].as_array().map(Vec::as_slice).unwrap_or_default();
    for via in &device.via {
        let Via::Peer { name } = via else { continue };
        let url = peers
            .iter()
            .find(|p| p["name"].as_str() == Some(name.as_str()))
            .and_then(|p| p["url"].as_str())
            .unwrap_or_default();
        if url.starts_with("ssh://") {
            return acpmux::peer::ssh_target(url)
                .map(|t| t.destination)
                .map_err(|why| format!("its peer URL is refused: {why}"));
        }
    }
    sources
        .ssh_hosts
        .iter()
        .find(|h| h.alias.eq_ignore_ascii_case(&device.name))
        .map(|h| h.alias.clone())
        .ok_or_else(|| "no ssh route (not an ssh peer, not a Host in your ssh config)".into())
}

/// `--all`: every device with what to do, a route or why it is skipped. Phones, Cloud and
/// joined machines, short-lived pool machines, logins and devices with no ssh route are skipped.
pub(crate) fn select(
    listing: &Listing,
    sources: &Sources,
) -> Vec<(String, Result<String, String>)> {
    listing
        .devices
        .iter()
        .map(|d| {
            let pick = if d.kind == Kind::Phone {
                Err("a phone".to_owned())
            } else if d.via.iter().all(|v| matches!(v, Via::Grant { .. } | Via::Allow { .. })) {
                Err("a login that uses this computer, not a computer of yours".to_owned())
            } else if d.via.iter().all(|v| matches!(v, Via::Joined { .. })) {
                Err("a Cloud or team machine, not one of your Macs".to_owned())
            } else if model::pool_stem(&d.name).is_some() {
                Err("a short-lived pool machine".to_owned())
            } else if let Some(os) = d.os.as_deref().filter(|os| !is_mac(os)) {
                Err(format!("not a Mac ({os})"))
            } else {
                route(d, sources)
            };
            (d.name.clone(), pick)
        })
        .collect()
}

fn is_mac(os: &str) -> bool {
    matches!(os.to_ascii_lowercase().as_str(), "macos" | "darwin" | "mac" | "osx")
}

// ---------------------------------------------------------------------------------------------
// The verbs

/// This machine as the asking side.
struct ThisMachine;

impl Asking for ThisMachine {
    fn feed(&self) -> Result<String, String> {
        http_get(FEED).and_then(|bytes| String::from_utf8(bytes).map_err(|e| e.to_string()))
    }

    fn team_id(&self) -> Option<String> {
        if !cfg!(target_os = "macos") {
            return None;
        }
        let out = cmux_process::Command::new("codesign")
            .args(["-dv", "--verbose=2", APP])
            .stdin(cmux_process::Stdio::null())
            .output()
            .ok()?;
        String::from_utf8_lossy(&out.stderr)
            .lines()
            .find_map(|l| l.strip_prefix("TeamIdentifier="))
            .map(|t| t.trim().to_owned())
            .filter(|t| !t.is_empty() && t.bytes().all(|b| b.is_ascii_alphanumeric()))
    }

    fn mint_handoff(&self) -> Result<String, AskError> {
        let out = super::cmux()
            .map_err(|e| AskError::Failed(e.to_string()))?
            .args(["auth", "handoff", "mint", "--json"])
            .stdin(Stdio::null())
            .output()
            .map_err(|e| AskError::Failed(e.to_string()))?;
        let text = format!(
            "{}\n{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        if !out.status.success() {
            return Err(if out.status.code() == Some(2) || unknown_verb(&text) {
                AskError::Unsupported
            } else {
                AskError::Failed(last_line(&String::from_utf8_lossy(&out.stderr)))
            });
        }
        serde_json::from_slice::<Value>(&out.stdout)
            .ok()
            .and_then(|v| v["code"].as_str().map(str::to_owned))
            .filter(|code| !code.is_empty() && !code.contains(['\n', '\r']))
            .ok_or_else(|| AskError::Failed("the sign-in handoff printed no code".into()))
    }

    fn agents_allowed(&self) -> Result<bool, AskError> {
        let value = local_json(&["remote-host", "agents", "status", "--json"])?;
        let value = if value["data"].is_object() { &value["data"] } else { &value };
        ["allowed", "on", "enabled"].iter().find_map(|key| value[*key].as_bool()).ok_or_else(|| {
            AskError::Failed("`cmux remote-host agents status` said no state".into())
        })
    }

    #[cfg(unix)]
    fn allow_agents(&self) -> Result<Value, Value> {
        crate::cli::confirm_allow_agents()
    }

    #[cfg(not(unix))]
    fn allow_agents(&self) -> Result<Value, Value> {
        Err(json!({"code": "unavailable", "message": "the cmux app runs on a Mac"}))
    }
}

/// `cmux <args>` on this machine as JSON (stdout may be empty); an unknown verb (exit 2, or a
/// usage or unknown-command answer) is [`AskError::Unsupported`].
fn local_json(args: &[&str]) -> Result<Value, AskError> {
    let out = super::cmux()
        .map_err(|e| AskError::Failed(e.to_string()))?
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| AskError::Failed(e.to_string()))?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    if !out.status.success() {
        let text = format!("{stdout}\n{stderr}");
        let unknown = out.status.code() == Some(2)
            || unknown_verb(&text)
            || text.to_ascii_lowercase().contains("usage: cmux remote-host");
        return Err(if unknown {
            AskError::Unsupported
        } else {
            let why = last_line(&stderr);
            AskError::Failed(if why.is_empty() { last_line(&stdout) } else { why })
        });
    }
    Ok(serde_json::from_str(stdout.trim()).unwrap_or(Value::Null))
}

/// One GET with a 30 s timeout.
#[cfg(unix)]
fn http_get(url: &str) -> Result<Vec<u8>, String> {
    // reqwest's rustls-no-provider build needs the workspace's ring provider.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| format!("runtime: {error}"))?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .user_agent(concat!("cmux-tui/", env!("CARGO_PKG_VERSION"), " device-setup"))
        .build()
        .map_err(|error| format!("http client: {error}"))?;
    runtime.block_on(async {
        let response = client.get(url).send().await.map_err(|error| error.to_string())?;
        if !response.status().is_success() {
            return Err(format!("HTTP {}", response.status()));
        }
        response.bytes().await.map(|bytes| bytes.to_vec()).map_err(|error| error.to_string())
    })
}

#[cfg(not(unix))]
fn http_get(_url: &str) -> Result<Vec<u8>, String> {
    Err("reading the NIGHTLY feed needs macOS or Linux".into())
}

/// A run's switches.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Options {
    pub dry_run: bool,
    /// `--allow-agents`: turn the agents permission on (never on without it).
    pub allow_agents: bool,
}

/// Where a run finds its devices, its Macs and its asking side: this machine's, or a test's.
pub(crate) trait World {
    /// The device's name and ssh route, or why there is none.
    fn lookup(&self, target: &str) -> Result<(String, String), String>;
    fn remote<'a>(&'a self, route: &'a str) -> Box<dyn Remote + 'a>;
    fn asking(&self) -> &dyn Asking;
    /// Appends to the device audit.
    fn record(&self, event: &str, fields: Value);
}

/// One device's run: what `cmux device setup|start DEVICE`, the MCP tools (through the CLI) and
/// the daemon's `device-setup` all run. `emit` sees each step line, with its device, as it is
/// made.
pub(crate) fn run_one(
    world: &dyn World,
    target: &str,
    mode: Mode,
    options: Options,
    emit: &mut dyn FnMut(&str, &Line),
) -> Run {
    let mut run = match world.lookup(target) {
        Ok((name, route)) => {
            let remote = world.remote(&route);
            run_device(&name, remote.as_ref(), world.asking(), mode, options.dry_run, &mut |line| {
                emit(&name, line);
            })
        }
        Err(why) => {
            let line = Line {
                step: "reach",
                state: StepState::Fail,
                detail: why,
                fix: format!("cmux device add {}", super::shell_word(target)),
            };
            emit(target, &line);
            Run { device: target.to_owned(), lines: vec![line], changed: Vec::new() }
        }
    };
    if mode == Mode::Setup {
        let line = share_policy_step(world.asking(), options.allow_agents, options.dry_run);
        if line.state == StepState::Changed {
            run.changed.push("agents allowed".into());
        }
        emit(&run.device, &line);
        run.lines.push(line);
    }
    if !options.dry_run {
        let event = if mode == Mode::Setup { "device.setup" } else { "device.start" };
        world.record(
            event,
            json!({"device": run.device, "changed": run.changed, "failed": run.failed()}),
        );
    }
    run
}

/// The line the CLI prints for a step: its `--json` line, else one human line.
pub(crate) fn cli_line(device: &str, line: &Line, json_out: bool) -> String {
    if json_out { line.json(device).to_string() } else { line.human() }
}

/// The daemon's `device-setup`: each step line goes to `step` (the server sends it as a
/// `device-setup-step` event); the answer is the summary line.
pub(crate) fn serve(
    world: &dyn World,
    request: &cmux_tui_core::device_setup::DeviceSetupRequest,
    step: &mut dyn FnMut(Value),
) -> Value {
    let mode = if request.start_only { Mode::Start } else { Mode::Setup };
    let options = Options { dry_run: request.dry_run, allow_agents: request.allow_agents };
    let run = run_one(world, &request.device, mode, options, &mut |device, line| {
        step(line.json(device));
    });
    run.summary_json()
}

/// What the daemon installs (`cmux_tui_core::device_setup::on_device_setup`).
pub(crate) fn daemon_run(
    request: &cmux_tui_core::device_setup::DeviceSetupRequest,
    step: &mut dyn FnMut(Value),
) -> Result<Value, String> {
    let flags = super::Flags::parse(&[], &[], &[]).map_err(|e| e.to_string())?;
    let here = Here::read(&flags).map_err(|e| format!("{e:#}"))?;
    Ok(serve(&here, request, step))
}

/// This machine's devices and routes, as `cmux device list` reads them.
struct Here {
    listing: Listing,
    sources: Sources,
}

impl Here {
    fn read(flags: &super::Flags) -> anyhow::Result<Self> {
        let auth = super::JoinAuth::read(flags)?;
        let net = super::network::pick(
            super::choice(flags)?,
            Box::new(super::network::WeftNetwork),
            || Box::new(super::network::TailscaleNetwork::read()),
        );
        let mut notes = Vec::new();
        let sources = super::read_sources(&auth, &mut notes);
        let listing = model::merge(&sources, net.status(), &net.nodes());
        Ok(Self { listing, sources })
    }
}

impl World for Here {
    fn lookup(&self, target: &str) -> Result<(String, String), String> {
        match model::find(&self.listing, target) {
            Some(device) => route(device, &self.sources).map(|r| (device.name.clone(), r)),
            None => Err(format!("no device named {target}")),
        }
    }

    fn remote<'a>(&'a self, route: &'a str) -> Box<dyn Remote + 'a> {
        Box::new(SshRemote(route))
    }

    fn asking(&self) -> &dyn Asking {
        &ThisMachine
    }

    fn record(&self, event: &str, fields: Value) {
        super::record(event, fields);
    }
}

/// `cmux device setup DEVICE|--all [--json] [--dry-run] [--allow-agents]` and
/// `cmux device start DEVICE [--json]`.
pub(super) fn verb(args: &[String], mode: Mode) -> anyhow::Result<()> {
    let booleans: &[&str] = match mode {
        Mode::Setup => &["json", "dry-run", "all", "allow-agents"],
        Mode::Start => &["json"],
    };
    let flags = super::Flags::parse(args, &["network"], booleans)?;
    let json_out = flags.has("json");
    let options =
        Options { dry_run: flags.has("dry-run"), allow_agents: flags.has("allow-agents") };
    let all = flags.has("all");
    let target = match (flags.positional.as_slice(), all) {
        ([], true) => None,
        ([device], false) => Some(device.clone()),
        _ => {
            return Err(super::usage(if mode == Mode::Setup {
                "needs one DEVICE, or --all"
            } else {
                "needs one DEVICE"
            }));
        }
    };
    let here = Here::read(&flags)?;
    let print_summary = |run: &Run| {
        if json_out {
            println!("{}", run.summary_json());
        } else {
            println!("{}", run.summary());
        }
    };

    let Some(target) = target else {
        let (mut done, mut skipped, mut failed) = (0, 0, 0);
        for (name, pick) in select(&here.listing, &here.sources) {
            if let Err(why) = pick {
                skipped += 1;
                let line =
                    Line { step: "reach", state: StepState::Skip, detail: why, fix: String::new() };
                if json_out {
                    println!("{}", line.json(&name));
                } else {
                    println!("{name}: skipped, {}", line.detail);
                }
                continue;
            }
            let run = run_one(&here, &name, mode, options, &mut |_, _| {});
            if run.failed().is_empty() {
                done += 1;
            } else {
                failed += 1;
            }
            print_summary(&run);
        }
        let summary = format!("{done} set up, {failed} failed, {skipped} skipped");
        if json_out {
            println!(
                "{}",
                json!({"total": {"set_up": done, "failed": failed, "skipped": skipped}, "summary": summary})
            );
        } else {
            println!("{summary}");
        }
        if failed > 0 {
            anyhow::bail!("{failed} device(s) failed; their lines say why");
        }
        return Ok(());
    };

    let run = run_one(&here, &target, mode, options, &mut |device, line| {
        println!("{}", cli_line(device, line, json_out));
    });
    print_summary(&run);
    if !run.failed().is_empty() {
        anyhow::bail!("a step failed on {}; its line says why", run.device);
    }
    Ok(())
}

/// What the MCP tools run: `cmux device <args> --json` as a child (its stdout is not the MCP
/// channel), every JSON line it printed, and whether it exited 0.
pub(crate) fn run_json_lines(args: &[&str]) -> anyhow::Result<(bool, Vec<Value>, String)> {
    let out =
        super::cmux()?.arg("device").args(args).arg("--json").stdin(Stdio::null()).output()?;
    let lines = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .collect();
    Ok((out.status.success(), lines, last_line(&String::from_utf8_lossy(&out.stderr))))
}

#[cfg(test)]
#[path = "setup_tests.rs"]
mod tests;
