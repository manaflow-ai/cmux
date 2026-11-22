//! `cmux helper`: cmux Helper, the build's one app that holds macOS's
//! Accessibility and Screen Recording grants for Computer Use and Screen
//! Sharing (docs/cmux-helper.md). `status` reads the daemon (the helper's
//! grants as the cmux app reported them); `grants` and `open-settings` read
//! and open System Settings. Sharing changes go to the cmux app: turning
//! Share This Mac on and a device's access ask the person first, so an agent
//! never grants a device access to this Mac by itself; share off and stop
//! are the app's own Stop actions.

use std::time::Duration;

use serde_json::{Value, json};

use super::{GlobalArgs, parse_globals};

const HELP: &str = "Usage: cmux helper <status|open-settings|share|grants|access|stop>\n\ncmux Helper holds the macOS grants (Accessibility, Screen Recording) for Computer Use and Screen Sharing. Grant them once; cmux never needs a relaunch.\n\n  cmux helper status                       The helper's grants and the Computer Use worker\n  cmux helper open-settings accessibility|screen-recording\n                                           Open the System Settings pane that lists cmux Helper\n  cmux helper share on|off                 Share This Mac (on: the person confirms in cmux)\n  cmux helper share on --device DEVICE     Share another Mac of yours: you confirm here, in this device's cmux, and that Mac admits it only from a machine its owner granted\n  cmux helper grants [--device DEVICE] [--open]\n                                           Which macOS grant cmux Helper lacks on a Mac (--open opens its System Settings pane there), and whether an agent can click it over screen sharing\n  cmux helper access DEVICE none|ask|view|full\n                                           A device's access to this Mac (the person confirms in cmux)\n  cmux helper stop                         Stop the current Screen Sharing session\n";

/// How long the person may take to answer cmux's confirmation sheet: the CLI and the
/// `helper_*` MCP tools wait this long for the click. The app's `remote.confirm` deadline
/// (`CmuxHelperActionEnvironment.confirmationTimeout`) is the same 600 s. It was 130 s on
/// both sides, and the CLI's clock starts before the app gets the request, so a late
/// Allow was cancelled with the dialog while the CLI reported a timeout.
pub(super) const CONFIRM_TIMEOUT: Duration = Duration::from_secs(600);

/// Handles `cmux helper` before the normal daemon grammar.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = parse_globals(args).ok()?;
    let (first, rest) = command_args.split_first()?;
    if first != "helper" {
        return None;
    }
    Some(run(global, rest))
}

fn run(global: GlobalArgs, args: &[String]) -> i32 {
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    match words.as_slice() {
        [] | ["status"] => status(&global),
        ["open-settings", permission] => match permission_grant(permission) {
            Some(grant) => open_settings(&global, grant),
            None => usage(&global, args),
        },
        ["share", "off"] => lower(&global, LowerChange::ShareOff),
        ["share", "on"] => app(&global, json!({"action": "share", "on": true})),
        ["share", "on", "--device", device] => share_device(&global, device),
        ["grants", rest @ ..] => match grants_args(rest) {
            Some((device, open)) => grants(&global, device, open),
            None => usage(&global, args),
        },
        ["access", device, scope @ ("none" | "ask" | "view" | "full")] => {
            app(&global, json!({"action": "access", "device": device, "scope": scope}))
        }
        ["stop"] => lower(&global, LowerChange::StopSession),
        ["help"] | ["--help"] | ["-h"] => {
            print!("{HELP}");
            0
        }
        _ => usage(&global, args),
    }
}

fn usage(global: &GlobalArgs, args: &[String]) -> i32 {
    super::scope_usage_failure(global.output, "helper", &super::unknown_words("helper", args), HELP)
}

fn permission_grant(word: &str) -> Option<&'static super::helper_grants::Grant> {
    let key = match word {
        "accessibility" => "accessibility",
        "screen-recording" | "screen_recording" => "screen-recording",
        _ => return None,
    };
    super::helper_grants::GRANTS.iter().find(|grant| grant.key == key)
}

/// `open-settings`: the grant's System Settings pane, where macOS lists cmux Helper.
fn open_settings(global: &GlobalArgs, grant: &super::helper_grants::Grant) -> i32 {
    let opened = cmux_process::Command::new("/usr/bin/open")
        .arg(grant.pane)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .status();
    match opened {
        Ok(status) if status.success() => super::wire::print_local_success(
            &json!({"opened": grant.key, "pane": grant.pane}),
            global.output,
        ),
        Ok(status) => super::wire::print_local_error(
            &json!({"code": "open.failed", "message": format!("open exited with {status}")}),
            global.output,
            1,
        ),
        Err(error) => super::wire::print_local_error(
            &json!({"code": "open.failed", "message": format!("cannot run open: {error}")}),
            global.output,
            1,
        ),
    }
}

/// A change that only lowers what this Mac shares: the cmux app's own action makes it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum LowerChange {
    ShareOff,
    StopSession,
}

impl LowerChange {
    /// The cmux app action that makes the change.
    pub(super) fn app_action(self) -> &'static str {
        match self {
            Self::ShareOff => "macScreen.stopSharingThisMac",
            Self::StopSession => "macScreen.stopSharing",
        }
    }
}

fn lower(global: &GlobalArgs, change: LowerChange) -> i32 {
    let action = change.app_action();
    let params =
        Value::Object(super::app::action_run_params(action, super::app::ActionName::Any, "cli"));
    let timeout = super::app::waiting_run_timeout(action);
    match super::mcp::agent_app(global, "action.run", params, timeout, None) {
        Ok(value) => super::wire::print_local_success(&value, global.output),
        Err(error) => super::wire::print_local_error(&error, global.output, 1),
    }
}

/// `cmux helper status`: the daemon's `helper-status`.
fn status(global: &GlobalArgs) -> i32 {
    match daemon_value(global, &json!({"id": 1, "cmd": "helper-status"})) {
        Ok(value) => super::wire::print_local_success(&value, global.output),
        Err(error) => super::wire::print_local_error(&error, global.output, 1),
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
        Err(error) => super::wire::print_local_error(&still_open(error), global.output, 1),
    }
}

/// A confirmation past its wait, from the app (`timeout`) or this read: the
/// dialog stays open in cmux and an Allow there still makes the change, so the
/// error says that instead of "the cmux app did not answer".
fn still_open(mut error: Value) -> Value {
    let timed_out = error.get("code").and_then(Value::as_str) == Some("timeout")
        || error.pointer("/details/timeout_seconds").is_some();
    if timed_out && let Some(object) = error.as_object_mut() {
        let message = crate::localization::catalog().app_control.helper_confirm_still_open;
        object.insert("message".into(), Value::String(message.into()));
    }
    error
}

/// `remote.confirm {"action":"allow_agents","on":true}` to this machine's cmux app: turns on
/// "My agents can turn screen sharing and control on my machines". The app always asks the
/// person first. `cmux device setup --allow-agents` (devices/setup.rs) sends it.
pub(crate) fn confirm_allow_agents() -> Result<Value, Value> {
    super::mcp::agent_app(
        &GlobalArgs::default(),
        "remote.confirm",
        json!({"action": "allow_agents", "on": true}),
        CONFIRM_TIMEOUT,
        None,
    )
}

/// `share on --device DEVICE`: the person confirms in this device's cmux app, which signs the
/// approval only after the click; the target Mac admits it (`crate::remote_host::share_approval`).
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
    use super::helper_grants::{Local, Ssh, grants, route};
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
    use serde_json::json;

    use super::{LowerChange, still_open};

    /// The app actions share off and stop go to are in the catalog the app reads.
    #[test]
    fn the_app_actions_for_share_off_and_stop_are_cataloged() {
        let catalog: serde_json::Value =
            serde_json::from_str(&cmux_tui_core::packed_catalogs::ACTION_SURFACES.inflate())
                .expect("the action catalog is valid JSON");
        for change in [LowerChange::ShareOff, LowerChange::StopSession] {
            let id = change.app_action();
            assert!(
                catalog["actions"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|action| action["id"] == id),
                "{id} is not in the action catalog"
            );
        }
    }

    #[test]
    fn a_confirmation_past_its_wait_says_the_dialog_still_counts() {
        let expected = crate::localization::catalog().app_control.helper_confirm_still_open;
        let read = json!({"code": "app.transport", "message": "the cmux app did not answer", "details": {"timeout_seconds": 130}});
        assert_eq!(still_open(read)["message"], expected);
        let app =
            json!({"code": "timeout", "message": "remote.confirm did not finish within 130000 ms"});
        assert_eq!(still_open(app)["message"], expected);
        let other = json!({"code": "app.unreachable", "message": "no app"});
        assert_eq!(still_open(other.clone()), other);
    }

    /// The person gets minutes, not the old 130 s, to answer; the app's deadline matches.
    #[test]
    fn share_confirmation_waits_for_the_person_past_the_old_timeout() {
        assert_eq!(super::CONFIRM_TIMEOUT, std::time::Duration::from_secs(600));
        assert!(super::CONFIRM_TIMEOUT > std::time::Duration::from_secs(130));
    }
}
