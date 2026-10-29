//! The daemon's IPC layer, counted: streams, the per-connection sequence
//! depth, messages and bytes by kind in each direction, JSON parses per
//! request, write syscalls per message, write stalls and bad_message
//! closes. `server-stats` reports them when `include` names `ipc`
//! (plans/cmux-next/chrome-parity/p05-ipc.md, 3.7). Every transport is
//! counted the same way: the local socket and the remote entry
//! (`line_connection.rs`) and WebSocket connections
//! (`websocket_listener.rs`).
//!
//! Chrome's channel keeps the same facts at the same points: a malformed
//! read ends the channel with `Error::kReceivedMalformedData`
//! (mojo/core/channel.cc, `Channel::OnReadComplete`), and a write the socket
//! takes only in part queues the rest until the fd is writable again
//! (mojo/core/channel_posix.cc, `ChannelPosix::FlushOutgoingMessagesNoLock`).
//! Recording is a relaxed atomic add, as `base/metrics/histogram_macros.h`
//! records; nothing here allocates or locks.

use std::cell::Cell;
use std::io::{self, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use cmux_ipc::frame::FrameKind;
use serde::Serialize;

use super::{HistogramSnapshot, LogLinearHistogram};

/// One write syscall that blocked this long found the peer's receive buffer
/// full: a write stall. A non-blocking write (the mux-io loop) that finds it
/// full counts one at once ([`IpcStats::write_stall`]).
pub const WRITE_STALL_THRESHOLD: Duration = Duration::from_millis(1);

/// The name of a JSON message (a line, or a WebSocket text message) in
/// `received` and `sent`; frames use [`FrameKind::name`].
const LINE_KIND: &str = "line";

/// One slot per message kind: slot 0 is a JSON message, a frame's slot is its
/// wire value (1..=20; unused values stay zero).
const KIND_SLOTS: usize = 21;

/// How a message reached the daemon: a JSON line or a binary frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IpcTransport {
    Lines,
    Frames,
}

#[derive(Default)]
struct KindCounter {
    messages: AtomicU64,
    bytes: AtomicU64,
}

impl KindCounter {
    fn add(&self, bytes: usize) {
        self.messages.fetch_add(1, Ordering::Relaxed);
        self.bytes.fetch_add(bytes as u64, Ordering::Relaxed);
    }
}

#[derive(Default)]
struct ParseCounter {
    requests: AtomicU64,
    json_parses: AtomicU64,
}

/// Every IPC counter of one daemon, over the connections of every transport.
pub struct IpcStats {
    streams_open: AtomicU64,
    streams_peak: AtomicU64,
    streams_opened: AtomicU64,
    sequence_depth: LogLinearHistogram,
    received: [KindCounter; KIND_SLOTS],
    sent: [KindCounter; KIND_SLOTS],
    line_parses: Arc<ParseCounter>,
    frame_parses: Arc<ParseCounter>,
    messages_written: AtomicU64,
    write_syscalls: AtomicU64,
    write_stalls: AtomicU64,
    bad_message: AtomicU64,
}

impl Default for IpcStats {
    fn default() -> Self {
        Self {
            streams_open: AtomicU64::new(0),
            streams_peak: AtomicU64::new(0),
            streams_opened: AtomicU64::new(0),
            sequence_depth: LogLinearHistogram::new(),
            received: std::array::from_fn(|_| KindCounter::default()),
            sent: std::array::from_fn(|_| KindCounter::default()),
            line_parses: Arc::default(),
            frame_parses: Arc::default(),
            messages_written: AtomicU64::new(0),
            write_syscalls: AtomicU64::new(0),
            write_stalls: AtomicU64::new(0),
            bad_message: AtomicU64::new(0),
        }
    }
}

impl IpcStats {
    /// A connection's stream 0 opened; it counts as open until the guard
    /// drops. No connection opens a second stream yet (attach-streams),
    /// so today this counts open connections.
    #[must_use = "the stream counts as open until the guard drops"]
    pub fn stream_opened(&self) -> OpenStream<'_> {
        self.streams_opened.fetch_add(1, Ordering::Relaxed);
        let open = self.streams_open.fetch_add(1, Ordering::AcqRel) + 1;
        self.streams_peak.fetch_max(open, Ordering::Relaxed);
        OpenStream { stats: self }
    }

    /// [`Self::stream_opened`] for an owner that cannot hold a borrow (a
    /// connection served on the mux-io loop and its line sequence).
    pub fn stream_opened_owned(self: &Arc<Self>) -> OwnedOpenStream {
        std::mem::forget(self.stream_opened());
        OwnedOpenStream { stats: self.clone() }
    }

    /// A request arrived at its connection's sequence, which then held
    /// `depth` requests (itself included), also when the sequence was full
    /// and refused it.
    pub fn sequence_depth(&self, depth: usize) {
        self.sequence_depth.record(depth as u64);
    }

    /// A JSON message of `bytes` (a line's delimiter included) arrived.
    pub fn line_received(&self, bytes: usize) {
        self.received[0].add(bytes);
    }

    /// A JSON message of `bytes` (a line's delimiter included) went to the
    /// writer.
    pub fn line_sent(&self, bytes: usize) {
        self.sent[0].add(bytes);
        self.messages_written.fetch_add(1, Ordering::Relaxed);
    }

    /// A frame of `kind` arrived; `bytes` counts its header and payload.
    pub fn frame_received(&self, kind: FrameKind, bytes: usize) {
        frame_slot(&self.received, kind).add(bytes);
    }

    /// A frame of `kind` went to the writer; `bytes` counts its header and
    /// payload.
    pub fn frame_sent(&self, kind: FrameKind, bytes: usize) {
        frame_slot(&self.sent, kind).add(bytes);
        self.messages_written.fetch_add(1, Ordering::Relaxed);
    }

    /// A non-blocking write found the peer's receive buffer full: one
    /// stall, however long the queue then waits for room (the mux-io loop
    /// counts it once per wait).
    pub fn write_stall(&self) {
        self.write_stalls.fetch_add(1, Ordering::Relaxed);
    }

    /// A connection closed because a message was malformed.
    pub fn bad_message(&self) {
        self.bad_message.fetch_add(1, Ordering::Relaxed);
    }

    /// `writer`, with each `write` or `write_vectored` call (one syscall on
    /// a socket) counted
    /// and timed against [`WRITE_STALL_THRESHOLD`].
    pub fn counted<'a, W: Write + ?Sized>(&'a self, writer: &'a mut W) -> CountedWrite<'a, W> {
        CountedWrite { stats: self, inner: writer }
    }

    pub fn snapshot(&self) -> IpcSnapshot {
        let messages_written = self.messages_written.load(Ordering::Relaxed);
        let write_syscalls = self.write_syscalls.load(Ordering::Relaxed);
        IpcSnapshot {
            streams: IpcStreamsSnapshot {
                open: self.streams_open.load(Ordering::Acquire),
                peak: self.streams_peak.load(Ordering::Relaxed),
                opened: self.streams_opened.load(Ordering::Relaxed),
            },
            sequence_depth: self.sequence_depth.snapshot(),
            received: kinds_snapshot(&self.received),
            sent: kinds_snapshot(&self.sent),
            parses: IpcParsesSnapshot {
                lines: parses_snapshot(&self.line_parses),
                frames: parses_snapshot(&self.frame_parses),
            },
            writes: IpcWritesSnapshot {
                messages: messages_written,
                syscalls: write_syscalls,
                syscalls_per_message: ratio(write_syscalls, messages_written),
                stalls: self.write_stalls.load(Ordering::Relaxed),
            },
            bad_message: self.bad_message.load(Ordering::Relaxed),
        }
    }

    fn parses(&self, transport: IpcTransport) -> &Arc<ParseCounter> {
        match transport {
            IpcTransport::Lines => &self.line_parses,
            IpcTransport::Frames => &self.frame_parses,
        }
    }
}

fn ratio(numerator: u64, denominator: u64) -> f64 {
    if denominator == 0 { 0.0 } else { numerator as f64 / denominator as f64 }
}

fn kind_name(slot: usize) -> Option<&'static str> {
    if slot == 0 {
        return Some(LINE_KIND);
    }
    u8::try_from(slot).ok().and_then(FrameKind::from_wire).map(FrameKind::name)
}

/// The counter of a frame kind: the slot of its wire value.
#[allow(
    clippy::indexing_slicing,
    reason = "INVARIANT: each FrameKind wire value is below KIND_SLOTS (ipc_tests records ALL)"
)]
fn frame_slot(counters: &[KindCounter; KIND_SLOTS], kind: FrameKind) -> &KindCounter {
    &counters[usize::from(kind.wire())]
}

fn kinds_snapshot(counters: &[KindCounter; KIND_SLOTS]) -> Vec<IpcKindSnapshot> {
    counters
        .iter()
        .enumerate()
        .filter_map(|(slot, counter)| {
            let messages = counter.messages.load(Ordering::Relaxed);
            let kind = kind_name(slot).filter(|_| messages > 0)?;
            Some(IpcKindSnapshot { kind, messages, bytes: counter.bytes.load(Ordering::Relaxed) })
        })
        .collect()
}

fn parses_snapshot(counter: &ParseCounter) -> IpcParseSnapshot {
    let requests = counter.requests.load(Ordering::Relaxed);
    let json_parses = counter.json_parses.load(Ordering::Relaxed);
    IpcParseSnapshot {
        requests,
        json_parses,
        json_parses_per_request: ratio(json_parses, requests),
    }
}

/// A stream counted as open by [`IpcStats::stream_opened`].
pub struct OpenStream<'a> {
    stats: &'a IpcStats,
}

impl Drop for OpenStream<'_> {
    fn drop(&mut self) {
        self.stats.streams_open.fetch_sub(1, Ordering::AcqRel);
    }
}

/// An open stream counted until it drops ([`IpcStats::stream_opened_owned`]).
pub struct OwnedOpenStream {
    stats: Arc<IpcStats>,
}

impl Drop for OwnedOpenStream {
    fn drop(&mut self) {
        self.stats.streams_open.fetch_sub(1, Ordering::AcqRel);
    }
}

/// A writer whose `write` calls count as syscalls ([`IpcStats::counted`]).
pub struct CountedWrite<'a, W: Write + ?Sized> {
    stats: &'a IpcStats,
    inner: &'a mut W,
}

impl<W: Write + ?Sized> CountedWrite<'_, W> {
    /// One write call that began at `started`, a stall when it took
    /// [`WRITE_STALL_THRESHOLD`] or longer.
    fn count_call(&self, started: Instant) {
        self.stats.write_syscalls.fetch_add(1, Ordering::Relaxed);
        if started.elapsed() >= WRITE_STALL_THRESHOLD {
            self.stats.write_stalls.fetch_add(1, Ordering::Relaxed);
        }
    }
}

impl<W: Write + ?Sized> Write for CountedWrite<'_, W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let started = Instant::now();
        let written = self.inner.write(buf);
        self.count_call(started);
        written
    }

    /// Forwarded whole, so a socket gathers the buffers in one `writev`.
    fn write_vectored(&mut self, bufs: &[io::IoSlice<'_>]) -> io::Result<usize> {
        let started = Instant::now();
        let written = self.inner.write_vectored(bufs);
        self.count_call(started);
        written
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

thread_local! {
    /// JSON parses of the request message this thread is handling, while a
    /// [`JsonParseScope`] is open on it; `None` outside one.
    static JSON_PARSES: Cell<Option<u64>> = const { Cell::new(None) };
}

/// Count one JSON parse of a request message's bytes toward the request
/// whose [`JsonParseScope`] is open on this thread. Outside a scope (a test
/// that dispatches in process, the WebSocket authentication message) it
/// counts nothing, so no parse carries over into a later request.
pub(crate) fn note_json_parse() {
    JSON_PARSES.with(|parses| {
        if let Some(count) = parses.get() {
            parses.set(Some(count.wrapping_add(1)));
        }
    });
}

/// One request message from arrival to its answer or dispatch, entered by
/// the connection loop that read it: when it ends it counts as one request
/// of its transport, with the parses noted on this thread inside it.
pub struct JsonParseScope<'a> {
    counter: Arc<ParseCounter>,
    /// The count of a scope this one is nested in, restored when it ends.
    outer: Option<u64>,
    /// The counter of that scope, restored when this one ends.
    outer_counter: Option<Arc<ParseCounter>>,
    /// False for [`Self::resume`]: the request was counted where it began.
    counts_request: bool,
    _stats: std::marker::PhantomData<&'a IpcStats>,
}

thread_local! {
    /// The counter of the innermost [`JsonParseScope`] on this thread.
    static ACTIVE_COUNTER: std::cell::RefCell<Option<Arc<ParseCounter>>> =
        const { std::cell::RefCell::new(None) };
}

/// The request a [`JsonParseScope`] counts, handed to another thread that
/// finishes it ([`JsonParseScope::handoff`], [`JsonParseScope::resume`]).
#[derive(Clone)]
pub struct JsonParseHandoff(Option<Arc<ParseCounter>>);

impl<'a> JsonParseScope<'a> {
    pub fn enter(stats: &'a IpcStats, transport: IpcTransport) -> Self {
        Self::open(stats.parses(transport).clone(), true)
    }

    fn open(counter: Arc<ParseCounter>, counts_request: bool) -> Self {
        let outer = JSON_PARSES.with(|parses| parses.replace(Some(0)));
        let outer_counter =
            ACTIVE_COUNTER.with(|active| active.borrow_mut().replace(counter.clone()));
        Self { counter, outer, outer_counter, counts_request, _stats: std::marker::PhantomData }
    }

    /// The request this thread's innermost scope counts, for the thread
    /// that finishes it (a line the reader hands to its connection's
    /// request sequence). Empty outside a scope.
    pub fn handoff() -> JsonParseHandoff {
        JsonParseHandoff(ACTIVE_COUNTER.with(|active| active.borrow().clone()))
    }
}

impl JsonParseScope<'static> {
    /// The rest of a request whose scope began on another thread: its
    /// parses count toward that scope's transport, and the request is not
    /// counted again. Counts nothing for an empty handoff.
    pub fn resume(handoff: JsonParseHandoff) -> Option<Self> {
        handoff.0.map(|counter| Self::open(counter, false))
    }
}

impl Drop for JsonParseScope<'_> {
    fn drop(&mut self) {
        let parses = JSON_PARSES.with(|parses| parses.replace(self.outer)).unwrap_or(0);
        let outer = self.outer_counter.take();
        let _ = ACTIVE_COUNTER.try_with(|active| *active.borrow_mut() = outer);
        if self.counts_request {
            self.counter.requests.fetch_add(1, Ordering::Relaxed);
        }
        self.counter.json_parses.fetch_add(parses, Ordering::Relaxed);
    }
}

/// [`IpcStats`] read at one moment (`server-stats` `ipc`).
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct IpcSnapshot {
    pub streams: IpcStreamsSnapshot,
    /// Requests in their connection's sequence as each one arrived at it.
    pub sequence_depth: HistogramSnapshot,
    /// Messages and bytes that arrived, by kind; kinds never seen are absent.
    pub received: Vec<IpcKindSnapshot>,
    /// Messages and bytes handed to the writers, by kind.
    pub sent: Vec<IpcKindSnapshot>,
    pub parses: IpcParsesSnapshot,
    pub writes: IpcWritesSnapshot,
    /// Connections closed for a malformed message, on any transport.
    pub bad_message: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct IpcStreamsSnapshot {
    pub open: u64,
    pub peak: u64,
    pub opened: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct IpcKindSnapshot {
    pub kind: &'static str,
    pub messages: u64,
    pub bytes: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct IpcParsesSnapshot {
    pub lines: IpcParseSnapshot,
    pub frames: IpcParseSnapshot,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct IpcParseSnapshot {
    pub requests: u64,
    pub json_parses: u64,
    pub json_parses_per_request: f64,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct IpcWritesSnapshot {
    pub messages: u64,
    pub syscalls: u64,
    pub syscalls_per_message: f64,
    pub stalls: u64,
}

#[cfg(test)]
#[path = "ipc_tests.rs"]
mod tests;
