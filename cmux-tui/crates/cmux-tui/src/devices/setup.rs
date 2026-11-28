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
pub(crate) const FEED: &str = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml";
/// The only places a NIGHTLY DMG may come from (scripts/fuzz/macos-matrix/onboarding/nightly.py).
pub(crate) const DMG_PREFIXES: [&str; 2] = [
    "https://github.com/manaflow-ai/cmux/releases/download/nightly-next/",
    "https://files-next.cmux.com/nightly-next/",
];
/// The feed channels a Nightly app is offered: none, `cmux-next-stable`, `cmux-next`. Any other
/// (a Dev ring, Canary) is never installed.
const NIGHTLY_CHANNELS: [Option<&str>; 3] = [None, Some("cmux-next-stable"), Some("cmux-next")];
/// The LaunchAgent that brings a closed NIGHTLY back.
pub(crate) const KEEPALIVE_LABEL: &str = "com.cmuxterm.app.nightly.keepalive";
/// The Team ID cmux releases are signed with (scripts/ci/nightly-next-legacy-identity.sh), used
/// when the asking side has no installed NIGHTLY to read it from (a Linux machine).
const RELEASE_TEAM: &str = "7WLXT3NR37";

mod feed;
mod scripts;
mod verbs;

pub(crate) use feed::*;
pub(crate) use scripts::*;
pub(crate) use verbs::*;

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

    /// The probe's `reach` skip when the device turned out not to be a Mac: a skip, not a set-up.
    pub(crate) fn not_a_mac(&self) -> Option<&Line> {
        self.lines.iter().find(|l| l.step == "reach" && l.state == StepState::Skip)
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
        Ok(value) if value.get("agents_may_share").and_then(Value::as_bool) == Some(true) => {
            agents_line(StepState::Changed, format!("\"{AGENTS_POLICY}\" is on"), "")
        }
        Ok(value) if value.get("declined").and_then(Value::as_bool) == Some(true) => agents_line(
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
            let code = error.get("code").and_then(Value::as_str).unwrap_or("");
            let message = error.get("message").and_then(Value::as_str).unwrap_or("");
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
    /// `uname -m`: `arm64` on Apple silicon; the NIGHTLY feed has only arm64 builds.
    arch: String,
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
                "arch" => probe.arch = value,
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
    // The feed (FEED, appcast-arm64.xml) has only Apple silicon builds: an Intel Mac is skipped
    // before anything is installed or replaced (#43385 review F1 at 0a493be7).
    if !probe.arch.is_empty() && probe.arch != "arm64" {
        push(
            &mut run,
            "reach",
            StepState::Skip,
            format!("not an Apple silicon Mac ({}): cmux NIGHTLY is arm64 only", probe.arch),
            String::new(),
        );
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
                ["email", "login", "user"]
                    .iter()
                    .find_map(|k| v.get(*k).and_then(Value::as_str).map(str::to_owned))
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
    let status = status.get("data").filter(|d| d.is_object()).unwrap_or(&status);
    let host = status.get("host").unwrap_or(&Value::Null);
    let shared = ["shared", "sharing", "on"]
        .iter()
        .find_map(|key| host.get("screen").and_then(|s| s.get(*key)).and_then(Value::as_bool))
        .or_else(|| status.pointer("/screen/shared").and_then(Value::as_bool));
    let sharing = match shared {
        Some(true) => "Share This Mac is on",
        Some(false) => "Share This Mac is off",
        None => "Share This Mac: unknown",
    };
    let permissions = host.get("permissions").unwrap_or(&Value::Null);
    if permissions.is_null() {
        return (
            StepState::Warn,
            format!(
                "{sharing}; cmux Remote did not report its grants ({})",
                status.get("state").and_then(Value::as_str).unwrap_or("not running")
            ),
            String::new(),
        );
    }
    let missing: Vec<(&str, &str)> = GRANTS
        .iter()
        .filter(|(key, _, _)| permissions.get(*key).and_then(Value::as_bool) != Some(true))
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
    let peers =
        sources.peers.get("peers").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
    for via in &device.via {
        let Via::Peer { name } = via else { continue };
        let url = peers
            .iter()
            .find(|p| p.get("name").and_then(Value::as_str) == Some(name.as_str()))
            .and_then(|p| p.get("url").and_then(Value::as_str))
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

#[cfg(test)]
#[path = "setup_tests.rs"]
mod tests;
