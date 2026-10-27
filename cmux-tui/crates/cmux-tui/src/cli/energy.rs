//! `cmux energy [status|off|on|auto]`: Energy Saver from the command line
//! (plans/cmux-next/chrome-parity/p14-energy.md, task 033).
//!
//! The app owns Energy Saver: it resolves it from the power inputs and the
//! `energy.saver` setting, and tells the daemon on each edge (`energy.set`).
//! So `off`, `on` and `auto` run the app's session actions through
//! `action.run`, the path the palette and MCP use
//! (`energy.saver.turnOffForNow`, `energy.saver.turnOnNow`): Chrome's
//! battery saver bubble offers the same "Turn off for now"
//! (chrome/browser/ui/views/performance_controls/battery_saver_bubble_view.cc).
//! `status` reads both owners: the app's resolved policy and inputs (its
//! control method `energy.status`, served in every build) and the daemon's
//! mode (the session socket's `energy.status`). The MCP `energy_status`
//! tool returns the same report.

use std::io::{BufRead, BufReader, Read, Write};
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::app::ActionName;
use super::{GlobalArgs, OutputMode, UsageError};
use crate::cli::json_fields::JsonFields;
use crate::localization::EnergyMessages;

/// The app action that `off` runs.
pub(super) const TURN_OFF_FOR_NOW: &str = "energy.saver.turnOffForNow";
/// The app action that `on` and `auto` run.
pub(super) const TURN_ON_NOW: &str = "energy.saver.turnOnNow";
/// The app method that reports the resolved policy and its inputs
/// (CmuxNextControl `EnergyReport.statusMethod`, registered in release
/// builds too; `debug.energy` is the Debug-only cost report).
pub(super) const APP_STATUS_METHOD: &str = "energy.status";
/// The daemon line that reports its mode (cmux-tui-core server/energy_op.rs).
pub(super) const DAEMON_STATUS_COMMAND: &str = "energy.status";
/// `energy.status` answers from memory; this only bounds a stuck daemon.
const DAEMON_READ_TIMEOUT: Duration = Duration::from_secs(5);
/// The largest `energy.status` reply line read.
const MAX_DAEMON_REPLY: u64 = 64 * 1024;
/// The MCP tool that reads both halves of `status`.
pub(super) const MCP_STATUS_TOOL: &str = "energy_status";

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Verb {
    Help,
    Status,
    /// Runs this app action.
    Action(&'static str),
}

/// `cmux energy …`. `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (first, rest) = command_args.split_first()?;
    if first != "energy" {
        return None;
    }
    Some(match parse(rest) {
        Ok(verb) => run(&global, verb),
        Err(error) => {
            super::app::failure("usage.invalid", &format!("cmux: {error}"), global.output, 2)
        }
    })
}

pub(super) fn parse(rest: &[String]) -> Result<Verb, UsageError> {
    let messages = &crate::localization::catalog().energy;
    if rest.iter().any(|arg| arg == "--help" || arg == "-h") {
        return Ok(Verb::Help);
    }
    let (verb, tail) = match rest.split_first() {
        Some((verb, tail)) => (verb.as_str(), tail),
        None => ("status", rest),
    };
    let parsed = match verb {
        "help" => return Ok(Verb::Help),
        "status" => Verb::Status,
        // The app catalog's CLI names (`energy turn-off-for-now`, `energy turn-on`) too.
        "off" | "turn-off-for-now" => Verb::Action(TURN_OFF_FOR_NOW),
        "on" | "auto" | "turn-on" => Verb::Action(TURN_ON_NOW),
        other => return Err(UsageError::new(messages.unknown_verb.replace("{verb}", other))),
    };
    if let Some(extra) = tail.first() {
        return Err(UsageError::new(
            messages.unexpected_argument.replace("{verb}", verb).replace("{value}", extra),
        ));
    }
    Ok(parsed)
}

fn run(global: &GlobalArgs, verb: Verb) -> i32 {
    let messages = &crate::localization::catalog().energy;
    match verb {
        Verb::Help => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(messages.usage.as_bytes());
            let _ = stdout.flush();
            0
        }
        Verb::Action(action) => match super::app::run_action(action, &[], ActionName::Any) {
            Ok(command) => super::app::run(global, command),
            Err(error) => {
                super::app::failure("usage.invalid", &format!("cmux: {error}"), global.output, 2)
            }
        },
        Verb::Status => {
            let app = app_status(global);
            let daemon = daemon_status(global);
            let report = report(app, daemon);
            let shown = match global.output {
                OutputMode::Human => json!(status_text(&report, messages)),
                _ => report,
            };
            super::wire::print_local_success(&shown, global.output)
        }
    }
}

/// The app's resolved policy and inputs, or the error that kept them.
fn app_status(global: &GlobalArgs) -> Result<Value, String> {
    let mut stream = super::app::connect_command(global).map_err(|error| error_text(&error))?;
    match super::app::request(&mut stream, APP_STATUS_METHOD, json!({}), super::app::READ_TIMEOUT) {
        Ok(Ok(value)) => Ok(app_part(&value)),
        Ok(Err(error)) => Err(error_text(&error)),
        Err(message) => Err(message),
    }
}

/// The part of the app's report that `status` and the MCP tool show: the
/// policy and the inputs it was resolved from.
pub(super) fn app_part(report: &Value) -> Value {
    json!({
        "policy": report.get("policy").cloned().unwrap_or(Value::Null),
        "inputs": report.get("inputs").cloned().unwrap_or(Value::Null),
    })
}

/// The daemon's `energy.status`, or the error that kept it.
fn daemon_status(global: &GlobalArgs) -> Result<Value, String> {
    daemon_line(global, DAEMON_STATUS_COMMAND)
}

/// The data of the session daemon's reply to the field-less line `cmd`
/// (one the daemon answers before its command parse), or its error.
pub(super) fn daemon_line(global: &GlobalArgs, cmd: &str) -> Result<Value, String> {
    let (socket, derived) =
        super::wire::resolve_socket_with_origin(global).map_err(|error| error.to_string())?;
    let stream = cmux_tui_core::server::connect_session_socket(&socket, derived)
        .map_err(|error| error.to_string())?;
    // wakeup-allow: cli-only `cmux energy status`'s one bound on the daemon's reply; the reply ends the read first
    let _ = stream.set_read_timeout(Some(DAEMON_READ_TIMEOUT));
    let mut reader = BufReader::new(stream);
    let request = json!({"id": "energy-status", "cmd": cmd});
    let mut line = serde_json::to_vec(&request).map_err(|error| error.to_string())?;
    line.push(b'\n');
    reader.get_mut().write_all(&line).map_err(|error| error.to_string())?;
    loop {
        let mut reply = String::new();
        let read = reader
            .by_ref()
            .take(MAX_DAEMON_REPLY)
            .read_line(&mut reply)
            .map_err(|error| error.to_string())?;
        if read == 0 {
            return Err("transport closed before response".into());
        }
        let value: Value = serde_json::from_str(&reply).map_err(|error| error.to_string())?;
        if value.get("id") != Some(request.field("id")) {
            continue;
        }
        return daemon_reply(value);
    }
}

/// The data of an `energy.status` reply, or its error.
pub(super) fn daemon_reply(reply: Value) -> Result<Value, String> {
    if reply.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(reply.get("data").cloned().unwrap_or(Value::Null));
    }
    Err(reply
        .get("error_code")
        .or_else(|| reply.get("error"))
        .and_then(Value::as_str)
        .unwrap_or("energy.status failed")
        .to_owned())
}

/// The message (or code) of an owner's error.
pub(super) fn error_text(error: &Value) -> String {
    error
        .get("message")
        .or_else(|| error.get("code"))
        .and_then(Value::as_str)
        .unwrap_or("unknown error")
        .to_owned()
}

/// `{"app": …, "daemon": …}`; a side that did not answer is
/// `{"error": "…"}`.
pub(super) fn report(app: Result<Value, String>, daemon: Result<Value, String>) -> Value {
    let side =
        |result: Result<Value, String>| result.unwrap_or_else(|error| json!({"error": error}));
    json!({"app": side(app), "daemon": side(daemon)})
}

/// One line for the app and one for the daemon.
pub(super) fn status_text(report: &Value, messages: &EnergyMessages) -> String {
    let app = &report["app"];
    let app_line = if app.get("error").is_some() {
        messages.app_unreachable.to_owned()
    } else if app.field("policy").field("isSaver") == true {
        let reason = reason_text(app.field("policy").field("reason").as_str(), messages);
        messages.app_on.replace("{reason}", reason)
    } else if app.field("inputs").field("sessionOverride") == true {
        messages.app_held_off.to_owned()
    } else {
        messages.app_off.to_owned()
    };
    let daemon = &report["daemon"];
    let daemon_line = match daemon.get("error").and_then(Value::as_str) {
        Some(error) => messages.daemon_unreachable.replace("{error}", error),
        None => {
            let by_app = daemon["source"] == "app";
            match (daemon["saver"] == true, by_app) {
                (true, true) => messages.daemon_on_app.to_owned(),
                (true, false) => messages.daemon_on_own.to_owned(),
                (false, true) => messages.daemon_off_app.to_owned(),
                (false, false) => messages.daemon_off_own.to_owned(),
            }
        }
    };
    format!("{app_line}\n{daemon_line}")
}

fn reason_text<'m>(reason: Option<&str>, messages: &'m EnergyMessages) -> &'m str {
    match reason {
        Some("lowPowerMode") => messages.reason_low_power_mode,
        Some("battery") => messages.reason_battery,
        Some("thermal") => messages.reason_thermal,
        _ => messages.reason_setting,
    }
}

/// The MCP tool that reads Energy Saver in the app and the session daemon,
/// as `cmux energy status --json` prints it. `off` and `on` are the
/// app's own action tools (`app_energy_turn_off_for_now`,
/// `app_energy_turn_on`), listed from `action.list` like every CLI action.
pub(super) fn mcp_tool() -> Value {
    json!({
        "name": MCP_STATUS_TOOL,
        "description": "Whether cmux's Energy Saver is on, why, and the inputs it was resolved from \
            (Low Power Mode, power source, battery, thermal state, the energy.saver setting, \"off for \
            now\"), as {app, daemon}: app is the app's policy and inputs, daemon the session daemon's \
            mode, its source (the app's override or its own reading) and both inputs. A side that does \
            not answer is {error}. Changes nothing; the app_energy_* tools turn it off for now and back on.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false},
        "annotations": {
            "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false,
        },
    })
}

/// The MCP tool's arguments: it takes none.
pub(super) fn mcp_arguments(arguments: &Map<String, Value>) -> Result<(), String> {
    match arguments.keys().next() {
        Some(name) => Err(format!("{MCP_STATUS_TOOL} has no argument {name:?}")),
        None => Ok(()),
    }
}

#[cfg(test)]
#[path = "energy_tests.rs"]
mod tests;
