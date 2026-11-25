//! `cmux-feed-approve`'s rules over the JSON channel (ops `feed_approve_*`): the check of a
//! phone's signed approve answer (cx-aocz). The app reads the presence keys and its own token;
//! every rule about them is here.
//!
//! - `feed_approve_shown_sha256` `{action}` -> `{sha256}`: the digest of what the person saw.
//! - `feed_approve_keys` `{value}` -> `{keys: {install: key}}`: a `user.presence_key.list` value.
//! - `feed_approve_context` `{token}` -> `{context: context | null}`: this Mac's install token.
//! - `feed_approve_check` `{decision, by, item, shown_sha256, context, keys, now_ms}` ->
//!   `{failure: null | name}`.

use std::collections::HashMap;

use crate::ERR_INVALID;
use cmux_feed_approve::{Context, Decision, Key, ShownText};
use serde::Deserialize;
use serde_json::{Value, json};

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"feed_approve_")
}

#[derive(Deserialize)]
struct CheckRequest {
    decision: Decision,
    by: String,
    item: String,
    shown_sha256: String,
    context: Context,
    keys: HashMap<String, Key>,
    now_ms: f64,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let reply = match operation {
        b"feed_approve_check" => {
            let r: CheckRequest = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
            let failure = cmux_feed_approve::check(
                &r.decision,
                &r.by,
                &r.item,
                &r.shown_sha256,
                &r.context,
                &r.keys,
                r.now_ms,
            )
            .err();
            json!({ "failure": failure })
        }
        other => {
            let request: Value = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
            match other {
                b"feed_approve_shown_sha256" => {
                    let action = request.get("action").unwrap_or(&Value::Null);
                    json!({ "sha256": ShownText::from_action(action).sha256() })
                }
                b"feed_approve_keys" => {
                    let value = request.get("value").unwrap_or(&Value::Null);
                    json!({ "keys": cmux_feed_approve::keys(value) })
                }
                b"feed_approve_context" => {
                    let token = request.get("token").and_then(Value::as_str).unwrap_or_default();
                    json!({ "context": cmux_feed_approve::context_of_token(token) })
                }
                _ => return Err(ERR_INVALID),
            }
        }
    };
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
