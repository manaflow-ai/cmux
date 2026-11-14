//! A daemon of another build than this CLI does not know an operation the
//! CLI sends. Its envelope parse refuses the unknown `operation` (or a
//! parameter it does not know) as `validation.invalid` "invalid request
//! envelope", which says nothing about the cause. The CLI then reads the
//! daemon's build (`identify` with `revisions`) and orders the two builds
//! the way the attach notice does (`staged_update::stale_notice`): by the
//! source commit's time, where a daemon that reports none predates the
//! field and so is older.
//!
//! - The daemon is older: `daemon.outdated` and the fix, `cmux daemon
//!   restart`, which swaps the daemon for this build and keeps every
//!   terminal (cli/lifecycle.rs).
//! - The daemon is newer: `cli.outdated`; this CLI is the stale one, and a
//!   restart from it would downgrade the daemon, so no restart is offered.
//!   The fix is this command run with the daemon's own CLI (`cli_path`,
//!   cli/skew.rs) when the daemon names it.
//! - The order is unknown (no answer, or no build time on this side):
//!   `daemon.build_mismatch` with no fix.
//!
//! The daemon's own text is never printed.

use std::io::{BufReader, Write};
use std::path::Path;
use std::time::Duration;

use cmux_json::JsonSet as _;
use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

type Reader = BufReader<Box<dyn transport::Stream>>;

/// The text an envelope refusal carries in every build.
const ENVELOPE_REFUSAL: &str = "invalid request envelope";

/// Lines read for the `identify` reply before giving up (events of a
/// subscription on the same connection come first).
const IDENTIFY_LINES: usize = 64;

/// How long the refused connection may take to answer `identify`.
// timeout: a wedged daemon is named without its identity; the refusal still ends the command.
const IDENTIFY_BUDGET: Duration = Duration::from_secs(2);

/// Whether `error` is a daemon's refusal of the request envelope itself.
pub(super) fn is_envelope_refusal(error: &Value) -> bool {
    error.get("code").and_then(Value::as_str) == Some("validation.invalid")
        && (error.get("message").and_then(Value::as_str) == Some(ENVELOPE_REFUSAL)
            || error
                .get("details")
                .and_then(|details| details.get("reason"))
                .and_then(Value::as_str)
                == Some(ENVELOPE_REFUSAL))
}

/// The error to print instead of `error` when it is an envelope refusal of
/// `operation` by a daemon of another build; `None` leaves `error` as it is
/// (another error, or the daemon is this build: then the refusal is real).
/// `socket` names the daemon in the restart fix when the caller knows it.
/// Otherwise the fix names the default socket of the session the daemon
/// reports, but only when that socket reaches this same daemon (pid and
/// generation): a restart there would else start another owner beside it.
/// With neither, the error names no restart command.
pub(super) fn replace(
    reader: &mut Reader,
    error: &Value,
    operation: &str,
    socket: Option<&Path>,
) -> Option<Value> {
    if !is_envelope_refusal(error) {
        return None;
    }
    let identity = identify(reader).unwrap_or(Value::Null);
    let stamp = crate::build_stamp();
    let own = Own {
        version: cmux_tui_core::release::distribution_version(),
        build_commit: stamp.build_commit(),
        build_time: stamp.build_time().unwrap_or(0),
    };
    let session = identity.get("session").and_then(Value::as_str);
    let rerun = identity.get("cli_path").and_then(Value::as_str).map(|cli| {
        super::fix_command::run_with_daemon_cli(Path::new(cli), std::env::args_os().skip(1))
    });
    let cli = super::fix_command::this_cli();
    let restart = socket
        .map(Path::to_path_buf)
        .or_else(|| session.and_then(|session| default_socket_of(session, &identity)))
        .map(|socket| super::fix_command::restart_daemon_in_place(&cli, &socket));
    let fixes = Fixes { restart: restart.as_deref(), rerun: rerun.as_deref() };
    explain(&identity, operation, &own, &fixes)
}

/// The commands an explanation may name: `restart` swaps an older daemon
/// for this build (`None`: the daemon's socket is not known); `rerun` runs
/// this command with a newer daemon's own CLI.
pub(super) struct Fixes<'a> {
    pub restart: Option<&'a str>,
    pub rerun: Option<&'a str>,
}

/// This CLI's release, source commit and the commit's time (0: unknown).
pub(super) struct Own<'a> {
    pub version: &'a str,
    pub build_commit: Option<&'a str>,
    pub build_time: u64,
}

/// How the daemon's build compares with this CLI's.
#[derive(Debug, PartialEq, Eq)]
enum Order {
    DaemonOlder,
    DaemonNewer,
    Unknown,
}

/// `None` when the daemon is this build.
fn order(identity: &Value, own: &Own<'_>) -> Option<Order> {
    let daemon_commit = identity.get("build_commit").and_then(Value::as_str);
    if daemon_commit.is_some() && daemon_commit == own.build_commit {
        return None;
    }
    if identity.is_null() || own.build_time == 0 {
        return Some(Order::Unknown);
    }
    // A build before `identify` reported its time has no `build_time` key;
    // a later build without a stamp reports `null`, which orders nothing.
    let Some(time) = identity.get("build_time") else { return Some(Order::DaemonOlder) };
    Some(match time.as_u64() {
        None | Some(0) => Order::Unknown,
        Some(time) if time < own.build_time => Order::DaemonOlder,
        Some(time) if time > own.build_time => Order::DaemonNewer,
        Some(_) => Order::Unknown,
    })
}

/// The error for a refusal by the daemon that answered `identity` (`Null`
/// when it did not answer); `None` when the daemon is this build.
pub(super) fn explain(
    identity: &Value,
    operation: &str,
    own: &Own<'_>,
    fixes: &Fixes<'_>,
) -> Option<Value> {
    let order = order(identity, own)?;
    let daemon_commit = identity.get("build_commit").and_then(Value::as_str);
    let daemon_version = identity.get("version").and_then(Value::as_str);
    let messages = &crate::localization::catalog().skew;
    let short = |commit: Option<&str>| {
        commit.map_or_else(|| messages.unknown_build.to_owned(), |c| c.chars().take(8).collect())
    };
    let (code, action, template) = match (&order, daemon_version) {
        (Order::DaemonOlder, _) if fixes.restart.is_some() => {
            ("daemon.outdated", "restart_daemon", messages.older_daemon)
        }
        (Order::DaemonOlder, _) => {
            ("daemon.outdated", "restart_daemon", messages.older_daemon_no_socket)
        }
        (Order::DaemonNewer, _) if fixes.rerun.is_some() => {
            ("cli.outdated", "use_daemon_cli", messages.newer_daemon)
        }
        (Order::DaemonNewer, _) => ("cli.outdated", "use_daemon_cli", messages.newer_daemon_no_cli),
        (Order::Unknown, Some(_)) => {
            ("daemon.build_mismatch", "match_builds", messages.other_build_daemon)
        }
        (Order::Unknown, None) => {
            ("daemon.build_mismatch", "match_builds", messages.unknown_daemon)
        }
    };
    let fix = match order {
        Order::DaemonOlder => fixes.restart,
        Order::DaemonNewer => fixes.rerun,
        Order::Unknown => None,
    };
    let message = template
        .replace("{daemon}", daemon_version.unwrap_or_default())
        .replace("{build}", &short(daemon_commit))
        .replace("{own_build}", &short(own.build_commit))
        .replace("{own}", own.version)
        .replace("{operation}", operation)
        .replace("{fix}", fix.unwrap_or_default());
    let mut details = json!({
        "operation": operation,
        "daemon_version": daemon_version,
        "daemon_build": daemon_commit,
        "cli_version": own.version,
        "cli_build": own.build_commit,
        "action": action,
    });
    if let Some(fix) = fix {
        details.set("fix", Value::String(fix.to_owned()));
    }
    Some(json!({"code": code, "message": message, "details": details, "retryable": false}))
}

/// The default socket of `session` when it reaches the daemon that
/// answered `identity` (the same pid and generation); `None` otherwise.
fn default_socket_of(session: &str, identity: &Value) -> Option<std::path::PathBuf> {
    let socket = cmux_tui_core::server::try_default_socket_path(session).ok()?;
    let stream = cmux_tui_core::server::connect_session_socket(&socket, true).ok()?;
    let there = identify(&mut BufReader::new(stream))?;
    let same = |key: &str| there.get(key).is_some() && there.get(key) == identity.get(key);
    (same("pid") && same("generation")).then_some(socket)
}

/// The daemon's `identify` data, asked on the connection that was refused
/// (an envelope refusal keeps it open), within [`IDENTIFY_BUDGET`]; `None`
/// when it does not answer. The refused request ends the command, so the
/// connection keeps the budget as its read timeout.
fn identify(reader: &mut Reader) -> Option<Value> {
    let request = json!({"id": "cli-older-daemon", "cmd": "identify", "revisions": true});
    let stream = reader.get_mut();
    stream.set_read_timeout(Some(IDENTIFY_BUDGET)).ok()?;
    stream.write_all(format!("{request}\n").as_bytes()).and_then(|()| stream.flush()).ok()?;
    for _ in 0..IDENTIFY_LINES {
        let value = super::wire::read_envelope(reader, false).ok()??;
        if value.get("id").and_then(Value::as_str) == Some("cli-older-daemon") {
            return (value.get("ok") == Some(&Value::Bool(true)))
                .then(|| value.get("data").cloned().unwrap_or_default());
        }
    }
    None
}

#[cfg(test)]
mod tests;
