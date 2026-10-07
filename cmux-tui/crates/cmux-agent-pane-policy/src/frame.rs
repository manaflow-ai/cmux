//! The decision on one page frame (CmuxNextAgentPane `AcpmuxPaneMethods.decide`,
//! `decideFrame`, AcpmuxPaneMethods.swift): size, the duplicate-key check
//! before any parse, JSON-RPC 2.0, a method, C1 (no `mcpServers` to spawn),
//! `initialize` first and only first, then the allowlist (default deny).

use crate::data::policy;
use crate::error::Refusal;
use crate::json_keys::{self, Verdict};
use serde_json::{Map, Value, json};
use std::collections::BTreeSet;
use unicode_normalization::UnicodeNormalization;

/// What the host does with one page frame.
#[derive(Clone, Debug, PartialEq)]
pub enum Decision {
    /// Send this text (the first frame with the LocalApp token added when
    /// there is one).
    Send(String),
    /// Refuse it. `request_id` is the JSON-RPC id of a refused request as raw
    /// JSON, so the host can answer it with [`refusal_frame`].
    Refuse { refusal: Refusal, method: Option<String>, request_id: Option<String> },
}

/// A refused frame's details (see [`Decision::Refuse`]).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refused {
    pub refusal: Refusal,
    pub method: Option<String>,
    pub request_id: Option<String>,
}

impl From<Refused> for Decision {
    fn from(r: Refused) -> Decision {
        Decision::Refuse { refusal: r.refusal, method: r.method, request_id: r.request_id }
    }
}

/// Whether `set` holds `value` as Swift's `Set<String>` would (canonical
/// equivalence).
pub(crate) fn contains(set: &BTreeSet<String>, value: &str) -> bool {
    set.contains(value) || {
        let nfc: String = value.nfc().collect();
        set.iter().any(|s| s.nfc().eq(nfc.chars()))
    }
}

/// The decision for `text`, the connection's first frame or a later one.
pub fn decide(text: &str, is_first: bool, local_app_token: Option<&str>) -> Decision {
    match decide_frame(text, is_first) {
        Err(refused) => refused.into(),
        Ok(object) => {
            let Some(token) = local_app_token.filter(|_| is_first) else {
                return Decision::Send(text.to_owned());
            };
            let object = with_local_app_token(object, token);
            match serde_json::to_string(&object) {
                Ok(text) => Decision::Send(text),
                Err(_) => Refused {
                    refusal: Refusal::InvalidFrame,
                    method: object.get("method").and_then(Value::as_str).map(str::to_owned),
                    request_id: object.get("id").and_then(raw_id),
                }
                .into(),
            }
        }
    }
}

/// The one parse of a page frame every rule reads: the duplicate check
/// before it, then the allowlist and C1. The parsed frame on success.
pub fn decide_frame(text: &str, is_first: bool) -> Result<Map<String, Value>, Refused> {
    let p = policy();
    let refuse = |refusal, method: Option<String>, request_id: Option<String>| {
        Err(Refused { refusal, method, request_id })
    };
    if text.len() > p.maximum_frame_bytes {
        return refuse(Refusal::FrameTooLarge, None, None);
    }
    match json_keys::verdict(text) {
        Verdict::Clean => {}
        Verdict::Malformed => return refuse(Refusal::InvalidFrame, None, None),
        Verdict::Duplicate => {
            let (method, id) = identity(text);
            return refuse(Refusal::DuplicateKey, method, id);
        }
    }
    let object = match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(o)) if o.get("jsonrpc").and_then(Value::as_str) == Some("2.0") => o,
        _ => return refuse(Refusal::InvalidFrame, None, None),
    };
    let id = object.get("id").and_then(raw_id);
    let Some(method) = object.get("method").and_then(Value::as_str).map(str::to_owned) else {
        return refuse(Refusal::MethodRefused, None, None);
    };
    if object.get("params").is_some_and(carries_servers) {
        return refuse(Refusal::McpServersRefused, Some(method), id);
    }
    if is_first {
        if method != p.initialize || id.is_none() {
            return refuse(Refusal::FirstFrameNotInitialize, Some(method), id);
        }
        return Ok(object);
    }
    let allowed = if id.is_none() {
        contains(&p.notifications, &method)
    } else {
        contains(&p.requests, &method)
    };
    if allowed { Ok(object) } else { refuse(Refusal::MethodRefused, Some(method), id) }
}

/// The first frame with the LocalApp token in `params._meta.acpmux` (the
/// host's own key; the page never sees it).
pub fn with_local_app_token(mut object: Map<String, Value>, token: &str) -> Map<String, Value> {
    let mut params = object.remove("params").and_then(into_object).unwrap_or_default();
    let mut meta = params.remove("_meta").and_then(into_object).unwrap_or_default();
    let mut acpmux = meta.remove("acpmux").and_then(into_object).unwrap_or_default();
    acpmux.insert("localAppToken".into(), Value::String(token.into()));
    meta.insert("acpmux".into(), Value::Object(acpmux));
    params.insert("_meta".into(), Value::Object(meta));
    object.insert("params".into(), Value::Object(params));
    object
}

pub(crate) fn into_object(v: Value) -> Option<Map<String, Value>> {
    match v {
        Value::Object(o) => Some(o),
        _ => None,
    }
}

/// The error frame that answers a refused request, as the daemon answers an
/// unknown one. `root_requested`: the host offered to add the refused folder
/// as a root.
pub fn refusal_frame(
    request_id: &str,
    refusal: Refusal,
    method: Option<&str>,
    root_requested: bool,
) -> String {
    let mut data = Map::new();
    data.insert("code".into(), Value::String(refusal.code().into()));
    data.insert("origin".into(), Value::String("native".into()));
    if let Some(method) = method {
        data.insert("method".into(), Value::String(method.into()));
    }
    if root_requested {
        data.insert("rootRequested".into(), Value::Bool(true));
    }
    let body = json!({"code": -32601, "message": "Refused by the cmux host", "data": data});
    format!(r#"{{"jsonrpc":"2.0","id":{request_id},"error":{body}}}"#)
}

/// A frame's method and raw id, for a refusal.
pub(crate) fn identity(text: &str) -> (Option<String>, Option<String>) {
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(o)) => (
            o.get("method").and_then(Value::as_str).map(str::to_owned),
            o.get("id").and_then(raw_id),
        ),
        _ => (None, None),
    }
}

/// Whether `value` holds a non-empty `mcpServers` (or one that is not a
/// list) at any depth.
pub fn carries_servers(value: &Value) -> bool {
    let key = &policy().servers_key;
    match value {
        Value::Object(o) => o.iter().any(|(k, inner)| {
            if k == key {
                !matches!(inner, Value::Array(a) if a.is_empty())
            } else {
                carries_servers(inner)
            }
        }),
        Value::Array(a) => a.iter().any(carries_servers),
        _ => false,
    }
}

/// A JSON-RPC id (number or string) as raw JSON, written as Foundation
/// writes it (`NSNumber.stringValue`; a string with `/` escaped).
pub fn raw_id(value: &Value) -> Option<String> {
    match value {
        Value::Number(n) => Some(match (n.as_i64(), n.as_u64(), n.as_f64()) {
            (Some(i), _, _) => i.to_string(),
            (_, Some(u), _) => u.to_string(),
            (_, _, Some(f)) if f.fract() == 0.0 && f.abs() < 1e15 => format!("{}", f as i64),
            (_, _, Some(f)) => f.to_string(),
            _ => n.to_string(),
        }),
        Value::String(s) => serde_json::to_string(s).ok().map(|s| s.replace('/', "\\/")),
        _ => None,
    }
}
