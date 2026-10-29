//! The session list replies (`_acpmux/sessions`, `_acpmux/watch`, ACP's `session/list`)
//! through the hub's list guard (`hub/list_guard.rs`): a connection waits out its list
//! pace, then reads the shared snapshot. The reply is queued here, already serialized,
//! without a copy of the list as a JSON tree, and only if no `session_changed` notice
//! was queued on the connection since the list was read (checked under its outbound
//! lock): such a list may lack the change the notice told, so it is read once more. A
//! list sent after a notice anyway (stale again, or one that waited for room in a full
//! queue) is followed by `_acpmux/lagged {watch: true}`, to read again. A peer reads
//! summaries masked (`peer_text.rs`), made once per build too. `remote_guard::after`
//! changes nothing in a list reply.

use super::{Conn, Hub, Message, RpcError, Value, json, peer_text};
use crate::hub::list_guard::Snapshot;
use std::cell::RefCell;
use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::Ordering;

/// Lists read again for a reply whose list a notice overtook, before it goes with a lag.
const REBUILDS: usize = 1;

tokio::task_local! {
    /// The request's id, and whether its reply was sent here: then whether it went whole.
    static REPLY: RefCell<(Value, Option<bool>)>;
}

/// Runs request `id`, whose list reply may be sent here: then the option is set, true if the
/// reply went whole (not as its too-large error).
pub(super) async fn scope<F: Future>(id: Value, request: F) -> (F::Output, Option<bool>) {
    let run = async move { (request.await, REPLY.with(|r| r.borrow().1)) };
    REPLY.scope(RefCell::new((id, None)), run).await
}

/// `limit`, `cursor`, `peer` and `status` all absent, null or empty: the whole list.
fn whole(params: &Value) -> bool {
    let unset = |k: &str| params.get(k).is_none_or(|v| v.is_null() || v.as_str() == Some(""));
    ["limit", "cursor", "peer", "status"].into_iter().all(unset)
}

/// Waits out this connection's pace, then sends `make` of the shared list as the reply,
/// once it is current; outside a request task, returns it.
async fn reply(
    hub: &Hub,
    conn: &Conn,
    limit: Option<u64>,
    make: impl Fn(&Snapshot) -> Result<Arc<String>, RpcError>,
) -> Result<Value, RpcError> {
    let guard = &hub.list_guard;
    let notices = || conn.notices.load(Ordering::SeqCst);
    // Read before each list is: a notice counted after it may tell a change the list lacks.
    let mut seen = notices();
    // The first list: built before it is paced, so the pace is the build's.
    let mut first = if guard.window().is_zero() { Some(guard.snapshot(hub).await) } else { None };
    let wait = guard.reserve(&conn.list_pace, guard.share(limit)).map_err(busy)?;
    tokio::time::sleep(wait).await;
    for reads in 0..=REBUILDS {
        let list = match first.take() {
            Some(list) => list,
            None => {
                seen = notices();
                guard.snapshot(hub).await
            }
        };
        let text = make(&list)?;
        let Ok(id) = REPLY.try_with(|r| r.borrow().0.clone()) else {
            return Ok(serde_json::from_str(&text).unwrap_or(Value::Null));
        };
        if let Some(whole) = conn.send_serialized(&id, &text, seen, reads == REBUILDS) {
            REPLY.with(|r| r.borrow_mut().1 = Some(whole));
            break;
        }
    }
    Ok(Value::Null)
}

fn busy(wait: std::time::Duration) -> RpcError {
    let ms = u64::try_from(wait.as_millis()).unwrap_or(u64::MAX);
    RpcError::new(-32000, format!("session lists are paced: try again in {ms} ms"))
        .with_data(json!({"reason": "list.paced", "retryable": true, "retryAfterMs": ms}))
}

/// `_acpmux/sessions`: the whole list shared, or a page or filter cut from it.
pub(super) async fn sessions(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let raw = conn.raw_text;
    if !whole(params) {
        return reply(hub, conn, params.get("limit").and_then(Value::as_u64), |list| {
            let page = list.page(params)?;
            Ok(Arc::new(if raw {
                page
            } else {
                masked(serde_json::from_str(&page).unwrap_or_default())
            }))
        })
        .await;
    }
    reply(hub, conn, None, |list| {
        Ok(if raw {
            list.whole.clone()
        } else {
            list.made("masked", |list| masked(json!({"sessions": list.values()})))
        })
    })
    .await
}

/// `_acpmux/watch`: turns the watch on before it reads the list, so no change is missed.
pub(super) async fn watch(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    crate::hub::session_pages::refuse_watch_filters(params)?;
    let on = params.get("enabled").and_then(Value::as_bool).unwrap_or(true);
    conn.watch_all.store(on, Ordering::SeqCst);
    sessions(hub, conn, params).await
}

/// ACP's `session/list`: every session, its summary under `_meta.acpmux`.
pub(super) async fn acp_list(hub: &Hub, conn: &Conn) -> Result<Value, RpcError> {
    let raw = conn.raw_text;
    reply(hub, conn, None, |list| {
        Ok(list.made(if raw { "acp" } else { "acp masked" }, |list| {
            let sessions: Vec<Value> = list.values().iter().map(acp_row).collect();
            let result = json!({"sessions": sessions});
            if raw { result.to_string() } else { masked(result) }
        }))
    })
    .await
}

fn acp_row(s: &Value) -> Value {
    let text = |k: &str| s.get(k).and_then(Value::as_str).map(str::to_owned);
    json!({
        "sessionId": s.get("sessionId").cloned().unwrap_or(Value::Null),
        "cwd": s.get("cwd").cloned().unwrap_or(Value::Null),
        "title": text("title").or_else(|| text("name")),
        "updatedAt": super::clock_text::iso(s.get("updatedAt").and_then(Value::as_u64).unwrap_or(0)),
        "_meta": {"acpmux": s},
    })
}

/// `result` as a peer reads it (`peer_text.rs`), serialized.
fn masked(result: Value) -> String {
    let reply = Message::ok(Value::Null, result);
    match peer_text::masked(&reply).unwrap_or(reply) {
        Message::Response { result: Some(result), .. } => result.to_string(),
        _ => "null".to_owned(),
    }
}

/// The reply line for `id` whose result is `result`, serialized: the bytes
/// `Message::ok(id, result).to_line()` writes.
pub(super) fn reply_line(id: &Value, result: &str) -> String {
    let id = id.to_string();
    let mut line = String::with_capacity(id.len() + result.len() + 32);
    for part in ["{\"id\":", &id, ",\"jsonrpc\":\"2.0\",\"result\":", result, "}\n"] {
        line.push_str(part);
    }
    line
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_serialized_reply_is_the_line_message_writes_and_parsed_back_outside_a_request() {
        let result = json!({"sessions": [{"sessionId": "a", "z": [1, "x\n"]}]});
        for id in [json!(7), json!("req-1")] {
            let line = Message::ok(id.clone(), result.clone()).to_line();
            assert_eq!(reply_line(&id, &result.to_string()), line);
        }
        assert!(whole(&json!({"limit": null, "peer": "", "enabled": true})));
        for p in [json!({"limit": 5}), json!({"cursor": "k1.2"}), json!({"status": 3})] {
            assert!(!whole(&p), "{p}");
        }
    }
}
