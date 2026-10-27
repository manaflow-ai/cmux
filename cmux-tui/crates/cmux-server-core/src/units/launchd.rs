//! launchd property lists (server.md 4.3; 9.3 `restart.notLoggedIn`).
//!
//! Output is the canonical form plutil writes (keys sorted, tab indent), so
//! the app agent plist equals the one scripts/cmux-next/bundle-server-helper.sh
//! stamps into the bundle byte for byte (tests/fixtures/app-service-agent.plist).
//!
//! The install mode is the argument `--mode <user|system>`, never a plist
//! `EnvironmentVariables` entry: launchd passes that environment to every
//! child of the job, including the user's shells.

use std::collections::BTreeMap;

use super::{UnitError, host_run_argv_with_mode};
use crate::layout::{LAUNCHD_LABEL, Layout, ServiceKind};
use crate::pg::valid_os_user;
use crate::platform::{InstallMode, Platform};

/// The bundled CLI, relative to the app bundle (SMAppService resolves
/// `BundleProgram` inside the bundle that registers the job).
pub const APP_BUNDLE_PROGRAM: &str = "Contents/Resources/bin/cmux";

/// The launchd jobs cmux installs, each with its `ProcessType`
/// (threading-model.md "Process roles"). A person's input or the frames it
/// produces pass through every job here, so every one is `Interactive`: an
/// app's limits, that is none (launchd.plist(5)). `Background` puts a job
/// under darwinbg CPU, I/O and network throttling; `Standard` keeps
/// launchd's daemon limits; `Adaptive` lifts a job only while an XPC
/// message is in flight, and these jobs talk over Unix sockets and QUIC.
/// Chrome likewise never lowers a process a person is using: only a hidden
/// renderer drops below the browser (base/process/process_mac.cc
/// `Process::SetPriority`, from
/// content/browser/renderer_host/render_process_host_impl.cc
/// `UpdateProcessPriority`).
///
/// launchd reads a plist only at bootstrap, so a plist an older cmux wrote
/// keeps its old `ProcessType` until it is rewritten: each installer
/// rewrites its plist on update or restart (the link and remote-host
/// agents through cmux-tui `launchd_role::upgrade_process_type`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LaunchdJob {
    /// `cmux host run`: `com.cmux.server` (agent and daemon) and the app's
    /// `<bundle id>.server`. Every terminal key and frame passes through it.
    Server,
    /// `cmux link serve` (`com.cmuxterm.link`): the overlay endpoint that
    /// carries a paired peer's session streams.
    Link,
    /// `cmux host serve` (`com.cmuxterm.host-remote`): serves this
    /// machine's sessions to a remote client's keys.
    RemoteHost,
    /// `acpmux daemon run` (`com.acpmux.daemon`, installed by `acpmux
    /// hosts`): carries the agent sessions a person prompts and watches.
    AcpmuxDaemon,
    /// `cmux-relay` (`com.chatmux.relay`, `--autostart`): bridges a paired
    /// chat client's terminal keys to this machine's PTYs.
    ChatmuxRelay,
}

impl LaunchdJob {
    pub const ALL: [Self; 5] =
        [Self::Server, Self::Link, Self::RemoteHost, Self::AcpmuxDaemon, Self::ChatmuxRelay];

    /// The plist `ProcessType` value.
    pub const fn process_type(self) -> &'static str {
        match self {
            Self::Server
            | Self::Link
            | Self::RemoteHost
            | Self::AcpmuxDaemon
            | Self::ChatmuxRelay => "Interactive",
        }
    }
}

enum Value {
    Str(String),
    Bool(bool),
    Int(u32),
    Array(Vec<Value>),
    Dict(BTreeMap<&'static str, Value>),
}

fn xml_escape(value: &str) -> Result<String, UnitError> {
    if value.chars().any(|c| c.is_control()) {
        return Err(UnitError::UnsafePath("control character"));
    }
    Ok(value.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;"))
}

fn write(out: &mut String, value: &Value, depth: usize) -> Result<(), UnitError> {
    let pad = "\t".repeat(depth);
    match value {
        Value::Str(s) => out.push_str(&format!("{pad}<string>{}</string>\n", xml_escape(s)?)),
        Value::Bool(true) => out.push_str(&format!("{pad}<true/>\n")),
        Value::Bool(false) => out.push_str(&format!("{pad}<false/>\n")),
        Value::Int(n) => out.push_str(&format!("{pad}<integer>{n}</integer>\n")),
        Value::Array(items) if items.is_empty() => out.push_str(&format!("{pad}<array/>\n")),
        Value::Array(items) => {
            out.push_str(&format!("{pad}<array>\n"));
            for item in items {
                write(out, item, depth + 1)?;
            }
            out.push_str(&format!("{pad}</array>\n"));
        }
        Value::Dict(entries) => {
            out.push_str(&format!("{pad}<dict>\n"));
            for (key, item) in entries {
                out.push_str(&format!("{pad}\t<key>{key}</key>\n"));
                write(out, item, depth + 1)?;
            }
            out.push_str(&format!("{pad}</dict>\n"));
        }
    }
    Ok(())
}

fn document(root: BTreeMap<&'static str, Value>) -> Result<String, UnitError> {
    let mut out = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
",
    );
    write(&mut out, &Value::Dict(root), 0)?;
    out.push_str("</plist>\n");
    Ok(out)
}

fn program_arguments(program: &str, mode: InstallMode) -> Value {
    Value::Array(host_run_argv_with_mode(program, mode).into_iter().map(Value::Str).collect())
}

/// KeepAlive `{SuccessfulExit: false}`: restart only after a failure, so a
/// clean exit (the host was disabled) stays down.
///
/// Exit contract of `cmux host run` (every launchd job here relies on it):
/// exit status 0 ONLY on a deliberate stop (disable, unpair, uninstall, a
/// stop request). Every error path (bad arguments, a store or socket that
/// fails to open, a panic, a lost lock) exits non-zero, so launchd restarts
/// the job after ThrottleInterval. The `host run` parser lands with the
/// server stack and carries the test of this contract.
fn restart_on_failure() -> Value {
    Value::Dict(BTreeMap::from([("SuccessfulExit", Value::Bool(false))]))
}

/// The headless agent and the daemon: label `com.cmux.server`, the store
/// profile's binary, a log under `<state>/logs`.
fn headless_plist(layout: &Layout, user: Option<&str>) -> Result<String, UnitError> {
    let log = layout.logs().join("server.log").to_string();
    let mut root = BTreeMap::new();
    root.insert("Label", Value::Str(LAUNCHD_LABEL.to_owned()));
    root.insert("ProgramArguments", program_arguments(layout.current_cmux.as_str(), layout.mode));
    if let Some(user) = user {
        root.insert("UserName", Value::Str(user.to_owned()));
    }
    root.insert("RunAtLoad", Value::Bool(true));
    root.insert("KeepAlive", restart_on_failure());
    root.insert("ProcessType", Value::Str(LaunchdJob::Server.process_type().to_owned()));
    root.insert("ThrottleInterval", Value::Int(10));
    root.insert("StandardOutPath", Value::Str(log.clone()));
    root.insert("StandardErrorPath", Value::Str(log));
    document(root)
}

/// `~/Library/LaunchAgents/com.cmux.server.plist` on a Mac without the app.
/// Runs only while the user is logged in. The app layout has a per-build
/// label: use [`app_service_agent_plist`].
pub fn launch_agent_plist(layout: &Layout) -> Result<String, UnitError> {
    if layout.platform != Platform::MacOs
        || layout.mode != InstallMode::User
        || !matches!(layout.service, ServiceKind::LaunchAgent { .. })
    {
        return Err(UnitError::WrongLayout);
    }
    headless_plist(layout, None)
}

/// `/Library/LaunchDaemons/com.cmux.server.plist`: starts at boot without a
/// login and runs as `user` (the installing user for a user-mode layout, the
/// service user for a system-mode layout). Installed by the
/// `restart.notLoggedIn` fix with admin rights once.
pub fn launch_daemon_plist(layout: &Layout, user: &str) -> Result<String, UnitError> {
    if layout.platform != Platform::MacOs {
        return Err(UnitError::WrongLayout);
    }
    if !valid_os_user(user) {
        return Err(UnitError::BadUser);
    }
    headless_plist(layout, Some(user))
}

/// A plain reverse-DNS bundle id, the same rule as bundle-server-helper.sh:
/// `^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$`.
fn valid_bundle_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    let edge = |b: &u8| b.is_ascii_alphanumeric();
    bytes.len() >= 2
        && bytes.first().is_some_and(edge)
        && bytes.last().is_some_and(edge)
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'.' || *b == b'-')
}

/// The plist bundled in the app for `SMAppService.agent`
/// (`Contents/Library/LaunchAgents/com.cmux.server.plist`). The label is the
/// per-build `<bundle id>.server`, so every build has its own job. The plist
/// is sealed in a bundle that every user of the Mac shares: no environment,
/// no per-user path, no log path (`cmux host run` writes its own log).
/// KeepAlive `{SuccessfulExit: false}` restarts the job only after a failure,
/// at most once per ThrottleInterval (10 s).
pub fn app_service_agent_plist(layout: &Layout, bundle_id: &str) -> Result<String, UnitError> {
    if layout.platform != Platform::MacOs
        || layout.mode != InstallMode::User
        || !matches!(layout.service, ServiceKind::AppServiceAgent { .. })
    {
        return Err(UnitError::WrongLayout);
    }
    if !valid_bundle_id(bundle_id) {
        return Err(UnitError::BadBundleId);
    }
    let mut root = BTreeMap::new();
    root.insert("Label", Value::Str(format!("{bundle_id}.server")));
    root.insert("BundleProgram", Value::Str(APP_BUNDLE_PROGRAM.to_owned()));
    root.insert(
        "AssociatedBundleIdentifiers",
        Value::Array(vec![Value::Str(bundle_id.to_owned())]),
    );
    root.insert("ProgramArguments", program_arguments(APP_BUNDLE_PROGRAM, InstallMode::User));
    root.insert("RunAtLoad", Value::Bool(true));
    root.insert("KeepAlive", restart_on_failure());
    root.insert("ThrottleInterval", Value::Int(10));
    root.insert("ProcessType", Value::Str(LaunchdJob::Server.process_type().to_owned()));
    document(root)
}
