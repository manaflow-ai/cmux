//! A cmux VM agent key's mint (`POST /v1/agent-keys` on the cmux VM API, workers/cmux-vm
//! src/api/agents.ts): the request body, where it goes, and how the answer reads. One set of rules
//! for both mint paths: the app's `vm.agent_key.create` (it holds the Stack session, asks
//! [`request`] and [`answer`] over the app FFI and does the HTTP call), and the `cmux vm token
//! create` CLI with its own credential (a session token or a team key), which builds the same
//! body with [`body`] and reads the app's refusals with [`outcome`].
//!
//! An agent key holds only `vm:read`, `vm:write` and `vm:exec`, reaches only the VMs it creates,
//! has a VM count and a USD/h budget, and expires within a day.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::config::{Backend, vm_api_base_url};

/// The only scopes an agent key is asked for, whatever the caller sent.
pub const SCOPES: [&str; 3] = ["vm:read", "vm:write", "vm:exec"];
pub const DEFAULT_NAME: &str = "cmux vm token";
pub const NAME_MAX_CHARS: usize = 200;
pub const TTL_SECONDS: std::ops::RangeInclusive<u64> = 60..=86_400;
pub const MAX_VMS: std::ops::RangeInclusive<u64> = 1..=20;
pub const MAX_USD_PER_HOUR: f64 = 50.0;
pub const DEFAULT_TTL_SECONDS: u64 = 8 * 3600;
pub const DEFAULT_MAX_VMS: u32 = 3;
pub const DEFAULT_MAX_USD_PER_HOUR: f64 = 2.0;
/// The path the key is minted at, under the VM API's base URL.
pub const PATH: &str = "v1/agent-keys";

/// A mint refused here or by the VM API, as the app socket's error: the code the CLI maps to an
/// exit status ([`outcome`]) and a message that never carries the key.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Refusal {
    pub code: String,
    pub message: String,
    /// The HTTP status of an `unavailable` answer (0: no answer at all).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<u16>,
    /// The app's own localized text to show instead of `message` (`notSignedIn`, `unreachable`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app_text: Option<String>,
}

impl Refusal {
    fn new(code: &str, message: impl Into<String>, status: Option<u16>) -> Self {
        Self { code: code.to_owned(), message: message.into(), status, app_text: None }
    }

    fn with_app_text(mut self, text: &str) -> Self {
        self.app_text = Some(text.to_owned());
        self
    }
}

/// The request body for the caller's `params` (`name`, `ttlSeconds`, `maxVms`, `maxUsdPerHour`):
/// only VM scopes. A limit that is present must be valid: a bad one is refused (`invalid_params`),
/// never dropped, since the server's default would be larger. An absent one is left to the server.
pub fn body(params: &Map<String, Value>) -> Result<Value, Refusal> {
    let invalid =
        |name: &str| Refusal::new("invalid_params", format!("{name} is out of range"), None);
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty())
        .map(|name| name.chars().take(NAME_MAX_CHARS).collect::<String>())
        .unwrap_or_else(|| DEFAULT_NAME.to_owned());
    let mut body = Map::new();
    body.insert("name".into(), json!(name));
    body.insert("scopes".into(), json!(SCOPES));
    if let Some(raw) = params.get("ttlSeconds") {
        let ttl = exact_integer(raw)
            .filter(|ttl| TTL_SECONDS.contains(ttl))
            .ok_or_else(|| invalid("ttlSeconds"))?;
        body.insert("ttlSeconds".into(), json!(ttl));
    }
    if let Some(raw) = params.get("maxVms") {
        let vms = exact_integer(raw)
            .filter(|vms| MAX_VMS.contains(vms))
            .ok_or_else(|| invalid("maxVms"))?;
        body.insert("maxVms".into(), json!(vms));
    }
    if let Some(raw) = params.get("maxUsdPerHour") {
        let usd = raw
            .as_f64()
            .filter(|usd| usd.is_finite() && *usd > 0.0 && *usd <= MAX_USD_PER_HOUR)
            .ok_or_else(|| invalid("maxUsdPerHour"))?;
        body.insert("maxUsdPerHour".into(), json!(usd));
    }
    Ok(Value::Object(body))
}

/// A JSON number that is an exact, non-negative integer (`60` and `60.0`), else `None`.
fn exact_integer(value: &Value) -> Option<u64> {
    if let Some(n) = value.as_u64() {
        return Some(n);
    }
    let n = value.as_f64().filter(|n| *n >= 0.0 && n.fract() == 0.0 && *n < 1e15)?;
    // Below 1e15 an integral f64 prints exactly, so this is the number with no lossy cast.
    format!("{n:.0}").parse().ok()
}

/// What the app sends: `POST <url>` with `body`, `Authorization: Bearer <session>`,
/// `x-cmux-team-id: <team>` and `content-type: application/json`, within 20 s.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub url: String,
    pub base_url: String,
    pub body: Value,
    pub timeout_seconds: u32,
}

/// The mint request for this build's Cloud: the VM API for `backend`, never another (the app
/// sends its Stack session only there).
pub fn request(backend: &Backend, params: &Map<String, Value>) -> Result<Request, Refusal> {
    let base_url = vm_api_base_url(backend).to_owned();
    Ok(Request {
        url: format!("{base_url}/{PATH}"),
        base_url,
        body: body(params)?,
        timeout_seconds: 20,
    })
}

/// The answer as the socket's result: the VM API's fields plus `baseUrl` and `teamId` (so the CLI
/// stores the key with the service and team it works at), or the refusal. `status` 0 is no
/// answer at all. The key is never in a refusal.
pub fn answer(status: u16, body: &[u8], base_url: &str, team_id: &str) -> Result<Value, Refusal> {
    let parsed: Option<Value> = serde_json::from_slice(body).ok();
    if status == 0 {
        return Err(Refusal::new(
            "unavailable",
            "The cmux VM service didn't answer. Try again in a moment.",
            Some(0),
        )
        .with_app_text("unreachable"));
    }
    if (200..300).contains(&status)
        && let Some(Value::Object(mut fields)) = parsed.clone()
        && fields.get("key").is_some_and(Value::is_string)
    {
        fields.insert("baseUrl".into(), json!(base_url));
        fields.insert("teamId".into(), json!(team_id));
        return Ok(Value::Object(fields));
    }
    let key = parsed.as_ref().and_then(|answer| answer.get("key")).and_then(Value::as_str);
    let message = parsed
        .as_ref()
        .and_then(|answer| answer.get("message"))
        .and_then(Value::as_str)
        .map(|message| redacted(message, key).chars().take(300).collect::<String>())
        .unwrap_or_else(|| format!("HTTP {status}"));
    Err(match status {
        401 => Refusal::new("not_signed_in", "Sign in to cmux in the cmux app first.", None)
            .with_app_text("notSignedIn"),
        402 => Refusal::new("plan_required", message, None),
        403 => Refusal::new("forbidden", message, None),
        400 => Refusal::new("invalid_params", message, None),
        429 => Refusal::new("rate_limited", message, None),
        _ => Refusal::new("unavailable", message, Some(status)),
    })
}

/// The VM API's key prefix (workers/cmux-vm src/auth/credentials.ts `API_KEY_PREFIX`).
pub const KEY_PREFIX: &str = "cmuxvm_sk_";

/// `message` with the answer's own key and anything shaped like a VM API key taken out, so a
/// refusal never carries a secret whatever the service put in its text.
fn redacted(message: &str, key: Option<&str>) -> String {
    let text = match key.filter(|key| !key.is_empty()) {
        Some(key) => message.replace(key, "<redacted>"),
        None => message.to_owned(),
    };
    let mut out = String::with_capacity(text.len());
    let mut rest = text.as_str();
    while let Some((before, after)) = rest.split_once(KEY_PREFIX) {
        out.push_str(before);
        out.push_str(KEY_PREFIX);
        out.push_str("<redacted>");
        rest =
            after.trim_start_matches(|c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    }
    out.push_str(rest);
    out
}

/// What a mint refused by the app means for the CLI's exit status: the cmux-vm CLI maps each
/// to its own code (`exit.rs`), so scripts tell the cases apart the same way on either mint path.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Nothing reached the service, or the app cannot mint now (no team, Cloud off).
    Network,
    Unauthenticated,
    PaymentRequired,
    Forbidden,
    QuotaExceeded,
    Usage,
    /// The app has no `vm.agent_key.create`.
    MethodNotFound,
    ServiceUnavailable,
    /// Another HTTP status from the service: the CLI's own status map.
    Status(u16),
    Unexpected,
}

/// The outcome of a mint the app refused with socket error `code` (and, for `unavailable`, the
/// VM API's HTTP `status`).
pub fn outcome(code: &str, status: Option<u64>) -> Outcome {
    match code {
        "labs_off" | "no_team" | "feature.disabled" => Outcome::Network,
        "not_signed_in" => Outcome::Unauthenticated,
        "plan_required" => Outcome::PaymentRequired,
        "forbidden" => Outcome::Forbidden,
        "rate_limited" => Outcome::QuotaExceeded,
        "invalid_params" => Outcome::Usage,
        "method_not_found" => Outcome::MethodNotFound,
        "unavailable" => match status.and_then(|status| u16::try_from(status).ok()) {
            None | Some(0) => Outcome::Network,
            Some(status) if status >= 500 => Outcome::ServiceUnavailable,
            Some(status) => Outcome::Status(status),
        },
        _ => Outcome::Unexpected,
    }
}

#[cfg(test)]
#[path = "agent_key_tests.rs"]
mod tests;
