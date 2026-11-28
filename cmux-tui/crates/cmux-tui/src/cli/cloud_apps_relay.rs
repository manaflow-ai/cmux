//! `cmux cloud apps-relay`: one read of the person's published apps as the signed-in person, for
//! the app's `cloud.apps` control method (what `cmux app ls` and `cmux app versions` call off a
//! Cloud machine, RFD 0003). A CLI process has no account token, and a `cmux auth token` mint has no
//! `execute`, which the platform's apps routes refuse; so the app runs this with its own session:
//! one JSON request on stdin (the credential never goes in argv), one JSON line out, always
//! `{ok: true, value}` or `{ok: false, error: {code, message}}`. Only `GET /v1/cloud/apps` and
//! `GET /v1/cloud/apps/{slug}` are sent (`cmux_apps::account::route`).
//!
//! ```json
//! {"api": "https://…", "credential": "…"|null, "team": "…"|null, "request": {"op": "list"}}
//! ```

use std::io::{Read as _, Write as _};
use std::time::Duration;

use cmux_apps::account;
use serde_json::Value;

use super::cloud_client_session::secure_origin;

// timeout: the app's bound on one Cloud read; a read that never answers fails that call.
const TIMEOUT: Duration = Duration::from_secs(20);

/// `Some(exit code)` when `args` is `cloud apps-relay`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (_global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "apps-relay" {
        return None;
    }
    let answer = if rest.is_empty() {
        let mut input = Vec::new();
        match std::io::stdin().read_to_end(&mut input) {
            Ok(_) => relay_blocking(&input),
            Err(_) => account::refusal("invalid_params", "the request could not be read"),
        }
    } else {
        account::refusal(
            "invalid_params",
            "cmux cloud apps-relay takes its request as JSON on stdin",
        )
    };
    let mut stdout = std::io::stdout().lock();
    let written = writeln!(stdout, "{answer}").and_then(|()| stdout.flush());
    Some(if written.is_ok() && answer.get("ok") == Some(&Value::Bool(true)) { 0 } else { 1 })
}

fn relay_blocking(input: &[u8]) -> Value {
    let _ = rustls::crypto::ring::default_provider().install_default();
    match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime.block_on(relay(input)),
        Err(error) => account::refusal("app.unreachable", &error.to_string()),
    }
}

/// Sends one stdin request.
pub(super) async fn relay(input: &[u8]) -> Value {
    let Ok(envelope) = serde_json::from_slice::<Value>(input) else {
        return account::refusal("invalid_params", "the request is not a JSON object");
    };
    let path = match account::route(envelope.get("request").unwrap_or(&Value::Null)) {
        Ok(path) => path,
        Err(refusal) => return refusal,
    };
    let Some(credential) =
        envelope.get("credential").and_then(Value::as_str).filter(|c| !c.trim().is_empty())
    else {
        return account::refusal("not_signed_in", "sign in to cmux to list your apps");
    };
    let api = match envelope.get("api").and_then(Value::as_str).map(|api| secure_origin(api.trim()))
    {
        Some(Ok(api)) => api,
        Some(Err(message)) => return account::refusal("app.unreachable", &message),
        None => return account::refusal("app.unreachable", "no cmux API origin"),
    };
    let team =
        envelope.get("team").and_then(Value::as_str).map(str::trim).filter(|t| !t.is_empty());
    let user_agent = concat!("cmux/", env!("CARGO_PKG_VERSION"));
    let (base, http) =
        match cmux_cloud_client::http(&api, Some(credential.trim()), team, user_agent, TIMEOUT) {
            Ok(built) => built,
            Err(error) => return account::refusal("app.unreachable", &error.to_string()),
        };
    let response = match http.get(format!("{base}{path}")).send().await {
        Ok(response) => response,
        Err(error) => return account::refusal("app.unreachable", &error.without_url().to_string()),
    };
    let status = response.status().as_u16();
    match response.bytes().await {
        Ok(body) => account::answer(status, &body),
        Err(error) => account::refusal("app.unreachable", &error.without_url().to_string()),
    }
}

#[cfg(test)]
#[path = "cloud_apps_relay_tests.rs"]
mod tests;
