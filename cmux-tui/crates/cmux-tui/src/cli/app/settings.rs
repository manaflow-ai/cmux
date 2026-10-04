//! `cmux settings get [PATH] | set PATH VALUE | reset PATH | unset PATH`,
//! the app's `settings.*` control methods (plans/cmux-next/settings-surfaces.md).
//!
//! A socket write of a user-only key (schema `agent_settable: false`) is
//! refused with `setting_user_only`. `--confirm` sends `confirm: true`: the
//! app then asks the person at the Mac on a native sheet, so the CLI waits
//! with no read deadline (the app bounds the sheet itself). A declined sheet
//! answers `setting_user_only` with `data.declined: true`. Both refusals exit
//! 1, the CLI's code for an op the app refused.

use serde_json::{Value, json};

use super::{AppCommand, READ_TIMEOUT, UsageError};

/// The app's refusal of a user-only key.
const USER_ONLY: &str = "setting_user_only";

/// `rest` starts with the verb (`get`, `set`, `reset`, `unset`).
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let usage = || UsageError::new(messages.settings_usage);
    let Some((verb, args)) = rest.split_first() else { return Err(usage()) };
    if verb == "get" {
        return match args {
            [] => Ok(read(json!({}))),
            [path] if !path.starts_with("--") => Ok(read(json!({ "path": path }))),
            _ => Err(usage()),
        };
    }
    let confirm = args.iter().any(|arg| arg == "--confirm");
    let words: Vec<&String> = args.iter().filter(|arg| *arg != "--confirm").collect();
    if let Some(flag) = words.iter().find(|word| word.starts_with("--")) {
        return Err(UsageError::new(messages.unexpected_argument.replace("{value}", flag)));
    }
    let (method, mut params) = match (verb.as_str(), words.as_slice()) {
        ("set", [path, value]) => {
            // A JSON value when it parses as one, else the literal string.
            let value = serde_json::from_str(value).unwrap_or(Value::String((*value).clone()));
            ("settings.set", json!({ "path": path, "value": value }))
        }
        ("reset", [path]) => ("settings.reset", json!({ "path": path })),
        ("unset", [path]) => ("settings.unset", json!({ "path": path })),
        _ => return Err(usage()),
    };
    if confirm {
        params["confirm"] = json!(true);
    }
    // With --confirm a person answers: no client deadline cancels the wait.
    let timeout = if confirm { None } else { Some(READ_TIMEOUT) };
    Ok(AppCommand::Call { method, params, timeout, pick: None })
}

fn read(params: Value) -> AppCommand {
    AppCommand::Call { method: "settings.get", params, timeout: Some(READ_TIMEOUT), pick: None }
}

/// Says what to do about a `setting_user_only` refusal of a settings write,
/// in the error's `message` (the human output prints it; JSON keeps `code`
/// and `data`). Without `--confirm`: the app's message, then the rerun hint.
/// A declined sheet: "declined in cmux". The value is never echoed.
pub(super) fn explain_refusal(method: &str, params: &Value, error: &mut Value) {
    if !matches!(method, "settings.set" | "settings.reset" | "settings.unset")
        || error.get("code").and_then(Value::as_str) != Some(USER_ONLY)
    {
        return;
    }
    let messages = &crate::localization::catalog().app_control;
    let confirmed = params.get("confirm") == Some(&Value::Bool(true));
    let declined = error.pointer("/data/declined") == Some(&Value::Bool(true));
    let text = if confirmed && declined {
        messages.settings_declined.to_owned()
    } else if confirmed {
        return;
    } else {
        let message = error.get("message").and_then(Value::as_str).unwrap_or_default();
        format!("{message}\n{}", messages.settings_confirm_hint)
    };
    error["message"] = json!(text);
}
