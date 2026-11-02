//! `cmux setup notifications [--dry-run]`: lets cmux show macOS notifications
//! (agent turns that finished or wait for the person, terminal alerts), and
//! hands the person only their one click.
//!
//! The state is the app's `notifications.status` (`{authorization, alert,
//! alert_style, sound, badge, bundle_id}`, read without prompting). Not
//! determined yet, setup sends `notifications.request`: macOS asks the person
//! on its own prompt and setup waits for that click. Denied, only the person
//! can turn it on, in System Settings > Notifications: the `user_action`
//! command opens that pane. macOS has no command that takes the permission back, so the
//! undo of a change opens the same pane, where the person turns it off.
//! Which notifications show (sounds, quiet hours, muted workspaces) are
//! `notifications.*` settings, not this task.
//!
//! The app serves all of it, so without the app the task says to open it,
//! and an app without these methods leaves the person the pane;
//! off macOS, where there is no cmux app, it is `not_applicable`.

use std::time::Duration;

use serde_json::{Value, json};

use super::super::GlobalArgs;
use super::{Outcome, Refusal};
use cmux_json::JsonSet as _;

const TASK: &str = "notifications";

const STATUS_METHOD: &str = "notifications.status";
const REQUEST_METHOD: &str = "notifications.request";

/// How long setup waits for the person to answer the macOS prompt. The app
/// bounds the wait itself; this only keeps a lost reply from hanging setup.
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(11 * 60);

/// System Settings > Notifications; `?id=` selects the app's own page.
const PANE: &str = "x-apple.systempreferences:com.apple.Notifications-Settings.extension";

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
    if before["authorization"] != "not_determined" {
        let action = next_step(&before);
        report.set("state", json!(if action.is_some() { "needs_user" } else { "ok" }));
        report.set("after", before);
        report.set("user_action", action.unwrap_or(Value::Null));
        return Ok(Outcome { report, failed: false });
    }
    if dry_run {
        report.set("state", json!("planned"));
        set_undo(&mut report, &before);
        return Ok(Outcome { report, failed: false });
    }
    eprintln!("cmux: setup notifications: waiting for the person to allow notifications for cmux");
    let after =
        match super::super::mcp::agent_app(
            global,
            REQUEST_METHOD,
            json!({}),
            APPROVAL_TIMEOUT,
            None,
        ) {
            Ok(status) => status,
            // The app bounds the prompt (600 s): left unanswered, it ends `timeout`.
            Err(error) if error["code"] == "timeout" => {
                report.set("state", json!("needs_user"));
                report.set("user_action", json!({
                "kind": "declined",
                "text": "Notifications were not allowed: the person did not answer the macOS \
                         prompt in time; ask the person before running `cmux setup \
                         notifications` again",
                "command": Value::Null,
                "url": Value::Null,
            }));
                return Ok(Outcome { report, failed: false });
            }
            // macOS failed the request itself: nothing for the person to do.
            Err(error) if error["code"] == "internal_error" => {
                report.set("state", json!("failed"));
                report.set("error", error);
                return Ok(Outcome { report, failed: true });
            }
            Err(error) => {
                report.set("state", json!("needs_user"));
                report.set("user_action", app_problem(&error));
                return Ok(Outcome { report, failed: false });
            }
        };
    report.set("after", after.clone());
    match after["authorization"].as_str().unwrap_or_default() {
        // Allowed, with banners off: the grant still has its undo.
        "authorized" | "provisional" if next_step(&after).is_some() => {
            report.set("state", json!("needs_user"));
            report.set("user_action", next_step(&after).unwrap_or(Value::Null));
            set_undo(&mut report, &before);
        }
        "authorized" | "provisional" => {
            report.set("state", json!("changed"));
            set_undo(&mut report, &before);
        }
        "denied" => {
            report.set("state", json!("needs_user"));
            report.set(
                "user_action",
                json!({
                    "kind": "declined",
                    "text": "The person did not allow notifications for cmux; ask them before \
                             running `cmux setup notifications` again (macOS shows its prompt only \
                             once: after that it is their switch in System Settings)",
                    "command": Value::Null,
                    "url": Value::Null,
                }),
            );
        }
        _ => {
            report.set("state", json!("needs_user"));
            report.set("user_action", next_step(&after).unwrap_or(Value::Null));
        }
    }
    Ok(Outcome { report, failed: false })
}

/// The check `cmux setup status` reports.
pub(super) fn status(global: &GlobalArgs) -> Value {
    if !applies(global) {
        return json!({"task": TASK, "state": "not_applicable"});
    }
    match read(global) {
        Ok(status) => {
            let action = next_step(&status);
            let state = match (&action, status["authorization"].as_str()) {
                (_, Some("not_determined")) => "needs_setup",
                (Some(_), _) => "needs_user",
                (None, _) => "ok",
            };
            let fix = (state != "ok").then_some("cmux setup notifications");
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
                    "cmux: setup notifications: unexpected argument {other:?}"
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

/// The app's `notifications.status`, or what the person must do because the
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

/// cmux's page in System Settings > Notifications (the pane itself when the
/// app named no bundle id).
fn pane_url(status: &Value) -> String {
    match status["bundle_id"].as_str().filter(|id| !id.is_empty()) {
        Some(id) => format!("{PANE}?id={id}"),
        None => PANE.to_owned(),
    }
}

/// The command that opens cmux's page in System Settings > Notifications.
fn pane_command(status: &Value) -> String {
    format!("open '{}'", pane_url(status))
}

/// Whether macOS shows no banner for cmux: the alert style None, or alerts
/// off. `alert` (`alertSetting`) can stay true with the style None, so only
/// `alert_style` catches that; an app from before `alert_style` sends `alert`
/// alone.
fn banners_off(status: &Value) -> bool {
    status["alert_style"] == "none" || status["alert"] == false
}

/// The undo of allowing them: the pane where the person turns them off
/// (`undo_note` says why it is not a command that does it).
fn set_undo(report: &mut Value, status: &Value) {
    report["undo"] = json!(pane_command(status));
    report["undo_note"] = json!(
        "macOS has no command that takes the permission back: the undo opens System Settings > \
         Notifications, where the person turns off Allow Notifications for cmux"
    );
}

/// What the person does when the app refused or did not answer.
fn app_problem(error: &Value) -> Value {
    let code = error.get("code").and_then(Value::as_str).unwrap_or_default();
    let message = error.get("message").and_then(Value::as_str).unwrap_or_default();
    let text = match code {
        "app.not_found" | "app.unreachable" => {
            "Open cmux: notifications come from the cmux app, which is not running; then run \
             `cmux setup notifications` again"
                .to_owned()
        }
        "app.transport" => "cmux did not answer; run `cmux setup notifications` again".to_owned(),
        "method_not_found" => {
            return json!({
                "kind": "app",
                "text": "This cmux app cannot read or ask for notification permission; the \
                         command opens System Settings > Notifications, where cmux's page shows \
                         whether it may notify",
                "command": format!("open '{PANE}'"),
                "url": PANE,
            });
        }
        _ => format!("cmux refused ({code}): {message}"),
    };
    json!({"kind": "app", "text": text, "command": Value::Null, "url": Value::Null})
}

/// The one thing left for the person, or `None` when cmux may notify.
fn next_step(status: &Value) -> Option<Value> {
    match status["authorization"].as_str().unwrap_or_default() {
        // Allowed with the alert style None: macOS shows no banner.
        "authorized" if banners_off(status) => Some(json!({
            "kind": "grant",
            "text": "Notifications for cmux are allowed but banners are turned off (alert \
                     style None in System Settings > Notifications; the command opens \
                     cmux's page there): the person picks Banners or Alerts, then run `cmux \
                     setup notifications` again",
            "command": pane_command(status),
            "url": pane_url(status),
        })),
        "authorized" | "provisional" => None,
        "not_determined" => Some(json!({
            "kind": "approval",
            "text": "macOS has not asked yet; `cmux setup notifications` shows its prompt and \
                     the person clicks Allow",
            "command": "cmux setup notifications",
            "url": Value::Null,
        })),
        "denied" => Some(json!({
            "kind": "grant",
            "text": "Notifications for cmux are off in System Settings > Notifications \
                     (the command opens cmux's page there): the person turns on Allow \
                     Notifications, then run `cmux setup notifications` again",
            "command": pane_command(status),
            "url": pane_url(status),
        })),
        other => Some(json!({
            "kind": "app",
            "text": format!(
                "cmux reported notification permission as {:?}; System Settings > \
                 Notifications shows it",
                if other.is_empty() { "nothing" } else { other }
            ),
            "command": pane_command(status),
            "url": pane_url(status),
        })),
    }
}
