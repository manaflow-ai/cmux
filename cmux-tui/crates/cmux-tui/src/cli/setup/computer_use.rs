//! `cmux setup computer-use [--dry-run]`: lets agents use the Mac through
//! cmux Computer Use, and hands the person only their clicks.
//!
//! The state is the app's `computer_use.status` (the model behind Computer
//! Use Setup and `cmux agents doctor`): `{phase, accessibility,
//! screen_recording, helper}`. Turned off, setup turns it on with
//! `settings.set computerUse.enabled true` and `confirm: true`: the key is
//! the person's, so the app asks them on a native sheet and setup waits for
//! that one click (the app bounds the sheet; one left unanswered reads as
//! declined). The undo turns it off the same way. The macOS grants
//! (Accessibility, Screen Recording) are the person's switches in System
//! Settings: each missing one is a `user_action` whose command opens its
//! pane. Managed settings that turn Computer Use off, and a helper that
//! does not run, are named and left. Capture consent is not reported by the
//! app yet.
//!
//! The app serves all of it, so without the app the task says to open it;
//! off macOS, where there is no cmux app, it is `not_applicable`.

use std::time::Duration;

use serde_json::{Value, json};

use super::super::GlobalArgs;
use super::super::agents_doctor::{ACCESSIBILITY_URL, SCREEN_RECORDING_URL, STATUS_METHOD};
use super::{Outcome, Refusal};
use cmux_json::JsonSet as _;

const TASK: &str = "computer_use";

/// The setting that turns Computer Use on, a key only the person sets.
const SETTING: &str = "computerUse.enabled";

/// The command that turns it back off, on the same sheet.
const UNDO: &str = "cmux settings set computerUse.enabled false --confirm";

/// How long setup waits for the person to answer the app's sheet. The app
/// bounds the sheet itself; this only keeps a lost reply from hanging setup.
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(15 * 60);

/// The palette entry that shows Computer Use Setup, a GUI-only action.
const SETUP_PAGE: &str = "cmux action run palette.computerUse.setup";

pub(super) fn run(global: &GlobalArgs, args: &[String]) -> Result<Outcome, Refusal> {
    let dry_run = parse(args)?;
    let mut report = json!({
        "schema_version": 1,
        "task": TASK,
        "dry_run": dry_run,
        "before": Value::Null,
        "after": Value::Null,
        "undo": Value::Null,
        "user_action": Value::Null,
    });
    if !applies(global) {
        report.set("state", json!("not_applicable"));
        return Ok(Outcome { report, failed: false });
    }
    let before = match read(global) {
        Ok(status) => status,
        Err(action) => {
            report.set("state", json!("needs_user"));
            report.set("user_action", action);
            return Ok(Outcome { report, failed: false });
        }
    };
    report.set("before", before.clone());
    let mut current = before;
    if current["phase"] == "off" {
        // Already on, and the app's phase has not caught up: asking again
        // would show the person a second sheet.
        if enabled(global) {
            report.set("state", json!("needs_user"));
            report.set("after", current);
            report.set("user_action", wait_step());
            return Ok(Outcome { report, failed: false });
        }
        if dry_run {
            report.set("state", json!("planned"));
            report.set("undo", json!(UNDO));
            return Ok(Outcome { report, failed: false });
        }
        if let Err(action) = turn_on(global) {
            report.set("state", json!("needs_user"));
            report.set("user_action", action);
            return Ok(Outcome { report, failed: false });
        }
        report.set("undo", json!(UNDO));
        current = match read(global) {
            Ok(status) => status,
            Err(action) => {
                report.set("state", json!("needs_user"));
                report.set("user_action", action);
                return Ok(Outcome { report, failed: false });
            }
        };
        report.set("after", current.clone());
    }
    let changed = !report["undo"].is_null();
    // The app's phase follows the setting a moment later: right after the
    // person allowed it, `off` means the helper has not caught up, and asking
    // again would show them a second sheet.
    let action =
        if changed && current["phase"] == "off" { Some(wait_step()) } else { next_step(&current) };
    report.set(
        "state",
        json!(match (&action, changed) {
            (Some(_), _) => "needs_user",
            (None, true) => "changed",
            (None, false) => "ok",
        }),
    );
    if report["after"].is_null() {
        report.set("after", current);
    }
    report.set("user_action", action.unwrap_or(Value::Null));
    Ok(Outcome { report, failed: false })
}

/// The check `cmux setup status` reports: the phase and the grants.
pub(super) fn status(global: &GlobalArgs) -> Value {
    if !applies(global) {
        return json!({"task": TASK, "state": "not_applicable"});
    }
    match read(global) {
        Ok(status) => {
            // Off but already allowed: the phase lags the setting, and `run`
            // says to wait rather than ask again; so does the check.
            let lags = status["phase"] == "off" && enabled(global);
            let action = if lags { Some(wait_step()) } else { next_step(&status) };
            let state = match (&action, status["phase"].as_str()) {
                (_, Some("off")) if !lags => "needs_setup",
                (Some(_), _) => "needs_user",
                (None, _) => "ok",
            };
            let fix = (state != "ok").then_some("cmux setup computer-use");
            json!({"task": TASK, "state": state, "status": status, "user_action": action, "fix": fix})
        }
        Err(action) => json!({"task": TASK, "state": "needs_user", "user_action": action}),
    }
}

fn parse(args: &[String]) -> Result<bool, Refusal> {
    let mut dry_run = false;
    for arg in args {
        match arg.as_str() {
            "--dry-run" => dry_run = true,
            other => {
                return Err(Refusal::Usage(format!(
                    "cmux: setup computer-use: unexpected argument {other:?}"
                )));
            }
        }
    }
    Ok(dry_run)
}

/// Whether there is a cmux app to ask: macOS, or an app socket named by
/// `--app-socket` or `CMUX_SOCKET_PATH`.
fn applies(global: &GlobalArgs) -> bool {
    cfg!(target_os = "macos")
        || global.app_socket.is_some()
        || std::env::var_os("CMUX_SOCKET_PATH").is_some_and(|path| !path.is_empty())
}

/// The app's `computer_use.status`, or what the person must do because the
/// app did not answer.
fn read(global: &GlobalArgs) -> Result<Value, Value> {
    super::super::mcp::agent_app(
        global,
        STATUS_METHOD,
        json!({}),
        super::super::app::READ_TIMEOUT,
        None,
    )
    .map_err(|error| app_problem(&error))
}

/// Whether the setting is already on. An app that does not answer reads as
/// off, so setup asks as before.
fn enabled(global: &GlobalArgs) -> bool {
    let params = json!({"path": SETTING});
    super::super::mcp::agent_app(
        global,
        "settings.get",
        params,
        super::super::app::READ_TIMEOUT,
        None,
    )
    .is_ok_and(|reply| reply["value"] == Value::Bool(true))
}

/// Turns Computer Use on: the app asks the person on its sheet. Answers what
/// the person must do when it did not turn on.
fn turn_on(global: &GlobalArgs) -> Result<(), Value> {
    eprintln!("cmux: setup computer-use: waiting for the person to allow Computer Use in cmux");
    let params = json!({"path": SETTING, "value": true, "confirm": true});
    match super::super::mcp::agent_app(global, "settings.set", params, APPROVAL_TIMEOUT, None) {
        Ok(_) => Ok(()),
        Err(error) if error.pointer("/data/declined") == Some(&Value::Bool(true)) => Err(json!({
            "kind": "declined",
            "text": "Computer Use was not allowed: the person declined, or cmux had no window to \
                     show the sheet in; ask the person before running `cmux setup computer-use` \
                     again",
            "command": Value::Null,
            "url": Value::Null,
        })),
        // The app bounds the sheet (120 s): left unanswered, it ends `timeout`.
        Err(error) if error.get("code").and_then(Value::as_str) == Some("timeout") => Err(json!({
            "kind": "declined",
            "text": "Computer Use was not allowed: the person did not answer the sheet in cmux in \
                     time; ask the person before running `cmux setup computer-use` again",
            "command": Value::Null,
            "url": Value::Null,
        })),
        Err(error) => Err(app_problem(&error)),
    }
}

/// What the person does when the app refused or did not answer.
fn app_problem(error: &Value) -> Value {
    let code = error.get("code").and_then(Value::as_str).unwrap_or_default();
    let message = error.get("message").and_then(Value::as_str).unwrap_or_default();
    let text = match code {
        "app.not_found" | "app.unreachable" => {
            "Open cmux: Computer Use runs in the cmux app, which is not running; then run \
             `cmux setup computer-use` again"
                .to_owned()
        }
        "app.transport" => "cmux did not answer; run `cmux setup computer-use` again".to_owned(),
        _ => format!("cmux refused ({code}): {message}"),
    };
    json!({"kind": "app", "text": text, "command": Value::Null, "url": Value::Null})
}

/// The one thing left for the person once Computer Use is on, or `None`
/// when agents can use the Mac.
fn next_step(status: &Value) -> Option<Value> {
    let action = |kind: &str, text: &str, command: Option<String>, url: Option<&str>| {
        Some(json!({"kind": kind, "text": text, "command": command, "url": url}))
    };
    match status["phase"].as_str().unwrap_or_default() {
        "ready" => {}
        "off" => {
            return action(
                "approval",
                "Computer Use is off; `cmux setup computer-use` turns it on after the person \
                 allows it in cmux",
                Some("cmux setup computer-use".into()),
                None,
            );
        }
        "disabled_by_policy" => {
            return action(
                "policy",
                "Managed settings on this Mac turn Computer Use off; only the person's \
                 administrator can turn it on",
                None,
                None,
            );
        }
        "starting" => return Some(wait_step()),
        "failed" => {
            return action(
                "app",
                "The cmux Computer Use helper did not respond. Run the Restart Computer Use \
                 Helper palette action, or click Restart Helper in Settings > Agents.",
                Some("cmux action run palette.computerUse.restart".into()),
                None,
            );
        }
        phase => {
            let text = format!(
                "The Computer Use helper is not ready ({}); Computer Use Setup in cmux shows why",
                if phase.is_empty() { "no report" } else { phase }
            );
            return action("app", &text, Some(SETUP_PAGE.into()), None);
        }
    }
    let grant = |key: &str, pane: &str, url: &str| {
        (status[key] != Value::Bool(true)).then(|| {
            json!({
                "kind": "grant",
                "text": format!(
                    "Allow cmux Computer Use in System Settings > Privacy & Security > {pane} \
                     (the command opens that pane), then run `cmux setup computer-use` again"
                ),
                "command": format!("open '{url}'"),
                "url": url,
            })
        })
    };
    grant("accessibility", "Accessibility", ACCESSIBILITY_URL)
        .or_else(|| grant("screen_recording", "Screen Recording", SCREEN_RECORDING_URL))
}

/// The helper is on its way: rerun in a few seconds.
fn wait_step() -> Value {
    json!({
        "kind": "wait",
        "text": "The Computer Use helper is starting; run `cmux setup computer-use` again in a \
                 few seconds",
        "command": "cmux setup computer-use",
        "url": Value::Null,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failed_helper_offers_restart_instead_of_waiting() {
        let step = next_step(&json!({"phase": "failed", "accessibility": null,
                                    "screen_recording": null}))
        .expect("restart step");
        assert_eq!(step["kind"], "app");
        assert_eq!(step["command"], "cmux action run palette.computerUse.restart");
        let text = step["text"].as_str().unwrap();
        assert!(text.contains("did not respond"));
        assert!(text.contains("Settings > Agents"));
    }
}
