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
use crate::hub::list_guard::{RequestStage, Snapshot};
use crate::hub::row_log;
use cmux_json::JsonSet as _;
use std::cell::RefCell;
use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::Ordering;

/// Lists read again for a reply whose list a notice overtook, before it goes with a lag.
const REBUILDS: usize = 1;

/// A list reply's request: its id, its list method ([`list_method`]), its claim on its
/// connection's in-flight entry (`in_flight.rs`), and whether its reply was sent here: then
/// whether it went whole.
struct Reply {
    id: Value,
    method: Option<&'static str>,
    claim: Option<super::in_flight::Claim>,
    sent: Option<bool>,
}

tokio::task_local! {
    static REPLY: RefCell<Reply>;
}

/// Runs request `id` (of `method`), whose list reply may be sent here: then the option is set,
/// true if the reply went whole (not as its too-large error), false if it was not sent because a
/// cancel answered the request first (its `claim` lost). The request's future is made on the
/// heap (`heap_future.rs`): this future, the task's, and their poll frames hold only its pointer.
pub(super) async fn scope<F: Future>(
    id: Value,
    method: &str,
    claim: Option<super::in_flight::Claim>,
    request: impl FnOnce() -> F,
) -> (F::Output, Option<bool>) {
    let request = crate::heap_future::heap(request);
    let run = async move { (request.await, REPLY.with(|r| r.borrow().sent)) };
    let reply = Reply { id, method: list_method(method), claim, sent: None };
    REPLY.scope(RefCell::new(reply), run).await
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

fn excludes_closed(params: &Value) -> bool {
    params
        .get("excludeStatus")
        .and_then(Value::as_array)
        .is_some_and(|values| values.iter().any(|value| value.as_str() == Some("closed")))
}

/// Waits out this connection's pace, then sends `make` of the shared list as the reply,
/// once it is current; outside a request task, returns it.
async fn reply(
    hub: &Hub,
    conn: &Conn,
    share: f64,
    live_only: bool,
    cursor: Option<Cursor>,
    make: impl Fn(&Snapshot) -> Result<Arc<String>, RpcError>,
) -> Result<Value, RpcError> {
    let guard = &hub.list_guard;
    let notices = || conn.notices.load(Ordering::SeqCst);
    // Read before each list is: a notice counted after it may tell a change the list lacks.
    let mut seen = notices();
    // The first list: built before it is paced, so the pace is the build's.
    let mut first = if guard.window().is_zero() {
        Some(if live_only { guard.snapshot_live(hub).await } else { guard.snapshot(hub).await })
    } else {
        None
    };
    let wait = guard.reserve(&conn.list_pace, share).map_err(busy)?;
    tokio::time::sleep(wait).await;
    for reads in 0..=REBUILDS {
        let list = match first.take() {
            Some(list) => list,
            None => {
                seen = notices();
                if live_only { guard.snapshot_live(hub).await } else { guard.snapshot(hub).await }
            }
        };
        let text = with_watch_cursor(hub, make(&list)?, cursor);
        if let Some(done) = send_list(hub, conn, text, seen, reads == REBUILDS).await {
            return Ok(done);
        }
    }
    Ok(Value::Null)
}

/// `text` with the list position a watch's list is current to: read before the list was, so every
/// change after it reaches the watcher as a notice (`row_log.rs`).
fn with_watch_cursor(hub: &Hub, text: Arc<String>, cursor: Option<Cursor>) -> Arc<String> {
    match cursor {
        Some(Cursor { head, reset }) => {
            Arc::new(row_log::with_cursor(&text, head, hub.list_cursor().1, reset))
        }
        None => text,
    }
}

/// Sends `text` as this request's list reply, unless a `session_changed` notice was queued on the
/// connection since `seen` (its count before the list was read) and this is not the `last` read:
/// then `None`, and the list is read again. Sent, the request's result is null (its reply is
/// queued already); outside a request task, the result is `text` parsed.
async fn send_list(
    hub: &Hub,
    conn: &Conn,
    text: Arc<String>,
    seen: u64,
    last: bool,
) -> Option<Value> {
    let Ok((id, method, claim)) = REPLY.try_with(|r| {
        let r = r.borrow();
        (r.id.clone(), r.method, r.claim.clone())
    }) else {
        return Some(serde_json::from_str(&text).unwrap_or(Value::Null));
    };
    hub.request_hold(RequestStage::ListBuilt, method.unwrap_or_default(), &id).await;
    let whole = conn.send_serialized(&id, method, claim.as_ref(), text, seen, last)?;
    REPLY.with(|r| r.borrow_mut().sent = Some(whole));
    hub.request_hold(RequestStage::ListQueued, method.unwrap_or_default(), &id).await;
    Some(Value::Null)
}

/// A page by `limit`, or a census in its own order (`orderBy`): its own rows, picked before any is
/// built (`Hub::session_page_rows`), at most `limit` of them and at most [`LIST_PAGE_BYTES`]
/// (`list_guard::cut_page`, as the whole list's page cuts them). It reads no list snapshot, and
/// the list pace charges it its rows' share of the list (`ListGuard::share_rows`): a page of five
/// costs next to nothing, one of every row about a list. A page whose list a notice overtook is
/// read again, as a list is ([`send_list`]).
async fn page(
    hub: &Hub,
    conn: &Conn,
    params: &Value,
    tools: bool,
    cursor: Option<Cursor>,
) -> Result<Value, RpcError> {
    use crate::hub::list_guard::{cut_page, serialize_in_order};
    let raw = conn.raw_text;
    let guard = &hub.list_guard;
    let limit = params.get("limit").and_then(Value::as_u64);
    let wait = guard.reserve(&conn.list_pace, guard.share_rows(limit)).map_err(busy)?;
    tokio::time::sleep(wait).await;
    for reads in 0..=REBUILDS {
        // Read before the rows are: a notice counted after it may tell a change they lack.
        let seen = conn.notices.load(Ordering::SeqCst);
        let (rows, next) = hub.session_page_rows(params, tools)?;
        let (text, spans, keys) = serialize_in_order(&rows);
        drop(rows);
        let text = within_limit(raw, LIST_PAGE_BYTES, |budget| {
            Ok(cut_page((text.as_str(), spans.as_slice()), &keys, next.clone(), params, budget))
        })?;
        let text = with_watch_cursor(hub, text, cursor);
        if let Some(done) = send_list(hub, conn, text, seen, reads == REBUILDS).await {
            return Ok(done);
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

/// `_acpmux/sessions`: the whole list shared, or a filter cut from it, or a page of its own rows.
/// One with no `limit` goes whole, newest first, as before, when it fits in [`LIST_PAGE_BYTES`]
/// as the client reads it; one larger goes in pages, each with the `nextCursor` of the rest
/// (`Snapshot::bounded`), rather than as one message too large to send. A page by `limit`, or a
/// census in its own order (`orderBy`), holds at most `limit` rows and at most
/// [`LIST_PAGE_BYTES`], and builds only those rows ([`page`]): no reply here is too large to
/// send, and none costs every chat for a few.
pub(super) async fn sessions(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    list(hub, conn, params, None).await
}

/// The list position a watch's list is current to, and whether it answers a cursor the log could
/// not follow (`reset`: the client drops what it held).
#[derive(Clone, Copy)]
struct Cursor {
    head: u64,
    reset: bool,
}

/// [`sessions`], its reply current to list position `cursor` when a watch asked for it.
async fn list(
    hub: &Hub,
    conn: &Conn,
    params: &Value,
    cursor: Option<Cursor>,
) -> Result<Value, RpcError> {
    let raw = conn.raw_text;
    if crate::hub::session_pages::bool_filter(params, "pendingOnly")? {
        return pending(hub, raw, params);
    }
    let unset = |k: &str| params.get(k).is_none_or(|v| v.is_null() || v.as_str() == Some(""));
    let by_bytes = unset("limit") && unset("orderBy");
    let tools = with_tools(params)?;
    if !by_bytes {
        return page(hub, conn, params, tools, cursor).await;
    }
    let (most, guard) = (LIST_PAGE_BYTES, &hub.list_guard);
    // A byte page costs its bytes' share of the list: a whole list read in pages costs about one
    // list in all, not one per page.
    if tools || !whole(params) {
        return reply(hub, conn, guard.share_bytes(most), excludes_closed(params), cursor, |list| {
            within_limit(raw, most, |budget| list.bounded(hub, params, tools, budget))
        })
        .await;
    }
    reply(hub, conn, guard.share_bytes(most), excludes_closed(params), cursor, |list| {
        // The cached whole list, as the client reads it (masked for a peer, which may lengthen
        // it), when that fits in one message; else its pages.
        if list.whole.len() <= most {
            let whole = if raw {
                list.whole.clone()
            } else {
                list.made("masked", |list| masked(json!({"sessions": list.values()})))
            };
            if whole.len() <= most {
                return Ok(whole);
            }
        }
        within_limit(raw, most, |budget| list.bounded(hub, params, false, budget))
    })
    .await
}

/// `_acpmux/sessions {pendingOnly: true}`: the sessions with a pending ask
/// (`Hub::pending_session_summaries`), never through the list guard: it summarizes only those
/// chats, so it costs no list build and waits on no list pace. It takes no other filter, and its
/// reply is never paged: rows that would pass the message budget are left out, newest kept.
fn pending(hub: &Hub, raw: bool, params: &Value) -> Result<Value, RpcError> {
    const OTHERS: [&str; 7] =
        ["limit", "peer", "status", "localOnly", "excludeStatus", "orderBy", "withTools"];
    if let Some(name) = OTHERS.into_iter().find(|k| params.get(*k).is_some_and(|v| !v.is_null())) {
        return Err(RpcError::invalid_params(format!("pendingOnly takes no {name}")));
    }
    let cursor = match params.get("cursor").filter(|v| !v.is_null()) {
        None => None,
        Some(Value::String(cursor)) => Some(cursor.as_str()),
        Some(_) => return Err(RpcError::invalid_params("cursor must be a string")),
    };
    let rows = hub.pending_session_summaries();
    // Pages of at most `LIST_PAGE_BYTES`, as every list on the connection is, with the
    // `nextCursor` of the rest: the chats with an open ask are few, but each holds its summary,
    // and before this one reply held them all up to the message limit. The pages go in
    // `byte_page`'s stable order, so an ask answered while a client pages moves no other row.
    let text = within_limit(raw, LIST_PAGE_BYTES, |budget| {
        let (page, next) = crate::hub::session_pages::byte_page(
            &rows,
            cursor,
            budget,
            |at| rows.get(at).map(Value::to_string).unwrap_or_default(),
            String::len,
        )?;
        // The last page, the only one most reads see, has no `nextCursor`, as before.
        let next =
            next.map(|c| format!(",\"nextCursor\":{}", Value::String(c))).unwrap_or_default();
        Ok(format!("{{\"sessions\":[{}]{next}}}", page.join(",")))
    })?;
    let mut reply: Value =
        serde_json::from_str(&text).map_err(|error| RpcError::internal(error.to_string()))?;
    if let Some(rows) = reply.get_mut("sessions").and_then(Value::as_array_mut) {
        crate::hub::session_pages::sort_session_summaries(rows);
    }
    Ok(reply)
}

/// `_acpmux/watch`: turns the watch on before it reads the list, so no change is missed.
/// A connection served as a peer (it proved this launch's peer token) reads only this
/// daemon's own sessions: the link drops every row mirrored from a peer (`peer.rs`
/// `watch_sessions`), and with them one lane VM's list was 17 MB with tools on 2026-10-30, past
/// the message limit, so no peer's handshake there finished. Built from the own sessions
/// alone, never from the whole list, once per snapshot.
pub(super) async fn watch(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    crate::hub::session_pages::refuse_watch_filters(params)?;
    let on = params.get("enabled").and_then(Value::as_bool).unwrap_or(true);
    let tools = with_tools(params)?;
    conn.watch_tools.store(on && tools, Ordering::SeqCst);
    conn.watch_all.store(on, Ordering::SeqCst);
    // The position the reply is current to, read once the watch is on: every change after it is
    // a notice on this connection (`row_log.rs`).
    let head = hub.list_cursor().0;
    let own_only = conn.origin == super::Origin::Peer;
    if on && let Some(after) = follow_cursor(hub, params)? {
        // Rows changed after the client's cursor, never the list: its cost is the changes.
        if let Some(done) = follow(hub, conn, after, own_only, tools).await {
            return done;
        }
        // The log cannot follow it (another run, or older than its oldest removal): the list, as
        // on a first watch, marked `reset`.
        return watch_list(hub, conn, params, tools, Cursor { head, reset: true }).await;
    }
    watch_list(hub, conn, params, tools, Cursor { head, reset: false }).await
}

/// The follow from `after`, sent as a list reply is: never after a `session_changed` it may lack
/// (its rows are built when read; a change stamped meanwhile may go out as a notice before it),
/// so it is read once more, then sent followed by a lag ([`reply`]). None: the log cannot follow
/// `after`.
async fn follow(
    hub: &Hub,
    conn: &Conn,
    after: u64,
    own_only: bool,
    tools: bool,
) -> Option<Result<Value, RpcError>> {
    let raw = conn.raw_text;
    for reads in 0..=REBUILDS {
        let seen = conn.notices.load(Ordering::SeqCst);
        let text = within_limit(raw, LIST_PAGE_BYTES, |budget| {
            hub.list_follow(after, own_only, tools, budget)
                .map(|follow| follow.text)
                .ok_or_else(|| RpcError::internal("reset"))
        })
        .ok()?;
        let Ok((id, method, claim)) = REPLY.try_with(|r| {
            let r = r.borrow();
            (r.id.clone(), r.method, r.claim.clone())
        }) else {
            return Some(
                serde_json::from_str(&text).map_err(|e| RpcError::internal(e.to_string())),
            );
        };
        let last = reads == REBUILDS;
        if let Some(whole) = conn.send_serialized(&id, method, claim.as_ref(), text, seen, last) {
            REPLY.with(|r| r.borrow_mut().sent = Some(whole));
            break;
        }
    }
    Some(Ok(Value::Null))
}

/// `afterSeq` of a watch: a cursor of another run (its `listEpoch` is not this run's) is read as
/// one past every position, which the log answers `reset`.
fn follow_cursor(hub: &Hub, params: &Value) -> Result<Option<u64>, RpcError> {
    let after = match params.get("afterSeq") {
        None | Some(Value::Null) => return Ok(None),
        Some(value) => value
            .as_u64()
            .ok_or_else(|| RpcError::invalid_params("afterSeq must be a non-negative integer"))?,
    };
    let epoch = params.get("listEpoch").and_then(Value::as_str);
    // Past any head: the follow answers reset.
    Ok(Some(if epoch == Some(hub.list_cursor().1) { after } else { u64::MAX }))
}

/// The watch's list (its first page, or whole), current to list position `head`.
async fn watch_list(
    hub: &Hub,
    conn: &Conn,
    params: &Value,
    tools: bool,
    cursor: Cursor,
) -> Result<Value, RpcError> {
    if conn.origin == super::Origin::Peer && whole(params) {
        let raw = conn.raw_text;
        let most = LIST_PAGE_BYTES;
        return reply(hub, conn, hub.list_guard.share_bytes(most), false, Some(cursor), |list| {
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
            if own.len() <= most {
                return Ok(own);
            }
            // Too large for one of this link's pages: the list's pages, whose cursor the link
            // follows (`peer.rs` `watch_pages`); it drops the rows mirrored from its peers on
            // each page as on a whole list (`watch_sessions`).
            within_limit(raw, most, |budget| list.bounded(hub, params, tools, budget))
        })
        .await;
    }
    list(hub, conn, params, Some(cursor)).await
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
    reply(
        hub,
        conn,
        hub.list_guard.share_bytes(LIST_PAGE_BYTES),
        excludes_closed(params),
        None,
        |list| {
            let full = list.full_rows(hub);
            // An ACP row holds its summary whole, so rows already over the budget are no whole
            // reply: that one is not made only to be dropped.
            if cursor.is_none() && full.bytes() <= LIST_PAGE_BYTES {
                let whole = list.made(if raw { "acp" } else { "acp masked" }, |list| {
                    let full: Value =
                        serde_json::from_str(&list.full_whole(hub)).unwrap_or_default();
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
            within_limit(raw, LIST_PAGE_BYTES, page)
        },
    )
    .await
}

/// The page `page` cuts to `most` bytes ([`LIST_PAGE_BYTES`]), as the client reads it: a peer reads
/// it masked (`peer_text.rs`), which may make it longer than the budget it was cut to; then it
/// is cut again, smaller. A raw page takes the same check.
fn within_limit(
    raw: bool,
    most: usize,
    page: impl Fn(usize) -> Result<String, RpcError>,
) -> Result<Arc<String>, RpcError> {
    let mut budget = most;
    loop {
        let text = page(budget)?;
        let text = if raw { text } else { masked(serde_json::from_str(&text).unwrap_or_default()) };
        if text.len() <= most || budget < MIN_PAGE_BYTES {
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

/// The most a session list result holds (`session/list`, `_acpmux/sessions`, `_acpmux/watch`), on
/// every connection: [`REPLY_PAGE_BYTES`](crate::rpc::REPLY_PAGE_BYTES) less room for the reply
/// line's frame. Past it a whole list goes in pages with the `nextCursor` of the rest, which every
/// client follows (the pane's `SessionPager.whole`, the app's `AgentTurnStateFeed` pages, the
/// phone's `AcpmuxConnection.wholeList`, `Client::whole_list`, `peer.rs` `watch_pages`). Before,
/// the app's own connections read up to 30 MB in one reply: a Mac sent a 31 MB watch list near
/// the 32 MB frame cap 9,208 times in 11 days, and every small reply on that connection, a
/// prompt's acknowledgement too, waited behind it (2026-11-11). Web and peer connections had
/// 4 MB pages since 2026-11-06 (one Mac's 24.8 MB list to its phone host, read about every
/// minute). Detector: `reply_size_tests.rs`.
pub(super) const LIST_PAGE_BYTES: usize = crate::rpc::REPLY_PAGE_BYTES - (16 << 10);

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
/// `Message::ok(id, result).to_line()` writes. The daemon makes it with [`reply_line_in`].
#[cfg(test)]
pub(super) fn reply_line(id: &Value, result: &str) -> String {
    let id = id.to_string();
    let mut line = String::with_capacity(id.len() + result.len() + 32);
    for part in ["{\"id\":", &id, ",\"jsonrpc\":\"2.0\",\"result\":", result, "}\n"] {
        line.push_str(part);
    }
    line
}

/// [`reply_line`], made in `result`'s own buffer when no one else holds it and its spare
/// capacity holds the frame (a page made by `list_guard::page_text`): no second buffer of the
/// page's size. A shared result (the cached whole list) is copied as before.
pub(super) fn reply_line_in(id: &Value, result: Arc<String>) -> String {
    let id = id.to_string();
    let head = ["{\"id\":", &id, ",\"jsonrpc\":\"2.0\",\"result\":"].concat();
    match Arc::try_unwrap(result) {
        Ok(mut text) if text.capacity() - text.len() >= head.len() + 2 => {
            text.insert_str(0, &head);
            text.push_str("}\n");
            text
        }
        Ok(text) => reply_line_parts(&head, &text),
        Err(shared) => reply_line_parts(&head, &shared),
    }
}

fn reply_line_parts(head: &str, result: &str) -> String {
    let mut line = String::with_capacity(head.len() + result.len() + 2);
    for part in [head, result, "}\n"] {
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

    #[test]
    fn a_page_becomes_its_reply_line_in_its_own_buffer() {
        use crate::hub::list_guard::page_text;
        let rows = [r#"{"sessionId":"a"}"#, r#"{"sessionId":"b","t":"x\n"}"#];
        for next in [None, Some(Value::String("h1.2".into()).to_string())] {
            let text = page_text(next.clone(), &rows);
            let parsed: Value = serde_json::from_str(&text).unwrap();
            assert_eq!(parsed["sessions"][1]["sessionId"], "b");
            assert_eq!(parsed.get("nextCursor").is_some(), next.is_some());
            for id in [json!(7), json!("req-1")] {
                let page = Arc::new(page_text(next.clone(), &rows));
                let (at, room) = (page.as_ptr(), page.capacity());
                let line = reply_line_in(&id, page);
                assert_eq!(line, reply_line(&id, &text));
                assert_eq!((line.as_ptr(), line.capacity()), (at, room), "made in place");
                // A shared result (the cached whole list) is copied and stays as it was.
                let shared = Arc::new(text.clone());
                assert_eq!(reply_line_in(&id, shared.clone()), reply_line(&id, &text));
                assert_eq!(*shared, text);
            }
        }
        // An id too long for the spare room still gives the same line.
        let id = json!("i".repeat(4096));
        assert_eq!(
            reply_line_in(&id, Arc::new(page_text(None, &rows))),
            reply_line(&id, &page_text(None, &rows))
        );
    }
}
