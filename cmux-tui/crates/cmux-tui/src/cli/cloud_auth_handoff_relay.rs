//! `cmux cloud auth-handoff-relay`: cmux-api's sign-in hand-off (`backend/apps/api/src/
//! auth-handoff.ts`) for the app's `auth.handoff.mint` and `auth.handoff.redeem` control methods
//! (what `cmux auth handoff mint|redeem` calls). A CLI process has no account token, so the app
//! runs this with its own, the way it runs `cmux cloud automation-relay`: one JSON request on
//! stdin (the credential never goes in argv), one JSON line out, `{ok: true, value}` or
//! `{ok: false, error: {code, message}}`. The rules (single use, two minutes, rate limit, SSO,
//! audit, human sessions only) are the server's; this file sends the two requests and reads them.
//!
//! ```json
//! {"api": "https://api.cmux.dev", "credential": "…"|null, "request": {"op": "mint", "device": "air"}}
//! {"api": "https://api.cmux.dev", "credential": null, "request": {"op": "redeem", "code": "cmh_…", "device": "air", "expected_user": "…"}}
//! ```
//!
//! - `mint` posts `/v1/auth/handoffs` with `credential`, the app's own human Stack session, as the
//!   bearer; no credential is `not_signed_in` before any request. Its value is
//!   `{code, expires_at, user, email, device}`.
//! - `redeem` posts `/v1/auth/handoffs/redeem` with no bearer (the code is the credential), even
//!   when a credential is given. Its value is `{session, reply}`: `session` is the new session's
//!   `{access_token, refresh_token}` for the app to sign in with (null when the app is signed in
//!   as that user already), and `reply` is what the control method answers, never a token.
//!
//! Every refusal's `code` is one the CLI maps to its exit code: `handoff_invalid`, `other_user`,
//! `not_signed_in`, `sso_required`, `rate_limited`, `invalid_params` or `unavailable`.

use std::io::{Read as _, Write as _};
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::auth_handoff::is_code;
use super::cloud_client_session::secure_origin;

/// One hand-off request's bound (the app's control method allows 25 s for the whole call).
// timeout: the app's bound; a cmux-api call that never answers fails that call.
const TIMEOUT: Duration = Duration::from_secs(20);
/// Longest device name, as cmux-api takes it.
const MAX_DEVICE: usize = 64;
/// Longest `expected_user`, as cmux-api takes it.
const MAX_USER: usize = 128;
/// Largest stdin request read; a hand-off request is well under 1 KiB.
const MAX_INPUT: u64 = 65_536;

/// `Some(exit code)` when `args` is `cloud auth-handoff-relay`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (_global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "auth-handoff-relay" {
        return None;
    }
    let answer = if rest.is_empty() {
        let mut input = zeroize::Zeroizing::new(Vec::new());
        match std::io::stdin().take(MAX_INPUT).read_to_end(&mut input) {
            Ok(_) => relay_blocking(&input),
            Err(_) => refusal("invalid_params", "the request could not be read"),
        }
    } else {
        refusal(
            "invalid_params",
            "cmux cloud auth-handoff-relay takes its request as JSON on stdin",
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
        Err(error) => refusal("unavailable", &error.to_string()),
    }
}

/// `{ok: false, error: {code, message}}`.
pub(super) fn refusal(code: &str, message: &str) -> Value {
    json!({ "ok": false, "error": { "code": code, "message": message } })
}

/// The socket code for cmux-api's error `code` (auth-handoff-routes.ts).
pub(super) fn socket_code(server: Option<&str>) -> &'static str {
    match server {
        Some("auth_handoff.invalid") => "handoff_invalid",
        Some("auth_handoff.other_user") => "other_user",
        Some("auth.sso_required") => "sso_required",
        Some("auth_handoff.rate_limited") => "rate_limited",
        Some(
            "auth_handoff.human_session_required"
            | "auth.unauthenticated"
            | "auth_handoff.no_account",
        ) => "not_signed_in",
        Some("validation.invalid") => "invalid_params",
        _ => "unavailable",
    }
}

/// The optional `device`: absent, null or blank is none; else at most 64 printable characters.
fn device(request: &Value) -> Result<Option<String>, Value> {
    match request.get("device") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(raw)) => {
            let trimmed = raw.trim();
            // A code is never a device label: it would be stored and audited as one.
            if trimmed.starts_with("cmh_")
                || trimmed.chars().count() > MAX_DEVICE
                || trimmed.chars().any(char::is_control)
            {
                return Err(refusal(
                    "invalid_params",
                    "device is a name of at most 64 printable characters",
                ));
            }
            Ok((!trimmed.is_empty()).then(|| trimmed.to_owned()))
        }
        Some(_) => {
            Err(refusal("invalid_params", "device is a name of at most 64 printable characters"))
        }
    }
}

/// Forwards one stdin request.
pub(super) async fn relay(input: &[u8]) -> Value {
    let Ok(envelope) = serde_json::from_slice::<Value>(input) else {
        return refusal("invalid_params", "the request is not a JSON object");
    };
    let request = envelope.get("request").cloned().unwrap_or(Value::Null);
    let device = match device(&request) {
        Ok(device) => device,
        Err(refused) => return refused,
    };
    let api = match envelope.get("api").and_then(Value::as_str).map(|api| secure_origin(api.trim()))
    {
        Some(Ok(api)) => api,
        Some(Err(message)) => return refusal("unavailable", &message),
        None => return refusal("unavailable", "no cmux API origin"),
    };
    let mut body = Map::new();
    if let Some(device) = device {
        body.insert("device".into(), json!(device));
    }
    match request.get("op").and_then(Value::as_str) {
        Some("mint") => {
            let Some(credential) = envelope
                .get("credential")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|c| !c.is_empty())
            else {
                return refusal("not_signed_in", "sign in to cmux on this Mac first");
            };
            match post(&api, Some(credential), "/v1/auth/handoffs", Value::Object(body)).await {
                Ok(value) => minted(&value),
                Err(refused) => refused,
            }
        }
        Some("redeem") => {
            let Some(code) =
                request.get("code").and_then(Value::as_str).filter(|code| is_code(code))
            else {
                return refusal(
                    "invalid_params",
                    "auth.handoff takes a code of the shape cmux mints",
                );
            };
            body.insert("code".into(), json!(code));
            match request.get("expected_user") {
                None | Some(Value::Null) => {}
                Some(Value::String(user)) if !user.is_empty() && user.len() <= MAX_USER => {
                    body.insert("expected_user".into(), json!(user));
                }
                Some(_) => return refusal("invalid_params", "expected_user is a Stack user id"),
            }
            // No bearer: the code is the credential, and this Mac's session is not sent anywhere.
            match post(&api, None, "/v1/auth/handoffs/redeem", Value::Object(body)).await {
                Ok(value) => redeemed(&value),
                Err(refused) => refused,
            }
        }
        _ => refusal("invalid_params", "the op is mint or redeem"),
    }
}

/// One POST: the 2xx body as JSON, or the refusal with its socket code.
async fn post(api: &str, bearer: Option<&str>, path: &str, body: Value) -> Result<Value, Value> {
    let user_agent = concat!("cmux/", env!("CARGO_PKG_VERSION"));
    let (base, http) = cmux_cloud_client::http(api, bearer, None, user_agent, TIMEOUT)
        .map_err(|error| refusal("unavailable", &error.to_string()))?;
    let response = http
        .post(format!("{base}{path}"))
        .json(&body)
        .send()
        .await
        .map_err(|error| refusal("unavailable", &error.without_url().to_string()))?;
    let status = response.status();
    let bytes = response
        .bytes()
        .await
        .map_err(|error| refusal("unavailable", &error.without_url().to_string()))?;
    let object = serde_json::from_slice::<Value>(&bytes).ok().filter(Value::is_object);
    if status.is_success() {
        return object.ok_or_else(|| refusal("unavailable", "cmux answered no JSON object"));
    }
    let text = |name: &str| {
        object
            .as_ref()
            .and_then(|o| o.get("error"))
            .and_then(|e| e.get(name))
            .and_then(Value::as_str)
    };
    let code = socket_code(text("code"));
    Err(refusal(code, text("message").unwrap_or("cmux refused the hand-off")))
}

fn text_or_null(value: &Value, name: &str) -> Value {
    value.get(name).and_then(Value::as_str).map_or(Value::Null, |text| json!(text))
}

/// The mint's value: `{code, expires_at, user, email, device}`, or `unavailable` when the answer
/// lacks the code, its expiry or its user.
pub(super) fn minted(value: &Value) -> Value {
    let code = value.get("code").and_then(Value::as_str).filter(|code| is_code(code));
    let expires = value.get("expires_at").and_then(Value::as_i64);
    let user = value.get("user").and_then(Value::as_str);
    let (Some(code), Some(expires), Some(user)) = (code, expires, user) else {
        return refusal("unavailable", "cmux answered no hand-off code");
    };
    json!({ "ok": true, "value": {
        "code": code, "expires_at": expires, "user": user,
        "email": text_or_null(value, "email"), "device": text_or_null(value, "device"),
    }})
}

/// The redeem's value: `{session, reply}` (the module docs), or `unavailable` when the answer
/// lacks its user or, unless the app is signed in as that user already, either token.
pub(super) fn redeemed(value: &Value) -> Value {
    let user = value.get("user").and_then(Value::as_str);
    let stack_user = value.get("stack_user").and_then(Value::as_str);
    let (Some(user), Some(_)) = (user, stack_user) else {
        return refusal("unavailable", "cmux answered no user");
    };
    let already = value.get("already_signed_in").and_then(Value::as_bool).unwrap_or(false);
    let token = |name: &str| value.get(name).and_then(Value::as_str).filter(|t| !t.is_empty());
    let session = match (already, token("access_token"), token("refresh_token")) {
        (true, _, _) => Value::Null,
        (false, Some(access), Some(refresh)) => {
            json!({ "access_token": access, "refresh_token": refresh })
        }
        (false, _, _) => return refusal("unavailable", "cmux answered no session"),
    };
    json!({ "ok": true, "value": {
        "session": session,
        "reply": {
            "signed_in": true, "already_signed_in": already, "user": user,
            "email": text_or_null(value, "email"), "device": text_or_null(value, "device"),
        },
    }})
}

#[cfg(test)]
mod tests;
