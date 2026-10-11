//! `cmux [--app-socket PATH] app call <method> [json]`: one app control
//! method, for a DEV or tagged build's debug socket only (debug.* reads such
//! as `debug.surfaces` or `debug.window_snapshot`).
//!
//! The CLI first asks the app `system.identify` on the same connection and
//! refuses (exit 1) any app whose bundle is not a debug build, before it
//! sends the method. The params are the JSON object as given, sent without
//! the read barrier (`debug.hangs` reads its own `after`), with the CLI's
//! `origin` (`cli` or `script`) put over any `origin` in the JSON: a call
//! never claims to be the person, so person-only operations stay refused.
//! The app's own error passes through with its code (exit 1).

use std::os::unix::net::UnixStream;

use serde_json::{Map, Value, json};

use super::{AppCommand, READ_TIMEOUT, UsageError, WAITING_RUN_TIMEOUT};
use crate::app_identity::is_debug_bundle;
use crate::cli::GlobalArgs;

/// `rest` starts with `call`.
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let (method, params) = match &rest[1..] {
        [method] => (method, Map::new()),
        [method, json] => {
            let Ok(Value::Object(params)) = serde_json::from_str::<Value>(json) else {
                return Err(UsageError::new(messages.app_call_bad_json));
            };
            (method, params)
        }
        _ => return Err(UsageError::new(messages.app_call_usage)),
    };
    if method.is_empty() || method.starts_with('-') {
        return Err(UsageError::new(messages.app_call_usage));
    }
    Ok(AppCommand::DebugCall { method: method.clone(), params })
}

/// Identify the app, refuse a non-debug build, then send the method.
pub(super) fn run(
    global: &GlobalArgs,
    stream: &mut UnixStream,
    method: &str,
    mut params: Map<String, Value>,
) -> i32 {
    let messages = &crate::localization::catalog().app_control;
    let output = global.output;
    let identity = match super::exchange(stream, "system.identify", json!({}), READ_TIMEOUT) {
        Ok(Ok(identity)) => identity,
        Ok(Err(error)) => return super::super::wire::print_local_error(&error, output, 1),
        Err(error) => return super::failure("app.transport", &error, output, 3),
    };
    let bundle = identity.get("bundle_id").and_then(Value::as_str).unwrap_or_default();
    if !is_debug_bundle(bundle) {
        let shown = if bundle.is_empty() { "?" } else { bundle };
        let message = messages.app_call_debug_only.replace("{bundle}", shown);
        return super::failure("app.call_debug_only", &message, output, 1);
    }
    params.insert("origin".into(), json!(super::action_origin()));
    match super::exchange(stream, method, Value::Object(params), WAITING_RUN_TIMEOUT) {
        Ok(Ok(result)) => super::super::wire::print_local_success(&result, output),
        Ok(Err(error)) => super::super::wire::print_local_error(&error, output, 1),
        Err(error) => super::failure("app.transport", &error, output, 3),
    }
}
