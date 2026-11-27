//! The `phone-page` link service (`phone-page-v1`), sans-I/O: an agent on the
//! Mac drives a browser tab the iPhone shows in its own web view, with the
//! same `browser.page.*` verbs the Mac's own tabs answer (RFD 0089, "Agents
//! drive the phone's tab"), so it can check a dev build as a phone sees it:
//! the phone's viewport, touch and WebKit.
//!
//! The path, end to end:
//!
//! 1. The agent names the tab with its device: `cmux browser tab_…@phone eval
//!    'document.title'` (the one linked phone) or `tab_…@<device>` (a phone's
//!    device id or name). [`Address`] parses it. The tab id is the Mac's tab:
//!    the phone shows that same tab natively ("Open on iPhone").
//! 2. The CLI asks this Mac's link host (hostd) on its local socket
//!    (`{"op":"phone-page","device":D,"method":M,"params":P}`).
//! 3. hostd picks the phone ([`pick`]) among those holding a `phone-page`
//!    channel open, and writes one [`request_line`] on it. No phone holds one:
//!    the call is refused [`NOT_LINKED`], never queued.
//! 4. The phone runs the verb on the tab's web view and writes one
//!    [`answer_line`]; hostd matches it by id ([`parse_answer`]) and answers
//!    the CLI, or refuses [`TIMEOUT`] past the verb's [`timeout`].
//!
//! Lines are JSON, one per message, ended by `\n` in both directions (a
//! screenshot is megabytes, so a message spans many link frames).

use std::time::Duration;

use serde_json::{Map, Value, json};

/// The service the phone opens on its link to the Mac and holds open.
pub const SERVICE: &str = "phone-page";
/// What hostd lists in `version` when it routes agents' calls to phone tabs.
pub const CAPABILITY: &str = "phone-page-v1";
/// The longest line either side accepts (a full-page screenshot as base64).
pub const MAX_LINE: usize = 48 << 20;
/// The device word that means "the one phone linked now".
pub const ANY_PHONE: &str = "phone";

/// No phone holds `phone-page` open on this Mac (none linked, or its app is
/// an older build).
pub const NOT_LINKED: &str = "phone_not_linked";
/// `@phone` with several phones linked: name one.
pub const AMBIGUOUS: &str = "phone_ambiguous";
/// The verb is not one a phone tab answers ([`VERBS`]).
pub const UNSUPPORTED: &str = "unsupported_verb";
/// The phone did not answer within the verb's [`timeout`].
pub const TIMEOUT: &str = "phone_timeout";
/// The phone's channel closed before it answered.
pub const GONE: &str = "phone_gone";
/// The phone does not show that tab in its own web view (it mirrors the Mac's
/// page, or the tab is not open there).
pub const NOT_ON_PHONE: &str = "tab_not_on_phone";
/// A malformed request or answer.
pub const BAD_REQUEST: &str = "bad_request";

/// The `browser.page.*` methods a phone tab answers, with the params each
/// reads besides `tab` (the Mac's own tab answers these with the same params
/// and the same result shape, `BrowserPageService`):
///
/// - `navigate {url}`, `back`, `forward`, `reload` → `{}`
/// - `state` → `{url, title, loading}`
/// - `eval {script}` → `{value}` (the script's completion value, JSON)
/// - `text {selector}` → `{text}` (the first match's `innerText`)
/// - `screenshot` → `{png_base64, width, height}` (the visible viewport)
pub const VERBS: &[&str] = &[
    "browser.page.navigate",
    "browser.page.back",
    "browser.page.forward",
    "browser.page.reload",
    "browser.page.state",
    "browser.page.eval",
    "browser.page.text",
    "browser.page.screenshot",
];

/// Whether a phone tab answers `method`.
pub fn supports(method: &str) -> bool {
    VERBS.contains(&method)
}

/// How long hostd waits for the phone's answer to `method` (a screenshot
/// crosses the link as megabytes; a page load can take a while on cellular).
pub fn timeout(method: &str) -> Duration {
    match method {
        "browser.page.screenshot" => Duration::from_secs(35),
        "browser.page.navigate" | "browser.page.reload" | "browser.page.eval" => {
            Duration::from_secs(30)
        }
        _ => Duration::from_secs(15),
    }
}

/// A browser tab as one phone shows it: `tab_…@phone` or `tab_…@<device>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Address {
    /// The Mac's tab id (`tab_…`), which the phone's native tab keeps.
    pub tab: String,
    /// The phone's device id or name; `None` for [`ANY_PHONE`].
    pub device: Option<String>,
}

impl Address {
    /// Parses a CLI target; `None` when it is not a phone tab address (a
    /// plain `tab_…` stays the Mac's tab).
    pub fn parse(target: &str) -> Option<Self> {
        let (tab, device) = target.split_once('@')?;
        let valid_tab = tab.len() > "tab_".len()
            && tab.starts_with("tab_")
            && tab.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
        if !valid_tab || device.is_empty() || device.chars().any(char::is_whitespace) {
            return None;
        }
        let device = (device != ANY_PHONE).then(|| device.to_owned());
        Some(Self { tab: tab.to_owned(), device })
    }
}

/// One phone holding `phone-page` open, as hostd lists it to [`pick`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Linked {
    pub device_id: String,
    /// The name the phone gave when it opened the channel (may be empty).
    pub name: String,
}

/// A refusal: the code (one of the constants above) and a sentence for the
/// person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub message: String,
}

impl Refusal {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }

    /// As the link socket's answer line: `{"error":CODE,"message":…}`.
    pub fn to_json(&self) -> Value {
        json!({"error": self.code, "message": self.message})
    }
}

/// The phone `device` names among `linked`: by device id, else by name
/// (case-insensitive); `None` is the only one linked.
pub fn pick<'a>(linked: &'a [Linked], device: Option<&str>) -> Result<&'a Linked, Refusal> {
    let not_linked = || {
        Refusal::new(
            NOT_LINKED,
            "no iPhone is linked to this Mac with its browser open to agents; open cmux on the phone \
             (signed in, this Mac connected) and show the tab there with Open on iPhone",
        )
    };
    let listed = || {
        linked
            .iter()
            .map(|phone| {
                if phone.name.is_empty() {
                    phone.device_id.clone()
                } else {
                    format!("{} ({})", phone.name, phone.device_id)
                }
            })
            .collect::<Vec<_>>()
            .join(", ")
    };
    let Some(device) = device else {
        return match linked {
            [] => Err(not_linked()),
            [one] => Ok(one),
            _ => Err(Refusal::new(
                AMBIGUOUS,
                format!("several iPhones are linked: {}; name one as tab_…@<device id>", listed()),
            )),
        };
    };
    if let Some(phone) = linked.iter().find(|phone| phone.device_id == device) {
        return Ok(phone);
    }
    let by_name: Vec<&Linked> =
        linked.iter().filter(|phone| phone.name.eq_ignore_ascii_case(device)).collect();
    match by_name.as_slice() {
        [one] => Ok(one),
        [] if linked.is_empty() => Err(not_linked()),
        [] => Err(Refusal::new(
            NOT_LINKED,
            format!("no linked iPhone is named {device}; linked: {}", listed()),
        )),
        _ => Err(Refusal::new(
            AMBIGUOUS,
            format!("several iPhones are named {device}: {}; use a device id", listed()),
        )),
    }
}

/// Checks an agent's call before it goes to the phone: a verb the phone
/// answers, params an object with the tab. Returns the params to send.
pub fn check(method: &str, params: &Value) -> Result<Map<String, Value>, Refusal> {
    if !supports(method) {
        return Err(Refusal::new(
            UNSUPPORTED,
            format!(
                "a phone tab answers {}; not {method}",
                VERBS
                    .iter()
                    .map(|v| v.trim_start_matches("browser.page."))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        ));
    }
    let Some(params) = params.as_object() else {
        return Err(Refusal::new(BAD_REQUEST, "params must be an object"));
    };
    if !params.get("tab").and_then(Value::as_str).is_some_and(|tab| tab.starts_with("tab_")) {
        return Err(Refusal::new(BAD_REQUEST, "params.tab must name a tab_… id"));
    }
    Ok(params.clone())
}

/// hostd → phone: one call, `{"id":N,"method":M,"params":{…}}\n`.
pub fn request_line(id: u64, method: &str, params: &Map<String, Value>) -> Vec<u8> {
    let mut line = json!({"id": id, "method": method, "params": params}).to_string().into_bytes();
    line.push(b'\n');
    line
}

/// A call as the phone reads it.
#[derive(Debug, Clone, PartialEq)]
pub struct Request {
    pub id: u64,
    pub method: String,
    pub tab: String,
    pub params: Map<String, Value>,
}

/// The phone's reading of one request line; `Err` with the id (when one was
/// readable) and the refusal to answer.
pub fn parse_request(line: &[u8]) -> Result<Request, (Option<u64>, Refusal)> {
    let value: Value = serde_json::from_slice(line)
        .map_err(|_| (None, Refusal::new(BAD_REQUEST, "one JSON line")))?;
    let id = value
        .get("id")
        .and_then(Value::as_u64)
        .ok_or((None, Refusal::new(BAD_REQUEST, "no id")))?;
    let method = value.get("method").and_then(Value::as_str).unwrap_or_default();
    let params = check(method, value.get("params").unwrap_or(&Value::Null))
        .map_err(|refusal| (Some(id), refusal))?;
    let tab = params
        .get("tab")
        .and_then(Value::as_str)
        .ok_or_else(|| (Some(id), Refusal::new(BAD_REQUEST, "a request needs a tab")))?
        .to_owned();
    Ok(Request { id, method: method.to_owned(), tab, params })
}

/// phone → hostd: the answer to call `id`, `{"id":N,"ok":true,"value":V}\n` or
/// `{"id":N,"error":{"code":C,"message":M}}\n`.
pub fn answer_line(id: u64, answer: Result<Value, (&str, &str)>) -> Vec<u8> {
    let value = match answer {
        Ok(value) => json!({"id": id, "ok": true, "value": value}),
        Err((code, message)) => json!({"id": id, "error": {"code": code, "message": message}}),
    };
    let mut line = value.to_string().into_bytes();
    line.push(b'\n');
    line
}

/// hostd's reading of one answer line: the call's id and its result, the
/// refusal as `{code, message}`.
pub fn parse_answer(line: &[u8]) -> Option<(u64, Result<Value, Value>)> {
    let value: Value = serde_json::from_slice(line).ok()?;
    let id = value.get("id").and_then(Value::as_u64)?;
    if value.get("ok").and_then(Value::as_bool) == Some(true) {
        return Some((id, Ok(value.get("value").cloned().unwrap_or(Value::Null))));
    }
    let error = value.get("error")?;
    let code = error.get("code").and_then(Value::as_str).unwrap_or("operation.failed");
    let message = error.get("message").and_then(Value::as_str).unwrap_or_default();
    Some((id, Err(json!({"code": code, "message": message}))))
}

#[cfg(test)]
mod tests;
