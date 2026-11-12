//! A connection's outbound queue, bounded in bytes (rework stage 3, cmuxterm-hq
//! `docs/design/acpmux-otp-rework.md` C1, C2, C4; moved out of `server/mod.rs`, which is over its
//! size budget).
//!
//! Every line a connection sends (a reply, a request, a notification) goes into one queue, in
//! order, and one pump task moves it to the transport (the socket's or WebSocket's writer). The
//! queue counts the bytes of every line from the moment it is queued until the transport's
//! reader takes it: lines in the queue, lines the pump holds (waiting for the durable gate, or for
//! room in the transport), and lines in the transport's own channel. A reply never waits in a task
//! of its own, so a client that asks and does not read holds no memory past the bound.
//!
//! A line that would take the count past [`OUTBOUND_BYTE_BOUND`] ends the connection instead
//! ([`Overrun`]): the queue drops what it holds, the transport gets one last line naming why
//! (`reader.too_slow`), and the connection's request loop stops. Nothing is dropped from the
//! middle of the stream, so the client never sees a gap: it reconnects and reads from its cursor.
//! Before this a slow reader cost up to 4,096 lines of up to 31 MiB each, plus every reply waiting
//! for room, with no bound at all.
//!
//! The transport's channel is counted by its lines: the pump is its only sender, so the lines it
//! sent minus the room the channel has again are the ones still there, oldest first. One slot is
//! kept free for the last line.

use super::*;
use std::collections::VecDeque;
use tokio::sync::{Notify, watch};

/// The bytes one connection may have queued and not yet read: two lines of the largest size
/// ([`crate::rpc::MAX_MESSAGE_BYTES`]) and change, so a whole list and the stream behind it fit.
pub(super) const OUTBOUND_BYTE_BOUND: usize = 64 << 20;

/// Connections ended because their reader fell [`OUTBOUND_BYTE_BOUND`] behind, since the daemon
/// started (`daemon status`, `outboundOverruns`).
pub(crate) static OVERRUNS: AtomicU64 = AtomicU64::new(0);

/// Why a connection's queue ended it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Overrun {
    /// What it held when the line that did not fit came.
    pub(super) held: usize,
}

impl Overrun {
    /// The connection's last line: an error with no id, as a line over the limit ends a socket
    /// connection (`stream.rs`).
    fn last_line(&self, bound: usize) -> String {
        let error = RpcError::new(
            -32000,
            format!(
                "this connection fell more than {} MiB behind; reconnect and read from your cursor",
                bound >> 20
            ),
        )
        .with_data(json!({
            "reason": "reader.too_slow",
            "limit": bound,
            "held": self.held,
            "retryable": true,
        }));
        Message::err(Value::Null, error).to_line()
    }
}

/// The queue's state, under its one lock.
struct State {
    queue: VecDeque<String>,
    /// Bytes queued and not yet taken by the transport's reader: [`State::queue`], the pump's
    /// lines, and [`State::sent`].
    held: usize,
    /// The sizes of the lines the pump sent to the transport that may still be in its channel,
    /// oldest first.
    sent: VecDeque<usize>,
    /// The transport, to read its room. Weak: once the pump ends, nothing holds it open.
    transport: mpsc::WeakSender<String>,
    capacity: usize,
    /// Every handle is gone: the pump sends what is left and ends.
    finished: bool,
    overrun: Option<Overrun>,
}

impl State {
    /// Forgets the lines the transport's reader took since the last look.
    fn settle(&mut self) {
        let Some(transport) = self.transport.upgrade() else {
            return;
        };
        let in_channel = self.capacity.saturating_sub(transport.capacity());
        while self.sent.len() > in_channel {
            let Some(size) = self.sent.pop_front() else { break };
            self.held = self.held.saturating_sub(size);
        }
    }
}

struct Shared {
    state: StdMutex<State>,
    /// The pump has lines to take, the last handle is gone, or the queue overran.
    wake: Notify,
    overrun: watch::Sender<bool>,
    bound: usize,
}

impl Shared {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Queues `line` with the lock held; false (and nothing queued) once it overran.
    fn push_locked(&self, state: &mut State, line: String) -> bool {
        if state.overrun.is_some() {
            return false;
        }
        let size = line.len();
        if state.held + size > self.bound {
            state.settle();
        }
        if state.held + size > self.bound {
            let overrun = Overrun { held: state.held };
            tracing::warn!(
                held = state.held,
                line = size,
                bound = self.bound,
                "a connection's reader fell past its byte bound: it is disconnected"
            );
            OVERRUNS.fetch_add(1, Ordering::Relaxed);
            state.overrun = Some(overrun);
            state.held = state.sent.iter().sum();
            state.queue = VecDeque::new();
            self.overrun.send_replace(true);
            self.wake.notify_one();
            return false;
        }
        state.held += size;
        state.queue.push_back(line);
        self.wake.notify_one();
        true
    }

    /// Takes every queued line into `batch`; false once there is nothing more to send (every
    /// handle is gone and the queue is empty, or it overran).
    async fn take(&self, batch: &mut Vec<String>) -> bool {
        loop {
            {
                let mut state = self.lock();
                if state.overrun.is_some() {
                    return false;
                }
                if !state.queue.is_empty() {
                    batch.extend(state.queue.drain(..));
                    return true;
                }
                if state.finished {
                    return false;
                }
            }
            // `notify_one` keeps a permit when nobody waits, so a push between the check and
            // here is not missed.
            self.wake.notified().await;
        }
    }
}

/// A connection's handle on its queue. The last one dropped lets the pump send what is left and
/// end, which closes the transport, as dropping the last sender of a channel did.
pub(super) struct Outbound {
    shared: Arc<Shared>,
}

impl Drop for Outbound {
    fn drop(&mut self) {
        self.shared.lock().finished = true;
        self.shared.wake.notify_one();
    }
}

/// The queue's lock, held across several lines that must go together (`Conn::send_serialized`
/// reads its notice count and queues under it).
pub(super) struct Queue<'a> {
    shared: &'a Shared,
    state: std::sync::MutexGuard<'a, State>,
}

impl Queue<'_> {
    pub(super) fn push(&mut self, line: String) -> bool {
        self.shared.push_locked(&mut self.state, line)
    }
}

impl Outbound {
    /// Queues `line`; false when the connection overran or its reader is gone.
    pub(super) fn push(&self, line: String) -> bool {
        self.lock().push(line)
    }

    pub(super) fn lock(&self) -> Queue<'_> {
        Queue { shared: &self.shared, state: self.shared.lock() }
    }

    /// The reader is gone, or the queue ended the connection.
    pub(super) fn is_closed(&self) -> bool {
        let state = self.shared.lock();
        state.overrun.is_some() || state.transport.upgrade().is_none_or(|t| t.is_closed())
    }

    /// Resolves once [`Self::is_closed`].
    pub(super) async fn closed(&self) {
        let transport = self.shared.lock().transport.upgrade();
        let mut overrun = self.shared.overrun.subscribe();
        match transport {
            Some(transport) => tokio::select! {
                () = transport.closed() => {}
                _ = overrun.wait_for(|o| *o) => {}
            },
            None => {}
        }
    }

    /// Resolves once the queue ended the connection ([`Overrun`]).
    pub(super) async fn overrun(&self) {
        let mut overrun = self.shared.overrun.subscribe();
        let _ = overrun.wait_for(|o| *o).await;
    }

    /// Bytes queued and not yet read.
    #[cfg(test)]
    pub(super) fn held(&self) -> usize {
        let mut state = self.shared.lock();
        state.settle();
        state.held
    }
}

/// What moves a connection's lines to its transport: the plain pump, or the durable gate
/// (`durable_gate.rs`), which waits for the journal between taking and sending.
pub(super) struct Pump {
    shared: Arc<Shared>,
    transport: mpsc::Sender<String>,
    overrun: watch::Receiver<bool>,
}

impl Pump {
    /// See [`Shared::take`].
    pub(super) async fn take(&mut self, batch: &mut Vec<String>) -> bool {
        self.shared.take(batch).await
    }

    /// Sends `line` to the transport once it has room, keeping its last slot free; false when its
    /// reader is gone or the queue overran.
    pub(super) async fn forward(&mut self, line: String) -> bool {
        let keep = if self.transport.max_capacity() > 1 { 2 } else { 1 };
        let room = tokio::select! {
            biased;
            _ = self.overrun.wait_for(|o| *o) => return false,
            room = self.transport.reserve_many(keep) => room,
        };
        let Ok(mut room) = room else { return false };
        let Some(permit) = room.next() else { return false };
        let size = line.len();
        let mut state = self.shared.lock();
        if state.overrun.is_some() {
            return false;
        }
        permit.send(line);
        state.sent.push_back(size);
        true
    }

    /// The transport is gone.
    pub(super) async fn transport_closed(&self) {
        self.transport.closed().await
    }

    /// Ends the pump: after an overrun, the last line goes into the slot kept for it.
    pub(super) fn end(self) {
        let state = self.shared.lock();
        if let Some(overrun) = state.overrun {
            let _ = self.transport.try_send(overrun.last_line(self.shared.bound));
        }
    }

    async fn run(mut self) {
        let mut batch = Vec::new();
        'pump: loop {
            tokio::select! {
                biased;
                () = self.transport.closed() => break 'pump,
                more = self.shared.take(&mut batch) => if !more { break 'pump },
            }
            for line in batch.drain(..) {
                if !self.forward(line).await {
                    break 'pump;
                }
            }
        }
        self.end();
    }
}

/// A connection's queue over `transport`, with its pump started on `scope`; with the journal on
/// (`durability`), the pump is the durable gate and its gate is returned too.
pub(super) fn start(
    scope: &cmux_scope::Scope,
    durability: Option<crate::store::Durability>,
    transport: mpsc::Sender<String>,
) -> (Arc<Outbound>, Option<Arc<durable_gate::Gate>>) {
    start_bounded(scope, durability, transport, OUTBOUND_BYTE_BOUND)
}

pub(super) fn start_bounded(
    scope: &cmux_scope::Scope,
    durability: Option<crate::store::Durability>,
    transport: mpsc::Sender<String>,
    bound: usize,
) -> (Arc<Outbound>, Option<Arc<durable_gate::Gate>>) {
    let (overrun, overrun_rx) = watch::channel(false);
    let shared = Arc::new(Shared {
        state: StdMutex::new(State {
            queue: VecDeque::new(),
            held: 0,
            sent: VecDeque::new(),
            transport: transport.downgrade(),
            capacity: transport.max_capacity(),
            finished: false,
            overrun: None,
        }),
        wake: Notify::new(),
        overrun,
        bound,
    });
    let pump = Pump { shared: Arc::clone(&shared), transport, overrun: overrun_rx };
    let gate = match durability {
        Some(durability) => {
            let (gate, run) = durable_gate::install(durability, pump);
            scope.spawn_named("conn-durable-gate", run);
            Some(gate)
        }
        None => {
            scope.spawn_named("conn-outbound", pump.run());
            None
        }
    };
    (Arc::new(Outbound { shared }), gate)
}
