//! `cmux remote-host grants [--device DEVICE] [--open]`: which macOS grant
//! cmux Remote still lacks on a Mac, named exactly, and its System Settings
//! pane opened there (Leo, 2026-11-14: "make the setup flow say exactly which
//! grant is missing and open its pane"). macOS lets only a click on that Mac
//! give a grant; this never fakes one.
//!
//! In a build without cmux Remote (Release and NIGHTLY, status `bundled:
//! false`) the cmux app captures the screen itself, so the grants read are the
//! app's own, which it reports to the daemon (status `app.permissions`); each
//! row's `holder` says which process the grant belongs to.
//!
//! It also reads whether the Mac has Screen Sharing or Apple Remote
//! Management on: then an agent can click the grant over screen sharing with
//! the owner's OK ("where the Mac has Remote Management on, let an agent do
//! that click over screen sharing with the owner's OK"). The click itself is
//! not done here.
//!
//! With `--device`, one fixed script runs on that Mac over key-only ssh (the
//! device's acpmux peer route, else DEVICE as an ssh host or alias); without
//! it, on this Mac. The script takes no data but the grant to open, which is
//! one of two fixed words.

use std::io::Write as _;

use serde_json::{Value, json};

/// One macOS grant cmux Remote holds.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Grant {
    /// `cmux remote-host request|open-settings` word.
    pub key: &'static str,
    /// The field in `remote-host-status`'s `host.permissions` (and `app.permissions`).
    pub field: &'static str,
    /// System Settings' name for it.
    pub name: &'static str,
    /// What it is for.
    pub needed_for: &'static str,
    /// The pane's URL.
    pub pane: &'static str,
    /// The list it is in under System Settings > Privacy & Security on current macOS.
    pub settings: &'static str,
}

pub(super) const GRANTS: [Grant; 2] = [
    Grant {
        key: "screen-recording",
        field: "screen_recording",
        name: "Screen Recording",
        needed_for: "Screen Sharing and Computer Use screenshots",
        pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        settings: "Screen & System Audio Recording",
    },
    Grant {
        key: "accessibility",
        field: "accessibility",
        name: "Accessibility",
        needed_for: "control over Screen Sharing and Computer Use clicks and typing",
        pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        settings: "Accessibility",
    },
];

/// The process that holds a grant on the Mac: cmux Remote where the build embeds it, the cmux app
/// itself in Release and NIGHTLY (`bundled: false`), which capture the screen without cmux Remote.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Holder {
    Remote,
    App,
    /// The Screen Sharing helper a share runs (`cmux-screen-sharing serve`, its own responsible
    /// process): what captures a device hub share, so its own reading counts before the app's.
    Helper,
}

impl Holder {
    /// The `holder` field, and the name the words use for the process.
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::Remote => "cmux Remote",
            Self::App => "cmux app",
            Self::Helper => "Screen Sharing helper",
        }
    }

    /// The name System Settings lists it under: the helper's own item where it reported one
    /// (`cmux NIGHTLY Screen Sharing`, `cmux Computer Use`).
    fn listed_as(self, status: Option<&Value>) -> String {
        match self {
            Self::Remote => "cmux Remote".into(),
            Self::App => "cmux".into(),
            Self::Helper => status
                .map(|status| status.get("data").unwrap_or(status))
                .and_then(|status| status.pointer("/share_host/helper/permissions/listed_as"))
                .and_then(Value::as_str)
                .unwrap_or("cmux Computer Use")
                .to_owned(),
        }
    }
}

/// A grant's state on the Mac and who holds it: `Some(true)` given, `Some(false)` missing,
/// `None` unknown (neither cmux Remote, the Screen Sharing helper nor the cmux app reported it).
pub(super) fn reading(status: &Value, grant: &Grant) -> (Option<bool>, Holder) {
    let status = status.get("data").unwrap_or(status);
    let remote = status
        .pointer(&format!("/host/permissions/{}", grant.field))
        .or_else(|| status.pointer(&format!("/permissions/{}", grant.field)))
        .and_then(Value::as_bool);
    if remote.is_some() {
        return (remote, Holder::Remote);
    }
    // Where cmux Remote is embedded it holds the grant even while stopped; the app's own
    // reading counts only where it is not (an older daemon without `bundled` has no `app` either).
    let bundled = status.get("bundled").and_then(Value::as_bool);
    if bundled == Some(true) {
        return (None, Holder::Remote);
    }
    // The helper read its grants itself when a share started it (`share-host status`).
    let helper = status
        .pointer(&format!("/share_host/helper/permissions/{}", grant.field))
        .and_then(Value::as_bool);
    if helper.is_some() {
        return (helper, Holder::Helper);
    }
    let app = status.pointer(&format!("/app/permissions/{}", grant.field)).and_then(Value::as_bool);
    let holder = if app.is_some() || bundled == Some(false) { Holder::App } else { Holder::Remote };
    (app, holder)
}

/// A grant's state on the Mac, from cmux Remote or else the cmux app ([`reading`]).
pub(super) fn grant_state(status: &Value, grant: &Grant) -> Option<bool> {
    reading(status, grant).0
}

/// Whether the Mac lets an agent see and click it over screen sharing.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct ScreenAccess {
    /// `com.apple.screensharing` enabled in launchd (Screen Sharing or Remote Management on).
    pub screen_sharing: Option<bool>,
    /// Apple Remote Desktop's agent running (Remote Management on).
    pub remote_management: Option<bool>,
    /// Something answers on 127.0.0.1:5900, the VNC port both use.
    pub vnc_port: Option<bool>,
}

impl ScreenAccess {
    /// Whether an agent could click a grant over screen sharing (with the owner's OK).
    pub(super) fn agent_can_click(&self) -> bool {
        self.vnc_port == Some(true)
            || self.screen_sharing == Some(true)
            || self.remote_management == Some(true)
    }
}

/// Finds this Mac's cmux CLI (an app bundle's first, then PATH) and prints, one tagged
/// line each: the cmux Remote status, launchd's Screen Sharing switch, the ARD agent, and
/// port 5900. `OPEN` (a fixed word or empty) opens that grant's pane through cmux Remote.
const PROBE: &str = r#"cmux=
for b in /Applications/cmux*.app/Contents/Resources/bin/cmux "$(command -v cmux 2>/dev/null)"; do
  [ -n "$b" ] && [ -x "$b" ] || continue
  out=$("$b" --json remote-host status 2>/dev/null) || continue
  cmux=$b
  printf 'status\t%s\n' "$(printf '%s' "$out" | tr -d '\n')"
  break
done
[ -n "$cmux" ] || printf 'status\t\n'
acp=
[ -n "$cmux" ] && [ -x "$(dirname "$cmux")/acpmux" ] && acp=$(dirname "$cmux")/acpmux
[ -n "$acp" ] || acp=$(command -v acpmux 2>/dev/null)
if [ -n "$acp" ] && out=$("$acp" --json share-host status 2>/dev/null); then
  printf 'sharehost\t%s\n' "$(printf '%s' "$out" | tr -d '\n')"
fi
printf 'screensharing\t%s\n' "$(launchctl print-disabled system 2>/dev/null | grep '"com.apple.screensharing"' | head -n 1)"
if pgrep -x ARDAgent >/dev/null 2>&1; then printf 'ard\ton\n'; else printf 'ard\toff\n'; fi
if command -v nc >/dev/null 2>&1; then
  if nc -z -G 2 127.0.0.1 5900 >/dev/null 2>&1; then printf 'vnc\topen\n'; else printf 'vnc\tclosed\n'; fi
fi
case "$OPEN" in
  screen-recording) pane='x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture' ;;
  accessibility) pane='x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' ;;
  *) pane= ;;
esac
if [ -n "$pane" ]; then
  if [ -n "$cmux" ] && "$cmux" --json remote-host open-settings "$OPEN" >/dev/null 2>&1; then printf 'opened\t%s\n' "$OPEN"
  elif open "$pane" >/dev/null 2>&1; then printf 'opened\t%s\n' "$OPEN"
  else printf 'open-failed\t%s\n' "$OPEN"; fi
fi
"#;

/// The probe with `open` (one of [`GRANTS`]' keys, checked) set.
pub(super) fn script(open: Option<&Grant>) -> String {
    let word = open.map_or("", |grant| grant.key);
    debug_assert!(GRANTS.iter().any(|g| g.key == word) || word.is_empty());
    format!("OPEN='{word}'\n{PROBE}")
}

/// What the probe printed.
#[derive(Debug, Default, PartialEq)]
pub(super) struct Probe {
    pub status: Option<Value>,
    pub access: ScreenAccess,
    pub opened: Vec<String>,
    pub open_failed: Vec<String>,
}

pub(super) fn parse_probe(stdout: &str) -> Probe {
    let mut probe = Probe::default();
    for line in stdout.lines() {
        let Some((tag, value)) = line.split_once('\t') else { continue };
        let value = value.trim();
        match tag {
            "status" => probe.status = serde_json::from_str(value).ok(),
            // After `status`: the share host's status (its helper's own grant reading) joins
            // it as `share_host`.
            "sharehost" => {
                if let (Ok(share_host), Some(Value::Object(map))) =
                    (serde_json::from_str::<Value>(value), probe.status.as_mut())
                {
                    let wrapped = matches!(map.get("data"), Some(Value::Object(_)));
                    let map = if wrapped {
                        map.get_mut("data").and_then(Value::as_object_mut)
                    } else {
                        Some(map)
                    };
                    if let Some(map) = map {
                        map.insert("share_host".into(), share_host);
                    }
                }
            }
            "screensharing" => {
                // `"com.apple.screensharing" => disabled|enabled` (older) or `=> true|false`
                // (newer, true meaning disabled); no line: launchd has no record.
                probe.access.screen_sharing =
                    value.rsplit("=>").next().and_then(|word| match word.trim() {
                        "enabled" | "false" => Some(true),
                        "disabled" | "true" => Some(false),
                        _ => None,
                    });
            }
            "ard" => probe.access.remote_management = Some(value == "on"),
            "vnc" => probe.access.vnc_port = Some(value == "open"),
            "opened" => probe.opened.push(value.to_owned()),
            "open-failed" => probe.open_failed.push(value.to_owned()),
            _ => {}
        }
    }
    probe
}

/// The grant to open with `--open`: the first missing one (Screen Recording first).
pub(super) fn first_missing(status: Option<&Value>) -> Option<&'static Grant> {
    let status = status?;
    GRANTS.iter().find(|grant| grant_state(status, grant) == Some(false))
}

/// The report: each grant's state with the exact words and pane for a missing one, and
/// whether an agent could click it over screen sharing.
pub(super) fn report(device: Option<&str>, probe: &Probe) -> Value {
    let on = device.unwrap_or("this Mac");
    let grants: Vec<Value> = GRANTS
        .iter()
        .map(|grant| {
            let (state, holder) = probe
                .status
                .as_ref()
                .map_or((None, Holder::Remote), |status| reading(status, grant));
            let mut row = json!({
                "grant": grant.key,
                "name": grant.name,
                "granted": state,
                "holder": holder.name(),
                "needed_for": grant.needed_for,
                "pane": grant.pane,
            });
            if state != Some(true)
                && let Some(map) = row.as_object_mut()
            {
                let fix = match (device, holder) {
                    (Some(device), _) => format!("cmux remote-host grants --device {} --open", super::fix_command::quote_arg(device)),
                    (None, Holder::Remote) => format!("cmux remote-host open-settings {}", grant.key),
                    // No cmux Remote to open it: the pane itself.
                    (None, Holder::App | Holder::Helper) => format!("open '{}'", grant.pane),
                };
                let listed = holder.listed_as(probe.status.as_ref());
                let words = match (state, holder) {
                    (Some(false), Holder::Helper) => format!(
                        "{} not granted on {on}: on {on}, open System Settings > Privacy & Security > {} and turn on \"{listed}\" ({}).",
                        grant.name, grant.settings, grant.needed_for
                    ),
                    (Some(false), _) => format!(
                        "Missing on {on}: {} for {listed} ({}). Turn on {listed} in System Settings > Privacy & Security > {} on {on}.",
                        grant.name, grant.needed_for, grant.name
                    ),
                    (_, Holder::Remote) => format!("Unknown on {on}: cmux Remote is not running there, so {} was not read.", grant.name),
                    (_, Holder::App | Holder::Helper) => format!(
                        "Unknown on {on}: the cmux app there has not reported {} yet (it does when it connects and when it becomes active).",
                        grant.name
                    ),
                };
                map.insert("missing".into(), json!(words));
                map.insert("fix".into(), json!(fix));
            }
            row
        })
        .collect();
    let missing: Vec<&str> = GRANTS
        .iter()
        .filter(|grant| {
            probe.status.as_ref().and_then(|status| grant_state(status, grant)) == Some(false)
        })
        .map(|grant| grant.key)
        .collect();
    let access = &probe.access;
    let click = if access.agent_can_click() {
        format!(
            "An agent can click this grant over screen sharing with your OK: {on} has {} on.",
            if access.remote_management == Some(true) {
                "Remote Management"
            } else {
                "Screen Sharing"
            }
        )
    } else {
        format!(
            "Someone at {on} clicks the grant: Screen Sharing and Remote Management are off there, so no agent can click it remotely."
        )
    };
    json!({
        "device": device,
        "cmux_remote": probe.status.is_some(),
        "grants": grants,
        "missing": missing,
        "screen_access": {
            "screen_sharing": access.screen_sharing,
            "remote_management": access.remote_management,
            "vnc_port": access.vnc_port,
            "agent_can_click": access.agent_can_click(),
            "words": click,
        },
        "opened": probe.opened,
        "open_failed": probe.open_failed,
    })
}

/// Where to run the probe for `device`: its acpmux peer's ssh route
/// (`acp host ls --json`), else `device` itself as an ssh host or alias.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Route {
    pub target: String,
    pub port: Option<u16>,
}

pub(super) fn route(peers: &Value, device: &str) -> Route {
    let wanted = device.trim();
    let bare = wanted.strip_prefix("peer:").unwrap_or(wanted);
    let url = peers
        .get("peers")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find(|peer| {
            peer.get("name")
                .and_then(Value::as_str)
                .is_some_and(|name| name.eq_ignore_ascii_case(bare))
        })
        .and_then(|peer| peer.get("url").and_then(Value::as_str))
        .and_then(|url| url.strip_prefix("ssh://"));
    let Some(authority) = url.map(|rest| rest.split(['/', '?', '#']).next().unwrap_or(rest)) else {
        return Route { target: bare.to_owned(), port: None };
    };
    let (user, hostport) = match authority.rsplit_once('@') {
        Some((user, hostport)) => (Some(user), hostport),
        None => (None, authority),
    };
    let (host, port) = match hostport.strip_prefix('[') {
        Some(v6) => {
            let (host, rest) = v6.split_once(']').unwrap_or((v6, ""));
            (host, rest.strip_prefix(':').and_then(|port| port.parse().ok()))
        }
        None => match hostport.rsplit_once(':') {
            Some((host, port)) => (host, port.parse().ok()),
            None => (hostport, None),
        },
    };
    let target = match user {
        Some(user) => format!("{user}@{host}"),
        None => host.to_owned(),
    };
    Route { target, port }
}

/// Runs a fixed script with `sh -s` here or on a Mac over key-only ssh.
pub(super) trait Shell {
    fn run(&self, script: &str) -> Result<String, String>;
}

pub(super) struct Local;

impl Shell for Local {
    fn run(&self, script: &str) -> Result<String, String> {
        feed(cmux_process::Command::new("/bin/sh").arg("-s"), script)
    }
}

pub(super) struct Ssh(pub Route);

impl Shell for Ssh {
    fn run(&self, script: &str) -> Result<String, String> {
        let mut command = cmux_process::Command::new("ssh");
        command.args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]);
        if let Some(port) = self.0.port {
            command.args(["-p", &port.to_string()]);
        }
        command.args(["--", &self.0.target, "/bin/sh", "-s"]);
        feed(&mut command, script)
    }
}

fn feed(command: &mut cmux_process::Command, script: &str) -> Result<String, String> {
    let mut child = command
        .stdin(cmux_process::Stdio::piped())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::piped())
        .spawn()
        .map_err(|error| format!("cannot start the probe: {error}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(script.as_bytes())
            .map_err(|error| format!("cannot send the probe: {error}"))?;
    }
    let output = child.wait_with_output().map_err(|error| format!("the probe failed: {error}"))?;
    if !output.status.success() {
        let said = String::from_utf8_lossy(&output.stderr);
        let said = said.lines().map(str::trim).rfind(|line| !line.is_empty()).unwrap_or_default();
        return Err(format!("the probe exited with {}: {said}", output.status));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Reads the Mac (and with `open`, opens the first missing grant's pane there).
pub(super) fn grants(shell: &impl Shell, device: Option<&str>, open: bool) -> Result<Value, Value> {
    let failure = |message: String| json!({"code": "grants.unreachable", "message": message});
    let first = parse_probe(&shell.run(&script(None)).map_err(failure)?);
    let probe = match (open, first_missing(first.status.as_ref())) {
        (true, Some(grant)) => parse_probe(&shell.run(&script(Some(grant))).map_err(failure)?),
        _ => first,
    };
    Ok(report(device, &probe))
}

#[cfg(test)]
#[path = "remote_host_grants_tests.rs"]
mod tests;
