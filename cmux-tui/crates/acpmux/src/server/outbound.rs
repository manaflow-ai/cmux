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
//! The transport's channel is counted by its lines: the pump is its only sender (a WebSocket's
//! upload replies, `upload_frames.rs`, come through this queue too), so the lines it sent minus the
//! room the channel has again are the ones still there, oldest first. One slot is kept free for
//! the last line, which no other sender can take.
//!
//! Two lanes (cmuxterm-hq `docs/design/remote-cloud-durability.md` 4.6, F18): the answer to a
//! cheap read ([`is_cheap_read`]: identify, the session list, host health, status) goes in the
//! read lane, which the pump takes before anything else; every other line keeps its order in the
//! bulk lane. So the pump never lets the bulk lane hold more than [`BULK_WINDOW`] bytes in the
//! transport's channel: a replay of thousands of lines stays here, where a read answered after it
//! goes ahead, instead of in the channel, where it would wait behind all of them. A read's answer
//! shows nothing a line before it needs to have said: identify and status are about the daemon,
//! and the client keeps each list row with the higher `listSeq` (`hub/row_log.rs`).
//!
//! Stream lines (a chat's live `session/update` or `_acpmux/event`, [`Outbound::push_stream`])
//! are bounded far tighter: each is a journaled record the client can read again from its cursor,
//! so a reader that stops costs at most [`LAG_BOUND`], not the 64 MiB a list needs. A stream line
//! that would take the connection past it drops every stream line still queued and the line
//! itself, and one `_acpmux/lagged {dropped, reason: "slow_reader"}` takes the place of the first
//! one dropped: the client reads the note before anything that came after the hole, and reads the
//! chat again from its cursor (webviews `resyncAfterLag`, cmux-tui `agent_session_stream.rs`, a
//! peer daemon's link `hub/peers.rs`), as for a hub ring that lapped it (`fanout.rs`). Until the
//! transport's reader takes that note, later stream lines are dropped too: the client's read after
//! the note covers them. Replies, requests and every other line are never dropped. The share-host
//! subscriber queue does the same at its own 4 MiB (`share_host`).
//!
//! Every queue's bytes also count against [`TOTAL_BOUND`], one cap over every connection: past it,
//! a stream line resyncs a connection that holds more than [`LAG_FLOOR`], so a hundred slow
//! followers cannot together hold what one may not. A stream line shared by several connections
//! (the hub builds each record's line once, `HubEvent::lines`) is held once in memory and counted
//! in each connection that holds it.

use super::*;
use std::collections::VecDeque;
use std::sync::atomic::AtomicUsize;
use tokio::sync::{Notify, watch};

/// The bytes of the bulk lane the transport's channel may hold: what a read answered now waits
/// behind at most. 256 KiB is a few ms at link speed, and still many lines per wake of the pump.
pub(super) const BULK_WINDOW: usize = 256 << 10;

/// Whether the answer to `method` goes in the read lane ([module docs](self)).
pub(super) fn is_cheap_read(method: &str) -> bool {
    use crate::rpc::method;
    matches!(
        method,
        method::INITIALIZE
            | method::SESSION_LIST
            | method::MUX_SESSIONS
            | method::MUX_STATUS
            | method::MUX_HARNESS_HEALTH
            | "_acpmux/host_health"
    )
}

/// The lane of `msg`, the answer to a request whose method is `reply_to` when it is one.
pub(super) fn reply_lane(msg: &Message, reply_to: Option<&str>) -> Lane {
    match (msg, reply_to) {
        (Message::Response { .. }, Some(m)) if is_cheap_read(m) => Lane::Read,
        _ => Lane::Bulk,
    }
}

/// The lane of a line serialized for `method` (a list or status answer sent as one line).
pub(super) fn method_lane(method: Option<&str>) -> Lane {
    match method {
        Some(m) if is_cheap_read(m) => Lane::Read,
        _ => Lane::Bulk,
    }
}

/// Which lane a line goes in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Lane {
    Read,
    Bulk,
}

/// The bytes one connection may have queued and not yet read: two lines of the largest size
/// ([`crate::rpc::MAX_MESSAGE_BYTES`]) and change, so a whole list and the stream behind it fit.
pub(super) const OUTBOUND_BYTE_BOUND: usize = 64 << 20;

/// The bytes a connection may hold before its queued stream lines are dropped for a resync
/// ([module docs](self)): 2 MiB, eight [`BULK_WINDOW`]s, so a reader that keeps up never comes
/// near it, and 1/32 of [`OUTBOUND_BYTE_BOUND`].
pub(super) const LAG_BOUND: usize = 2 << 20;

/// Bytes queued over every connection past which a stream line resyncs its connection when that
/// connection holds more than [`LAG_FLOOR`].
pub(super) const TOTAL_BOUND: usize = 64 << 20;

/// What a connection may hold and still take stream lines once [`TOTAL_BOUND`] is passed: two
/// [`BULK_WINDOW`]s, what a reader that keeps up holds at most.
pub(super) const LAG_FLOOR: usize = 2 * BULK_WINDOW;

/// Bytes queued over every connection past which a line that is not a stream line ends a
/// connection that holds more than [`LAG_BOUND`] ([`Overrun`]): the backstop over the
/// per-connection [`OUTBOUND_BYTE_BOUND`].
pub(super) const TOTAL_HARD_BOUND: usize = 512 << 20;

/// Connections ended because their reader fell [`OUTBOUND_BYTE_BOUND`] behind, since the daemon
/// started (`daemon status`, `gauges.queues.overruns`).
pub(crate) static OVERRUNS: AtomicU64 = AtomicU64::new(0);

/// Bytes held by every connection's queue now (`gauges.queues.held`).
pub(crate) static TOTAL_HELD: AtomicUsize = AtomicUsize::new(0);

/// Resync notes sent for a slow reader ([module docs](self)), since the daemon started
/// (`gauges.queues.slowReaderResyncs`).
pub(crate) static SLOW_RESYNCS: AtomicU64 = AtomicU64::new(0);

/// Stream lines dropped for a slow reader, since the daemon started
/// (`gauges.queues.streamLinesDropped`).
pub(crate) static STREAM_DROPS: AtomicU64 = AtomicU64::new(0);

/// The note that takes the place of the stream lines a slow reader's queue dropped.
fn slow_reader_note(dropped: usize) -> String {
    Message::notification("_acpmux/lagged", json!({"dropped": dropped, "reason": "slow_reader"}))
        .to_line()
}

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
    /// The bulk lane.
    queue: VecDeque<Line>,
    /// The read lane, taken first.
    reads: VecDeque<Line>,
    /// Bytes queued and not yet taken by the transport's reader: both lanes, the pump's
    /// lines, and [`State::sent`].
    held: usize,
    /// The sizes of the lines the pump sent to the transport that may still be in its channel,
    /// oldest first.
    sent: VecDeque<Sent>,
    /// The sum of [`State::sent`].
    sent_bytes: usize,
    /// Lines the pump took and has not sent yet (waiting for the durable gate, or for room).
    taken: usize,
    /// The transport, to read its room. Weak: once the pump ends, nothing holds it open.
    transport: mpsc::WeakSender<String>,
    capacity: usize,
    /// Every handle is gone: the pump sends what is left and ends.
    finished: bool,
    overrun: Option<Overrun>,
    /// The pump ended (its transport closed, the journal's writer ended, the daemon is stopping,
    /// or it overran): nothing queued now would ever be sent.
    ended: bool,
    /// A slow-reader note is queued, or sent and not yet taken by the transport's reader: stream
    /// lines are dropped until it is ([module docs](self)).
    lagging: bool,
}

/// A line sent to the transport that may still be in its channel.
struct Sent {
    size: usize,
    _ticket: Option<super::controls::Ticket>,
    /// The slow-reader note: once the reader takes it, stream lines are queued again.
    resync: bool,
}

impl Drop for State {
    fn drop(&mut self) {
        TOTAL_HELD.fetch_sub(self.held, Ordering::Relaxed);
    }
}

impl State {
    fn add_held(&mut self, bytes: usize) {
        self.held += bytes;
        TOTAL_HELD.fetch_add(bytes, Ordering::Relaxed);
    }

    fn sub_held(&mut self, bytes: usize) {
        let bytes = bytes.min(self.held);
        self.held -= bytes;
        TOTAL_HELD.fetch_sub(bytes, Ordering::Relaxed);
    }

    /// Forgets the lines the transport's reader took since the last look.
    fn settle(&mut self) {
        let Some(transport) = self.transport.upgrade() else {
            return;
        };
        let in_channel = self.capacity.saturating_sub(transport.capacity());
        while self.sent.len() > in_channel {
            let Some(sent) = self.sent.pop_front() else { break };
            self.sent_bytes -= sent.size;
            self.sub_held(sent.size);
            if sent.resync {
                self.lagging = false;
            }
        }
    }

    /// Drops every stream line in the bulk lane and puts one slow-reader note where the first
    /// was ([module docs](self)); `incoming` more were dropped before they were queued.
    fn resync(&mut self, incoming: usize) {
        let mut first = None;
        let (mut dropped, mut freed) = (incoming, 0);
        let mut kept = VecDeque::with_capacity(self.queue.len());
        for line in self.queue.drain(..) {
            if line.kind == Kind::Stream {
                first.get_or_insert(kept.len());
                dropped += 1;
                freed += line.text.len();
            } else {
                kept.push_back(line);
            }
        }
        self.sub_held(freed);
        let note =
            Line { text: slow_reader_note(dropped).into(), ticket: None, kind: Kind::Resync };
        self.add_held(note.text.len());
        kept.insert(first.unwrap_or(kept.len()), note);
        self.queue = kept;
        self.lagging = true;
        SLOW_RESYNCS.fetch_add(1, Ordering::Relaxed);
        STREAM_DROPS.fetch_add(dropped as u64, Ordering::Relaxed);
        tracing::debug!(
            dropped,
            freed,
            held = self.held,
            "a slow reader's stream lines were dropped for a resync"
        );
    }

    /// Lines lost for good: the pump ended or the connection overran.
    fn clear(&mut self) {
        let queued: usize =
            self.queue.iter().chain(self.reads.iter()).map(|line| line.text.len()).sum();
        self.sub_held(queued);
        self.queue = VecDeque::new();
        self.reads = VecDeque::new();
    }

    /// Takes the read lane, then the bulk lane while the transport's channel holds less than
    /// `window` bytes (at least one line into an empty channel, whatever its size).
    fn take_into(&mut self, batch: &mut Vec<Line>, window: usize) -> Taken {
        let mut took = self.reads.len();
        batch.extend(self.reads.drain(..));
        if !self.queue.is_empty() {
            self.settle();
            let mut ahead = self.sent_bytes;
            while let Some(line) = self.queue.front() {
                if ahead >= window || (ahead > 0 && ahead + line.text.len() > window) {
                    break;
                }
                ahead += line.text.len();
                took += 1;
                batch.extend(self.queue.pop_front());
            }
        }
        self.taken += took;
        if took > 0 {
            Taken::Lines
        } else if !self.queue.is_empty() {
            Taken::WindowFull
        } else if self.finished {
            Taken::Done
        } else {
            Taken::Empty
        }
    }
}

/// What [`State::take_into`] found.
enum Taken {
    Lines,
    /// Only bulk lines wait, and the transport's channel holds its window.
    WindowFull,
    Empty,
    /// Every handle is gone and both lanes are empty.
    Done,
}

struct Shared {
    state: StdMutex<State>,
    /// The pump has lines to take, the last handle is gone, or the queue overran.
    wake: Notify,
    /// True once the queue overran or its pump ended.
    closed: watch::Sender<bool>,
    bound: usize,
    /// [`LAG_BOUND`], or the whole bound when that is smaller.
    lag_bound: usize,
}

impl Shared {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Queues `line` in `lane` with the lock held; false (and nothing queued) once it overran.
    fn push_locked(&self, state: &mut State, line: Line, lane: Lane) -> bool {
        if state.overrun.is_some() || state.ended {
            return false;
        }
        let size = line.text.len();
        let over = |state: &State| {
            state.held + size > self.bound
                || (state.held + size > self.lag_bound
                    && TOTAL_HELD.load(Ordering::Relaxed) + size > TOTAL_HARD_BOUND)
        };
        if over(state) {
            state.settle();
        }
        if over(state) {
            let overrun = Overrun { held: state.held };
            tracing::warn!(
                held = state.held,
                line = size,
                bound = self.bound,
                "a connection's reader fell past its byte bound: it is disconnected"
            );
            OVERRUNS.fetch_add(1, Ordering::Relaxed);
            state.overrun = Some(overrun);
            state.clear();
            // What the pump took and holds is never sent either.
            let pending = state.held.saturating_sub(state.sent_bytes);
            state.sub_held(pending);
            self.closed.send_replace(true);
            self.wake.notify_one();
            return false;
        }
        state.add_held(size);
        match lane {
            Lane::Read => state.reads.push_back(line),
            Lane::Bulk => state.queue.push_back(line),
        }
        self.wake.notify_one();
        true
    }

    /// Queues a stream line, or drops it for a resync ([module docs](self)); false once the
    /// connection overran or its pump ended.
    fn push_stream_locked(&self, state: &mut State, text: Text) -> bool {
        if state.overrun.is_some() || state.ended {
            return false;
        }
        let size = text.len();
        let over = |state: &State| {
            state.lagging
                || state.held + size > self.lag_bound
                || (state.held + size > LAG_FLOOR.min(self.lag_bound)
                    && TOTAL_HELD.load(Ordering::Relaxed) + size > TOTAL_BOUND)
        };
        if over(state) {
            state.settle();
        }
        if !over(state) {
            let line = Line { text, ticket: None, kind: Kind::Stream };
            return self.push_locked(state, line, Lane::Bulk);
        }
        if state.lagging {
            STREAM_DROPS.fetch_add(1, Ordering::Relaxed);
        } else {
            state.resync(1);
            self.wake.notify_one();
        }
        true
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
        self.push_in(line, Lane::Bulk)
    }

    pub(super) fn push_in(&mut self, line: String, lane: Lane) -> bool {
        self.shared.push_locked(&mut self.state, Line::new(line, None), lane)
    }
}

/// A line's bytes: its own, or one line shared by every connection that sends it (a record's
/// stream line, `HubEvent::lines`), copied only as it goes into the transport's channel.
pub(super) enum Text {
    Owned(String),
    Shared(Arc<str>),
}

impl Text {
    pub(super) fn len(&self) -> usize {
        match self {
            Text::Owned(text) => text.len(),
            Text::Shared(text) => text.len(),
        }
    }

    fn into_string(self) -> String {
        match self {
            Text::Owned(text) => text,
            Text::Shared(text) => text.as_ref().to_owned(),
        }
    }
}

impl From<String> for Text {
    fn from(text: String) -> Self {
        Text::Owned(text)
    }
}

/// What a queued line is, for what a slow reader may drop ([module docs](self)).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Kind {
    /// Never dropped.
    Kept,
    /// A chat's live record, read again after a resync: dropped for a slow reader.
    Stream,
    /// The slow-reader note.
    Resync,
}

/// A control ticket stays held through the pump and the transport channel.
pub(super) struct Line {
    pub(super) text: Text,
    pub(super) ticket: Option<super::controls::Ticket>,
    pub(super) kind: Kind,
}

impl Line {
    pub(super) fn new(text: String, ticket: Option<super::controls::Ticket>) -> Self {
        Line { text: Text::Owned(text), ticket, kind: Kind::Kept }
    }
}

impl Outbound {
    pub(super) fn push_control(&self, line: Line) -> bool {
        self.shared.push_locked(&mut self.shared.lock(), line, Lane::Bulk)
    }

    pub(super) fn settle(&self) {
        self.shared.lock().settle();
    }

    /// Queues `line` in the bulk lane; false when the connection overran or its reader is gone.
    pub(super) fn push(&self, line: String) -> bool {
        self.lock().push(line)
    }

    /// [`Self::push`] into `lane`.
    pub(super) fn push_in(&self, line: String, lane: Lane) -> bool {
        self.lock().push_in(line, lane)
    }

    /// Queues a chat's live record line, which a slow reader's queue drops for one resync note
    /// ([module docs](self)); false when the connection overran or its reader is gone.
    // perf-hot: 1us acpmux-token-fanout (every streamed token, per attached connection)
    pub(super) fn push_stream(&self, text: Text) -> bool {
        self.shared.push_stream_locked(&mut self.shared.lock(), text)
    }

    pub(super) fn lock(&self) -> Queue<'_> {
        Queue { shared: &self.shared, state: self.shared.lock() }
    }

    /// The reader is gone, the queue ended the connection, or its pump ended.
    pub(super) fn is_closed(&self) -> bool {
        let state = self.shared.lock();
        state.overrun.is_some()
            || state.ended
            || state.transport.upgrade().is_none_or(|t| t.is_closed())
    }

    /// Resolves once the queue overran ([`Overrun`]) or its pump ended, which it does when the
    /// reader is gone: no line queued after it would be sent. Holds no sender of the transport,
    /// so a wait here never keeps the connection open.
    pub(super) async fn closed(&self) {
        let mut closed = self.shared.closed.subscribe();
        let _ = closed.wait_for(|c| *c).await;
    }

    /// Bytes queued and not yet read.
    #[cfg(test)]
    pub(super) fn held(&self) -> usize {
        self.gauge().bytes
    }

    /// What the queue holds now, for `daemon status` (`queue_gauge.rs`).
    pub(super) fn gauge(&self) -> Gauge {
        let mut state = self.shared.lock();
        state.settle();
        Gauge {
            lines: state.queue.len() + state.reads.len() + state.taken + state.sent.len(),
            bytes: state.held,
            bound: self.shared.bound,
            overrun: state.overrun.is_some(),
            lagging: state.lagging,
        }
    }
}

/// A connection's queue as `daemon status` shows it.
pub(super) struct Gauge {
    /// Lines queued, held by the pump (the durable gate holds them for the journal), or in the
    /// transport's channel.
    pub(super) lines: usize,
    /// Bytes queued and not yet read: what counts against `bound`.
    pub(super) bytes: usize,
    pub(super) bound: usize,
    /// It fell past `bound` and its connection is ending.
    pub(super) overrun: bool,
    /// Its stream lines were dropped for a resync it has not read yet.
    pub(super) lagging: bool,
}

/// What moves a connection's lines to its transport: the plain pump, or the durable gate
/// (`durable_gate.rs`), which waits for the journal between taking and sending. Dropped, however
/// its task ends, it closes the queue; after an overrun its last line goes into the slot kept for
/// it first.
pub(super) struct Pump {
    shared: Arc<Shared>,
    transport: mpsc::Sender<String>,
}

impl Drop for Pump {
    fn drop(&mut self) {
        let mut state = self.shared.lock();
        if let Some(overrun) = state.overrun {
            let _ = self.transport.try_send(overrun.last_line(self.shared.bound));
        }
        state.ended = true;
        state.clear();
        // Nothing more is sent, and what the channel holds goes with its receiver.
        let held = state.held;
        state.sub_held(held);
        state.sent.clear();
        state.sent_bytes = 0;
        state.taken = 0;
        drop(state);
        self.shared.closed.send_replace(true);
    }
}

impl Pump {
    /// Takes the read lane's lines, then the bulk lane's that fit [`BULK_WINDOW`] ([module
    /// docs](self)), into `batch`, waiting until there is one; false once there is nothing more
    /// to send (every handle is gone and both lanes are empty, or it overran).
    pub(super) async fn take(&self, batch: &mut Vec<Line>) -> bool {
        self.take_within(batch, BULK_WINDOW).await
    }

    pub(super) async fn take_within(&self, batch: &mut Vec<Line>, window: usize) -> bool {
        loop {
            let taken = {
                let mut state = self.shared.lock();
                if state.overrun.is_some() {
                    return false;
                }
                state.take_into(batch, window)
            };
            match taken {
                Taken::Lines => return true,
                Taken::Done => return false,
                // `notify_one` keeps a permit when nobody waits, so a push between the check
                // and here is not missed.
                Taken::Empty => self.shared.wake.notified().await,
                // Until a read comes or the reader empties the channel. The pump is the
                // channel's only sender, so every slot free again means every line read.
                Taken::WindowFull => {
                    tokio::select! {
                        biased;
                        () = self.shared.wake.notified() => {}
                        room = self.transport.reserve_many(self.transport.max_capacity()) => {
                            if room.is_err() {
                                return false;
                            }
                        }
                    }
                }
            }
        }
    }

    /// Sends `line` to the transport once it has room, keeping its last slot free; false when its
    /// reader is gone or the queue overran.
    pub(super) async fn forward(&self, line: Line) -> bool {
        let keep = if self.transport.max_capacity() > 1 { 2 } else { 1 };
        let mut closed = self.shared.closed.subscribe();
        let room = tokio::select! {
            biased;
            _ = closed.wait_for(|c| *c) => return false,
            room = self.transport.reserve_many(keep) => room,
        };
        let Ok(mut room) = room else { return false };
        let Some(permit) = room.next() else { return false };
        let size = line.text.len();
        let text = line.text.into_string();
        let mut state = self.shared.lock();
        if state.overrun.is_some() {
            return false;
        }
        permit.send(text);
        state.taken = state.taken.saturating_sub(1);
        state.sent.push_back(Sent {
            size,
            _ticket: line.ticket,
            resync: line.kind == Kind::Resync,
        });
        state.sent_bytes += size;
        // Forget what the reader took meanwhile, so `sent` stays as short as the channel.
        state.settle();
        true
    }

    /// The transport is gone, or the queue overran: the pump stops.
    pub(super) async fn stopped(&self) {
        let mut closed = self.shared.closed.subscribe();
        tokio::select! {
            () = self.transport.closed() => {}
            _ = closed.wait_for(|c| *c) => {}
        }
    }

    async fn run(self) {
        let mut batch = Vec::new();
        'pump: loop {
            tokio::select! {
                biased;
                () = self.stopped() => break 'pump,
                more = self.take(&mut batch) => if !more { break 'pump },
            }
            for line in batch.drain(..) {
                if !self.forward(line).await {
                    break 'pump;
                }
            }
        }
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
    let (closed, _) = watch::channel(false);
    let shared = Arc::new(Shared {
        state: StdMutex::new(State {
            queue: VecDeque::new(),
            reads: VecDeque::new(),
            held: 0,
            sent: VecDeque::new(),
            sent_bytes: 0,
            taken: 0,
            transport: transport.downgrade(),
            capacity: transport.max_capacity(),
            finished: false,
            overrun: None,
            ended: false,
            lagging: false,
        }),
        wake: Notify::new(),
        closed,
        bound,
        lag_bound: LAG_BOUND.min(bound),
    });
    let pump = Pump { shared: Arc::clone(&shared), transport };
    let gate = match durability {
        Some(durability) => {
            let (gate, run) = durable_gate::install(durability, pump);
            scope.spawn_until_cancelled("conn-durable-gate", run);
            Some(gate)
        }
        None => {
            scope.spawn_until_cancelled("conn-outbound", pump.run());
            None
        }
    };
    (Arc::new(Outbound { shared }), gate)
}
