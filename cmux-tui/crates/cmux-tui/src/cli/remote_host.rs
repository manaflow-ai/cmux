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

const HELP: &str = "Usage: cmux remote-host <status|refresh|request|open-settings|restart|share|grants|access|stop>\n\ncmux Remote holds the macOS grants (Accessibility, Screen Recording) for Computer Use and Screen Sharing. Grant them once, to \"cmux Remote\"; cmux never needs a relaunch.\n\n  cmux remote-host status                       The host, its workers, the grants and this Mac's sharing state\n  cmux remote-host refresh                      Read the grants again (a worker started before a new grant restarts)\n  cmux remote-host request accessibility|screen-recording\n                                                Ask macOS for a grant (macOS asks the person; a second ask opens System Settings)\n  cmux remote-host open-settings accessibility|screen-recording\n                                                Open the System Settings pane that lists cmux Remote\n  cmux remote-host restart computer-use|screen-sharing [--force]\n                                                Start a worker again (a Screen Sharing session ends first only with --force)\n  cmux remote-host share on|off                 Share This Mac (on: the person confirms in cmux)\n  cmux remote-host share on --device DEVICE     Share another Mac of yours: you confirm here, in this device's cmux, and that Mac admits it only from a machine its owner granted\n  cmux remote-host grants [--device DEVICE] [--open]\n                                                Which macOS grant cmux Remote lacks on a Mac (--open opens its System Settings pane there), and whether an agent can click it over screen sharing\n  cmux remote-host access DEVICE none|ask|view|full\n                                                A device's access to this Mac (raising it: the person confirms in cmux)\n  cmux remote-host stop                         Stop the current Screen Sharing session\n";

/// How long the person may take to answer cmux's confirmation sheet: the CLI and the
/// `remote_*` MCP tools wait this long for the click. The app's `remote.confirm` deadline
/// (`CmuxRemoteActionEnvironment.confirmationTimeout`) is the same 600 s. It was 130 s on
/// both sides, and the CLI's clock starts before the app gets the request, so a late
/// Allow was cancelled with the dialog while the CLI reported a timeout.
pub(super) const CONFIRM_TIMEOUT: Duration = Duration::from_secs(600);

/// Handles `cmux remote-host` before the normal daemon grammar.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = parse_globals(args).ok()?;
    let (first, rest) = command_args.split_first()?;
    if first != "remote-host" {
        return None;
    }
    Some(run(global, rest))
}

fn run(global: GlobalArgs, args: &[String]) -> i32 {
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let call = |method: &str, params: Value| {
        daemon(&global, json!({"cmd": "remote-host-call", "method": method, "params": params}))
    };
    match words.as_slice() {
        [] | ["status"] => daemon(&global, json!({"cmd": "remote-host-status"})),
        ["refresh"] => call("refresh", json!({})),
        ["request", permission] => match permission_name(permission) {
            Some(name) => call("request", json!({"permission": name})),
            None => usage(&global, args),
        },
        ["open-settings", permission] => match permission_name(permission) {
            Some(name) => call("open_settings", json!({"permission": name})),
            None => usage(&global, args),
        },
        ["restart", worker @ ("computer-use" | "screen-sharing")] => {
            call("restart", json!({"worker": worker, "force": false}))
        }
        ["restart", worker @ ("computer-use" | "screen-sharing"), "--force"] => {
            call("restart", json!({"worker": worker, "force": true}))
        }
        ["share", "off"] => call("screen.share", json!({"on": false})),
        ["share", "on"] => app(&global, json!({"action": "share", "on": true})),
        ["share", "on", "--device", device] => share_device(&global, device),
        ["grants", rest @ ..] => match grants_args(rest) {
            Some((device, open)) => grants(&global, device, open),
            None => usage(&global, args),
        },
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
        _ => usage(&global, args),
    }
}

fn usage(global: &GlobalArgs, args: &[String]) -> i32 {
    super::scope_usage_failure(
        global.output,
        "remote-host",
        &super::unknown_words("remote-host", args),
        HELP,
    )
}

fn permission_name(word: &str) -> Option<&'static str> {
    match word {
        "accessibility" => Some("accessibility"),
        "screen-recording" | "screen_recording" => Some("screen-recording"),
        _ => None,
    }
}

fn daemon(global: &GlobalArgs, mut request: Value) -> i32 {
    if let Some(fields) = request.as_object_mut() {
        fields.insert("id".into(), json!(1));
    }
    raw::run(global.clone(), raw::RawCommandPlan { request, stream: false })
}

/// Tries the daemon's lowering path; `None` when the daemon says raising
/// needs the app (then the app asks the person).
fn lower_or_refused(global: &GlobalArgs, params: &Value) -> Option<i32> {
    let request =
        json!({"id": 1, "cmd": "remote-host-call", "method": "screen.access", "params": params});
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
    let (socket, derived) = super::wire::resolve_socket_with_origin(global)
        .map_err(|error| super::wire::resolve_failure(&error))?;
    let stream =
        cmux_tui_core::server::connect_session_socket(&socket, derived).map_err(|error| {
            failure(
                "transport.unavailable",
                format!("cannot connect to {}: {error}", socket.display()),
            )
        })?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(25)));
    let mut reader = BufReader::new(stream);
    writeln!(reader.get_mut(), "{request}")
        .and_then(|()| reader.get_mut().flush())
        .map_err(|error| failure("transport.failed", format!("{error}")))?;
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => {
                return Err(failure("transport.closed", "the daemon closed the connection".into()));
            }
            Ok(_) => {}
            Err(error) => return Err(failure("transport.failed", format!("{error}"))),
        }
        let Ok(response) = serde_json::from_str::<Value>(&line) else { continue };
        if response.get("event").is_some() || response.get("id") != request.get("id") {
            continue;
        }
        if response.get("ok").and_then(Value::as_bool) == Some(true) {
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

/// `share on --device DEVICE`: the person confirms in this device's cmux app, which signs the
/// approval only after the click; the target Mac admits it (`remote_host::share_approval`).
fn share_device(global: &GlobalArgs, device: &str) -> i32 {
    use crate::remote_host::share_approval;
    let ask =
        |params| super::mcp::agent_app(global, "remote.confirm", params, CONFIRM_TIMEOUT, None);
    let deliver = share_approval::AwaitingSameAccountControl;
    match share_approval::share_from_here(device, ask, &deliver, crate::devices::record) {
        Ok(value) => super::wire::print_local_success(&value, global.output),
        Err(error) => super::wire::print_local_error(&error, global.output, 1),
    }
}

/// `grants`' flags: `--device DEVICE` and `--open`, once each, in any order.
fn grants_args(words: &[&str]) -> Option<(Option<String>, bool)> {
    let (mut device, mut open) = (None, false);
    let mut words = words.iter();
    while let Some(word) = words.next() {
        match *word {
            "--device" if device.is_none() => device = Some((*words.next()?).to_owned()),
            "--open" if !open => open = true,
            _ => return None,
        }
    }
    Some((device, open))
}

fn grants(global: &GlobalArgs, device: Option<String>, open: bool) -> i32 {
    use super::remote_host_grants::{Local, Ssh, grants, route};
    let result = match device.as_deref() {
        None => grants(&Local, None, open),
        Some(device) => grants(&Ssh(route(&acpmux_peers(), device)), Some(device), open),
    };
    match result {
        Ok(value) => super::wire::print_local_success(&value, global.output),
        Err(error) => super::wire::print_local_error(&error, global.output, 1),
    }
}

/// `cmux acp host ls --json` (the acpmux peers and their routes); null when it does not answer.
fn acpmux_peers() -> Value {
    let Ok(exe) = crate::remote_host::self_exe() else { return Value::Null };
    cmux_process::Command::new(exe)
        .args(["acp", "host", "ls", "--json"])
        .stdin(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| serde_json::from_slice(&output.stdout).ok())
        .unwrap_or(Value::Null)
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::CONFIRM_TIMEOUT;

    /// The person gets minutes, not the old 130 s, to answer; the app's deadline matches.
    #[test]
    fn share_confirmation_waits_for_the_person_past_the_old_timeout() {
        assert_eq!(CONFIRM_TIMEOUT, Duration::from_secs(600));
        assert!(CONFIRM_TIMEOUT > Duration::from_secs(130));
    }
}
