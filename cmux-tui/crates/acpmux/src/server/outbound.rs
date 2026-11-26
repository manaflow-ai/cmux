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
//! A connection that reads the session list (not a peer daemon's link) does not end at its bound
//! while its queue holds list notices ([`LIST_NOTICE_PREFIX`]): each carries a chat's whole row,
//! which a newer notice or a read of the list replaces. They are left out of the bulk lane, and
//! one `_acpmux/lagged` (`watch: true`, reason `reader.too_slow`) goes after what is left, so the
//! client reads the list again from its cursor (webviews `resyncAfterLag`, cmux-tui-core
//! `agent_chat_notices.rs`, `AgentTurnStateFeed`). Every other line keeps its order. Only a
//! pass that frees at least a quarter of the bound counts, so each pass is paid for by the bytes
//! queued since the last, and a queue that still does not fit ends as before. On cosmic-gray,
//! 2026-11-22, the app's watchers (`cmux-tui-agent-chat-notices`, `cmux-next-turn-states`) reached
//! 64 MiB of rows of up to 82 KB each and were cut ten times in six minutes around Leo's chat
//! pane showing "reconnecting".
//!
//! Two lanes (cmuxterm-hq `docs/design/remote-cloud-durability.md` 4.6, F18): the answer to a
//! cheap read ([`is_cheap_read`]: identify, the session list, host health, status, the peer list
//! the agent pane probes the daemon's liveness with), or to a read an agent's tool call waits on
//! ([`is_tool_read`]), goes in the
//! read lane, which the pump takes before anything else; every other line keeps its order in the
//! bulk lane. So the pump never lets the bulk lane hold more than [`BULK_WINDOW`] bytes in the
//! transport's channel: a replay of thousands of lines stays here, where a read answered after it
//! goes ahead, instead of in the channel, where it would wait behind all of them. A read's answer
//! shows nothing a line before it needs to have said: identify and status are about the daemon,
//! and the client keeps each list row with the higher `listSeq` (`hub/row_log.rs`).
//!
//! A watcher's row (`_acpmux/session_changed` of a chat it did not attach) is the chat's whole row,
//! not a change to apply: a newer one says all an older one did, as a follow from the client's
//! cursor would ([`Row`]). So once a reader is behind (past [`COALESCE_FROM`] unread), a row still
//! queued is dropped when a newer one of the same chat comes, and the queue holds at most one per
//! chat. A reader that keeps up gets every row: each also names what changed (`kind`, a queued or
//! dequeued prompt), which a watcher waits on. Past [`ROW_BYTE_BOUND`] of them the connection
//! ends as at its own bound, and the client follows once from its cursor. Before this a reader
//! that fell behind held every row of every change: 224 MB on one Mac under heavy load
//! (2026-11-22), 62.8 MB of it in one watcher's 6,041 lines, all under the 64 MiB bound.

use super::*;
use std::collections::VecDeque;
use std::sync::atomic::AtomicUsize;
use std::time::{Duration, Instant};
use tokio::sync::{Notify, watch};

/// The bytes of the bulk lane the transport's channel may hold: what a read answered now waits
/// behind at most. 256 KiB is a few ms at link speed, and still many lines per wake of the pump.
pub(super) const BULK_WINDOW: usize = 256 << 10;

/// Whether the answer to `method` goes in the read lane ([module docs](self)).
pub(crate) fn is_cheap_read(method: &str) -> bool {
    use crate::rpc::method;
    matches!(
        method,
        method::INITIALIZE
            | method::SESSION_LIST
            | method::MUX_SESSIONS
            | method::MUX_STATUS
            | method::MUX_HARNESS_HEALTH
            | "_acpmux/host_health"
            | "_acpmux/host_overload"
            // The agent pane's liveness probe (webviews `direct.ts` `probeDaemon`): the pane gives
            // its socket up when this goes unanswered for 15 s, so behind a huge chat's replay a
            // busy but alive daemon had every pane cut and reattach at once.
            | "_acpmux/peers"
    )
}

/// Whether `method` is a read an agent's tool call waits on (`last`, `send_status`, `bg_output`,
/// `who_else`, a far machine's `machine_read`), whose answer goes in the read lane too (Leo,
/// 2026-11-25: "if we own the transport layer, could we also optimize for these cases?"). On a
/// peer link the far daemon answers these on the connection that carries its chats' replays and
/// streams, so in the bulk lane a tool call waited behind every replay line queued before it:
/// p99 1592 ms under 24 MiB of replays at 16 MiB/s (`outbound_queue_tests/flood_interactive.rs`).
/// Each is a page or a status read whole by the caller: a history or event page is merged by
/// `seq` (`agent_session_attach.rs` `bound_page`), so it needs no line ahead of it to have
/// arrived. `_acpmux/attach`, `wait` and `info` stay in order: their answers mark a stream position.
pub(crate) fn is_tool_read(method: &str) -> bool {
    use crate::rpc::method;
    matches!(
        method,
        method::MUX_EVENTS
            | method::MUX_HISTORY
            | method::MUX_SEND_STATUS
            | method::MUX_RESOLVE
            | method::MUX_SESSION_SEARCH
            | method::MUX_WHO_ELSE
            | method::MUX_MACHINE_INFO
            | method::MUX_MACHINE_FILES_CALL
            | method::MUX_COMPUTER_USE_STATE
            | method::MUX_BG_OUTPUT
            | method::MUX_BG_LIST
            | method::MUX_GOAL_GET
            | method::MUX_WATCH_LS
            | method::MUX_INBOX_THREADS
            | method::MUX_INBOX_THREAD
            | method::MUX_RACE_GET
            | method::MUX_RACE_LIST
            | method::MUX_GITHUB_PR_STATE
            | method::MUX_CHAT_TRANSCRIPT_PAGE
            | method::MUX_CHAT_TRANSCRIPT_FIND
    )
}

/// Whether the answer to a request for `method` goes ahead of the bulk lane.
pub(super) fn reads_ahead(method: &str) -> bool {
    is_cheap_read(method) || is_tool_read(method)
}

/// The lane of `msg`, the answer to a request whose method is `reply_to` when it is one.
pub(super) fn reply_lane(msg: &Message, reply_to: Option<&str>) -> Lane {
    match (msg, reply_to) {
        (Message::Response { .. }, Some(m)) if reads_ahead(m) => Lane::Read,
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

/// The bytes of rows ([`Row::Latest`]) one connection may have queued, one per chat at most: past
/// it the connection ends as at [`OUTBOUND_BYTE_BOUND`], and the client follows once from its
/// cursor, which costs it no more than these rows would.
pub(super) const ROW_BYTE_BOUND: usize = 4 << 20;

/// The bytes a connection holds unread past which its reader is behind and a chat's queued row is
/// replaced by its newer one ([`Row::Latest`]): about sixty rows. Under it every row is sent.
pub(super) const COALESCE_FROM: usize = 256 << 10;

/// What a line is to the rows the queue keeps one of per chat ([module docs](self)).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(super) enum Row {
    /// Any other line.
    #[default]
    None,
    /// The whole row of the chat it names (its key: the id, qualified for a peer's): it replaces
    /// that chat's row still queued.
    Latest(Arc<str>),
    /// A line about the chat that must come after its row queued before it (a permission ask, a
    /// purge): that row is kept, and a newer one queues after this.
    After(Arc<str>),
}

/// The bytes every connection's queue may hold together. Each connection alone may hold
/// [`OUTBOUND_BYTE_BOUND`], so a host with a few hundred readers (agents' CLIs, the app, peers)
/// could hold tens of GB before any one bound tripped: huge-blue's daemon reached 16.5 GB and
/// stopped answering (2026-11-20). Past this, a line for a connection that holds more than
/// [`FAIR_SHARE`] ends that connection, as its own bound would; one that holds less is still
/// served, so a cheap read's answer always goes out.
pub(super) const TOTAL_BYTE_BOUND: usize = 1 << 30;
/// What a connection may hold when the daemon is past [`TOTAL_BYTE_BOUND`].
pub(super) const FAIR_SHARE: usize = 4 << 20;
/// How long a reader over [`FAIR_SHARE`] may take nothing before the daemon-wide bound ends it.
/// One that is taking lines is slow, not stuck, and keeps its connection up to its own bound: on
/// cosmic-gray the cut fell on the app's coordinator chats mid-replay, each cut cost a re-attach of
/// the whole chat (99 s for the largest), and the re-attach queued the same bytes again
/// (cmuxterm-hq `docs/handbook/gui-chat-loses-its-agent-session.md`).
pub(super) const READER_STALL: Duration = Duration::from_secs(10);
/// The bytes every live queue holds now (the sum of their [`State::held`]).
pub(crate) static TOTAL_HELD: AtomicUsize = AtomicUsize::new(0);

/// The start of a list notice's line ([`crate::rpc::Message::to_line`] writes its keys sorted):
/// what a lagging reader that reads the list may be spared ([module docs](self)).
pub(super) const LIST_NOTICE_PREFIX: &str =
    r#"{"jsonrpc":"2.0","method":"_acpmux/session_changed","params":"#;

/// Times a lagging reader was spared its list notices instead of disconnected, since the daemon
/// started (`gauges.queues.listSheds`).
pub(crate) static LIST_SHEDS: AtomicU64 = AtomicU64::new(0);

/// The `_acpmux/lagged` a reader gets after `dropped` list notices were left out.
fn lag_marker(dropped: u64) -> String {
    Message::notification(
        "_acpmux/lagged",
        json!({"dropped": dropped, "watch": true, "reason": "reader.too_slow"}),
    )
    .to_line()
}

/// Connections ended because their reader fell [`OUTBOUND_BYTE_BOUND`] behind, since the daemon
/// started (`daemon status`, `gauges.queues.overruns`).
pub(crate) static OVERRUNS: AtomicU64 = AtomicU64::new(0);
/// Of [`OVERRUNS`], those the daemon-wide bound made ([`TOTAL_BYTE_BOUND`]: a stalled reader over
/// its fair share), not the connection's own (`gauges.queues.totalOverruns`). The GUI disconnect
/// detector reads the split (cmuxterm-hq `docs/handbook/gui-chat-loses-its-agent-session.md`).
pub(crate) static TOTAL_OVERRUNS: AtomicU64 = AtomicU64::new(0);

/// Why a connection's queue ended it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Overrun {
    /// What it held when the line that did not fit came.
    pub(super) held: usize,
    /// The bound it fell past: the connection's, or [`ROW_BYTE_BOUND`].
    pub(super) limit: usize,
}

impl Overrun {
    /// The connection's last line: an error with no id, as a line over the limit ends a socket
    /// connection (`stream.rs`).
    fn last_line(&self) -> String {
        let bound = self.limit;
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
    /// The bulk lane, its lines' [`Line::serial`] rising.
    queue: VecDeque<Line>,
    /// The serial the next bulk line gets.
    next_serial: u64,
    /// Each chat's row in [`State::queue`] ([`Row::Latest`]), by its key: the row's serial.
    rows: HashMap<Arc<str>, u64>,
    /// The bytes of the rows in [`State::rows`].
    row_bytes: usize,
    /// The read lane, taken first.
    reads: VecDeque<Line>,
    /// Bytes queued and not yet taken by the transport's reader: both lanes, the pump's
    /// lines, and [`State::sent`].
    held: usize,
    /// The sizes of the lines the pump sent to the transport that may still be in its channel,
    /// oldest first.
    sent: VecDeque<(usize, Option<super::controls::Ticket>)>,
    /// The sum of [`State::sent`].
    sent_bytes: usize,
    /// When the transport's reader last took a line, or the queue held nothing for it to take:
    /// the daemon-wide bound ends only a reader stalled past [`READER_STALL`].
    progress_at: Instant,
    /// Lines the pump took and has not sent yet (waiting for the durable gate, or for room).
    taken: usize,
    /// The transport, to read its room. Weak: once the pump ends, nothing holds it open.
    transport: mpsc::WeakSender<String>,
    capacity: usize,
    /// Every handle is gone: the pump sends what is left and ends.
    finished: bool,
    /// The sum [`State::held`] counts toward: [`TOTAL_HELD`], or a test's own.
    pool: &'static AtomicUsize,
    overrun: Option<Overrun>,
    /// The pump ended (its transport closed, the journal's writer ended, the daemon is stopping,
    /// or it overran): nothing queued now would ever be sent.
    ended: bool,
    /// Its list notices may be left out past the bound ([module docs](self)).
    sheds: bool,
    /// Who reads it, for the log: origin, client name, connection id.
    who: String,
    /// The bulk lane's bytes the transport's channel may hold: [`BULK_WINDOW`], or a peer
    /// link's own ([`Outbound::set_window`]).
    window: usize,
}

impl Drop for State {
    fn drop(&mut self) {
        self.set_held(0);
    }
}

impl State {
    /// Sets [`State::held`], keeping its pool ([`TOTAL_HELD`]) the sum over every queue.
    fn set_held(&mut self, held: usize) {
        if held >= self.held {
            self.pool.fetch_add(held - self.held, Ordering::Relaxed);
        } else {
            self.pool.fetch_sub(self.held - held, Ordering::Relaxed);
        }
        self.held = held;
    }

    /// Forgets the lines the transport's reader took since the last look.
    fn settle(&mut self) {
        let Some(transport) = self.transport.upgrade() else {
            return;
        };
        let in_channel = self.capacity.saturating_sub(transport.capacity());
        if self.sent.len() > in_channel {
            self.progress_at = Instant::now();
        }
        while self.sent.len() > in_channel {
            let Some((size, _ticket)) = self.sent.pop_front() else { break };
            self.sent_bytes -= size;
            self.set_held(self.held.saturating_sub(size));
        }
    }

    /// `line` left the bulk lane: its row, if it is one, is no longer queued.
    fn unrow(&mut self, line: &Line) {
        if let Row::Latest(key) = &line.row
            && self.rows.get(key) == Some(&line.serial)
        {
            self.rows.remove(key);
            self.row_bytes -= line.text.len();
        }
    }

    /// Drops `key`'s row still queued, a newer one coming ([`Row::Latest`]).
    fn drop_row(&mut self, key: &str) {
        let Some(serial) = self.rows.remove(key) else { return };
        if let Ok(at) = self.queue.binary_search_by_key(&serial, |line| line.serial)
            && let Some(old) = self.queue.remove(at)
        {
            self.row_bytes -= old.text.len();
            self.set_held(self.held - old.text.len());
        }
    }

    /// Keeps `key`'s queued row but no longer replaces it: the reader is not behind, so it gets it.
    fn forget_row(&mut self, key: &str) {
        let Some(serial) = self.rows.remove(key) else { return };
        if let Ok(at) = self.queue.binary_search_by_key(&serial, |line| line.serial)
            && let Some(old) = self.queue.get(at)
        {
            self.row_bytes -= old.text.len();
        }
    }

    /// Both lanes and the rows dropped (an overrun, or the pump ended).
    fn clear(&mut self) {
        self.queue = VecDeque::new();
        self.reads = VecDeque::new();
        self.rows = HashMap::new();
        self.row_bytes = 0;
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
                if let Some(line) = self.queue.pop_front() {
                    self.unrow(&line);
                    batch.push(line);
                }
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
    /// [`ROW_BYTE_BOUND`], or a test's.
    row_bound: usize,
    raised: Arc<Raised>,
    /// [`TOTAL_BYTE_BOUND`] and [`FAIR_SHARE`], or a test's.
    total_bound: usize,
    fair_share: usize,
    /// [`READER_STALL`], or a test's.
    reader_stall: Duration,
}

impl Shared {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Queues `line` in `lane` with the lock held; false (and nothing queued) once it overran.
    fn push_locked(&self, state: &mut State, mut line: Line, lane: Lane) -> bool {
        if state.overrun.is_some() || state.ended {
            return false;
        }
        // Read after the raise for this line (its caller raised first, `Conn::raise_gate`).
        line.needs = Needs {
            durable: self.raised.durable.load(Ordering::SeqCst),
            written: self.raised.written.load(Ordering::SeqCst),
        };
        let size = line.text.len();
        // A newer row says all the queued one did ([`Row`]); a line that must follow that one keeps it.
        let row = if lane == Lane::Bulk { line.row.clone() } else { Row::None };
        match &row {
            Row::Latest(key) if state.held >= COALESCE_FROM => state.drop_row(key),
            Row::Latest(key) => state.forget_row(key),
            Row::After(key) => state.forget_row(key),
            Row::None => {}
        }
        let over_rows = matches!(row, Row::Latest(_)) && state.row_bytes + size > self.row_bound;
        // A reader with nothing left to take is not behind.
        if state.held == 0 {
            state.progress_at = Instant::now();
        }
        let over_total = |state: &State| {
            state.held + size > self.fair_share
                && state.pool.load(Ordering::Relaxed) + size > self.total_bound
                && state.progress_at.elapsed() >= self.reader_stall
        };
        if state.held + size > self.bound || over_total(state) {
            state.settle();
        }
        let mut own = state.held + size > self.bound;
        if own && state.sheds {
            own = !self.shed_list_notices(state, size);
        }
        let own = own || over_rows;
        if own || over_total(state) {
            let limit = if over_rows { self.row_bound } else { self.bound };
            let overrun = Overrun { held: state.held, limit };
            tracing::warn!(
                who = %state.who,
                held = state.held,
                line = size,
                bound = limit,
                total = state.pool.load(Ordering::Relaxed),
                total_bound = self.total_bound,
                "{}",
                if own {
                    "a connection's reader fell past its byte bound: it is disconnected"
                } else {
                    "every connection's queues together are past their bound: this one, over its fair share, is disconnected"
                }
            );
            OVERRUNS.fetch_add(1, Ordering::Relaxed);
            if !own {
                TOTAL_OVERRUNS.fetch_add(1, Ordering::Relaxed);
            }
            state.overrun = Some(overrun);
            let in_channel = state.sent_bytes;
            state.set_held(in_channel);
            state.clear();
            self.closed.send_replace(true);
            self.wake.notify_one();
            return false;
        }
        let held = state.held + size;
        state.set_held(held);
        Self::queue_line(state, line, lane);
        self.wake.notify_one();
        true
    }

    fn queue_line(state: &mut State, mut line: Line, lane: Lane) {
        match lane {
            Lane::Read => state.reads.push_back(line),
            Lane::Bulk => {
                line.serial = state.next_serial;
                state.next_serial += 1;
                if let Row::Latest(key) = &line.row {
                    state.rows.insert(key.clone(), line.serial);
                    state.row_bytes += line.text.len();
                }
                state.queue.push_back(line);
            }
        }
    }

    /// Leaves the bulk lane's list notices out, and a lag marker from an earlier pass the reader
    /// has not taken yet, and queues one marker for all of them: true when that frees a quarter
    /// of the bound and the marker and a line of `size` then fit. Else changes nothing.
    fn shed_list_notices(&self, state: &mut State, size: usize) -> bool {
        let shed = |line: &Line| line.lag_marker > 0 || line.text.starts_with(LIST_NOTICE_PREFIX);
        let (mut freed, mut dropped) = (0usize, 0u64);
        for line in state.queue.iter().filter(|l| shed(l)) {
            freed += line.text.len();
            // A marker from an earlier pass stands for the notices it counted.
            dropped += line.lag_marker.max(1);
        }
        let marker = lag_marker(dropped);
        if freed < self.bound / 4 || state.held - freed + marker.len() + size > self.bound {
            return false;
        }
        // A shed row is no longer queued ([`State::unrow`]); the rest keep their order.
        for line in std::mem::take(&mut state.queue) {
            if shed(&line) {
                state.unrow(&line);
            } else {
                state.queue.push_back(line);
            }
        }
        LIST_SHEDS.fetch_add(1, Ordering::Relaxed);
        tracing::warn!(
            who = %state.who,
            held = state.held,
            freed,
            dropped,
            bound = self.bound,
            "a connection's reader fell past its byte bound: its list notices are left out and it reads the list again"
        );
        let held = state.held - freed + marker.len();
        state.set_held(held);
        let needs = Needs {
            durable: self.raised.durable.load(Ordering::SeqCst),
            written: self.raised.written.load(Ordering::SeqCst),
        };
        let marker = Line { text: marker, needs, lag_marker: dropped, ..Line::default() };
        Self::queue_line(state, marker, Lane::Bulk);
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
        self.push_row(line, lane, Row::None)
    }

    /// [`Self::push_in`] of a line that is a chat's row, or must follow it ([`Row`]).
    pub(super) fn push_row(&mut self, line: String, lane: Lane, row: Row) -> bool {
        let line = Line { text: line, row, ..Line::default() };
        self.shared.push_locked(&mut self.state, line, lane)
    }
}

/// A control ticket stays held through the pump and the transport channel.
#[derive(Default)]
pub(super) struct Line {
    pub(super) text: String,
    pub(super) ticket: Option<super::controls::Ticket>,
    /// What the journal must have reached before it goes out: set when it is queued.
    pub(super) needs: Needs,
    /// A lag marker's count of the list notices it stands for ([`Shared::shed_list_notices`]);
    /// 0 for every other line.
    pub(super) lag_marker: u64,
    /// A chat's row, or a line that must follow it ([`Row`]).
    pub(super) row: Row,
    /// Its place in the bulk lane: set when it is queued there.
    pub(super) serial: u64,
}

/// The journal's LSNs a line may show (`durable_gate.rs`): the connection's [`Raised`] when it
/// was queued, so it waits for the changes acknowledged before it, never for later ones.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct Needs {
    /// The acknowledged changes: their records durable.
    pub(super) durable: u64,
    /// The kept changes: their records written.
    pub(super) written: u64,
}

/// The highest LSNs a connection's lines raised so far (`durable_gate::Gate::raise`); every
/// line queued after a raise carries it ([`Needs`]). Zero without the journal.
#[derive(Default)]
pub(super) struct Raised {
    pub(super) durable: AtomicU64,
    pub(super) written: AtomicU64,
}

impl Outbound {
    pub(super) fn push_control(&self, line: Line) -> bool {
        self.shared.push_locked(&mut self.shared.lock(), line, Lane::Bulk)
    }

    pub(super) fn settle(&self) {
        self.shared.lock().settle();
    }

    /// Who reads this queue, for the log, and whether its list notices may be left out past its
    /// bound ([module docs](self)): never a peer daemon's link, whose mirror of this daemon's list
    /// reads it again only when it links again.
    pub(super) fn describe(&self, who: String, sheds: bool) {
        let mut state = self.shared.lock();
        state.who = who;
        state.sheds = sheds;
    }

    /// Bounds the bulk lane's bytes in the transport's channel at `bytes` (at least one line)
    /// instead of [`BULK_WINDOW`]: a peer link's send window (`ACPMUX_PEER_SEND_WINDOW_KB`, off
    /// by default, `requests/initialize.rs`). Lines past it wait here, where a read's answer goes
    /// ahead of them and a newer row of a watched chat replaces its queued one ([`Row`]),
    /// instead of in the transport's buffers on a lossy link, where nothing passes them.
    pub(super) fn set_window(&self, bytes: usize) {
        self.shared.lock().window = bytes.max(1);
        self.shared.wake.notify_one();
    }

    /// Queues `line` in the bulk lane; false when the connection overran or its reader is gone.
    pub(super) fn push(&self, line: String) -> bool {
        self.lock().push(line)
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
            let _ = self.transport.try_send(overrun.last_line());
        }
        state.ended = true;
        state.clear();
        drop(state);
        self.shared.closed.send_replace(true);
    }
}

impl Pump {
    /// Takes the read lane's lines, then the bulk lane's that fit its window ([`BULK_WINDOW`]
    /// unless [`Outbound::set_window`] set one, [module docs](self)), into `batch`, waiting until
    /// there is one; false once there is nothing more to send (every handle is gone and both
    /// lanes are empty, or it overran).
    pub(super) async fn take(&self, batch: &mut Vec<Line>) -> bool {
        let window = self.shared.lock().window;
        self.take_within(batch, window).await
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
        let mut state = self.shared.lock();
        if state.overrun.is_some() {
            return false;
        }
        permit.send(line.text);
        state.taken = state.taken.saturating_sub(1);
        state.sent.push_back((size, line.ticket));
        state.sent_bytes += size;
        // Forget what the reader took meanwhile, so `sent` stays as short as the channel.
        state.settle();
        true
    }

    /// A taken line with its text replaced (`durable_gate.rs`: a reply answered `disk.full`),
    /// the queue's bytes moved by the difference.
    pub(super) fn replace(&self, line: Line, text: String) -> Line {
        let mut state = self.shared.lock();
        let held = state.held.saturating_sub(line.text.len()).saturating_add(text.len());
        state.set_held(held);
        Line { text, ..line }
    }

    /// What this queue's lines were raised to (the durable gate raises it).
    pub(super) fn raised(&self) -> Arc<Raised> {
        Arc::clone(&self.shared.raised)
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
    let limits = Limits {
        pool: &TOTAL_HELD,
        total_bound: TOTAL_BYTE_BOUND,
        fair_share: FAIR_SHARE,
        reader_stall: READER_STALL,
    };
    start_limited(scope, durability, transport, bound, limits)
}

/// [`start_bounded`] with its rows bounded at `row_bound` ([`ROW_BYTE_BOUND`]).
#[cfg(test)]
pub(super) fn start_rows_bounded(
    scope: &cmux_scope::Scope,
    transport: mpsc::Sender<String>,
    bound: usize,
    row_bound: usize,
) -> Arc<Outbound> {
    let limits = Limits {
        pool: &TOTAL_HELD,
        total_bound: TOTAL_BYTE_BOUND,
        fair_share: FAIR_SHARE,
        reader_stall: READER_STALL,
    };
    start_with(scope, None, transport, bound, row_bound, limits).0
}

/// The daemon-wide limits of a queue: the sum it counts toward ([`TOTAL_HELD`]), its bound
/// ([`TOTAL_BYTE_BOUND`]), [`FAIR_SHARE`] and [`READER_STALL`]. A test gives its own pool, so other
/// tests' queues, filling and draining beside it, never move its bound.
pub(super) struct Limits {
    pub(super) pool: &'static AtomicUsize,
    pub(super) total_bound: usize,
    pub(super) fair_share: usize,
    pub(super) reader_stall: Duration,
}

/// [`start_bounded`] with the daemon-wide [`Limits`] given.
pub(super) fn start_limited(
    scope: &cmux_scope::Scope,
    durability: Option<crate::store::Durability>,
    transport: mpsc::Sender<String>,
    bound: usize,
    limits: Limits,
) -> (Arc<Outbound>, Option<Arc<durable_gate::Gate>>) {
    start_with(scope, durability, transport, bound, ROW_BYTE_BOUND, limits)
}

fn start_with(
    scope: &cmux_scope::Scope,
    durability: Option<crate::store::Durability>,
    transport: mpsc::Sender<String>,
    bound: usize,
    row_bound: usize,
    limits: Limits,
) -> (Arc<Outbound>, Option<Arc<durable_gate::Gate>>) {
    let Limits { pool, total_bound, fair_share, reader_stall } = limits;
    let (closed, _) = watch::channel(false);
    let shared = Arc::new(Shared {
        state: StdMutex::new(State {
            queue: VecDeque::new(),
            next_serial: 0,
            rows: HashMap::new(),
            row_bytes: 0,
            reads: VecDeque::new(),
            held: 0,
            sent: VecDeque::new(),
            sent_bytes: 0,
            progress_at: Instant::now(),
            taken: 0,
            transport: transport.downgrade(),
            capacity: transport.max_capacity(),
            finished: false,
            pool,
            overrun: None,
            ended: false,
            sheds: false,
            who: String::new(),
            window: BULK_WINDOW,
        }),
        wake: Notify::new(),
        closed,
        bound,
        row_bound,
        raised: Arc::default(),
        total_bound,
        fair_share,
        reader_stall,
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
