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
use cmux_json::JsonSet as _;
use std::cell::RefCell;
use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::Ordering;

/// Lists read again for a reply whose list a notice overtook, before it goes with a lag.
const REBUILDS: usize = 1;

tokio::task_local! {
    /// The request's id and list method ([`list_method`]), and whether its reply was sent here:
    /// then whether it went whole.
    static REPLY: RefCell<(Value, Option<&'static str>, Option<bool>)>;
}

/// Runs request `id` (of `method`), whose list reply may be sent here: then the option is set,
/// true if the reply went whole (not as its too-large error).
pub(super) async fn scope<F: Future>(
    id: Value,
    method: &str,
    request: F,
) -> (F::Output, Option<bool>) {
    let run = async move { (request.await, REPLY.with(|r| r.borrow().2)) };
    REPLY.scope(RefCell::new((id, list_method(method), None)), run).await
}

/// `method` as the name a list reply sent here goes by in the size watch (`wire_size.rs`):
/// a constant, so a request costs no copy of its method.
fn list_method(method: &str) -> Option<&'static str> {
    use crate::rpc::method::{MUX_SESSIONS, MUX_WATCH, SESSION_LIST};
    [MUX_SESSIONS, MUX_WATCH, SESSION_LIST].into_iter().find(|known| *known == method)
}

/// List filters absent, null or empty: the whole list.
fn whole(params: &Value) -> bool {
    let unset = |k: &str| params.get(k).is_none_or(|v| v.is_null() || v.as_str() == Some(""));
    ["limit", "cursor", "peer", "status", "localOnly", "excludeStatus", "orderBy"]
        .into_iter()
        .all(unset)
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
        let Ok((id, method)) = REPLY.try_with(|r| {
            let r = r.borrow();
            (r.0.clone(), r.1)
        }) else {
            return Ok(serde_json::from_str(&text).unwrap_or(Value::Null));
        };
        if let Some(whole) = conn.send_serialized(&id, method, &text, seen, reads == REBUILDS) {
            REPLY.with(|r| r.borrow_mut().2 = Some(whole));
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

fn with_tools(params: &Value) -> Result<bool, RpcError> {
    match params.get("withTools") {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(value)) => Ok(*value),
        Some(_) => Err(RpcError::invalid_params("withTools must be a boolean")),
    }
}

/// `_acpmux/sessions`: the whole list shared, or a page or filter cut from it. One with no
/// `limit` goes whole, newest first, as before, when it fits in [`LIST_PAGE_BYTES`] as the
/// client reads it; one larger goes in pages, each with the `nextCursor` of the rest
/// (`Snapshot::bounded`), rather than as one message too large to send. A page by `limit`, or a
/// census in its own order (`orderBy`), holds at most `limit` rows and at most
/// [`LIST_PAGE_BYTES`] (`Snapshot::page`): no reply here is too large to send.
pub(super) async fn sessions(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let raw = conn.raw_text;
    let limit = params.get("limit").and_then(Value::as_u64);
    let unset = |k: &str| params.get(k).is_none_or(|v| v.is_null() || v.as_str() == Some(""));
    let by_bytes = unset("limit") && unset("orderBy");
    let tools = with_tools(params)?;
    if tools || !whole(params) {
        return reply(hub, conn, limit, |list| {
            if by_bytes {
                return within_limit(raw, |budget| list.bounded(hub, params, tools, budget));
            }
            let full = tools.then(|| list.full_rows(hub));
            within_limit(raw, |budget| list.page(full.as_deref(), params, budget))
        })
        .await;
    }
    reply(hub, conn, None, |list| {
        // The cached whole list, as the client reads it (masked for a peer, which may lengthen
        // it), when that fits in one message; else its pages.
        if list.whole.len() <= LIST_PAGE_BYTES {
            let whole = if raw {
                list.whole.clone()
            } else {
                list.made("masked", |list| masked(json!({"sessions": list.values()})))
            };
            if whole.len() <= LIST_PAGE_BYTES {
                return Ok(whole);
            }
        }
        within_limit(raw, |budget| list.bounded(hub, params, false, budget))
    })
    .await
}

/// `_acpmux/watch`: turns the watch on before it reads the list, so no change is missed.
/// A connection served as a peer (it proved this launch's peer token) reads only this
/// daemon's own sessions: the link drops every row mirrored from a peer (`peer.rs`
/// `watch_sessions`), and with them big-red's list was 17 MB with tools on 2026-10-30, past
/// the message limit, so no peer's handshake there finished. Built from the own sessions
/// alone, never from the whole list, once per snapshot.
pub(super) async fn watch(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    crate::hub::session_pages::refuse_watch_filters(params)?;
    let on = params.get("enabled").and_then(Value::as_bool).unwrap_or(true);
    let tools = with_tools(params)?;
    conn.watch_tools.store(on && tools, Ordering::SeqCst);
    conn.watch_all.store(on, Ordering::SeqCst);
    if conn.origin == super::Origin::Peer && whole(params) {
        let raw = conn.raw_text;
        // What the link holds of this list already: it reads only what changed
        // (`watch_delta.rs`).
        let known = match params.get("known") {
            None | Some(Value::Null) => None,
            Some(Value::Object(known)) => Some(known),
            Some(_) => return Err(RpcError::invalid_params("known must be an object")),
        };
        return reply(hub, conn, None, |list| {
            let name = match (tools, raw) {
                (true, true) => "own tools",
                (true, false) => "own tools masked",
                (false, true) => "own",
                (false, false) => "own masked",
            };
            let own = list.made(name, |_| {
                let own = Snapshot::own_whole(hub, tools);
                if raw { own } else { masked(serde_json::from_str(&own).unwrap_or_default()) }
            });
            Ok(match known.and_then(|known| crate::watch_delta::delta(&own, known)) {
                Some(delta) => Arc::new(delta),
                None => own,
            })
        })
        .await;
    }
    sessions(hub, conn, params).await
}

/// ACP's `session/list`: every session, its summary under `_meta.acpmux`. A list too large
/// for one message (one daemon's was 17 MB with 5241 rows, 2026-10-30) goes in pages of at most
/// [`LIST_PAGE_BYTES`], each with the `nextCursor` ACP's client follows, in an order that
/// updates do not change rather than newest first ([`byte_page`](crate::hub::session_pages::byte_page));
/// one that fits goes whole, newest first, as before.
pub(super) async fn acp_list(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let raw = conn.raw_text;
    let cursor = match params.get("cursor") {
        None | Some(Value::Null) => None,
        Some(Value::String(text)) => Some(text.as_str()),
        Some(_) => return Err(RpcError::invalid_params("cursor must be a string")),
    };
    reply(hub, conn, None, |list| {
        let full = list.full_rows(hub);
        // An ACP row holds its summary whole, so rows already over the budget are no whole
        // reply: that one is not made only to be dropped.
        if cursor.is_none() && full.bytes() <= LIST_PAGE_BYTES {
            let whole = list.made(if raw { "acp" } else { "acp masked" }, |list| {
                let full: Value = serde_json::from_str(&list.full_whole(hub)).unwrap_or_default();
                let sessions: Vec<Value> = full
                    .get("sessions")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .map(acp_row)
                    .collect();
                let result = json!({"sessions": sessions});
                if raw { result.to_string() } else { masked(result) }
            });
            if whole.len() <= LIST_PAGE_BYTES {
                return Ok(whole);
            }
        }
        let page = |budget: usize| -> Result<String, RpcError> {
            let row = |at: usize| acp_row_within(&full.row(at), budget);
            let (sessions, next) =
                crate::hub::session_pages::byte_page(full.keys(), cursor, budget, row, |v| {
                    v.to_string().len()
                })?;
            let mut result = json!({"sessions": sessions});
            if let Some(next) = next {
                result.set("nextCursor", Value::String(next));
            }
            Ok(result.to_string())
        };
        within_limit(raw, page)
    })
    .await
}

/// The page `page` cuts to [`LIST_PAGE_BYTES`], as the client reads it: a peer reads it masked
/// (`peer_text.rs`), which may make it longer than the budget it was cut to; then it is cut
/// again, smaller. A raw page takes the same check.
fn within_limit(
    raw: bool,
    page: impl Fn(usize) -> Result<String, RpcError>,
) -> Result<Arc<String>, RpcError> {
    let mut budget = LIST_PAGE_BYTES;
    loop {
        let text = page(budget)?;
        let text = if raw { text } else { masked(serde_json::from_str(&text).unwrap_or_default()) };
        if text.len() <= LIST_PAGE_BYTES || budget < MIN_PAGE_BYTES {
            return Ok(Arc::new(text));
        }
        budget /= 2;
    }
}

/// The smallest budget a masked page is cut down to before it goes as it is.
const MIN_PAGE_BYTES: usize = 64 << 10;

/// [`acp_row`], or, for a row larger than `budget` alone, a stub that says so with its size, as
/// a record too large for a reply goes (`hub/paging.rs`): a page holds at least one row, and
/// one that large would be refused, page and all. The stub keeps only the row's id and `cwd`,
/// each at most [`STUB_TEXT_BYTES`], and no title: it stays small whatever field was large,
/// and holds no text a peer's reply masks (`peer_text.rs`).
fn acp_row_within(s: &Value, budget: usize) -> Value {
    let row = acp_row(s);
    let bytes = row.to_string().len();
    if bytes <= budget {
        return row;
    }
    let short =
        |k: &str| s.get(k).filter(|v| v.as_str().is_some_and(|t| t.len() <= STUB_TEXT_BYTES));
    let id = short("sessionId").cloned().unwrap_or(Value::Null);
    json!({
        "sessionId": id,
        "cwd": short("cwd").cloned().unwrap_or(Value::Null),
        "title": Value::Null,
        "updatedAt": row.get("updatedAt").cloned().unwrap_or_default(),
        "_meta": {"acpmux": {"sessionId": id, "omitted": {"bytes": bytes, "reason": "too_large"}}},
    })
}

/// The longest id or `cwd` a stub row keeps.
const STUB_TEXT_BYTES: usize = 4 << 10;

/// The most a session list result may hold (`session/list`, `_acpmux/sessions` and
/// `_acpmux/watch`): a megabyte under the message limit, for the reply's own frame and what
/// masking a peer's text may add, the bound of every reply fitted whole (`hub/reply_fit.rs`).
const LIST_PAGE_BYTES: usize = crate::hub::reply_fit::REPLY_BYTES;

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
#[path = "list_reply_tests.rs"]
mod link_tests;

#[cfg(test)]
mod tests {
    use super::*;

    /// A session row larger than a page alone goes as a stub with its size, not as a page
    /// too large to send.
    #[test]
    fn an_acp_row_larger_than_its_page_goes_as_a_stub() {
        let s = json!({"sessionId": "big", "cwd": "/w", "updatedAt": 5,
            "tools": [{"id": "t", "description": "x".repeat(1000)}]});
        assert_eq!(acp_row_within(&s, 1 << 20), acp_row(&s));
        let stub = acp_row_within(&s, 100);
        assert_eq!(stub["sessionId"], "big");
        assert_eq!(stub["_meta"]["acpmux"]["sessionId"], "big");
        assert_eq!(stub["_meta"]["acpmux"]["omitted"]["reason"], "too_large");
        assert!(stub["_meta"]["acpmux"]["omitted"]["bytes"].as_u64().unwrap() > 1000);
        assert!(stub.to_string().len() < 400, "{stub}");
        // A huge title or cwd is not kept either, and the stub has no title to mask.
        let s = json!({"sessionId": "big", "cwd": "/".repeat(1 << 20), "updatedAt": 5,
            "title": "secret ".repeat(1 << 18), "harness": "claude", "lastSeq": 1});
        let stub = acp_row_within(&s, 1 << 16);
        assert_eq!(stub["sessionId"], "big");
        assert!(stub["title"].is_null() && stub["cwd"].is_null(), "{stub}");
        assert!(stub.to_string().len() < 400, "{stub}");
    }

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
