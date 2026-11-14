//! `cmux cloud automation-relay`: one Cloud automation op as the signed-in
//! person, for the app's `cloud.automation` control method (what `cmux
//! automation --target cloud`, the Automations page and the Chief's
//! automation tool call). A CLI process has no account token, so the app
//! runs this with its own: one JSON request on stdin (the credential never
//! goes in argv), one JSON line out, always `{ok: true, value}` or `{ok:
//! false, error: {code, message, details?}}`. The rules (which ops pass,
//! where each goes, how an answer reads) are `cmux_cloud_wire::automation`'s.
//!
//! ```json
//! {"api": "https://api.cmux.dev", "credential": "…"|null, "request": {"op": "automation.list", "params": {}}}
//! ```

use std::io::{Read as _, Write as _};
use std::time::Duration;

use cmux_cloud_wire::automation;
use serde_json::Value;

use super::cloud_client_session::secure_origin;

/// The app's bound on one Cloud call.
// timeout: the app's bound; a Cloud call that never answers fails that call.
const TIMEOUT: Duration = Duration::from_secs(20);

/// `Some(exit code)` when `args` is `cloud automation-relay`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (_global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "automation-relay" {
        return None;
    }
    let answer = if rest.is_empty() {
        let mut input = Vec::new();
        match std::io::stdin().read_to_end(&mut input) {
            Ok(_) => relay_blocking(&input),
            Err(_) => automation::refusal("invalid_params", "the request could not be read"),
        }
    } else {
        automation::refusal(
            "invalid_params",
            "cmux cloud automation-relay takes its request as JSON on stdin",
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
        Err(error) => automation::refusal("owner.unreachable", &error.to_string()),
    }
}

/// Forwards one stdin request.
pub(super) async fn relay(input: &[u8]) -> Value {
    let Ok(envelope) = serde_json::from_slice::<Value>(input) else {
        return automation::refusal("invalid_params", "the request is not a JSON object");
    };
    let request = envelope.get("request").cloned().unwrap_or(Value::Null);
    let routed = match automation::route(&request) {
        Ok(routed) => routed,
        Err(refusal) => return refusal,
    };
    let Some(credential) =
        envelope.get("credential").and_then(Value::as_str).filter(|c| !c.trim().is_empty())
    else {
        return automation::refusal(
            "automation.signed_out",
            "sign in to cmux to use Cloud automations",
        );
    };
    let api = match envelope.get("api").and_then(Value::as_str).map(|api| secure_origin(api.trim()))
    {
        Some(Ok(api)) => api,
        Some(Err(message)) => return automation::refusal("owner.unreachable", &message),
        None => return automation::refusal("owner.unreachable", "no cmux API origin"),
    };
    let user_agent = concat!("cmux/", env!("CARGO_PKG_VERSION"));
    let (base, http) =
        match cmux_cloud_client::http(&api, Some(credential.trim()), None, user_agent, TIMEOUT) {
            Ok(built) => built,
            Err(error) => return automation::refusal("owner.unreachable", &error.to_string()),
        };
    let sent = http.post(format!("{base}{}", routed.path)).json(&routed.body).send().await;
    let response = match sent {
        Ok(response) => response,
        Err(error) => {
            return automation::refusal("owner.unreachable", &error.without_url().to_string());
        }
    };
    let status = response.status().as_u16();
    match response.bytes().await {
        Ok(body) => automation::answer(status, &body),
        Err(error) => automation::refusal("owner.unreachable", &error.without_url().to_string()),
    }
}

#[cfg(test)]
mod tests;
