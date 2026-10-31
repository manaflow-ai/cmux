//! `cmux remote-host`: cmux Remote, the one process that holds macOS's
//! Accessibility and Screen Recording grants for Computer Use and Screen
//! Sharing (docs/cmux-remote.md). Reads, refreshes, grant requests, worker
//! restarts and lowering access go to the daemon (they work with the app
//! quit). Turning Share This Mac on or raising a device's access goes to the
//! cmux app, which asks the person first: an agent never grants a device
//! access to this Mac by itself.

use std::time::Duration;

use serde_json::{Value, json};

use super::{GlobalArgs, parse_globals, raw};

const HELP: &str = "Usage: cmux remote-host <status|refresh|request|open-settings|restart|share|access|stop>\n\ncmux Remote holds the macOS grants (Accessibility, Screen Recording) for Computer Use and Screen Sharing. Grant them once, to \"cmux Remote\"; cmux never needs a relaunch.\n\n  cmux remote-host status                       The host, its workers, the grants and this Mac's sharing state\n  cmux remote-host refresh                      Read the grants again (a worker started before a new grant restarts)\n  cmux remote-host request accessibility|screen-recording\n                                                Ask macOS for a grant (macOS asks the person; a second ask opens System Settings)\n  cmux remote-host open-settings accessibility|screen-recording\n                                                Open the System Settings pane that lists cmux Remote\n  cmux remote-host restart computer-use|screen-sharing [--force]\n                                                Start a worker again (a Screen Sharing session ends first only with --force)\n  cmux remote-host share on|off                 Share This Mac (on: the person confirms in cmux)\n  cmux remote-host access DEVICE none|ask|view|full\n                                                A device's access to this Mac (raising it: the person confirms in cmux)\n  cmux remote-host stop                         Stop the current Screen Sharing session\n";

/// How long the person may take to answer cmux's confirmation sheet.
const CONFIRM_TIMEOUT: Duration = Duration::from_secs(130);

/// Handles `cmux remote-host` before the normal daemon grammar.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = parse_globals(args).ok()?;
    if command_args.first().map(String::as_str) != Some("remote-host") {
        return None;
    }
    Some(run(global, &command_args[1..]))
}

fn run(global: GlobalArgs, args: &[String]) -> i32 {
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let call = |method: &str, params: Value| daemon(&global, json!({"cmd": "remote-host-call", "method": method, "params": params}));
    match words.as_slice() {
        [] | ["status"] => daemon(&global, json!({"cmd": "remote-host-status"})),
        ["refresh"] => call("refresh", json!({})),
        ["request", permission] => match permission_name(permission) {
            Some(name) => call("request", json!({"permission": name})),
            None => usage(),
        },
        ["open-settings", permission] => match permission_name(permission) {
            Some(name) => call("open_settings", json!({"permission": name})),
            None => usage(),
        },
        ["restart", worker @ ("computer-use" | "screen-sharing")] => call("restart", json!({"worker": worker, "force": false})),
        ["restart", worker @ ("computer-use" | "screen-sharing"), "--force"] => {
            call("restart", json!({"worker": worker, "force": true}))
        }
        ["share", "off"] => call("screen.share", json!({"on": false})),
        ["share", "on"] => app(&global, json!({"action": "share", "on": true})),
        ["access", device, scope @ ("none" | "ask" | "view" | "full")] => {
            // Lowering works through the daemon; raising is the app's (the daemon says which).
            let params = json!({"device": device, "scope": scope});
            match lower_or_refused(&global, &params) {
                Some(code) => code,
                None => app(&global, json!({"action": "access", "device": device, "scope": scope})),
            }
        }
        ["stop"] => call("screen.stop_session", json!({})),
        ["help"] | ["--help"] | ["-h"] => {
            print!("{HELP}");
            0
        }
        _ => usage(),
    }
}

fn usage() -> i32 {
    eprint!("{HELP}");
    2
}

fn permission_name(word: &str) -> Option<&'static str> {
    match word {
        "accessibility" => Some("accessibility"),
        "screen-recording" | "screen_recording" => Some("screen-recording"),
        _ => None,
    }
}

fn daemon(global: &GlobalArgs, mut request: Value) -> i32 {
    request["id"] = json!(1);
    raw::run(global.clone(), raw::RawCommandPlan { request, stream: false })
}

/// Tries the daemon's lowering path; `None` when the daemon says raising
/// needs the app (then the app asks the person).
fn lower_or_refused(global: &GlobalArgs, params: &Value) -> Option<i32> {
    let request = json!({"id": 1, "cmd": "remote-host-call", "method": "screen.access", "params": params});
    match daemon_value(global, &request) {
        Ok(value) => Some(super::wire::print_local_success(&value, global.output)),
        Err(error) if error.get("code").and_then(Value::as_str) == Some("origin.forbidden") => None,
        Err(error) => Some(super::wire::print_local_error(&error, global.output, 1)),
    }
}

/// One legacy daemon command's `data`, or `{code, message}`.
pub(super) fn daemon_value(global: &GlobalArgs, request: &Value) -> Result<Value, Value> {
    use std::io::{BufRead, BufReader, Write};
    let failure = |code: &str, message: String| json!({"code": code, "message": message});
    let (socket, derived) =
        super::wire::resolve_socket_with_origin(global).map_err(|error| super::wire::resolve_failure(&error))?;
    let stream = cmux_tui_core::server::connect_session_socket(&socket, derived)
        .map_err(|error| failure("transport.unavailable", format!("cannot connect to {}: {error}", socket.display())))?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(25)));
    let mut reader = BufReader::new(stream);
    writeln!(reader.get_mut(), "{request}")
        .and_then(|()| reader.get_mut().flush())
        .map_err(|error| failure("transport.failed", format!("{error}")))?;
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => return Err(failure("transport.closed", "the daemon closed the connection".into())),
            Ok(_) => {}
            Err(error) => return Err(failure("transport.failed", format!("{error}"))),
        }
        let Ok(response) = serde_json::from_str::<Value>(&line) else { continue };
        if response.get("event").is_some() || response["id"] != request["id"] {
            continue;
        }
        if response["ok"] == true {
            return Ok(response.get("data").cloned().unwrap_or(Value::Null));
        }
        let code = response.get("error_code").and_then(Value::as_str).unwrap_or("request.rejected");
        let message = response.get("error").and_then(Value::as_str).unwrap_or("request rejected");
        return Err(failure(code, message.to_string()));
    }
}

/// An action the person confirms in cmux (`remote.confirm`).
fn app(global: &GlobalArgs, params: Value) -> i32 {
    match super::mcp::agent_app(global, "remote.confirm", params, CONFIRM_TIMEOUT, None) {
        Ok(value) => super::wire::print_local_success(&value, global.output),
        Err(error) => super::wire::print_local_error(&error, global.output, 1),
    }
}
