//! `_acpmux/surgery {sessionId, keepTurns?, minChars?, dryRun?}` (`hub/surgery.rs`): mask a
//! Claude chat's old tool output and resume it on the masked copy, with no model call. Answers
//! `{applied, ...}`; a chat mid-turn, not on Claude or with nothing to mask answers
//! `applied: false` and its reason. The app, the person's CLI and other agents on this machine
//! call it (cold wake picks it instead of `/compact`); a remote WebSocket device and a peer are
//! refused.

use super::{Conn, str_param};
use crate::hub::Hub;
use crate::hub::surgery::MaskOptions;
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

/// The reply to `surgery`, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if m != method::MUX_SURGERY {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    Some(handle(hub, params).await)
}

async fn handle(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    let n = |k: &str| params.get(k).and_then(Value::as_u64);
    let opts = (n("keepTurns").is_some() || n("minChars").is_some()).then(|| {
        let d = MaskOptions::default();
        MaskOptions {
            keep_turns: n("keepTurns").map_or(d.keep_turns, |v| v.clamp(1, 50) as usize),
            min_chars: n("minChars").map_or(d.min_chars, |v| v.clamp(256, 1_000_000) as usize),
        }
    });
    let dry = params.get("dryRun").and_then(Value::as_bool) == Some(true);
    hub.surgery(&session, opts, dry).await
}
