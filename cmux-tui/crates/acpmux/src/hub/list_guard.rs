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
}

impl Events {
    pub(super) fn new(capacity: usize) -> Self {
        Self { tx: broadcast::channel(capacity).0, changes: AtomicU64::new(0) }
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
    }
}

/// One build of the list, kept serialized: a JSON tree of every summary is several
/// times its text.
pub(crate) struct Snapshot {
    /// What it was built at (`key`).
    key: Key,
    serial: u64,
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
}

type Built = (String, Vec<Range<usize>>, Vec<Value>);

impl Snapshot {
    fn new(key: Key, serial: u64, window: Duration, (text, spans, keys): Built) -> Self {
        let (whole, made, started) = (Arc::new(text), Default::default(), Instant::now());
        Self { key, serial, started, window, whole, spans, keys, made }
    }

    /// Keep only serialized bytes and paging keys as summaries are produced. A full
    /// JSON tree of every row amplifies the list's peak heap, even when it is freed
    /// immediately after serialization.
    fn build(hub: &Hub) -> Built {
        let mut rows = Rows::default();
        hub.visit_session_summaries(|row| rows.push(&row));
        rows.finish()
    }

    #[cfg(test)]
    fn serialize(summaries: &[Value]) -> Built {
        let mut rows = Rows::default();
        for row in summaries {
            rows.push(row);
        }
        rows.finish()
    }

    /// The reply to a paged or filtered `params`, cut from the shared text: the bytes
    /// `session_list_reply` over the summaries writes (`nextCursor` sorts first).
    pub(crate) fn page(&self, params: &Value) -> Result<String, RpcError> {
        let picked = super::session_pages::session_list_reply(self.keys.clone(), params)?;
        let mut text = String::from("{");
        if let Some(next) = picked.get("nextCursor") {
            text.push_str(&format!("\"nextCursor\":{next},"));
        }
        text.push_str("\"sessions\":[");
        for (n, key) in picked["sessions"].as_array().into_iter().flatten().enumerate() {
            if n > 0 {
                text.push(',');
            }
            let at = key["at"].as_u64().unwrap_or_default() as usize;
            text.push_str(self.spans.get(at).map_or("null", |span| &self.whole[span.clone()]));
        }
        text.push_str("]}");
        Ok(text)
    }

    /// Every summary, parsed back.
    pub(crate) fn values(&self) -> Vec<Value> {
        let parse = |span: &Range<usize>| serde_json::from_str(&self.whole[span.clone()]);
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
        // Stable ties keep the original local-before-remote order, including duplicate IDs.
        self.keys.sort_by(|a, b| {
            b.updated_at.cmp(&a.updated_at).then_with(|| {
                a.session_id.as_deref().unwrap_or("").cmp(b.session_id.as_deref().unwrap_or(""))
            })
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
            whole.extend_from_slice(&self.text[self.spans[source].clone()]);
            spans.push(start..whole.len());
            let mut value = json!({"at": at});
            if let Some(session_id) = key.session_id {
                value["sessionId"] = Value::String(session_id);
            }
            if key.updated_at != 0 {
                value["updatedAt"] = Value::from(key.updated_at);
            }
            if let Some(peer) = key.peer {
                value["peer"] = Value::String(peer);
            }
            if let Some(status) = key.status {
                value["status"] = Value::String(status);
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
        let wait = pace.wait(now, window * (CONN_BURST - 1));
        let more = replies.wait(now + wait, window);
        if wait + more > MAX_WAIT {
            return Err(wait + more);
        }
        pace.spend(now + wait, window.mul_f64(share));
        replies.spend(now + wait + more, window.mul_f64(share) / REPLIES);
        tracing::debug!(target: "acpmux::list_cost", window_us = window.as_micros(),
            wait_us = (wait + more).as_micros(), share, "list_reply_reservation");
        Ok(wait + more)
    }

    /// The list for a request that arrived now: the shared snapshot while nothing it
    /// shows changed, or one begun since; else a new build once the pace allows.
    pub(crate) async fn snapshot(&self, hub: &Hub) -> Arc<Snapshot> {
        let asked = self.begun.load(Ordering::SeqCst);
        // One build at a time; requests that arrive meanwhile wait for it and share it.
        let mut state = self.state.lock().await;
        if let Some(last) = &state.last
            && last.key.0
            && (last.serial > asked || last.current(hub) && last.started.elapsed() < last.window)
        {
            return last.clone();
        }
        let wait = state.pace.wait(Instant::now(), self.window() * (BURST - 1));
        if !wait.is_zero() {
            tokio::time::sleep(wait).await;
        }
        // Counted before its key is read: it is as new as any request that came before.
        let serial = self.begun.fetch_add(1, Ordering::SeqCst) + 1;
        let (started, key) = (Instant::now(), key(hub));
        let built = Snapshot::build(hub);
        let elapsed = started.elapsed();
        let window = elapsed.saturating_mul(PACE).min(MAX_WINDOW);
        tracing::debug!(target: "acpmux::list_cost", serial, rows = built.1.len(),
            build_us = elapsed.as_micros(), window_us = window.as_micros(),
            builder_wait_us = wait.as_micros(), "list_snapshot_build");
        state.pace.spend(started, window);
        let nanos = u64::try_from(window.as_nanos()).unwrap_or(u64::MAX);
        self.window_nanos.store(nanos, Ordering::Relaxed);
        self.rows.store(built.1.len(), Ordering::Relaxed);
        let snapshot = Arc::new(Snapshot { started, ..Snapshot::new(key, serial, window, built) });
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
}

impl Pacer {
    fn wait(&self, now: Instant, burst: Duration) -> Duration {
        self.ahead_to.map_or(Duration::ZERO, |to| to.saturating_duration_since(now + burst))
    }

    fn spend(&mut self, at: Instant, cost: Duration) {
        self.ahead_to = Some(self.ahead_to.map_or(at, |to| to.max(at)) + cost);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let list = Snapshot::new((false, 0, 0, Vec::new()), 0, Duration::ZERO, built);
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
                list.page(&params).unwrap(),
                reply(&params).unwrap().to_string(),
                "{params}"
            );
        }
        assert!(list.page(&json!({"cursor": 3})).is_err());
    }

    #[test]
    fn streamed_rows_preserve_all_fields_and_stable_ties() {
        let mut rows = vec![
            json!({"sessionId": "z", "updatedAt": 1, "status": "closed", "tools": [{"id": "tool", "description": "雪\n\""}]}),
            json!({"sessionId": "same", "updatedAt": 9, "origin": "local"}),
            json!({"sessionId": "same", "updatedAt": 9, "peer": "remote", "origin": "remote"}),
            json!({"sessionId": "a", "updatedAt": 9, "unknown": {"array": [null, false, 42]}}),
            json!({"sessionId": null, "updatedAt": "invalid", "status": "closed"}),
            json!({"updatedAt": -1, "opaque": "preserved"}),
        ];
        let built = Snapshot::serialize(&rows);
        super::super::session_pages::sort_session_summaries(&mut rows);
        assert_eq!(built.0, json!({"sessions": rows}).to_string());
        let list = Snapshot::new((false, 0, 0, Vec::new()), 0, Duration::ZERO, built);
        assert_eq!(list.values(), rows);
        for params in
            [json!({}), json!({"limit": 2}), json!({"status": "closed"}), json!({"peer": "remote"})]
        {
            assert_eq!(
                list.page(&params).unwrap(),
                super::super::session_pages::session_list_reply(rows.clone(), &params)
                    .unwrap()
                    .to_string()
            );
        }
        assert_eq!(rows[1]["origin"], "local");
        assert_eq!(rows[2]["origin"], "remote");
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
        let held = Arc::new(Snapshot::new(key(hub), serial, window, Default::default()));
        hub.list_guard.state.lock().await.last = Some(held.clone());
        held
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
