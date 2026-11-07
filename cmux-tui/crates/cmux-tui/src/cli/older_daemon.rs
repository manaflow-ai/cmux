//! A daemon older than this CLI does not know an operation the CLI sends.
//! Its envelope parse refuses the unknown `operation` (or a parameter it
//! does not know) as `validation.invalid` "invalid request envelope", which
//! says nothing about the cause. The CLI then reads the daemon's build
//! (`identify`) and prints what is wrong and the command that fixes it:
//! `cmux daemon restart` swaps the daemon for this build and keeps every
//! terminal (cli/lifecycle.rs). The daemon's own text is never printed.

use std::io::{BufReader, Write};
use std::path::Path;

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

type Reader = BufReader<Box<dyn transport::Stream>>;

/// The text an envelope refusal carries in every build.
const ENVELOPE_REFUSAL: &str = "invalid request envelope";

/// Lines read for the `identify` reply before giving up (events of a
/// subscription on the same connection come first).
const IDENTIFY_LINES: usize = 64;

/// Whether `error` is a daemon's refusal of the request envelope itself.
pub(super) fn is_envelope_refusal(error: &Value) -> bool {
    error.get("code").and_then(Value::as_str) == Some("validation.invalid")
        && (error.get("message").and_then(Value::as_str) == Some(ENVELOPE_REFUSAL)
            || error["details"].get("reason").and_then(Value::as_str) == Some(ENVELOPE_REFUSAL))
}

/// The error to print instead of `error` when it is an envelope refusal of
/// `operation` by a daemon of another build; `None` leaves `error` as it is
/// (another error, or the daemon is this build: then the refusal is real).
/// `socket` names the daemon in the fix command when the caller knows it.
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
    let own = Own {
        version: cmux_tui_core::release::distribution_version(),
        build_commit: crate::build_stamp().build_commit(),
    };
    outdated(&identity, operation, &own, &fix_command(socket))
}

/// This CLI's release and source commit.
pub(super) struct Own<'a> {
    pub version: &'a str,
    pub build_commit: Option<&'a str>,
}

/// The `daemon.outdated` error for a daemon that answered `identity` (or
/// `Null` when it did not answer); `None` when the daemon is this build.
pub(super) fn outdated(
    identity: &Value,
    operation: &str,
    own: &Own<'_>,
    fix: &str,
) -> Option<Value> {
    let daemon_commit = identity.get("build_commit").and_then(Value::as_str);
    let daemon_version = identity.get("version").and_then(Value::as_str);
    if daemon_commit.is_some() && daemon_commit == own.build_commit {
        return None;
    }
    let messages = &crate::localization::catalog().skew;
    let message = match daemon_version {
        Some(version) => {
            let build = daemon_commit.map_or_else(
                || messages.unknown_build.to_owned(),
                |commit| commit.chars().take(8).collect(),
            );
            messages.older_daemon.replace("{daemon}", version).replace("{build}", &build)
        }
        None => messages.older_daemon_unknown.to_owned(),
    };
    let message = message
        .replace("{own}", own.version)
        .replace("{operation}", operation)
        .replace("{fix}", fix);
    Some(json!({
        "code": "daemon.outdated",
        "message": message,
        "details": {
            "operation": operation,
            "daemon_version": daemon_version,
            "daemon_build": daemon_commit,
            "cli_version": own.version,
            "cli_build": own.build_commit,
            "action": "restart_daemon",
            "fix": fix,
        },
        "retryable": false,
    }))
}

/// `cmux daemon restart` for the daemon at `socket`, run by this CLI.
fn fix_command(socket: Option<&Path>) -> String {
    let cli = super::fix_command::this_cli();
    match socket {
        Some(socket) => super::fix_command::restart_daemon_in_place(&cli, socket),
        None => format!("{} daemon restart", super::fix_command::quote_arg(&cli.to_string_lossy())),
    }
}

/// The daemon's `identify` data, asked on the connection that was refused
/// (an envelope refusal keeps it open); `None` when it does not answer.
fn identify(reader: &mut Reader) -> Option<Value> {
    let request = json!({"id": "cli-older-daemon", "cmd": "identify"});
    let stream = reader.get_mut();
    stream.write_all(format!("{request}\n").as_bytes()).and_then(|()| stream.flush()).ok()?;
    for _ in 0..IDENTIFY_LINES {
        let value = super::wire::read_envelope(reader, false).ok()??;
        if value.get("id").and_then(Value::as_str) == Some("cli-older-daemon") {
            return (value.get("ok") == Some(&Value::Bool(true))).then(|| value["data"].clone());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    const OWN: Own<'static> = Own { version: "1.0.0", build_commit: Some("af881f169c64") };

    fn refusal() -> Value {
        json!({
            "code": "validation.invalid",
            "message": "invalid request envelope",
            "details": {"reason": "invalid request envelope"},
            "retryable": false,
        })
    }

    #[test]
    fn an_envelope_refusal_is_recognized_in_old_and_new_shapes() {
        assert!(is_envelope_refusal(&refusal()));
        let newer = json!({"code":"validation.invalid","message":"invalid request envelope",
            "details":{"error":"unknown variant `agent.message.send`"}});
        assert!(is_envelope_refusal(&newer));
        let other = json!({"code":"validation.invalid","message":"body must be a string"});
        assert!(!is_envelope_refusal(&other));
    }

    #[test]
    fn an_older_daemon_is_named_with_its_build_and_the_restart_fix() {
        let identity =
            json!({"version":"0.1.0","build_commit":"316d139feaf89d9ab7c99dc9cffdce59309bef93"});
        let fix = "cmux daemon restart --socket /run/main.sock";
        let error = outdated(&identity, "agent.message.send", &OWN, fix).unwrap();
        let message = error["message"].as_str().unwrap();
        assert!(
            message.starts_with("daemon 0.1.0 (316d139f) is older than this cmux 1.0.0"),
            "{message}"
        );
        assert!(message.contains("agent.message.send"), "{message}");
        assert!(message.contains(fix), "{message}");
        assert!(message.contains("terminals are kept"), "{message}");
        assert!(!error.to_string().contains("invalid request envelope"), "{error}");
        assert_eq!(error["code"], "daemon.outdated");
        assert_eq!(error["details"]["daemon_build"], "316d139feaf89d9ab7c99dc9cffdce59309bef93");
    }

    #[test]
    fn a_daemon_that_does_not_answer_still_gets_the_restart_fix() {
        let error =
            outdated(&Value::Null, "agent.message.send", &OWN, "cmux daemon restart").unwrap();
        let message = error["message"].as_str().unwrap();
        assert!(message.contains("cmux daemon restart"), "{message}");
        assert!(!message.contains("invalid request envelope"), "{message}");
    }

    #[test]
    fn the_same_build_keeps_its_own_refusal() {
        let identity = json!({"version":"1.0.0","build_commit":"af881f169c64"});
        assert!(outdated(&identity, "agent.message.send", &OWN, "fix").is_none());
    }
}
