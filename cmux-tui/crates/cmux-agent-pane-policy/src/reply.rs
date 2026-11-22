//! Replies the host filters itself (CmuxNextAgentPane AcpmuxPaneMethods.swift
//! `replyShapes`, `filtered`, `filteredReply`): only the fields the pane
//! renders, at every depth.

use crate::data::ReplyShape;
use serde_json::{Map, Value, json};

/// `value` cut to `shape`: None when it does not fit (a list keeps only the
/// items that fit; an object with none of its fields is dropped).
pub fn filtered(value: &Value, shape: &ReplyShape) -> Option<Value> {
    match shape {
        ReplyShape::String => value.as_str().map(|s| Value::String(s.to_owned())),
        ReplyShape::List(item) => value
            .as_array()
            .map(|a| Value::Array(a.iter().filter_map(|v| filtered(v, item)).collect())),
        ReplyShape::Object(fields) => {
            let object = value.as_object()?;
            let kept: Map<String, Value> = fields
                .iter()
                .filter_map(|(k, field)| {
                    object.get(k).and_then(|v| filtered(v, field)).map(|v| (k.clone(), v))
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
        let code = error.get("code").and_then(Value::as_i64).unwrap_or(-32603);
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
