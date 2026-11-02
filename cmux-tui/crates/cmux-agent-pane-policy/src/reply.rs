//! Replies the host filters itself (CmuxNextAgentPane AcpmuxPaneMethods+ReplyShapes.swift
//! `replyShapes`, `filtered`, `filteredReply`): only the fields the pane
//! renders, at every depth.

use crate::data::ReplyShape;
use serde_json::{Map, Value, json};

/// `value` cut to `shape`: None when it does not fit (a list keeps only the
/// items that fit; an object with none of its fields is dropped).
pub fn filtered(value: &Value, shape: &ReplyShape) -> Option<Value> {
    match shape {
        ReplyShape::String => value.as_str().map(|s| Value::String(s.to_owned())),
        ReplyShape::Bool => value.as_bool().map(Value::Bool),
        ReplyShape::Scheme(_) => reported_scheme(value).map(|s| Value::String(s.to_owned())),
        // serde_json keeps no NaN or infinity, and a boolean is not a number.
        ReplyShape::Number => value.is_number().then(|| value.clone()),
        ReplyShape::List(item) => value
            .as_array()
            .map(|a| Value::Array(a.iter().filter_map(|v| filtered(v, item)).collect())),
        ReplyShape::Object(fields) => {
            let object = value.as_object()?;
            let kept: Map<String, Value> = fields
                .iter()
                .filter_map(|(k, field)| {
                    // A scheme field reads its sibling (`transport` from `url`).
                    let source = match field {
                        ReplyShape::Scheme(from) => from,
                        _ => k,
                    };
                    object.get(source).and_then(|v| filtered(v, field)).map(|v| (k.clone(), v))
                })
                .collect();
            (!kept.is_empty()).then_some(Value::Object(kept))
        }
    }
}

/// A reply to a filtered request, rebuilt with the page's id (raw JSON) and
/// its filtered result; an error keeps only its code and message. Keys
/// sorted, as Swift writes it.
pub fn filtered_reply(object: &Map<String, Value>, shape: &ReplyShape, page_id: &str) -> String {
    let id = serde_json::from_str::<Value>(page_id).unwrap_or(Value::Null);
    let mut reply = Map::new();
    reply.insert("jsonrpc".into(), json!("2.0"));
    reply.insert("id".into(), id);
    if let Some(error) = object.get("error").and_then(Value::as_object) {
        let code = error.get("code").and_then(integer_code).unwrap_or(-32603);
        let message = error.get("message").and_then(Value::as_str).unwrap_or_default();
        reply.insert("error".into(), json!({"code": code, "message": message}));
    } else {
        let result = object
            .get("result")
            .and_then(|r| filtered(r, shape))
            .unwrap_or_else(|| Value::Object(Map::new()));
        reply.insert("result".into(), result);
    }
    serde_json::to_string(&sort(Value::Object(reply))).unwrap_or_default()
}

fn sort(v: Value) -> Value {
    match v {
        Value::Object(o) => {
            let mut entries: Vec<(String, Value)> =
                o.into_iter().map(|(k, v)| (k, sort(v))).collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            Value::Object(entries.into_iter().collect())
        }
        Value::Array(a) => Value::Array(a.into_iter().map(sort).collect()),
        other => other,
    }
}

/// The schemes a [`ReplyShape::Scheme`] field may report.
pub const REPORTED_SCHEMES: [&str; 3] = ["ssh", "ws", "wss"];

/// The lower-cased scheme of the URL `value` when it is one of
/// [`REPORTED_SCHEMES`], as Swift's `URLComponents(string:)?.scheme` reads
/// it: the text is RFC 3986 characters only (a `%` starts a two-digit
/// escape), and the scheme is a letter then letters, digits, `+`, `-` or `.`
/// before the first `:`.
pub fn reported_scheme(value: &Value) -> Option<&'static str> {
    let text = value.as_str()?;
    let bytes = text.as_bytes();
    let mut at = 0;
    while let Some(&b) = bytes.get(at) {
        if b == b'%' {
            let hex = |i: usize| bytes.get(i).is_some_and(u8::is_ascii_hexdigit);
            let (Some(one), Some(two)) = (at.checked_add(1), at.checked_add(2)) else {
                return None;
            };
            if !hex(one) || !hex(two) {
                return None;
            }
            at = two;
        } else if !(b.is_ascii_alphanumeric() || b"-._~:/?#[]@!$&'()*+,;=".contains(&b)) {
            return None;
        }
        at = at.checked_add(1)?;
    }
    let (scheme, _) = text.split_once(':')?;
    let mut chars = scheme.chars();
    let first = chars.next()?;
    if !first.is_ascii_alphabetic()
        || !chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    {
        return None;
    }
    let lower = scheme.to_ascii_lowercase();
    REPORTED_SCHEMES.into_iter().find(|s| *s == lower)
}

/// A daemon error's code as Swift's `as? Int` reads a JSON number: an
/// integer, an integral float, or a boolean (1 or 0).
fn integer_code(value: &Value) -> Option<i64> {
    match value {
        Value::Bool(b) => Some(i64::from(*b)),
        Value::Number(n) => n.as_i64().or_else(|| {
            n.as_f64()
                .filter(|f| f.fract() == 0.0 && f.abs() < 9.2e18)
                .and_then(|f| format!("{f:.0}").parse().ok())
        }),
        _ => None,
    }
}
