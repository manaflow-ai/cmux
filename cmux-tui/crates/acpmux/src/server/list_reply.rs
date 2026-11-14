//! The session list replies (`_acpmux/sessions`, `_acpmux/watch`, ACP's `session/list`). Each
//! builds only the rows it sends: a page by `limit` its own rows (`page_first.rs`), a read with no
//! `limit` its rows until its page's bytes (`list_guard::bounded`), a follow the rows changed after
//! its cursor (`row_log.rs`). No reply waits for a pace or is refused for its cost, and none is
//! read again because a notice went first: a client keeps each row with its `listSeq` and drops
//! an older one, so order between a reply and the notices around it does not matter. Leo,
//! 2026-11-12: "Delete the pacer, the snapshot variants, watch_delta.rs and Known."
//!
//! The reply is queued here, already serialized, without a copy of the list as a JSON tree. A
//! peer reads summaries masked (`peer_text.rs`). `remote_guard::after` changes nothing in a list
//! reply.

use super::{Conn, Hub, Message, RpcError, Value, json, peer_text};
use crate::hub::list_guard::RequestStage;
use crate::hub::row_log;
use cmux_json::JsonSet as _;
use std::cell::RefCell;
use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::Ordering;

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

/// Sends `text` as this request's list reply. Sent, the request's result is null (its reply is
/// queued already); outside a request task, the result is `text` parsed.
async fn send_list(hub: &Hub, conn: &Conn, text: Arc<String>) -> Result<Value, RpcError> {
    let Ok((id, method, claim)) = REPLY.try_with(|r| {
        let r = r.borrow();
        (r.id.clone(), r.method, r.claim.clone())
    }) else {
        return serde_json::from_str(&text).map_err(|e| RpcError::internal(e.to_string()));
    };
    hub.request_hold(RequestStage::ListBuilt, method.unwrap_or_default(), &id).await;
    let whole = conn.send_serialized(&id, method, claim.as_ref(), text);
    REPLY.with(|r| r.borrow_mut().sent = Some(whole));
    hub.request_hold(RequestStage::ListQueued, method.unwrap_or_default(), &id).await;
    Ok(Value::Null)
}

/// A page by `limit`, or a census in its own order (`orderBy`): its own rows, picked before any is
/// built (`Hub::session_page_rows`), at most `limit` of them and at most [`LIST_PAGE_BYTES`]
/// (`list_guard::cut_page`): a page of five costs five rows, whatever the list's size.
async fn page(
    hub: &Hub,
    conn: &Conn,
    params: &Value,
    tools: bool,
    cursor: Option<Cursor>,
) -> Result<Value, RpcError> {
    use crate::hub::list_guard::{cut_page, serialize_in_order};
    let raw = conn.raw_text;
    let (rows, next) = hub.session_page_rows(params, tools)?;
    let (text, spans, keys) = serialize_in_order(&rows);
    drop(rows);
    let text = within_limit(raw, LIST_PAGE_BYTES, |budget| {
        Ok(cut_page((text.as_str(), spans.as_slice()), &keys, next.clone(), params, budget))
    })?;
    send_list(hub, conn, with_watch_cursor(hub, text, cursor)).await
}

/// A read with no `limit` (`params`: the whole list, a filter of it, or a byte page by its `h`
/// cursor) as the client reads it: its rows built as they go, at most [`LIST_PAGE_BYTES`] of them
/// (`Hub::session_list_text`). With `own_only`, this daemon's rows alone when they fit in one
/// reply, else the whole list's first page.
async fn whole_read(
    hub: &Hub,
    conn: &Conn,
    params: &Value,
    tools: bool,
    own_only: bool,
    cursor: Option<Cursor>,
) -> Result<Value, RpcError> {
    let raw = conn.raw_text;
    let text = {
        // A peer's page is masked, which parses it: one of a few at once (`parse_budget.rs`).
        let _parse = crate::parse_budget::permit().await;
        within_limit(raw, LIST_PAGE_BYTES, |budget| {
            let text = hub.session_list_text(params, tools, own_only, budget)?;
            // `page_text` writes a page's cursor first.
            if own_only && text.starts_with("{\"nextCursor\"") {
                return hub.session_list_text(params, tools, false, budget);
            }
            Ok(text)
        })?
    };
    send_list(hub, conn, with_watch_cursor(hub, text, cursor)).await
}

fn with_tools(params: &Value) -> Result<bool, RpcError> {
    match params.get("withTools") {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(value)) => Ok(*value),
        Some(_) => Err(RpcError::invalid_params("withTools must be a boolean")),
    }
}

/// `_acpmux/sessions`: the whole list, a filter of it, or a page of its own rows. One with no
/// `limit` goes whole, newest first, as before, when it fits in [`LIST_PAGE_BYTES`] as the client
/// reads it; one larger goes in pages, each with the `nextCursor` of the rest
/// (`list_guard::bounded`), rather than as one message too large to send. A page by `limit`, or a
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
    whole_read(hub, conn, params, tools, false, cursor).await
}

/// `_acpmux/sessions {pendingOnly: true}`: the sessions with a pending ask
/// (`Hub::pending_session_summaries`): it summarizes only those chats. It takes no other filter.
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
/// alone, never from the whole list.
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

/// The follow from `after`, sent as a list reply is. A change stamped while its rows are built may
/// go out as a notice before it: the client keeps the row with the higher `listSeq`. None: the log
/// cannot follow `after`.
async fn follow(
    hub: &Hub,
    conn: &Conn,
    after: u64,
    own_only: bool,
    tools: bool,
) -> Option<Result<Value, RpcError>> {
    let text = within_limit(conn.raw_text, LIST_PAGE_BYTES, |budget| {
        hub.list_follow(after, own_only, tools, budget)
            .map(|follow| follow.text)
            .ok_or_else(|| RpcError::internal("reset"))
    })
    .ok()?;
    Some(send_list(hub, conn, text).await)
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
    // A peer's link reads this daemon's own rows only, when they fit in one reply; it drops the
    // rows mirrored from its peers anyway (`peer.rs` `watch_sessions`). Too many for one, they go
    // as the whole list's byte pages, whose cursor the link follows with `_acpmux/sessions`
    // (`peer.rs` `watch_pages`): every page of one order, so no row is skipped.
    if conn.origin == super::Origin::Peer && whole(params) {
        return whole_read(hub, conn, params, tools, true, Some(cursor)).await;
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
    let text = {
        let _parse = crate::parse_budget::permit().await;
        let list = hub.list_rows(excludes_closed(params), false);
        let rows = list.rows();
        let full = |row| list.value(hub, row, true);
        within_limit(raw, LIST_PAGE_BYTES, |budget| {
            // An ACP row holds its summary whole: the list goes whole, newest first, while its
            // rows fit, and no row past the budget is built.
            if cursor.is_none() {
                let (mut sessions, mut used) = (Vec::new(), 0_usize);
                let fits = rows.iter().all(|row| {
                    let row = acp_row(&full(row));
                    used = used.saturating_add(row.to_string().len()).saturating_add(1);
                    sessions.push(row);
                    used <= budget
                });
                if fits {
                    return Ok(json!({"sessions": sessions}).to_string());
                }
            }
            let row = |at: usize| rows.get(at).map(|r| acp_row_within(&full(r), budget));
            let (sessions, next) =
                crate::hub::session_pages::byte_page(rows, cursor, budget, row, |v| {
                    v.as_ref().map_or(4, |v| v.to_string().len())
                })?;
            let mut result = json!({"sessions": sessions});
            if let Some(next) = next {
                result.set("nextCursor", Value::String(next));
            }
            Ok(result.to_string())
        })?
    };
    send_list(hub, conn, text).await
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
mod tests;
