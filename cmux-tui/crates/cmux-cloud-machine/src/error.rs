//! A typed Cloud API failure ([`ApiError`], the app's `CloudAPIError`): reading the server's
//! error body ([`from_response`]), the text a person reads ([`text`]) and the stable code a
//! caller maps to its own text ([`code`]).
//!
//! The JSON is the app's own encoding of its enum: one key, the case, holding its fields
//! (`{"http": {"status": 409, "code": "…", "message": "…", "action": null, "traceId": null}}`,
//! `{"timedOut": {"_0": "/api/vm"}}`, `{"notSignedIn": {}}`).

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ApiError {
    NotSignedIn {},
    /// The build points at a loopback origin with no server (local backend mode).
    NoBackend {
        #[serde(rename = "_0")]
        url: String,
    },
    TimedOut {
        #[serde(rename = "_0")]
        path: String,
    },
    Transport {
        #[serde(rename = "_0")]
        text: String,
    },
    /// `message` is the server's display-safe text, `action` its next step ("Run `…`") and
    /// `trace_id` the support reference a person pastes.
    #[serde(rename_all = "camelCase")]
    Http {
        status: i64,
        #[serde(default)]
        code: Option<String>,
        #[serde(default)]
        message: Option<String>,
        #[serde(default)]
        action: Option<String>,
        #[serde(default)]
        trace_id: Option<String>,
    },
    /// A refusal a paid plan lifts (`upgradeRequired`, not a credits purchase): `plan` is the
    /// plan that lifts it, `pro` or `max`; `upgrade_url` its cmux.com checkout or pricing link.
    PlanRequired {
        #[serde(default)]
        message: Option<String>,
        #[serde(default, rename = "upgradeURL")]
        upgrade_url: Option<String>,
        plan: String,
    },
    Decoding {
        #[serde(rename = "_0")]
        text: String,
    },
}

/// A non-empty trimmed string, else None.
fn trimmed(value: Option<&Value>) -> Option<String> {
    let text = value?.as_str()?.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

/// The failure an HTTP `status` with `body` (and the `x-cmux-vm-error` header's `header_code`)
/// means: the standard VM error body (`web/services/vms/routeHelpers.ts` `vmErrorResponse`:
/// `{error, message, action, traceId, ui: {message, traceId}}`), or the cmux API Worker's nested
/// `{ok: false, error: {code, message}}`. A refusal a paid plan lifts is `PlanRequired`.
pub fn from_response(status: i64, body: &[u8], header_code: Option<&str>) -> ApiError {
    let parsed = serde_json::from_slice::<Value>(body).ok();
    let object = parsed.as_ref().and_then(Value::as_object);
    let field = |key: &str| object.and_then(|object| object.get(key));
    let ui = field("ui").and_then(Value::as_object);
    let nested = field("error").and_then(Value::as_object);
    let code = header_code
        .map(str::to_owned)
        .or_else(|| trimmed(field("error")))
        .or_else(|| trimmed(nested.and_then(|n| n.get("code"))));
    let message = trimmed(ui.and_then(|ui| ui.get("message")))
        .or_else(|| trimmed(field("message")))
        .or_else(|| trimmed(nested.and_then(|n| n.get("message"))));
    if let Some(object) = object
        && let Some(plan) = lifting_plan(object, code.as_deref())
    {
        return ApiError::PlanRequired { message, upgrade_url: upgrade_url(object), plan };
    }
    ApiError::Http {
        status,
        code,
        message,
        action: trimmed(field("action")),
        trace_id: trimmed(field("traceId"))
            .or_else(|| trimmed(ui.and_then(|ui| ui.get("traceId")))),
    }
}

/// The plan an `upgradeRequired` refusal names (the server spreads `extra` to the top level):
/// `upgradePlanId`, else `pro`; None for a plan cmux does not sell here, and for a credits
/// top-up, a purchase rather than a plan.
fn lifting_plan(object: &Map<String, Value>, code: Option<&str>) -> Option<String> {
    if object.get("upgradeRequired").and_then(Value::as_bool) != Some(true)
        || code == Some("vm_create_credits_insufficient")
    {
        return None;
    }
    let plan = object.get("upgradePlanId").and_then(Value::as_str).unwrap_or("pro");
    matches!(plan, "pro" | "max").then(|| plan.to_owned())
}

/// The refusal's `upgradeUrl`, only an https cmux.com link. Strict, as a browser reads it: no
/// backslash (a browser reads `\\` as `/`, so `https://evil.com\\@cmux.com` is evil.com's), no
/// user info, a host of letters, digits, dots and dashes, and a port only of digits.
fn upgrade_url(object: &Map<String, Value>) -> Option<String> {
    let text = object.get("upgradeUrl")?.as_str()?;
    if text.chars().any(|c| c.is_whitespace() || c.is_control() || c == '\\') {
        return None;
    }
    let rest = text.strip_prefix("https://")?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    let (host, port) = authority.split_once(':').unwrap_or((authority, "0"));
    let host = host.to_ascii_lowercase();
    let host_ok = host.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-');
    let port_ok = !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit());
    (host_ok && port_ok && (host == "cmux.com" || host.ends_with(".cmux.com")))
        .then(|| text.to_owned())
}

/// The text a person reads. An HTTP failure reads as the server's message, then its next step,
/// then the trace id as `trace_format` writes it (`%@` stands for the id; the app passes its
/// localized "(trace %@)").
pub fn text(error: &ApiError, trace_format: &str) -> String {
    match error {
        ApiError::NotSignedIn {} => "not signed in".into(),
        ApiError::NoBackend { url } => format!("no Cloud backend at {url}"),
        ApiError::TimedOut { path } => format!("{path} timed out"),
        ApiError::Transport { text } => text.clone(),
        ApiError::Http { status, code, message, action, trace_id } => {
            let first = message
                .clone()
                .or_else(|| code.clone())
                .unwrap_or_else(|| format!("HTTP {status}"));
            let trace = trace_id.as_ref().map(|id| trace_format.replace("%@", id));
            [Some(first), action.clone(), trace].into_iter().flatten().collect::<Vec<_>>().join(" ")
        }
        ApiError::PlanRequired { message, plan, .. } => message.clone().unwrap_or_else(|| {
            if plan == "pro" {
                "Cloud machines need cmux Pro.".into()
            } else {
                format!("This needs cmux {}.", capitalized(plan))
            }
        }),
        ApiError::Decoding { text } => format!("unexpected response: {text}"),
    }
}

/// Each word's first letter upper case, the rest lower (as Foundation's `capitalized`).
fn capitalized(text: &str) -> String {
    text.split(' ')
        .map(|word| {
            let mut chars = word.chars();
            chars.next().map_or_else(String::new, |first| {
                first.to_uppercase().chain(chars.flat_map(char::to_lowercase)).collect()
            })
        })
        .collect::<Vec<_>>()
        .join(" ")
}

/// A stable code for a caller that maps failures to its own text: the server's error code
/// (`run_sandbox_unavailable`, …) when it sent one.
pub fn code(error: &ApiError) -> String {
    match error {
        ApiError::NotSignedIn {} => "not_signed_in".into(),
        ApiError::NoBackend { .. } | ApiError::Transport { .. } => "unavailable".into(),
        ApiError::TimedOut { .. } => "timeout".into(),
        ApiError::Http { status, code, .. } => {
            code.clone().unwrap_or_else(|| format!("http_{status}"))
        }
        ApiError::PlanRequired { .. } => "plan_required".into(),
        ApiError::Decoding { .. } => "bad_response".into(),
    }
}

#[cfg(test)]
mod tests;
