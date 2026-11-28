//! The shape checks of the page's frames: what a login, setting, page, side chat or prompt frame
//! asks for, and nothing else (a field of the wrong type is a refused frame, never a guess).

use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// A non-empty string field.
pub fn text<'a>(params: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    params.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

/// A whole non-negative number (a bool is not one).
pub fn uint(value: &Value) -> Option<u64> {
    if let Some(n) = value.as_u64() {
        return Some(n);
    }
    let f = value.as_f64()?;
    if f >= 0.0 && f.fract() == 0.0 && f < 1.8e19 {
        // A whole, in-range float: the exact conversion.
        Some(f as u64)
    } else {
        None
    }
}

/// Legacy text-only prompt: every block is exactly `{type: "text", text}`.
pub fn text_blocks(blocks: &[Value]) -> Option<String> {
    if blocks.is_empty() {
        return None;
    }
    let mut parts: Vec<&str> = Vec::with_capacity(blocks.len());
    for block in blocks {
        let object = block.as_object()?;
        if object.len() != 2 || object.get("type").and_then(Value::as_str) != Some("text") {
            return None;
        }
        parts.push(object.get("text").and_then(Value::as_str)?);
    }
    Some(parts.join("\n\n"))
}

/// A login frame as the daemon's `agent-session-login` step: its `op` and fields; `None` when a
/// field is missing or not text, or the frame's `sessionId` is refused by `names`.
pub fn login(
    method: &str,
    params: &Map<String, Value>,
    names: impl Fn(Option<&Value>) -> bool,
) -> Option<(&'static str, BTreeMap<String, String>)> {
    if !names(params.get("sessionId")) {
        return None;
    }
    let mut fields = BTreeMap::new();
    let mut put = |key: &str, value: &str| {
        fields.insert(key.to_owned(), value.to_owned());
    };
    let op = match method {
        "_acpmux/agent_login/start" => {
            put("agent", text(params, "agent")?);
            "start"
        }
        "_acpmux/agent_login/finish" => {
            put("login_id", text(params, "loginId")?);
            if params.contains_key("code") {
                put("code", text(params, "code")?);
            }
            "finish"
        }
        "_acpmux/agent_login/api_key" => {
            put("agent", text(params, "agent")?);
            put("key", text(params, "key")?);
            "api_key"
        }
        "_acpmux/agent_login/cancel" => {
            put("login_id", text(params, "loginId")?);
            "cancel"
        }
        _ => return None,
    };
    Some((op, fields))
}

/// What a setting frame asks for, as the daemon verb and its arguments.
pub fn setting(method: &str, params: &Map<String, Value>) -> Option<(&'static str, Value)> {
    match method {
        "session/set_model" => {
            Some(("set_model", serde_json::json!({"model_id": text(params, "modelId")?})))
        }
        "session/set_mode" => {
            Some(("set_mode", serde_json::json!({"mode_id": text(params, "modeId")?})))
        }
        "session/set_config_option" => Some((
            "set_config",
            serde_json::json!({"id": text(params, "configId")?, "value": text(params, "value")?}),
        )),
        _ => None,
    }
}

/// The boundary and first prompt of a `_acpmux/side_chat` frame: `throughSeq` a whole positive
/// number, or `live: true` (no `throughSeq`), never both; `None` for any other shape.
pub fn side_request(params: &Map<String, Value>) -> Option<(Option<i64>, Option<String>)> {
    let prompt = match params.get("prompt") {
        None => None,
        Some(Value::String(s)) if s.trim().is_empty() => None,
        Some(Value::String(s)) => Some(s.clone()),
        Some(_) => return None,
    };
    let live = params.get("live").and_then(Value::as_bool) == Some(true);
    match (live, params.get("throughSeq")) {
        (true, None) => Some((None, prompt)),
        (false, Some(number @ Value::Number(_))) => {
            let seq = number.as_i64().or_else(|| {
                let f = number.as_f64()?;
                (f.fract() == 0.0 && f.abs() < 9.0e15).then_some(f as i64)
            })?;
            (seq > 0).then_some((Some(seq), prompt))
        }
        _ => None,
    }
}

/// A page request: forward from `afterSeq`, or the newest `limit` before `beforeSeq`.
pub fn page(params: &Map<String, Value>, watch: bool) -> Value {
    if watch {
        return serde_json::json!({"limit": 1, "kinds": ["transcript"], "listing": true});
    }
    let mut page = Map::new();
    for (key, name) in [
        ("afterSeq", "after_seq"),
        ("beforeSeq", "before_seq"),
        ("limit", "limit"),
        ("maxBytes", "max_bytes"),
    ] {
        if let Some(n) = params.get(key).and_then(uint) {
            page.insert(name.to_owned(), n.into());
        }
    }
    if let Some(kinds) = params.get("kinds").and_then(Value::as_array) {
        let kinds: Vec<Value> = kinds.iter().filter(|k| k.is_string()).cloned().collect();
        page.insert("kinds".to_owned(), Value::Array(kinds));
    }
    Value::Object(page)
}

const IMAGE_EXTENSIONS: [&str; 5] = ["png", "jpg", "jpeg", "gif", "webp"];

/// True for a path whose last component has an image extension (a leading dot alone is no extension).
fn is_image_name(path: &str) -> bool {
    let trimmed = path.trim_end_matches('/');
    let name = trimmed.rsplit('/').next().unwrap_or("");
    match name.rfind('.') {
        Some(dot) if dot > 0 => {
            let ext = name.get(dot.saturating_add(1)..).unwrap_or("").to_lowercase();
            IMAGE_EXTENSIONS.contains(&ext.as_str())
        }
        _ => false,
    }
}

fn percent_decode(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0usize;
    while let Some(&b) = bytes.get(i) {
        if b == b'%' {
            let hex = text.get(i.saturating_add(1)..i.saturating_add(3))?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i = i.saturating_add(3);
        } else {
            out.push(b);
            i = i.saturating_add(1);
        }
    }
    String::from_utf8(out).ok()
}

/// The path of an image token the remote media reader may read: a plain path with its query or
/// fragment cut, or a local `file://` URL's path; `None` for a non-image or a non-local URL.
pub fn remote_image_path(text: &str) -> Option<String> {
    let is_file_url = text.get(..7).is_some_and(|p| p.eq_ignore_ascii_case("file://"));
    if is_file_url {
        let rest = text.get(7..)?;
        if rest.chars().any(|c| c.is_control() || c.is_whitespace() || "<>\"\\^`{|}".contains(c)) {
            return None;
        }
        let rest = rest.split(['?', '#']).next().unwrap_or("");
        let (host, path) = match rest.find('/') {
            Some(at) => (rest.get(..at)?, rest.get(at..)?),
            None => (rest, ""),
        };
        let host = percent_decode(host)?;
        if !(host.is_empty() || host == "localhost") {
            return None;
        }
        let path = percent_decode(path)?;
        return is_image_name(&path).then_some(path);
    }
    let path = text.trim_start_matches(['?', '#']).split(['?', '#']).next().unwrap_or("");
    (!path.is_empty() && is_image_name(path)).then(|| path.to_owned())
}

/// An agent's text or thinking on its way to the page: the model's first token, once the chat's
/// first prompt went out (the person's own words echoed back are a `user_message_chunk`).
pub fn is_first_token(frame: &str) -> bool {
    frame.contains("\"session/update\"")
        && (frame.contains("\"agent_message_chunk\"") || frame.contains("\"agent_thought_chunk\""))
}
