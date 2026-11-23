//! The background-process methods (`hub/processes.rs`,
//! docs/background-processes.md): `_acpmux/process/list {sessionId?, limit?, cursor?}` (without
//! `limit`, the newest processes that fit one reply, and `omitted`: `Hub::list_processes_reply`),
//! `_acpmux/process/tail {processId, fromByte?, maxBytes?}` and
//! `_acpmux/process/kill {processId, sessionId?, signal?}` (a named chat must
//! be the process's),
//! `_acpmux/process/background {sessionId, toolCallId?}` (Ctrl-B), and the
//! `_acpmux/process_update {process}` notification.
//!
//! Routed before every other method (`chats.rs`), like the secret methods:
//! they never reach a peer, and they check their own callers. Only this
//! machine's clients (the unix socket and the local app) get them: a
//! process's command line and output are local state, and a kill acts on
//! a local process (and Ctrl-B moves one), so a remote WebSocket device and
//! a peer daemon are refused before anything is read.

use super::{Conn, HubEvent, str_param};
use crate::hub::Hub;
use crate::protocol::process::ProcessBackgroundParams;
use crate::rpc::{Message, RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::Ordering;

/// The reply to a process method, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(
        m,
        method::MUX_PROCESS_LIST
            | method::MUX_PROCESS_TAIL
            | method::MUX_PROCESS_KILL
            | method::MUX_PROCESS_BACKGROUND
    ) {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    Some(handle(hub, m, params).await)
}

async fn handle(hub: &Arc<Hub>, m: &str, params: &Value) -> Result<Value, RpcError> {
    if m == method::MUX_PROCESS_LIST {
        let paging = process_page_params(params)?;
        let recent = recent_param(params)?;
        let within = byte_param(params, "endedWithin")?;
        let before = byte_param(params, "endedBefore")?;
        let calls = calls_param(params)?;
        if recent.is_some() && paging.is_some() {
            return Err(RpcError::invalid_params("recent does not take limit or cursor"));
        }
        if within.is_some() && recent.is_none() {
            return Err(RpcError::invalid_params("endedWithin requires recent"));
        }
        if before.is_some() && (recent.is_none() || within.is_some()) {
            return Err(RpcError::invalid_params(
                "endedBefore requires recent and takes no endedWithin",
            ));
        }
        if calls.is_some() && (recent.is_some() || paging.is_some()) {
            return Err(RpcError::invalid_params("calls takes no recent, limit or cursor"));
        }
        return match params.get("sessionId").filter(|v| !v.is_null()) {
            None if recent.is_some() || calls.is_some() => Err(RpcError::invalid_params(
                "a recent process list or one by calls requires a sessionId",
            )),
            None if paging.is_some() => {
                Err(RpcError::invalid_params("paged process lists require a sessionId"))
            }
            None => Ok(hub.list_processes_reply(None)),
            Some(key) => {
                let key = key
                    .as_str()
                    .ok_or_else(|| RpcError::invalid_params("sessionId must be a string"))?;
                let session = hub.resolve(key)?;
                if let (Some(recent), Some(before)) = (recent, before) {
                    return hub.list_older_processes(&session, recent, before);
                }
                if let Some(recent) = recent {
                    return hub.list_recent_processes(&session, recent, within);
                }
                if let Some(calls) = calls {
                    return Ok(hub.list_call_processes(&session, &calls));
                }
                match paging {
                    Some((limit, cursor)) => hub.list_processes_page(&session, limit, cursor),
                    None => Ok(hub.list_processes_reply(Some(&session))),
                }
            }
        };
    }
    if m == method::MUX_PROCESS_BACKGROUND {
        let p: ProcessBackgroundParams = serde_json::from_value(params.clone())
            .map_err(|e| RpcError::invalid_params(format!("bad params: {e}")))?;
        return hub.background_work(&p.session_id, p.tool_call_id.as_deref()).await;
    }
    let id = str_param(params, "processId")
        .ok_or_else(|| RpcError::invalid_params("processId is required"))?;
    if m == method::MUX_PROCESS_TAIL {
        let from = byte_param(params, "fromByte")?;
        let max = byte_param(params, "maxBytes")?;
        return hub.tail_process(id, from, max).await;
    }
    // Claude Code's stop_task has no signal: both stop the task.
    match params.get("signal").filter(|v| !v.is_null()) {
        None => {}
        Some(signal) if matches!(signal.as_str(), Some("term" | "kill")) => {}
        Some(_) => return Err(RpcError::invalid_params("signal must be term or kill")),
    }
    // A kill that names its chat (the agent pane's, whose host lets it name only a chat in the
    // pane's scope) stops only a process of that chat.
    if let Some(key) = params.get("sessionId").filter(|v| !v.is_null()) {
        let key =
            key.as_str().ok_or_else(|| RpcError::invalid_params("sessionId must be a string"))?;
        let session = hub.resolve(key)?;
        if id.split_once('/').map(|(sid, _)| sid) != Some(session.id.as_str()) {
            return Err(RpcError::invalid_params("processId is not a process of sessionId")
                .with_data(json!({"reason": "process.other_session"})));
        }
    }
    hub.kill_process(id).await
}

/// An opt-in process page. A bare cursor must never silently fall back to a full
/// list, and an unbounded requested limit is capped to a modest page size.
fn process_page_params(params: &Value) -> Result<Option<(usize, Option<&str>)>, RpcError> {
    let cursor = match params.get("cursor").filter(|v| !v.is_null()) {
        None => None,
        Some(Value::String(id)) if !id.is_empty() => Some(id.as_str()),
        Some(_) => return Err(RpcError::invalid_params("cursor must be a nonempty process ID")),
    };
    let Some(value) = params.get("limit").filter(|v| !v.is_null()) else {
        if cursor.is_some() {
            return Err(RpcError::invalid_params("cursor requires limit"));
        }
        return Ok(None);
    };
    let limit = value
        .as_u64()
        .filter(|&n| n > 0)
        .ok_or_else(|| RpcError::invalid_params("limit must be a positive integer"))?;
    let bounded = usize::try_from(limit).unwrap_or(usize::MAX).min(1_000);
    Ok(Some((bounded, cursor)))
}

/// `recent`: how many ended processes a chat's page holds beside the running ones
/// (`Hub::list_recent_processes`), a positive integer, at most 1,000.
fn recent_param(params: &Value) -> Result<Option<usize>, RpcError> {
    let Some(value) = params.get("recent").filter(|v| !v.is_null()) else { return Ok(None) };
    let recent = value
        .as_u64()
        .filter(|&n| n > 0)
        .ok_or_else(|| RpcError::invalid_params("recent must be a positive integer"))?;
    Ok(Some(usize::try_from(recent).unwrap_or(usize::MAX).min(1_000)))
}

/// `calls`: the tool calls whose processes to read (`Hub::list_call_processes`), 1 to 1,000
/// nonempty strings.
fn calls_param(params: &Value) -> Result<Option<Vec<String>>, RpcError> {
    let Some(value) = params.get("calls").filter(|v| !v.is_null()) else { return Ok(None) };
    let bad = || RpcError::invalid_params("calls must be 1 to 1,000 tool call ids");
    let list =
        value.as_array().filter(|list| !list.is_empty() && list.len() <= 1_000).ok_or_else(bad)?;
    list.iter()
        .map(|call| {
            call.as_str().filter(|call| !call.is_empty()).map(str::to_owned).ok_or_else(bad)
        })
        .collect::<Result<Vec<_>, _>>()
        .map(Some)
}

/// A byte count or offset: absent, null or a non-negative integer.
fn byte_param(params: &Value, key: &str) -> Result<Option<u64>, RpcError> {
    match params.get(key).filter(|v| !v.is_null()) {
        None => Ok(None),
        Some(v) => v
            .as_u64()
            .map(Some)
            .ok_or_else(|| RpcError::invalid_params(format!("{key} must be a byte count"))),
    }
}

/// A logged `process_update` as `_acpmux/process_update`, to a connection
/// attached to its session or watching every session, never to a remote
/// WebSocket device or a peer.
pub(super) fn push_update(conn: &Conn, ev: &HubEvent) {
    let rec = &ev.record;
    if rec.dir != "mux" || rec.kind != "process_update" || ev.remote.is_some() {
        return;
    }
    if conn.origin.web_class() {
        return;
    }
    if !conn.watch_all.load(Ordering::SeqCst) && conn.sub_opts(&ev.session_id).is_none() {
        return;
    }
    let process = rec.msg.get("process").cloned().unwrap_or(Value::Null);
    conn.send(&Message::notification(method::MUX_PROCESS_UPDATE, json!({"process": process})));
}

#[cfg(test)]
mod process_page_params_tests {
    use super::*;

    #[test]
    fn a_cursor_requires_a_positive_limited_session_page() {
        assert_eq!(process_page_params(&json!({})).unwrap(), None);
        assert_eq!(process_page_params(&json!({"limit": 1})).unwrap(), Some((1, None)));
        assert_eq!(
            process_page_params(&json!({"limit": 3_000, "cursor": "s/task"})).unwrap(),
            Some((1_000, Some("s/task")))
        );
        for bad in [
            json!({"cursor": "s/task"}),
            json!({"limit": 0}),
            json!({"limit": -1}),
            json!({"limit": "3"}),
            json!({"limit": true}),
            json!({"limit": 1, "cursor": ""}),
            json!({"limit": 1, "cursor": 13}),
        ] {
            assert!(process_page_params(&bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn calls_are_one_to_a_thousand_tool_call_ids() {
        assert_eq!(calls_param(&json!({})).unwrap(), None);
        assert_eq!(
            calls_param(&json!({"calls": ["a", "b"]})).unwrap(),
            Some(vec!["a".into(), "b".into()])
        );
        let many: Vec<String> = (0..1_001).map(|n| format!("call-{n}")).collect();
        for bad in [
            json!({"calls": []}),
            json!({"calls": [""]}),
            json!({"calls": [3]}),
            json!({"calls": "a"}),
            json!({"calls": many}),
        ] {
            assert!(calls_param(&bad).is_err(), "{bad}");
        }
    }
}
