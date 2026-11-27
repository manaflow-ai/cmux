//! The requests in flight when the daemon stops (cmuxterm-hq #19255, findings 2026-11-22
//! section 2). The hub's close (`Hub::close_owned_tasks_until`) cancels the connections' scopes,
//! but a request's task does not watch its scope, so every one still running then was aborted at
//! the deadline and its client read the connection's end with no answer: 479 requests over 34
//! stops, up to 43 at once ("N task(s) ignored the cancellation and were aborted at the deadline:
//! conn-request, ...").
//!
//! Before that close, [`drain_in_flight`]:
//!
//! 1. waits up to [`FINISH_WITHIN`] (at most a quarter of what is left of the stop) for the
//!    requests in flight to finish on their own; a quick read is answered as it always was;
//! 2. answers each still in flight on every connection of the hub with [`restarting_error`]
//!    (`errorKind: daemon.restarting`, `retryable: true`), taken from its table as a cancel takes
//!    it (`InFlight::drain_at_shutdown`), so it is answered exactly once and its task ends at
//!    once; a request read after this is refused the same way (`Ticket::refused`). A long
//!    request (a prompt's turn, which the next daemon continues) never holds the stop: it is
//!    answered here, within the bound;
//! 3. waits up to [`FLUSH_WITHIN`] (at most half of what is left) for those answers to leave the
//!    connections' queues for their transports, since the close stops each queue's pump.
//!
//! The cost is one pass over the live connections and the requests they hold, and two waits with
//! fixed bounds inside the stop's own deadline.

use super::*;
use std::time::Duration;

/// The longest the stop waits for the requests in flight to finish on their own.
// timeout: a request still running then is answered as restarting; the stop goes on.
pub(crate) const FINISH_WITHIN: Duration = Duration::from_millis(250);
/// The longest the stop waits for the restart answers to leave the connections' queues.
// timeout: a client that does not read keeps its answer queued; the stop goes on.
pub(crate) const FLUSH_WITHIN: Duration = Duration::from_millis(200);
/// How often the waits look again: the gauges they read are atomics and queue lengths.
const LOOK: Duration = Duration::from_millis(5);

/// The answer to a request the daemon's stop cut: typed `daemon.restarting` as the shutdown's
/// refusals are (`recovery.rs`), so a client reconnects to the next daemon and sends it again
/// there; a prompt sent with its prompt id never runs twice. No `created` key: whether a create
/// cut here made its session is unknown.
pub(crate) fn restarting_error() -> RpcError {
    RpcError::new(-32000, "acpmux is restarting; this request was cut before its answer").with_data(
        json!({
            "reason": crate::recovery::kind::DAEMON_RESTARTING,
            "errorKind": crate::recovery::kind::DAEMON_RESTARTING,
            "recovery": "The daemon is restarting. Send the request again in a few seconds; a \
                         send with the same --prompt-id never runs twice.",
            "retryable": true,
        }),
    )
}

/// What [`drain_in_flight`] did.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Drained {
    /// Requests still in flight after the wait, answered with [`restarting_error`].
    pub answered: usize,
    /// Connections whose queue still held bytes at the flush bound.
    pub unflushed: usize,
}

/// The connections `hub` serves now.
fn conns_of(hub: &Hub) -> Vec<Arc<Conn>> {
    let mut conns = queue_gauge::live();
    conns.retain(|conn| conn.in_flight.counts_into(&hub.requests_in_flight));
    conns
}

/// Wait at most until `until` for `done`, looking every [`LOOK`].
async fn wait_for(until: tokio::time::Instant, mut done: impl FnMut() -> bool) -> bool {
    loop {
        if done() {
            return true;
        }
        let now = tokio::time::Instant::now();
        if now >= until {
            return false;
        }
        tokio::time::sleep_until(std::cmp::min(until, now + LOOK)).await;
    }
}

/// Drain the requests in flight on every connection of `hub` before its close, within
/// `deadline` (the stop's cleanup deadline). See the module's doc.
pub(crate) async fn drain_in_flight(hub: &Hub, deadline: tokio::time::Instant) -> Drained {
    let left = || deadline.saturating_duration_since(tokio::time::Instant::now());
    let now = tokio::time::Instant::now();
    let finish_by = now + std::cmp::min(FINISH_WITHIN, left() / 4);
    wait_for(finish_by, || hub.requests_in_flight() == 0).await;
    let mut drained = Drained::default();
    let mut answered_on = Vec::new();
    for conn in conns_of(hub) {
        let taken = conn.in_flight.drain_at_shutdown();
        if taken.is_empty() {
            continue;
        }
        for (id, method, dual) in taken {
            if let Some(key) = dual {
                dual_requests::cancel(&key);
            }
            conn.send_replying(&Message::err(id, restarting_error()), Some(&method));
            drained.answered += 1;
        }
        answered_on.push(conn);
    }
    let flush_by = tokio::time::Instant::now() + std::cmp::min(FLUSH_WITHIN, left() / 2);
    wait_for(flush_by, || {
        answered_on.iter().all(|c| c.out.is_closed() || c.out.gauge().bytes == 0)
    })
    .await;
    drained.unflushed =
        answered_on.iter().filter(|c| !c.out.is_closed() && c.out.gauge().bytes > 0).count();
    if drained.answered > 0 {
        tracing::info!(
            answered = drained.answered,
            unflushed = drained.unflushed,
            "shutdown: answered the requests still in flight as restarting"
        );
    }
    drained
}

/// An update may proceed only after the answers already queued have left every connection.
/// A slow reader defers the update instead of allowing shutdown to cut its response.
pub(super) async fn flush_before_update(hub: &Hub, deadline: tokio::time::Instant) -> bool {
    let conns = conns_of(hub);
    wait_for(deadline, || conns.iter().all(|c| c.out.is_closed() || c.out.gauge().bytes == 0)).await
}
