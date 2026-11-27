//! Every `session/new` refusal carries a short `data.reason` code.
//!
//! A start that failed for a reason with no code reached the app as a bare
//! `agent_session.refused: acpmux refused the request`: the daemon passes on only acpmux's
//! `data.reason` (`agent_session_start::acpmux_reason`), never the message text, so a stub agent
//! that crashed at import (cmuxterm-hq notify-banner-click probe, run 46065488561) named no cause.
//! Each error that leaves `session/new` without a reason gets one here: the typed `errorKind`
//! when it has one (`recovery.rs`, e.g. `agent.exited`), else `session_new.<kind of error>`.

use crate::rpc::RpcError;
use serde_json::{Map, Value, json};

/// The longest code the daemon passes on (`agent_session_start::acpmux_reason`).
const MAX_REASON: usize = 64;

/// A short code: letters, digits and `._-`, at most [`MAX_REASON`] bytes.
fn is_code(code: &str) -> bool {
    (1..=MAX_REASON).contains(&code.len())
        && code.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

/// The code for an error with no reason of its own.
fn reason_of(error: &RpcError) -> String {
    if let Some(kind) = error
        .data
        .as_ref()
        .and_then(|data| data.get("errorKind"))
        .and_then(Value::as_str)
        .filter(|kind| is_code(kind))
    {
        return kind.to_owned();
    }
    match error.code {
        -32602 => "session_new.invalid_params",
        -32601 => "session_new.method_not_found",
        -32603 => "session_new.internal",
        -32002 => "session_new.not_found",
        -32001 => "session_new.not_allowed",
        _ => "session_new.refused",
    }
    .to_owned()
}

/// Gives a `session/new` error that has no short `data.reason` one. A reason that is already
/// a short code stays; any other data keeps its fields (a non-object moves to `data.detail`).
pub(super) fn stamp(error: &mut RpcError) {
    if error
        .data
        .as_ref()
        .and_then(|d| d.get("reason"))
        .and_then(Value::as_str)
        .is_some_and(is_code)
    {
        return;
    }
    let reason = reason_of(error);
    let mut data = match error.data.take() {
        Some(Value::Object(map)) => map,
        None | Some(Value::Null) => Map::new(),
        Some(other) => {
            let mut map = Map::new();
            map.insert("detail".into(), other);
            map
        }
    };
    // A reason that is not a short code (free text) stays readable as `reasonText`.
    if let Some(text) = data.remove("reason") {
        data.insert("reasonText".into(), text);
    }
    data.insert("reason".into(), json!(reason));
    error.data = Some(Value::Object(data));
}

#[cfg(test)]
#[path = "start_reason_tests.rs"]
mod tests;
