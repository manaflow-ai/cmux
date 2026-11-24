//! One event-driven fan-out task per connection, cancelled when its request
//! stream ends. Cached inventory has a separate opt-in and sanitized feed.

use super::{
    Conn, Hub, Message, Ordering, broadcast, deliver, durable_gate, harness_admin, inventory_watch,
    json,
};
use std::sync::Arc;
use tokio::sync::watch;

/// How long a turn's answer waits for its connection's fan-out to send the updates broadcast
/// before it ([`Flush::sent`]). The fan-out only sends queued lines (it never waits on a client),
/// so this bounds a stalled task, never a slow reader.
const FLUSH_BOUND: std::time::Duration = std::time::Duration::from_secs(2);

/// Asks the connection's fan-out to send every hub event already broadcast. A turn's answer goes
/// on the request's own task, its updates through the fan-out, so under load the answer could
/// overtake the turn's last text: the pane drew the turn ended, then its words, a layout shift
/// (tests/permission_matrix.rs, 2 runs in 50 on a loaded Linux box). Its events are broadcast
/// before the turn's answer resolves, so once the fan-out has drained its queue they are sent.
///
/// A coalescing slot, never a queue (RFD 0124 R4): an ask bumps a count, the fan-out drains once
/// for every ask made by then and posts the count it served. However many turns end while the
/// fan-out is stalled, the connection holds two numbers, where an unbounded channel held one
/// waiter per ask until the fan-out woke. Nothing is shed: one drain answers every ask before it.
pub(super) struct Flush {
    asked: watch::Sender<u64>,
    served: watch::Receiver<u64>,
}

/// The fan-out's end of [`Flush`].
pub(super) struct Flushes {
    asked: watch::Receiver<u64>,
    served: watch::Sender<u64>,
}

impl Flush {
    pub(super) fn channel() -> (Self, Flushes) {
        let (asked, asked_rx) = watch::channel(0);
        let (served_tx, served) = watch::channel(0);
        (Self { asked, served }, Flushes { asked: asked_rx, served: served_tx })
    }

    /// Returns once the fan-out sent what was broadcast before this call, its task ended, or
    /// [`FLUSH_BOUND`] passed.
    pub(super) async fn sent(&self) {
        let mut ask = 0;
        self.asked.send_modify(|n| {
            *n += 1;
            ask = *n;
        });
        let mut served = self.served.clone();
        // An ended fan-out drops its end: the wait returns at once.
        let _ = tokio::time::timeout(FLUSH_BOUND, served.wait_for(|n| *n >= ask)).await;
    }
}

impl Flushes {
    /// The next ask: the count to post once the queue is drained. `None` once the asking side
    /// is gone.
    async fn asked(&mut self) -> Option<u64> {
        self.asked.changed().await.ok()?;
        Some(*self.asked.borrow_and_update())
    }

    fn served(&self, ask: u64) {
        self.served.send_replace(ask);
    }
}

pub(super) fn send_event(hub: &Arc<Hub>, conn: &Arc<Conn>, ev: crate::hub::HubEvent) {
    // A record a catch-up after a lap already sent goes no second time (`stream_cursor.rs`).
    if ev.remote.is_none() && !conn.stream_cursors.advance(&ev.session_id, ev.record.seq) {
        return;
    }
    deliver_once(hub, conn, ev);
}

/// The ring dropped events for `conn`: it is told (`_acpmux/lagged`), and each chat it attached
/// is read from its cursor in the store before the next live event (`stream_cursor.rs`).
async fn lapped(hub: &Arc<Hub>, conn: &Arc<Conn>, dropped: u64) {
    // Events this connection never queued: no latency sample, a drop.
    crate::gauges::fanout_lagged(dropped);
    conn.controls.resync(conn, "lagged");
    conn.send(&Message::notification("_acpmux/lagged", lagged(conn, dropped)));
    super::stream_cursor::catch_up(hub, conn, deliver_once).await;
}

pub(super) fn deliver_once(hub: &Arc<Hub>, conn: &Arc<Conn>, ev: crate::hub::HubEvent) {
    // Agent output shows nothing acknowledged: it raises no gate (`durable_gate.rs`).
    let _stream = durable_gate::stream_scope(&ev.record);
    #[cfg(test)]
    tests::panic_if_marked(&ev.session_id);
    #[cfg(test)]
    tests::count_wake(conn);
    let row = ev.row.clone();
    deliver(hub, conn, ev);
    // Queued what this connection owes for it: the last connection to get here times the
    // event's fan-out (`gauges.fanout`).
    row.fanout.taken();
}

pub(super) fn start(
    hub: Arc<Hub>,
    conn: Arc<Conn>,
    mut flushes: Flushes,
) -> tokio::task::JoinHandle<()> {
    // Only the events routed to this connection (`interest.rs`), in broadcast order.
    let rx = conn.interest.inbox.clone();
    let mut harnesses = hub.subscribe_harness_changes();
    let mut peer_states = hub.peer_states().subscribe();
    let mut catalog = hub.catalog.subscribe();
    let mut inventory = hub.health.inventory_changes();
    let mut presence = hub.presence.subscribe();
    tokio::spawn(async move {
        loop {
            let ev = tokio::select! {
                ev = rx.recv() => ev,
                // A turn's answer waits for the events queued before it (`Flush`).
                Some(ask) = flushes.asked() => {
                    loop {
                        match rx.try_recv() {
                            Ok(ev) => super::follow::event(&hub, &conn, ev).await,
                            Err(broadcast::error::TryRecvError::Lagged(n)) => {
                                lapped(&hub, &conn, n).await
                            }
                            Err(_) => break,
                        }
                    }
                    flushes.served(ask);
                    continue;
                }
                note = harnesses.recv() => {
                    match note {
                        Ok(note) if conn.watch_all.load(Ordering::SeqCst) => {
                            harness_admin::watch_note(&conn, note)
                        }
                        // Lagged: a newer change follows with the full list.
                        Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                    continue;
                }
                // A peer link's state, to watchers, through the same `watch_note` (`peer_states.rs`).
                // Never to a peer daemon's connection: its handshake watches, and this host's
                // peers, their states and their errors are this machine's, not that peer's.
                note = peer_states.recv() => {
                    let hears = conn.origin != super::Origin::Peer
                        && conn.watch_all.load(Ordering::SeqCst);
                    match note {
                        Ok(note) if hears => harness_admin::watch_note(&conn, note),
                        // Fell behind: a note carries one change, so each peer's last one again.
                        Err(broadcast::error::RecvError::Lagged(_)) if hears => {
                            for note in hub.peer_states().snapshot() {
                                harness_admin::watch_note(&conn, note);
                            }
                        }
                        Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                    continue;
                }
                // Every connection hears a catalog change: no watch or attach is needed.
                changed = catalog.recv() => {
                    match changed {
                        Ok(summary) => conn.send(&Message::notification(crate::catalog::EVENT_CHANGED, summary)),
                        Err(broadcast::error::RecvError::Lagged(_)) => conn.send(&Message::notification(
                            crate::catalog::EVENT_CHANGED, hub.catalog.summary(),
                        )),
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                    continue;
                }
                // Who has a chat open (`hub/presence.rs`), to the connections attached to it.
                note = presence.recv() => {
                    match note {
                        Ok(note) => send_presence(&conn, &note),
                        // Fell behind: the chats it holds, as they are now.
                        Err(broadcast::error::RecvError::Lagged(_)) => {
                            for chat in conn.local_attached_ids() {
                                send_presence(&conn, &hub.presence.snapshot(&chat));
                            }
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                    continue;
                }
                changed = inventory.changed() => {
                    if changed.is_err() { break; }
                    inventory_watch::send_latest(&conn, &mut inventory).await;
                    continue;
                }
            };
            match ev {
                Ok(ev) => super::follow::event(&hub, &conn, ev).await,
                Err(broadcast::error::RecvError::Lagged(n)) => lapped(&hub, &conn, n).await,
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    })
}

/// `_acpmux/presence` for a chat of this daemon's that `conn` is attached to (not a peer's chat
/// with the same raw id); never to a peer daemon's link, which does not carry presence
/// (`hub/presence.rs`).
fn send_presence(conn: &Conn, note: &serde_json::Value) {
    if conn.origin == super::Origin::Peer {
        return;
    }
    let attached = note
        .get("sessionId")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|chat| conn.sub_opts(chat).is_some_and(|opts| !opts.remote));
    if attached {
        conn.send(&Message::notification(crate::rpc::method::MUX_PRESENCE, note.clone()));
    }
}

/// The fan-out task of `conn` ended while its connection was still open: a panic in a delivery,
/// or the hub's feed closed. The connection ends with it (`serve_connection_from`), never lives on answering
/// requests with no pushes, which left an attached chat standing still with no close.
pub(super) fn ended(conn: &Conn, ended: Result<(), tokio::task::JoinError>) {
    match ended {
        Err(error) if error.is_panic() => {
            tracing::error!(conn = %conn.id, "the connection's fan-out task panicked: it is disconnected");
        }
        _ => {
            tracing::warn!(conn = %conn.id, "the connection's fan-out task ended: it is disconnected")
        }
    }
}

/// `_acpmux/lagged` for `dropped` hub events this connection's fan-out fell behind on. A watcher
/// that asked for peer row batches is told its watch lost notices too (`watch: true`): it follows
/// the list from its cursor for them, a batch's close among them (`peer_rows_changed`). Every
/// other connection gets the note as before.
fn lagged(conn: &Conn, dropped: u64) -> serde_json::Value {
    let watch =
        conn.peer_row_batches.load(Ordering::SeqCst) && conn.watch_all.load(Ordering::SeqCst);
    if watch { json!({"dropped": dropped, "watch": true}) } else { json!({"dropped": dropped}) }
}

#[cfg(test)]
pub(super) mod tests {
    /// A chat id with this prefix panics the fan-out task at its first delivery: no shared state,
    /// so parallel tests never trip each other (the test-hooks check, cmux#41350).
    pub(in crate::server) const PANIC_PREFIX: &str = "fanout-test-panic-";

    pub(super) fn panic_if_marked(session: &str) {
        if session.starts_with(PANIC_PREFIX) {
            panic!("fan-out test panic for {session}");
        }
    }

    /// A connection named with this prefix (its `initialize` `clientInfo.name`) has the hub
    /// events its fan-out task woke for counted under that name (`fanout_interest_tests.rs`). A
    /// name is one test's own, so parallel tests never read each other's counts.
    pub(in crate::server) const WAKE_PREFIX: &str = "fanout-wake-";

    static WAKES: std::sync::LazyLock<std::sync::Mutex<std::collections::HashMap<String, u64>>> =
        std::sync::LazyLock::new(Default::default);

    pub(super) fn count_wake(conn: &super::Conn) {
        let name = conn.name.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if name.starts_with(WAKE_PREFIX) {
            *WAKES.lock().unwrap_or_else(|e| e.into_inner()).entry(name).or_default() += 1;
        }
    }

    /// A stalled fan-out holds two counts however many turns ask it to flush (RFD 0124 R4), and
    /// its one drain answers every ask made before it, none waiting out `FLUSH_BOUND`.
    #[tokio::test]
    async fn flush_asks_coalesce_while_the_fan_out_is_stalled() {
        let (flush, mut flushes) = super::Flush::channel();
        let flush = std::sync::Arc::new(flush);
        let started = std::time::Instant::now();
        let waits: Vec<_> = (0..10_000)
            .map(|_| {
                let flush = flush.clone();
                tokio::spawn(async move { flush.sent().await })
            })
            .collect();
        while *flush.asked.borrow() < 10_000 {
            tokio::task::yield_now().await;
        }
        assert_eq!(flushes.asked().await, Some(10_000), "one wake for every ask");
        flushes.served(10_000);
        for wait in waits {
            wait.await.expect("ask");
        }
        assert!(started.elapsed() < super::FLUSH_BOUND, "an ask waited out its bound");
        // An ask after the drain waits for the next one.
        let next = tokio::spawn({
            let flush = flush.clone();
            async move { flush.sent().await }
        });
        assert_eq!(flushes.asked().await, Some(10_001));
        assert!(!next.is_finished());
        flushes.served(10_001);
        next.await.expect("next ask");
    }

    /// An ended fan-out answers an ask at once, as a closed channel did.
    #[tokio::test]
    async fn a_flush_after_the_fan_out_ended_returns_at_once() {
        let (flush, flushes) = super::Flush::channel();
        drop(flushes);
        let started = std::time::Instant::now();
        flush.sent().await;
        assert!(started.elapsed() < super::FLUSH_BOUND);
    }

    /// Hub events the fan-out of the connection named `name` woke for.
    pub(in crate::server) fn wakes(name: &str) -> u64 {
        WAKES.lock().unwrap_or_else(|e| e.into_inner()).get(name).copied().unwrap_or(0)
    }
}
