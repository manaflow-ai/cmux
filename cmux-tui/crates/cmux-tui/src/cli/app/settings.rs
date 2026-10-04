//! `cmux settings set PATH VALUE | reset PATH | unset PATH [--confirm]`.
//!
//! A socket caller is never the user, so the app refuses a user-only key with
//! `setting_user_only` (SECURITY, agent_settable). `--confirm` sends
//! `confirm: true`: the app shows a native sheet naming the key and value and
//! writes only after the person approves it there. The CLI waits for the
//! sheet ([`CONFIRM_TIMEOUT`]); a declined sheet answers `setting_user_only`
//! with `data.declined`.

use std::time::Duration;

use serde_json::{Value, json};

use super::{AppCommand, READ_TIMEOUT, UsageError};

/// How long a `--confirm` write may wait for the person (the app allows the
/// sheet 120 s).
pub(super) const CONFIRM_TIMEOUT: Duration = Duration::from_secs(125);

/// The error code of a user-only key the caller may not write alone.
pub(super) const USER_ONLY: &str = "setting_user_only";

/// `set PATH VALUE`, `reset PATH` or `unset PATH`, each with an optional
/// `--confirm` anywhere after the verb.
pub(super) fn parse(verb: &str, args: &[String]) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let confirm = args.iter().filter(|arg| *arg == "--confirm").count();
    if confirm > 1 {
        return Err(UsageError::new(messages.settings_usage));
    }
    let positional: Vec<&String> = args.iter().filter(|arg| *arg != "--confirm").collect();
    let (method, mut params) = match (verb, positional.as_slice()) {
        ("set", [path, value]) => {
            // A JSON value when it parses as one, else the literal string.
            let value = serde_json::from_str(value).unwrap_or(Value::String((*value).clone()));
            ("settings.set", json!({ "path": path, "value": value }))
        }
        ("reset", [path]) => ("settings.reset", json!({ "path": path })),
        ("unset", [path]) => ("settings.unset", json!({ "path": path })),
        _ => return Err(UsageError::new(messages.settings_usage)),
    };
    let timeout = if confirm == 1 {
        params["confirm"] = json!(true);
        CONFIRM_TIMEOUT
    } else {
        READ_TIMEOUT
    };
    Ok(AppCommand::Call { method, params, timeout, pick: None })
}

/// What to tell the person about a refused settings write, if anything:
/// run again with `--confirm`, or the sheet was declined.
pub(super) fn refusal_hint(error: &Value) -> Option<&'static str> {
    if error.get("code").and_then(Value::as_str) != Some(USER_ONLY) {
        return None;
    }
    let messages = &crate::localization::catalog().app_control;
    let declined = error.get("data").and_then(|data| data.get("declined")) == Some(&json!(true));
    Some(if declined { messages.settings_declined } else { messages.settings_confirm_hint })
}
