//! `cmux cloud run-account`: the account the cmux app is signed in to, for the daemon's sandboxed
//! Runs (cmux-tui-core `server/cloud_runs.rs`): `{"account": {"signed_in", "user_id", "team_id"}}`,
//! the shape `cmux_cloud_api::sandbox::account_scope` reads. It is the app's `auth.status` (a read
//! of its sign-in, no network), which an organization's Cloud policy leaves open: a Run that
//! exists is still waited on and cancelled with Cloud turned off, and only a new one follows the
//! policy (its start is the app's Cloud verbs). Internal: not in `cmux cloud --help`.

use std::time::Duration;

use serde_json::{Value, json};

/// A main-actor read of the app's sign-in.
const READ_TIMEOUT: Duration = Duration::from_secs(10);

/// `Some(exit code)` when `args` is `cloud run-account`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "run-account" {
        return None;
    }
    if !rest.is_empty() {
        let message = "cmux cloud run-account takes no arguments";
        return Some(super::app::failure("usage.invalid", message, global.output, 2));
    }
    let mut stream = match super::app::connect_command(&global) {
        Ok(stream) => stream,
        Err(error) => return Some(super::wire::print_local_error(&error, global.output, 3)),
    };
    Some(match super::app::request(&mut stream, "auth.status", json!({}), READ_TIMEOUT) {
        Ok(Ok(status)) => super::wire::print_local_success(&account(&status), global.output),
        Ok(Err(error)) => super::wire::print_local_error(&error, global.output, 1),
        Err(message) => super::app::failure("app.transport", &message, global.output, 3),
    })
}

/// `auth.status`'s sign-in as `{"account": …}`: signed in only when it says so, and the person
/// and team only as it names them.
pub(super) fn account(status: &Value) -> Value {
    let named =
        |name: &str| status.get(name).filter(|v| v.is_string()).cloned().unwrap_or(Value::Null);
    json!({ "account": {
        "signed_in": status.get("signed_in") == Some(&Value::Bool(true)),
        "user_id": named("user_id"),
        "team_id": named("team_id"),
    } })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_apps_sign_in_is_the_runs_account() {
        let status = json!({ "signed_in": true, "restoring": false, "email": "a@b.c",
                             "user_id": "u1", "team_id": "team_1", "backend": "https://x" });
        assert_eq!(
            account(&status),
            json!({ "account": { "signed_in": true, "user_id": "u1", "team_id": "team_1" } })
        );
        let personal = json!({ "signed_in": true, "user_id": "u1", "team_id": null });
        assert_eq!(account(&personal)["account"]["team_id"], Value::Null);
        let out = json!({ "signed_in": false, "user_id": null, "team_id": null });
        assert_eq!(account(&out)["account"]["signed_in"], false);
        // An answer that names no sign-in is signed out, never a guess.
        assert_eq!(account(&json!({}))["account"]["signed_in"], false);
    }
}
