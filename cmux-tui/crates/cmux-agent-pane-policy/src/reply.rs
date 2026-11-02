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
/// [`REPORTED_SCHEMES`] and `value` is a strict RFC 3986 URL, the strict
/// parse of Swift's `URLComponents(string:)` (nil on macOS 14; macOS 15 and
/// later encode some invalid characters instead): a scheme (a letter, then
/// letters, digits, `+`, `-`, `.`), then for `//` an authority (a userinfo
/// `user[:password]` with no `@` and no second `:`, a reg-name host or a
/// `[...]` IPv6 literal, a port of digits), a path, a query and one
/// fragment, each of its own characters, `%` only as a two-digit escape.
/// Where this check is stricter than Foundation, the reply only loses a
/// peer's transport; it never reports one Foundation would not.
pub fn reported_scheme(value: &Value) -> Option<&'static str> {
    let text = value.as_str()?;
    let (scheme, rest) = text.split_once(':')?;
    let mut chars = scheme.chars();
    let first = chars.next()?;
    if !first.is_ascii_alphabetic()
        || !chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    {
        return None;
    }
    let (rest, fragment) = match rest.split_once('#') {
        Some((rest, fragment)) => (rest, Some(fragment)),
        None => (rest, None),
    };
    let (rest, query) = match rest.split_once('?') {
        Some((rest, query)) => (rest, Some(query)),
        None => (rest, None),
    };
    let path = match rest.strip_prefix("//") {
        Some(after) => {
            let (authority, path) = match after.find('/') {
                Some(at) => after.split_at(at),
                None => (after, ""),
            };
            if !valid_authority(authority) {
                return None;
            }
            path
        }
        None => rest,
    };
    let query_ok = |part: Option<&str>| part.is_none_or(|p| uri_chars(p, b":@/?"));
    if !uri_chars(path, b":@/") || !query_ok(query) || !query_ok(fragment) {
        return None;
    }
    let lower = scheme.to_ascii_lowercase();
    REPORTED_SCHEMES.into_iter().find(|s| *s == lower)
}

/// An RFC 3986 authority: `[userinfo@]host[:port]`.
fn valid_authority(authority: &str) -> bool {
    let (userinfo, host_port) = match authority.split_once('@') {
        Some((userinfo, host_port)) => (Some(userinfo), host_port),
        None => (None, authority),
    };
    // `user[:password]`: Foundation cuts at the first `:`, and a password
    // holds no `:`.
    if userinfo.is_some_and(|u| !uri_chars(u, b":") || u.matches(':').nth(1).is_some()) {
        return false;
    }
    let (host, port) = if let Some(literal) = host_port.strip_prefix('[') {
        let Some((address, after)) = literal.split_once(']') else { return false };
        if address.parse::<std::net::Ipv6Addr>().is_err() {
            return false;
        }
        match after.strip_prefix(':') {
            Some(port) => ("", Some(port)),
            None if after.is_empty() => ("", None),
            None => return false,
        }
    } else {
        match host_port.split_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (host_port, None),
        }
    };
    uri_chars(host, b"")
        && port.is_none_or(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
}

/// Whether `part` holds only RFC 3986 unreserved and sub-delim characters,
/// `%` two-digit escapes, and the bytes in `extra`.
fn uri_chars(part: &str, extra: &[u8]) -> bool {
    let mut bytes = part.bytes();
    while let Some(b) = bytes.next() {
        if b == b'%' {
            let escape = (bytes.next(), bytes.next());
            if !matches!(escape, (Some(x), Some(y)) if x.is_ascii_hexdigit() && y.is_ascii_hexdigit())
            {
                return false;
            }
        } else if !(b.is_ascii_alphanumeric()
            || b"-._~!$&'()*+,;=".contains(&b)
            || extra.contains(&b))
        {
            return false;
        }
    }
    true
}

/// A daemon error's code as Swift's `as? Int` reads a JSON number: an
/// integer, an integral float, or a boolean (1 or 0).
fn integer_code(value: &Value) -> Option<i64> {
    match value {
        Value::Bool(b) => Some(i64::from(*b)),
        // An integral float in i64's range (Swift's NSNumber gives Int for
        // it); i64::MIN is -2^63 exactly, and 2^63 is out of range.
        Value::Number(n) => n.as_i64().or_else(|| {
            n.as_f64()
                .filter(|f| {
                    f.fract() == 0.0
                        && *f >= -9_223_372_036_854_775_808.0
                        && *f < 9_223_372_036_854_775_808.0
                })
                .and_then(|f| format!("{f:.0}").parse().ok())
        }),
        _ => None,
    }
}
