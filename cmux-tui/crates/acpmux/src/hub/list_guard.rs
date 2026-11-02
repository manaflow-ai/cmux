//! Part of `Hub`; see `hub/mod.rs`. The guard on full session lists (`_acpmux/sessions`,
//! `_acpmux/watch`, ACP's `session/list`), for every client. A full list of 2,800 chats
//! costs about 0.16 s of CPU; cmux-tui servers from before #26255 asked for it about once
//! a second, and three of them kept a dogfood Mac's idle daemon at 30-60% of a core.
//!
//! - **One build, shared.** A [`Snapshot`] is the list serialized once; a whole list is
//!   sent as those bytes, a page or filter is cut from them (rows picked by their keys).
//! - **Never staler than a client is owed.** It is reused only while nothing a watcher
//!   hears of changed (every send on [`Events`], attach or detach, write to the peers'
//!   rows, and change of a peer's link state counts), within its window, and never while
//!   the chat logs load. Fields
//!   that change with the clock alone (a stall, an expiring tag) are at most a window old.
//!   A request shares any build begun after it arrived. A watcher's reply never follows
//!   a `session_changed` notice its list may lack (`list_reply.rs`).
//! - **Paced.** [`BURST`] builds back to back, then one per window ([`PACE`] times the
//!   last build's cost, at most [`MAX_WINDOW`]): about 1/32 of a core however many ask.
//!   Per connection, two lists back to back, then one per window; all connections
//!   together, [`REPLIES`] per window. A page costs its share of the rows, at least
//!   [`PAGE_MIN`]. The first list is built before it is paced, so the pace is known. A
//!   request that would wait more than [`MAX_WAIT`] is refused, to try again later.
//!
//! Cleanup: each build starts one task that drops its snapshot when the window ends
//! (unless a newer build replaced it); it holds a weak reference and ends after one
//! sleep. A connection's pace goes with the connection.

use super::*;
use std::ops::Range;
use std::time::Duration;
// Tokio's clock, so a paused test clock moves the pace and the windows too.
use cmux_json::JsonSet as _;
use tokio::time::Instant;

/// A build runs at most once per `PACE` times its own cost: about 3% of a core.
const PACE: u32 = 32;
/// The longest window, whatever a build cost.
const MAX_WINDOW: Duration = Duration::from_secs(15);
/// Builds that may run back to back before the pace holds.
const BURST: u32 = 4;
/// Lists one connection may read back to back.
const CONN_BURST: u32 = 2;
/// Lists all connections together read per window, after as many back to back.
const REPLIES: u32 = 8;
/// The least a page costs, in lists: it reads every row's key to find its rows.
const PAGE_MIN: f64 = 1.0 / 16.0;
/// The longest a list request waits for its turn; a longer wait is refused.
pub(crate) const MAX_WAIT: Duration = Duration::from_secs(30);

/// The hub's event channel. Every send is a change some list shows.
pub(crate) struct Events {
    tx: broadcast::Sender<HubEvent>,
    changes: AtomicU64,
    /// Any event may change a field in a closed row (for example attached/shown or usage).
    /// Closed summary bytes carry this generation so they are rebuilt only after a change.
    pub(super) summary_generation: Arc<AtomicU64>,
}

impl Events {
    pub(super) fn new(capacity: usize) -> Self {
        Self {
            tx: broadcast::channel(capacity).0,
            changes: AtomicU64::new(0),
            summary_generation: Arc::new(AtomicU64::new(0)),
        }
    }

    /// Counts the change, then sends it.
    pub(super) fn send(
        &self,
        event: HubEvent,
    ) -> Result<usize, broadcast::error::SendError<HubEvent>> {
        self.changed();
        self.tx.send(event)
    }

    pub(super) fn subscribe(&self) -> broadcast::Receiver<HubEvent> {
        self.tx.subscribe()
    }

    /// A change no event carries (an attach): the next list is built anew.
    pub(super) fn changed(&self) {
        self.changes.fetch_add(1, Ordering::SeqCst);
        self.summary_generation.fetch_add(1, Ordering::SeqCst);
    }
}

/// One build of the list, kept serialized: a JSON tree of every summary is several
/// times its text.
pub(crate) struct Snapshot {
    /// What it was built at (`key`).
    key: Key,
    serial: u64,
    /// Whether this snapshot intentionally omits closed records for the Mac census path.
    live_only: bool,
    started: Instant,
    /// How long it is reused, and how far the next build waits behind it.
    window: Duration,
    /// `{"sessions": [...]}` of every summary, local and remote, newest first.
    pub(crate) whole: Arc<String>,
    /// Where each summary is in `whole`.
    spans: Vec<Range<usize>>,
    /// What paging reads of each: `sessionId`, `updatedAt`, `peer`, `status`, and `at`.
    keys: Vec<Value>,
    /// Other results made from it, once each (masked for a peer, ACP's `session/list`).
    made: StdMutex<HashMap<&'static str, Arc<String>>>,
    /// The full rows are built only for trusted internal consumers (peer bootstrap and ACP).
    /// Ordinary census/watch replies keep using `whole`, so their retained bytes stay small.
    full: StdMutex<Option<Arc<FullRows>>>,
}

/// Every summary with its tools, serialized as [`Snapshot::whole`] is, with where each row is
/// and its paging keys: a page of it parses only its own rows.
pub(crate) struct FullRows {
    whole: Arc<String>,
    spans: Vec<Range<usize>>,
    keys: Vec<Value>,
}

impl FullRows {
    /// Each row's `sessionId` and `peer`, in the order of [`Self::row`].
    pub(crate) fn keys(&self) -> &[Value] {
        &self.keys
    }

    /// The bytes of every row together.
    pub(crate) fn bytes(&self) -> usize {
        self.whole.len()
    }

    /// Row `at`, parsed.
    pub(crate) fn row(&self, at: usize) -> Value {
        let text = self.spans.get(at).and_then(|span| self.whole.get(span.clone()));
        text.and_then(|text| serde_json::from_str(text).ok()).unwrap_or_default()
    }
}

type Built = (String, Vec<Range<usize>>, Vec<Value>);

impl Snapshot {
    fn new(
        key: Key,
        serial: u64,
        window: Duration,
        live_only: bool,
        (text, spans, keys): Built,
    ) -> Self {
        let (whole, made, started) = (Arc::new(text), Default::default(), Instant::now());
        Self {
            key,
            serial,
            live_only,
            started,
            window,
            whole,
            spans,
            keys,
            made,
            full: Default::default(),
        }
    }

    /// Keep only serialized bytes and paging keys as summaries are produced. A full
    /// JSON tree of every row amplifies the list's peak heap, even when it is freed
    /// immediately after serialization.
    fn build(hub: &Hub) -> Built {
        let mut rows = Rows::default();
        hub.visit_session_summaries(false, |row| rows.push(&row));
        rows.finish()
    }

    fn build_live(hub: &Hub) -> Built {
        let mut rows = Rows::default();
        hub.visit_live_session_summaries(false, |row| rows.push(&row));
        rows.finish()
    }

    /// Lazily serialize the same snapshot with tools for the ACP list and peer bootstrap.
    /// This daemon's own sessions only, no peer's row, serialized as a list reply: what a
    /// peer's link reads in its watch (`server/list_reply.rs` `watch`).
    pub(crate) fn own_whole(hub: &Hub, with_tools: bool) -> String {
        let mut rows = Rows::default();
        hub.visit_own_session_summaries(with_tools, |row| rows.push(&row));
        rows.finish().0
    }

    pub(crate) fn full_whole(&self, hub: &Hub) -> Arc<String> {
        self.full_rows(hub).whole.clone()
    }

    /// [`Self::full_whole`] with where each row is, for ACP's pages.
    pub(crate) fn full_rows(&self, hub: &Hub) -> Arc<FullRows> {
        let mut full = self.full.lock().unwrap_or_else(|e| e.into_inner());
        full.get_or_insert_with(|| {
            let mut rows = Rows::default();
            if self.live_only {
                hub.visit_live_session_summaries(true, |row| rows.push(&row));
            } else {
                hub.visit_session_summaries(true, |row| rows.push(&row));
            }
            let (whole, spans, keys) = rows.finish();
            Arc::new(FullRows { whole: Arc::new(whole), spans, keys })
        })
        .clone()
    }

    /// The reply to `params` that has no `limit` (the whole list, or a filter of it), with tools
    /// when `tools`: every row it lists, newest first, as before; or, when they come to more
    /// than `budget` bytes or `params` has a page's cursor, a page of them that fits, with the
    /// `nextCursor` of the rest (`session_pages::byte_page`, in an order updates do not change).
    /// One daemon's whole list was 17 MB with tools on 2026-10-30, past the message limit, and
    /// was refused whole.
    pub(crate) fn bounded(
        &self,
        hub: &Hub,
        params: &Value,
        tools: bool,
        budget: usize,
    ) -> Result<String, RpcError> {
        let full = tools.then(|| self.full_rows(hub));
        let (text, spans, keys) = match &full {
            Some(full) => (full.whole.as_str(), &full.spans, &full.keys),
            None => (self.whole.as_str(), &self.spans, &self.keys),
        };
        // A page's cursor (`h...`) is byte_page's; a session list cursor (`k...`) stays a
        // filter, as before: the rows after the session it names. A page of a list a `k` cursor
        // started carries it on (`h...~k...`), so every page keeps its cutoff.
        let mut filters = params.clone();
        let (cursor, after) = match params.get("cursor") {
            None | Some(Value::Null) => (None, None),
            Some(Value::String(text)) if text.starts_with('h') => match text.split_once('~') {
                Some((page, after)) => (Some(page), Some(after)),
                None => (Some(text.as_str()), None),
            },
            Some(Value::String(text)) => (None, Some(text.as_str())),
            Some(_) => return Err(RpcError::invalid_params("cursor must be a string")),
        };
        if let Some(p) = filters.as_object_mut() {
            match after {
                Some(after) => p.insert("cursor".to_owned(), Value::String(after.to_owned())),
                None => p.remove("cursor"),
            };
        }
        let picked = super::session_pages::session_list_reply_borrowed(keys, &filters)?;
        let rows =
            picked.get("sessions").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
        let row = |key: &Value| row_text(text, spans, key, budget);
        let whole = cursor.is_none() && {
            let bytes: usize = rows.iter().map(|key| row(key).len().saturating_add(1)).sum();
            bytes <= budget
        };
        let (page, next) = if whole {
            (rows.iter().map(row).collect(), None)
        } else {
            let (page, next) = super::session_pages::byte_page(
                rows,
                cursor,
                budget,
                |n| rows.get(n).map_or_else(|| "null".into(), row),
                |r| r.len(),
            )?;
            (page, next.map(|next| after.map_or_else(|| next.clone(), |k| format!("{next}~{k}"))))
        };
        let mut out = String::from("{");
        if let Some(next) = next {
            out.push_str(&format!("\"nextCursor\":{},", Value::String(next)));
        }
        out.push_str("\"sessions\":[");
        for (n, text) in page.iter().enumerate() {
            if n > 0 {
                out.push(',');
            }
            out.push_str(text);
        }
        out.push_str("]}");
        Ok(out)
    }

    #[cfg(test)]
    fn serialize(summaries: &[Value]) -> Built {
        let mut rows = Rows::default();
        for row in summaries {
            rows.push(row);
        }
        rows.finish()
    }

    /// The reply to a paged `params` (a `limit`, or a census's `orderBy`), cut from the shared
    /// text, with tools when `full` is given: the rows `session_list_reply` picks, as many as fit
    /// in `budget` bytes, at least one, and `nextCursor` first. A page cut short by its bytes ends
    /// with the `nextCursor` of its last row, as a page of that many rows would: 1000 rows of a
    /// busy host with usage were more than one message, refused whole on every retry. A row
    /// larger than `budget` alone is trimmed ([`row_text`]).
    pub(crate) fn page(
        &self,
        full: Option<&FullRows>,
        params: &Value,
        budget: usize,
    ) -> Result<String, RpcError> {
        let (text, spans, keys) = match full {
            Some(full) => (full.whole.as_str(), &full.spans, &full.keys),
            None => (self.whole.as_str(), &self.spans, &self.keys),
        };
        let picked = super::session_pages::session_list_reply_borrowed(keys, params)?;
        let rows =
            picked.get("sessions").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
        let mut next = picked.get("nextCursor").cloned();
        let (mut page, mut used) = (Vec::with_capacity(rows.len()), 0_usize);
        for (n, key) in rows.iter().enumerate() {
            let row = row_text(text, spans, key, budget);
            // One more byte for the comma between rows.
            let total = used.saturating_add(row.len()).saturating_add(1);
            if n > 0 && total > budget {
                let last = rows.get(n.saturating_sub(1)).unwrap_or(key);
                next = Some(Value::String(page_cursor(params, last)));
                break;
            }
            used = total;
            page.push(row);
        }
        let mut text = String::from("{");
        if let Some(next) = next {
            text.push_str(&format!("\"nextCursor\":{next},"));
        }
        text.push_str("\"sessions\":[");
        for (n, row) in page.iter().enumerate() {
            if n > 0 {
                text.push(',');
            }
            text.push_str(row);
        }
        text.push_str("]}");
        Ok(text)
    }

    /// Every summary, parsed back.
    pub(crate) fn values(&self) -> Vec<Value> {
        let parse =
            |span: &Range<usize>| serde_json::from_str(self.whole.get(span.clone()).unwrap_or(""));
        self.spans.iter().map(|span| parse(span).unwrap_or_default()).collect()
    }

    /// Nothing it shows changed since it was built.
    pub(crate) fn current(&self, hub: &Hub) -> bool {
        self.key == key(hub)
    }

    /// The result `name`, made by `make` the first time it is asked for.
    pub(crate) fn made(
        &self,
        name: &'static str,
        make: impl FnOnce(&Self) -> String,
    ) -> Arc<String> {
        let mut made = self.made.lock().unwrap_or_else(|e| e.into_inner());
        made.entry(name).or_insert_with(|| Arc::new(make(self))).clone()
    }
}

/// Row `key` of `text`: whole when it fits in `budget`, else trimmed to fit, its largest fields
/// first (`reply_fit.rs`), or as [`too_large_stub`] when even the fields it keeps do not.
fn row_text<'a>(
    text: &'a str,
    spans: &[Range<usize>],
    key: &Value,
    budget: usize,
) -> std::borrow::Cow<'a, str> {
    let at = key.get("at").and_then(Value::as_u64).and_then(|at| usize::try_from(at).ok());
    let Some(row) = at.and_then(|at| spans.get(at)).and_then(|span| text.get(span.clone())) else {
        return "null".into();
    };
    if row.len() <= budget {
        return row.into();
    }
    let mut value: Value = serde_json::from_str(row).unwrap_or_default();
    if super::reply_fit::fit_object(&mut value, budget) {
        value.to_string().into()
    } else {
        too_large_stub(key, row.len()).into()
    }
}

/// The cursor of the page after `last`: a census's (`orderBy`, `s:<id>`) or the list's
/// (`session_pages::cursor_after`).
fn page_cursor(params: &Value, last: &Value) -> String {
    let census = params.get("orderBy").and_then(Value::as_str).is_some_and(|o| !o.is_empty());
    if census {
        format!("s:{}", last.get("sessionId").and_then(Value::as_str).unwrap_or(""))
    } else {
        super::session_pages::cursor_after(last)
    }
}

/// A row larger than a page alone even trimmed (a kept field that large) goes as this stub, with
/// its size, as a record too large for a reply goes (`hub/paging.rs`): a page holds at least one
/// row, and one that large would be refused, page and all. It keeps the row's paging keys (an id longer than 4 KiB as null), so
/// a client still sees the chat and can read it alone (`_acpmux/info`).
fn too_large_stub(key: &Value, bytes: usize) -> String {
    let id = key.get("sessionId").filter(|v| v.as_str().is_some_and(|t| t.len() <= 4 << 10));
    let mut stub = json!({
        "sessionId": id.cloned().unwrap_or(Value::Null),
        "updatedAt": key.get("updatedAt").cloned().unwrap_or(Value::Null),
        "omitted": {"bytes": bytes, "reason": "too_large"},
    });
    for k in ["peer", "status"] {
        if let Some(v) = key.get(k).filter(|v| !v.is_null()) {
            stub.set(k, v.clone());
        }
    }
    stub.to_string()
}

/// A byte arena and small keys, rather than all the summaries' nested allocations.
/// Sort only captured keys: reading live timestamps in a comparator is not a total order.
#[derive(Default)]
struct Rows {
    text: Vec<u8>,
    spans: Vec<Range<usize>>,
    keys: Vec<RowKey>,
}

/// The fields needed for ordering, filtering, and cursors. Keeping these typed avoids
/// allocating a JSON object for every row while the snapshot is being built.
struct RowKey {
    at: usize,
    session_id: Option<String>,
    updated_at: u64,
    peer: Option<String>,
    status: Option<String>,
}

impl Rows {
    fn push(&mut self, row: &Value) {
        let start = self.text.len();
        // A Value always serializes, and Vec's writer cannot fail.
        let _ = serde_json::to_writer(&mut self.text, row);
        self.spans.push(start..self.text.len());
        self.keys.push(RowKey {
            at: self.keys.len(),
            session_id: row.get("sessionId").and_then(Value::as_str).map(str::to_owned),
            updated_at: row.get("updatedAt").and_then(Value::as_u64).unwrap_or_default(),
            peer: row.get("peer").and_then(Value::as_str).map(str::to_owned),
            status: row.get("status").and_then(Value::as_str).map(str::to_owned),
        });
    }

    fn finish(mut self) -> Built {
        // The order `sort_session_summaries` gives: a chat's copies local first, then by peer,
        // the order their cursors (`session_pages.rs`) read them in.
        self.keys.sort_by(|a, b| {
            b.updated_at
                .cmp(&a.updated_at)
                .then_with(|| {
                    a.session_id.as_deref().unwrap_or("").cmp(b.session_id.as_deref().unwrap_or(""))
                })
                .then_with(|| a.peer.cmp(&b.peer))
        });
        let prefix = br#"{"sessions":["#;
        let mut whole = Vec::with_capacity(
            prefix.len() + self.text.len() + self.keys.len().saturating_sub(1) + 2,
        );
        whole.extend_from_slice(prefix);
        let mut spans = Vec::with_capacity(self.spans.len());
        let mut keys = Vec::with_capacity(self.keys.len());
        for (at, key) in self.keys.into_iter().enumerate() {
            if at > 0 {
                whole.push(b',');
            }
            let source = key.at;
            let start = whole.len();
            whole.extend_from_slice(
                self.spans
                    .get(source)
                    .and_then(|span| self.text.get(span.clone()))
                    .unwrap_or_default(),
            );
            spans.push(start..whole.len());
            let mut value = json!({"at": at});
            if let Some(session_id) = key.session_id {
                value.set("sessionId", Value::String(session_id));
            }
            if key.updated_at != 0 {
                value.set("updatedAt", Value::from(key.updated_at));
            }
            if let Some(peer) = key.peer {
                value.set("peer", Value::String(peer));
            }
            if let Some(status) = key.status {
                value.set("status", Value::String(status));
            }
            keys.push(value);
        }
        whole.extend_from_slice(b"]}");
        // serde_json writes UTF-8, and rows are copied only at their boundaries.
        (String::from_utf8(whole).unwrap_or_default(), spans, keys)
    }
}

#[derive(Default)]
pub(crate) struct ListGuard {
    state: Arc<tokio::sync::Mutex<State>>,
    /// The last build's window (ns) and row count, read without waiting for a build.
    window_nanos: AtomicU64,
    rows: std::sync::atomic::AtomicUsize,
    /// Every connection's lists together (`reserve`).
    replies: StdMutex<Pacer>,
    /// Builds begun: a request shares any build begun after it arrived.
    begun: AtomicU64,
}

#[derive(Default)]
struct State {
    last: Option<Arc<Snapshot>>,
    pace: Pacer,
}

impl ListGuard {
    pub(crate) fn window(&self) -> Duration {
        Duration::from_nanos(self.window_nanos.load(Ordering::Relaxed))
    }

    /// The share of the list a page of `limit` rows costs (None: all of it).
    pub(crate) fn share(&self, limit: Option<u64>) -> f64 {
        let rows = self.rows.load(Ordering::Relaxed).max(1) as f64;
        limit.map_or(1.0, |limit| (limit as f64 / rows).clamp(PAGE_MIN, 1.0))
    }

    /// Reserves `share` of a list on a connection's `pace`, then on every connection's
    /// together: how long the request waits first. Over [`MAX_WAIT`], nothing is
    /// reserved and the wait is the error.
    pub(crate) fn reserve(&self, pace: &StdMutex<Pacer>, share: f64) -> Result<Duration, Duration> {
        let (window, now) = (self.window(), Instant::now());
        let mut pace = pace.lock().unwrap_or_else(|e| e.into_inner());
        // Sending even a shared list copies it into the reply line.
        let mut replies = self.replies.lock().unwrap_or_else(|e| e.into_inner());
        let wait = pace.wait(now, window * (CONN_BURST - 1), window);
        // Reprice at the real clock before probing a hypothetical admission time.
        // A rejected request must not advance shared debt to `now + wait`.
        replies.reprice(now, window / REPLIES);
        let more = replies.wait(now + wait, window, window / REPLIES);
        if wait + more > MAX_WAIT {
            return Err(wait + more);
        }
        pace.spend(now + wait, window.mul_f64(share), window);
        replies.spend(now + wait + more, window.mul_f64(share) / REPLIES, window / REPLIES);
        tracing::debug!(target: "acpmux::list_cost", window_us = window.as_micros(),
            wait_us = (wait + more).as_micros(), share, "list_reply_reservation");
        Ok(wait + more)
    }

    /// The list for a request that arrived now: the shared snapshot while nothing it
    /// shows changed, or one begun since; else a new build once the pace allows.
    pub(crate) async fn snapshot(&self, hub: &Hub) -> Arc<Snapshot> {
        self.snapshot_for(hub, false).await
    }

    /// Build the cheaper census projection when the caller explicitly excludes closed rows.
    pub(crate) async fn snapshot_live(&self, hub: &Hub) -> Arc<Snapshot> {
        self.snapshot_for(hub, true).await
    }

    async fn snapshot_for(&self, hub: &Hub, live_only: bool) -> Arc<Snapshot> {
        let asked = self.begun.load(Ordering::SeqCst);
        // One build at a time; requests that arrive meanwhile wait for it and share it.
        let mut state = self.state.lock().await;
        if let Some(last) = &state.last
            && last.live_only == live_only
            && last.key.0
            && (last.serial > asked || last.current(hub) && last.started.elapsed() < last.window)
        {
            return last.clone();
        }
        let window = self.window();
        // A fresh snapshot waits at most one current window, even if an earlier
        // reservation used a much more expensive build. Lock/build time is separate.
        let wait = state.pace.wait(Instant::now(), window * (BURST - 1), window).min(window);
        if !wait.is_zero() {
            tokio::time::sleep(wait).await;
        }
        // Counted before its key is read: it is as new as any request that came before.
        let serial = self.begun.fetch_add(1, Ordering::SeqCst) + 1;
        let (started, key) = (Instant::now(), key(hub));
        let built = if live_only { Snapshot::build_live(hub) } else { Snapshot::build(hub) };
        let elapsed = started.elapsed();
        let window = elapsed.saturating_mul(PACE).min(MAX_WINDOW);
        tracing::debug!(target: "acpmux::list_cost", serial, rows = built.1.len(),
            build_us = elapsed.as_micros(), window_us = window.as_micros(),
            builder_wait_us = wait.as_micros(), "list_snapshot_build");
        state.pace.spend(started, window, window);
        let nanos = u64::try_from(window.as_nanos()).unwrap_or(u64::MAX);
        self.window_nanos.store(nanos, Ordering::Relaxed);
        self.rows.store(built.1.len(), Ordering::Relaxed);
        let snapshot =
            Arc::new(Snapshot { started, ..Snapshot::new(key, serial, window, live_only, built) });
        state.last = Some(snapshot.clone());
        drop(state);
        self.expire(serial, window);
        snapshot
    }

    /// Drops snapshot `serial` when its window ends, unless a newer build replaced it.
    fn expire(&self, serial: u64, window: Duration) {
        let state = Arc::downgrade(&self.state);
        tokio::spawn(async move {
            tokio::time::sleep(window).await;
            let Some(state) = state.upgrade() else { return };
            let mut state = state.lock().await;
            if state.last.as_ref().is_some_and(|s| s.serial == serial) {
                state.last = None;
            }
        });
    }
}

/// Whether every chat log is read, the change count, the peers' row writes, and their
/// link states (each peer row's `peerState`).
type Key = (bool, u64, u64, Vec<(String, &'static str)>);

/// What a snapshot is reused under (only once every chat log is read).
fn key(hub: &Hub) -> Key {
    let ready = *hub.logs_ready.borrow();
    let writes = hub.remote_sessions.lock().unwrap_or_else(|e| e.into_inner()).writes;
    let peers = hub.peers.lock().unwrap_or_else(|e| e.into_inner());
    let mut states: Vec<_> = peers.values().map(|p| (p.name.clone(), p.state().as_str())).collect();
    drop(peers);
    states.sort_unstable();
    (ready, hub.events.changes.load(Ordering::SeqCst), writes, states)
}

/// A pace (the generic cell rate algorithm): work spends time ahead of the clock, and
/// waits while it is more than its burst ahead.
#[derive(Default)]
pub(crate) struct Pacer {
    ahead_to: Option<Instant>,
    /// Debt is measured in lists, so a new build cost rescales its time value.
    period: Duration,
}

impl Pacer {
    fn wait(&mut self, now: Instant, burst: Duration, period: Duration) -> Duration {
        self.reprice(now, period);
        self.ahead_to.map_or(Duration::ZERO, |to| to.saturating_duration_since(now + burst))
    }

    fn reprice(&mut self, now: Instant, period: Duration) {
        if self.period != period {
            // A busy host can briefly take seconds to build a list. Keeping that build's
            // absolute-time debt after the next cheap build made a 15 s window impose
            // nearly a minute of sleep: the burst allowance had already shrunk. Preserve
            // the number of lists owed in both directions. Discounting falls but not
            // charging rises would forgive debt on every oscillation, removing pacing.
            // Previously returned reservation sleeps are not rescheduled.
            self.ahead_to = self.ahead_to.map(|to| {
                let remaining = to.saturating_duration_since(now);
                let scaled = if self.period.is_zero() {
                    Duration::ZERO
                } else {
                    remaining.mul_f64(period.as_secs_f64() / self.period.as_secs_f64())
                };
                now + scaled
            });
            self.period = period;
        }
    }

    fn spend(&mut self, at: Instant, cost: Duration, period: Duration) {
        self.reprice(at, period);
        self.ahead_to = Some(self.ahead_to.map_or(at, |to| to.max(at)) + cost);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    impl Snapshot {
        /// [`Snapshot::bounded`] without tools, which needs no hub.
        fn bounded_text(&self, params: &Value, budget: usize) -> String {
            let hub = crate::hub::Hub::new(crate::config::Config::default(), {
                let mut config = crate::config::Config::default();
                config.store.mode = crate::config::StoreMode::Memory;
                crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap()
            });
            self.bounded(&hub, params, false, budget).unwrap()
        }
    }

    #[test]
    fn the_text_and_every_page_are_the_bytes_the_summaries_write() {
        let mut rows: Vec<Value> = (0..5)
            .map(|i| json!({"sessionId": format!("s{i}"), "updatedAt": 10 - i, "x": "q\"\n",
                "status": if i % 2 == 0 { "idle" } else { "closed" }, "peer": (i == 3).then_some("cmux16")}))
            .collect();
        super::super::session_pages::sort_session_summaries(&mut rows);
        let built = Snapshot::serialize(&rows);
        assert_eq!(built.0, json!({"sessions": rows}).to_string());
        assert_eq!(Snapshot::serialize(&[]).0, r#"{"sessions":[]}"#);
        let list = Snapshot::new((false, 0, 0, Vec::new()), 0, Duration::ZERO, false, built);
        assert_eq!(list.values(), rows);
        let reply = |p: &Value| super::super::session_pages::session_list_reply(rows.clone(), p);
        let next = reply(&json!({"limit": 2})).unwrap()["nextCursor"].clone();
        for params in [
            json!({"limit": 2}),
            json!({"limit": 2, "cursor": next}),
            json!({"limit": 9}),
            json!({"status": "idle"}),
            json!({"peer": "cmux16", "limit": 1}),
        ] {
            assert_eq!(
                list.page(None, &params, usize::MAX).unwrap(),
                reply(&params).unwrap().to_string(),
                "{params}"
            );
        }
        assert!(list.page(None, &json!({"cursor": 3}), usize::MAX).is_err());
    }

    /// A many-session daemon keeps the full keyset in its snapshot, but a one-row
    /// request copies and serializes only its selected row, with the same cursors
    /// and exact filters as the old owned path.
    #[test]
    fn three_thousand_key_snapshot_pages_only_selected_rows() {
        let rows: Vec<Value> = (0..3_000)
            .map(|i| {
                json!({
                    "sessionId": format!("s{i:04}"),
                    "updatedAt": 3_000 - i,
                    "peer": (i % 5 == 0).then_some("machine"),
                    "status": if i % 3 == 0 { "closed" } else { "idle" },
                })
            })
            .collect();
        let list = Snapshot::new(
            (false, 0, 0, Vec::new()),
            0,
            Duration::ZERO,
            false,
            Snapshot::serialize(&rows),
        );
        let first: Value =
            serde_json::from_str(&list.page(None, &json!({"limit": 1}), usize::MAX).unwrap())
                .unwrap();
        assert_eq!(first["sessions"].as_array().unwrap().len(), 1);
        assert_eq!(first["sessions"][0]["sessionId"], "s0000");
        let second: Value = serde_json::from_str(
            &list
                .page(None, &json!({"limit": 1, "cursor": first["nextCursor"]}), usize::MAX)
                .unwrap(),
        )
        .unwrap();
        assert_eq!(second["sessions"][0]["sessionId"], "s0001");
        let filter = json!({"localOnly": true, "excludeStatus": ["closed"],
            "orderBy": "sessionId", "limit": 1});
        let picked: Value =
            serde_json::from_str(&list.page(None, &filter, usize::MAX).unwrap()).unwrap();
        assert_eq!(picked["sessions"][0]["sessionId"], "s0001");
        assert_eq!(picked["nextCursor"], "s:s0001");
        // The existing owned API and the borrowed one remain byte-for-byte identical.
        for params in [
            json!({}),
            json!({"limit": 1}),
            json!({"status": "closed", "peer": "machine", "limit": 2}),
            filter,
        ] {
            let owned =
                super::super::session_pages::session_list_reply(rows.clone(), &params).unwrap();
            let borrowed =
                super::super::session_pages::session_list_reply_borrowed(&rows, &params).unwrap();
            assert_eq!(owned, borrowed, "{params}");
        }
    }
    /// A list read from a session list cursor (`k...`) with no `limit`, too large for one page,
    /// keeps that cursor's cutoff on every page: the rows after the session it names, each once.
    #[tokio::test]
    async fn byte_pages_of_a_list_after_a_session_cursor_keep_its_cutoff() {
        let mut rows: Vec<Value> = ["a", "b", "c", "d", "e", "f"]
            .iter()
            .enumerate()
            .map(|(i, id)| json!({"sessionId": id, "updatedAt": 10 - i, "pad": "x".repeat(40)}))
            .collect();
        super::super::session_pages::sort_session_summaries(&mut rows);
        let list = Snapshot::new(
            (false, 0, 0, Vec::new()),
            0,
            Duration::ZERO,
            false,
            Snapshot::serialize(&rows),
        );
        let after_b =
            super::super::session_pages::session_list_reply(rows.clone(), &json!({"limit": 2}))
                .unwrap()["nextCursor"]
                .clone();
        let (mut read, mut params) = (Vec::new(), json!({"cursor": after_b}));
        for _ in 0..10 {
            let page: Value = serde_json::from_str(&list.bounded_text(&params, 150)).unwrap();
            let listed = page["sessions"].as_array().unwrap();
            read.extend(listed.iter().map(|r| r["sessionId"].as_str().unwrap().to_owned()));
            match page.get("nextCursor") {
                Some(next) => params["cursor"] = next.clone(),
                None => break,
            }
        }
        read.sort();
        assert_eq!(read, ["c", "d", "e", "f"]);
    }

    #[tokio::test]
    async fn a_row_larger_than_its_page_goes_as_a_stub_with_its_keys() {
        let mut rows = vec![
            json!({"sessionId": "big", "updatedAt": 9, "peer": "box", "status": "idle",
                "preview": "x".repeat(5000)}),
            json!({"sessionId": "small", "updatedAt": 5, "status": "idle"}),
        ];
        super::super::session_pages::sort_session_summaries(&mut rows);
        let list = Snapshot::new(
            (false, 0, 0, Vec::new()),
            0,
            Duration::ZERO,
            false,
            Snapshot::serialize(&rows),
        );
        let first: Value = serde_json::from_str(&list.bounded_text(&json!({}), 1000)).unwrap();
        // Pages go in an order updates do not change (`byte_page`), not newest first.
        let listed = first["sessions"].as_array().unwrap();
        let by_id = |id: &str| listed.iter().find(|r| r["sessionId"] == id).unwrap();
        let stub = by_id("big");
        assert_eq!(stub["peer"], "box");
        assert_eq!(stub["omitted"]["reason"], "too_large");
        assert!(stub["omitted"]["bytes"].as_u64().unwrap() > 5000, "{stub}");
        assert!(stub.get("preview").is_none(), "{stub}");
        // The stub is small, so the next row goes on its page.
        assert_eq!(listed.len(), 2, "{first}");
        assert_eq!(by_id("small"), &rows[1], "{first}");
        assert!(first.get("nextCursor").is_none(), "{first}");
    }

    fn cached_rows_equal_uncached(hub: &Hub) {
        let mut uncached: Vec<Value> =
            hub.sessions().iter().map(|session| hub.session_summary(session)).collect();
        super::super::session_pages::sort_session_summaries(&mut uncached);
        assert_eq!(hub.all_session_summaries(), uncached);

        let mut uncached_list: Vec<Value> =
            hub.sessions().iter().map(|session| hub.session_list_summary(session)).collect();
        super::super::session_pages::sort_session_summaries(&mut uncached_list);
        let mut cached_list = Vec::new();
        hub.visit_session_summaries(false, |row| cached_list.push(row));
        assert_eq!(cached_list, uncached_list);
    }

    /// Closed rows are serialized once, but every metadata and list-visible runtime change must
    /// still produce the exact same row as the uncached walk. This exercises the fields that have
    /// historically changed after close: names, tags/archive, seen state, usage, child counts,
    /// reopen, and a closed parent's folded child preview.
    #[tokio::test]
    async fn closed_summary_cache_matches_uncached_after_every_mutation() {
        let cfg: crate::config::Config =
            serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
        let hub = Hub::new(
            cfg.clone(),
            crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap(),
        );
        let parent_meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "parent", "name": "parent",
            "harness": "claude", "family": "claude", "cwd": "/w", "status": "idle",
            "createdAt": 1, "updatedAt": 1, "preview": "parent preview", "unread": true,
        }))
        .unwrap();
        let child_meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "child", "name": "child",
            "harness": "claude", "family": "claude", "cwd": "/w", "status": "ready",
            "createdAt": 2, "updatedAt": 2, "subsession": {
                "startedBy": "parent", "shortName": "child", "depth": 1
            }
        }))
        .unwrap();
        let parent = hub.make_session(parent_meta);
        let child = hub.make_session(child_meta);
        hub.sessions
            .lock()
            .unwrap()
            .extend([(parent.id.clone(), parent.clone()), (child.id.clone(), child.clone())]);
        hub.update_live_session_index(&parent);
        hub.update_live_session_index(&child);
        hub.subsessions.note_status(&parent.id, &child.id, SessionStatus::Ready);

        hub.set_status(&parent, SessionStatus::Closed);
        cached_rows_equal_uncached(&hub); // close and the parent's folded child preview

        // A list build followed by the full form keeps both serialized rows coherent.
        hub.visit_session_summaries(false, |_| {});
        cached_rows_equal_uncached(&hub);

        // Appending after close changes the event-visible preview without a metadata write.
        hub.append(&parent, "mux", "message", json!({"text": "after close"}));
        hub.visit_session_summaries(false, |_| {});
        cached_rows_equal_uncached(&hub);

        // Opening a closed chat changes attached/shown fields in its full row.
        hub.attach_count(&parent, 1, true);
        cached_rows_equal_uncached(&hub);
        hub.attach_count(&parent, -1, true);
        cached_rows_equal_uncached(&hub);

        parent.meta.lock().unwrap().name = "renamed".into();
        hub.save_meta_answered(&parent).unwrap(); // rename
        cached_rows_equal_uncached(&hub);

        hub.set_tags_answered(
            &parent,
            Some(&serde_json::Map::from_iter([(String::from("team"), json!("red"))])),
            &[],
            None,
        )
        .unwrap(); // tag
        cached_rows_equal_uncached(&hub);
        hub.set_tags_answered(
            &parent,
            Some(&serde_json::Map::from_iter([(String::from("archived"), json!(true))])),
            &[],
            None,
        )
        .unwrap(); // archive tag
        cached_rows_equal_uncached(&hub);

        parent.meta.lock().unwrap().tags.insert(
            "expires".into(),
            crate::store::Tag {
                value: "soon".into(),
                expires_at: Some(crate::store::now_ms() + 20),
            },
        );
        hub.save_meta_answered(&parent).unwrap();
        cached_rows_equal_uncached(&hub);
        std::thread::sleep(std::time::Duration::from_millis(30));
        cached_rows_equal_uncached(&hub); // time-expiring tags invalidate without an event

        hub.set_visible(&parent, true); // mark-seen
        cached_rows_equal_uncached(&hub);

        parent.meta.lock().unwrap().usage = Some(json!({"inputTokens": 12, "size": 4096}));
        hub.save_meta_answered(&parent).unwrap(); // usage metadata
        cached_rows_equal_uncached(&hub);

        std::thread::scope(|scope| {
            for title in ["writer-a", "writer-b"] {
                scope.spawn(|| {
                    parent.meta.lock().unwrap().title = Some(title.into());
                    hub.save_meta(&parent);
                });
            }
        });
        cached_rows_equal_uncached(&hub); // concurrent metadata writers

        hub.set_status(&child, SessionStatus::Closed); // child count/fold changes
        cached_rows_equal_uncached(&hub);

        assert!(hub.reopen(&parent, parent.stops.load(Ordering::SeqCst))); // reopen
        cached_rows_equal_uncached(&hub);
        hub.set_status(&parent, SessionStatus::Closed);
        cached_rows_equal_uncached(&hub);

        // A purge removes the serialized row even when a late metadata writer runs afterward.
        parent.purged.store(true, Ordering::SeqCst);
        hub.remove_cached_closed_summary(&parent.id);
        assert!(!hub.closed_summary_cache.lock().unwrap().contains_key(&parent.id));
    }

    #[test]
    fn streamed_rows_preserve_all_fields_and_stable_ties() {
        let mut rows = vec![
            json!({"sessionId": "z", "updatedAt": 1, "status": "closed", "tools": [{"id": "tool", "description": "雪\n\""}]}),
            json!({"sessionId": "same", "updatedAt": 9, "origin": "local"}),
            json!({"sessionId": "same", "updatedAt": 9, "peer": "remote", "origin": "remote"}),
            json!({"sessionId": "same", "updatedAt": 9, "peer": "other", "origin": "other"}),
            json!({"sessionId": "a", "updatedAt": 9, "unknown": {"array": [null, false, 42]}}),
            json!({"sessionId": null, "updatedAt": "invalid", "status": "closed"}),
            json!({"updatedAt": -1, "opaque": "preserved"}),
        ];
        let built = Snapshot::serialize(&rows);
        super::super::session_pages::sort_session_summaries(&mut rows);
        assert_eq!(built.0, json!({"sessions": rows}).to_string());
        let list = Snapshot::new((false, 0, 0, Vec::new()), 0, Duration::ZERO, false, built);
        assert_eq!(list.values(), rows);
        for params in
            [json!({}), json!({"limit": 2}), json!({"status": "closed"}), json!({"peer": "remote"})]
        {
            assert_eq!(
                list.page(None, &params, usize::MAX).unwrap(),
                super::super::session_pages::session_list_reply(rows.clone(), &params)
                    .unwrap()
                    .to_string()
            );
        }
        assert_eq!(rows[1]["origin"], "local");
        assert_eq!(rows[2]["origin"], "other");
        assert_eq!(rows[3]["origin"], "remote");
    }

    #[test]
    fn a_connection_reads_two_lists_then_one_per_window_and_pages_by_their_share() {
        let guard = || {
            let guard = ListGuard::default();
            guard.window_nanos.store(4_000_000_000, Ordering::Relaxed);
            guard.rows.store(400, Ordering::Relaxed);
            guard
        };
        let (lists, pace) = (guard(), StdMutex::default());
        assert_eq!(lists.reserve(&pace, 1.0), Ok(Duration::ZERO));
        assert_eq!(lists.reserve(&pace, 1.0), Ok(Duration::ZERO));
        let third = lists.reserve(&pace, 1.0).unwrap();
        assert!(third > Duration::from_millis(3900), "{third:?}");
        // Pages of a quarter: a list ahead and one page more, then the pace holds.
        let (pages, pace) = (guard(), StdMutex::default());
        assert_eq!(pages.share(Some(100)), 0.25);
        let waits: Vec<Duration> = (0..6).map(|_| pages.reserve(&pace, 0.25).unwrap()).collect();
        assert_eq!(waits.iter().filter(|w| !w.is_zero()).count(), 1, "{waits:?}");
        // A page of one row (or none) still reads every key: it costs `PAGE_MIN`.
        assert_eq!((pages.share(Some(1)), pages.share(Some(0))), (PAGE_MIN, PAGE_MIN));
        // A new connection for each list: a window's `REPLIES` and one more, then they wait.
        let many = guard();
        let waits: Vec<Duration> =
            (0..REPLIES + 4).map(|_| many.reserve(&StdMutex::default(), 1.0).unwrap()).collect();
        assert_eq!(waits.iter().filter(|w| !w.is_zero()).count(), 3, "{waits:?}");
        // A flood waits at most `MAX_WAIT`; past it a request is refused and costs nothing.
        let waits: Vec<_> = (0..200).map(|_| many.reserve(&StdMutex::default(), 1.0)).collect();
        let refused = waits.iter().filter(|w| w.is_err()).count();
        assert!(refused > 100 && waits.iter().all(|w| w.unwrap_or_default() <= MAX_WAIT));
        let after = many.reserve(&StdMutex::default(), 1.0);
        assert!(after.is_err_and(|wait| wait <= MAX_WAIT + Duration::from_millis(500)));
    }

    /// Holds a snapshot of the hub as it is now for `window`, as a big daemon's would be.
    async fn hold(hub: &Hub, window: Duration) -> Arc<Snapshot> {
        hold_at(hub, window, hub.list_guard.begun.load(Ordering::SeqCst)).await
    }

    async fn hold_at(hub: &Hub, window: Duration, serial: u64) -> Arc<Snapshot> {
        let held = Arc::new(Snapshot::new(key(hub), serial, window, false, Default::default()));
        hub.list_guard.state.lock().await.last = Some(held.clone());
        held
    }

    /// A respawn's mark and its end each change a row (`respawnPending`): no list shows the
    /// row as it was (review 2 of the profile respawn).
    #[tokio::test]
    async fn a_profile_respawn_mark_and_its_end_rebuild_the_list() {
        let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "s1", "name": "lane", "harness": "claude",
            "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        hub.store.save(&meta).unwrap();
        let session = hub.make_session(meta);
        let (guard, minute) = (&hub.list_guard, Duration::from_secs(60));
        let seq = session.state_seq.load(Ordering::SeqCst);
        let held = hold(&hub, minute).await;
        hub.mark_profile_respawn(&session);
        assert_ne!(guard.snapshot(&hub).await.serial, held.serial, "the mark rebuilds");
        assert!(session.state_seq.load(Ordering::SeqCst) > seq, "watchers see the mark");
        let held = hold(&hub, minute).await;
        hub.mark_profile_respawn(&session);
        assert!(Arc::ptr_eq(&guard.snapshot(&hub).await, &held), "marked again: no change");
        hub.settle_profile_respawn(&session);
        assert_ne!(guard.snapshot(&hub).await.serial, held.serial, "its end rebuilds");
        let held = hold(&hub, minute).await;
        hub.settle_profile_respawn(&session);
        assert!(Arc::ptr_eq(&guard.snapshot(&hub).await, &held), "nothing pending: no change");
    }

    #[tokio::test]
    async fn a_snapshot_is_shared_until_a_change_and_never_while_the_logs_load() {
        let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
        let (guard, minute) = (&hub.list_guard, Duration::from_secs(60));
        let held = hold(&hub, minute).await;
        assert!(Arc::ptr_eq(&guard.snapshot(&hub).await, &held), "nothing changed");
        hub.events.changed();
        assert_ne!(guard.snapshot(&hub).await.serial, held.serial, "a change rebuilds");
        // A build begun after a request arrived is shared with it, whatever changed since.
        let begun = hold_at(&hub, minute, guard.begun.load(Ordering::SeqCst) + 1).await;
        hub.events.changed();
        assert!(Arc::ptr_eq(&guard.snapshot(&hub).await, &begun), "begun since: shared");
        let held = hold(&hub, minute).await;
        hub.remote_sessions.lock().unwrap().writes += 1;
        assert_ne!(guard.snapshot(&hub).await.serial, held.serial, "a peer's row rebuilds");
        // A peer's link state is every one of its rows' `peerState`.
        let held = hold(&hub, minute).await;
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = crate::peer::Peer::new("huge-blue", "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert("huge-blue".into(), peer);
        assert_ne!(guard.snapshot(&hub).await.serial, held.serial, "a peer's state rebuilds");
        hub.logs_ready.send_replace(false);
        let held = hold(&hub, minute).await;
        assert!(!held.key.0 && held.current(&hub));
        assert_ne!(guard.snapshot(&hub).await.serial, held.serial, "logs loading: rebuilt");
        // Nor is a build begun since the request shared while the logs load.
        let begun = hold_at(&hub, minute, guard.begun.load(Ordering::SeqCst) + 1).await;
        assert!(!Arc::ptr_eq(&guard.snapshot(&hub).await, &begun), "logs loading: not shared");
    }

    #[tokio::test(start_paused = true)]
    async fn a_snapshot_is_dropped_when_its_window_ends() {
        let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
        hub.list_guard.begun.store(99, Ordering::SeqCst);
        hold(&hub, Duration::from_secs(5)).await;
        hub.list_guard.expire(98, Duration::from_secs(1));
        hub.list_guard.expire(99, Duration::from_secs(5));
        tokio::time::sleep(Duration::from_secs(4)).await;
        assert!(hub.list_guard.state.lock().await.last.is_some(), "an older build's expiry");
        tokio::time::sleep(Duration::from_secs(2)).await;
        assert!(hub.list_guard.state.lock().await.last.is_none(), "it outlived its window");
    }
}

#[cfg(test)]
#[path = "list_scale_tests.rs"]
mod scale_tests;
