//! The session list replies (`_acpmux/sessions`, `_acpmux/watch`, ACP's `session/list`)
//! through the hub's list guard (`hub/list_guard.rs`): a connection waits out its list
//! pace, then reads the shared snapshot. The result goes back to the request task already
//! serialized ([`scope`]), which sends it as the reply line without a copy of the list as
//! a JSON tree. A peer reads summaries masked (`peer_text.rs`): the masked text is made
//! once per build too. `remote_guard::after` changes nothing in a list reply.

use super::{Conn, Hub, Message, RpcError, Value, json, peer_text};
use std::cell::RefCell;
use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::Ordering;

tokio::task_local! {
    /// A request's result already serialized, for its request task to send as it is.
    static SERIALIZED: RefCell<Option<Arc<String>>>;
}

/// Runs a request where a list reply may hand back its serialized result.
pub(super) async fn scope<F: Future>(request: F) -> (F::Output, Option<Arc<String>>) {
    let run = async move { (request.await, SERIALIZED.with(|s| s.borrow_mut().take())) };
    SERIALIZED.scope(RefCell::new(None), run).await
}

/// `result` as the reply: handed to the request task, or parsed back outside its scope.
fn serialized(result: Arc<String>) -> Value {
    match SERIALIZED.try_with(|s| *s.borrow_mut() = Some(result.clone())) {
        Ok(()) => Value::Null,
        Err(_) => serde_json::from_str(&result).unwrap_or(Value::Null),
    }
}

/// `limit`, `cursor`, `peer` and `status` all absent, null or empty: the whole list.
fn whole(params: &Value) -> bool {
    let unset = |k: &str| params.get(k).is_none_or(|v| v.is_null() || v.as_str() == Some(""));
    ["limit", "cursor", "peer", "status"].into_iter().all(unset)
}

/// Waits out this connection's pace, then the shared list.
async fn list(hub: &Hub, conn: &Conn, limit: Option<u64>) -> Arc<crate::hub::list_guard::Snapshot> {
    let guard = &hub.list_guard;
    let wait = guard.reserve(&conn.list_pace, guard.share(limit));
    if !wait.is_zero() {
        tokio::time::sleep(wait).await;
    }
    guard.snapshot(hub).await
}

/// `_acpmux/sessions`: the whole list shared, or a page or filter cut from it.
pub(super) async fn sessions(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    if !whole(params) {
        let list = list(hub, conn, params.get("limit").and_then(Value::as_u64)).await;
        let page = list.page(params)?;
        let page = if conn.raw_text {
            page
        } else {
            masked(serde_json::from_str(&page).unwrap_or_default())
        };
        return Ok(serialized(Arc::new(page)));
    }
    let list = list(hub, conn, None).await;
    Ok(serialized(if conn.raw_text {
        list.whole.clone()
    } else {
        list.made("masked", |list| masked(json!({"sessions": list.values()})))
    }))
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
    let list = list(hub, conn, None).await;
    Ok(serialized(list.made(if raw { "acp" } else { "acp masked" }, |list| {
        let sessions: Vec<Value> = list.values().iter().map(acp_row).collect();
        let result = json!({"sessions": sessions});
        if raw { result.to_string() } else { masked(result) }
    })))
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
        let text = Arc::new(result.to_string());
        assert_eq!(serialized(text.clone()), result);
        let (out, sent) = scope(async { serialized(text.clone()) }).await;
        assert_eq!((out, sent), (Value::Null, Some(text)));
        assert!(whole(&json!({"limit": null, "peer": "", "enabled": true})));
        for p in [json!({"limit": 5}), json!({"cursor": "k1.2"}), json!({"status": 3})] {
            assert!(!whole(&p), "{p}");
        }
    }
}
