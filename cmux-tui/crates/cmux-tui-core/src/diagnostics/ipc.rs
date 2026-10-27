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

use std::cell::RefCell;
use std::io::{self, Write};
use std::marker::PhantomData;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use cmux_ipc::frame::FrameKind;
use serde::Serialize;

use super::{HistogramSnapshot, LogLinearHistogram};

/// One write syscall that blocked this long found the peer's receive buffer
/// full: a write stall.
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

impl ParseCounter {
    /// One request ended after `parses` JSON parses.
    fn count(&self, parses: u64) {
        self.requests.fetch_add(1, Ordering::Relaxed);
        self.json_parses.fetch_add(parses, Ordering::Relaxed);
    }
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
    /// drops. No connection opens a second stream yet (attach-streams,
    /// p05-ipc-074), so today this counts open connections.
    #[must_use = "the stream counts as open until the guard drops"]
    pub fn stream_opened(&self) -> OpenStream<'_> {
        self.streams_opened.fetch_add(1, Ordering::Relaxed);
        let open = self.streams_open.fetch_add(1, Ordering::AcqRel) + 1;
        self.streams_peak.fetch_max(open, Ordering::Relaxed);
        OpenStream { stats: self }
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
        self.received[usize::from(kind.wire())].add(bytes);
    }

    /// A frame of `kind` went to the writer; `bytes` counts its header and
    /// payload.
    pub fn frame_sent(&self, kind: FrameKind, bytes: usize) {
        self.sent[usize::from(kind.wire())].add(bytes);
        self.messages_written.fetch_add(1, Ordering::Relaxed);
    }

    /// A connection closed because a message was malformed.
    pub fn bad_message(&self) {
        self.bad_message.fetch_add(1, Ordering::Relaxed);
    }

    /// `writer`, with each `write` call (one syscall on a socket) counted
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

/// A writer whose `write` calls count as syscalls ([`IpcStats::counted`]).
pub struct CountedWrite<'a, W: Write + ?Sized> {
    stats: &'a IpcStats,
    inner: &'a mut W,
}

impl<W: Write + ?Sized> Write for CountedWrite<'_, W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let started = Instant::now();
        let written = self.inner.write(buf);
        self.stats.write_syscalls.fetch_add(1, Ordering::Relaxed);
        if started.elapsed() >= WRITE_STALL_THRESHOLD {
            self.stats.write_stalls.fetch_add(1, Ordering::Relaxed);
        }
        written
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

/// The request scope open on a thread: its parses so far and the counter
/// it ends in.
struct OpenParseScope {
    parses: u64,
    counter: Arc<ParseCounter>,
    /// Its request moved to another thread ([`hand_off_json_parses`]),
    /// which counts it; the end of this scope counts nothing.
    handed_off: bool,
}

thread_local! {
    /// The request message this thread is handling, while a
    /// [`JsonParseScope`] is open on it; `None` outside one.
    static JSON_PARSES: RefCell<Option<OpenParseScope>> = const { RefCell::new(None) };
}

/// Count one JSON parse of a request message's bytes toward the request
/// whose [`JsonParseScope`] is open on this thread. Outside a scope (a test
/// that dispatches in process, the WebSocket authentication message) it
/// counts nothing, so no parse carries over into a later request.
pub(crate) fn note_json_parse() {
    JSON_PARSES.with_borrow_mut(|scope| {
        if let Some(scope) = scope {
            scope.parses = scope.parses.wrapping_add(1);
        }
    });
}

/// One request message from arrival to its answer or dispatch, entered by
/// the connection loop that read it: when it ends it counts as one request
/// of its transport, with the parses noted on this thread inside it. A
/// request handed to another thread ([`hand_off_json_parses`]) counts
/// there instead. Not `Send`: it ends on the thread it began.
pub struct JsonParseScope<'a> {
    /// The scope this one is nested in, restored when it ends.
    outer: Option<OpenParseScope>,
    _stats: PhantomData<&'a IpcStats>,
    _not_send: PhantomData<*const ()>,
}

impl<'a> JsonParseScope<'a> {
    pub fn enter(stats: &'a IpcStats, transport: IpcTransport) -> Self {
        Self::open(stats.parses(transport).clone(), 0)
    }

    fn open(counter: Arc<ParseCounter>, parses: u64) -> Self {
        let open = OpenParseScope { parses, counter, handed_off: false };
        let outer = JSON_PARSES.with_borrow_mut(|scope| scope.replace(open));
        Self { outer, _stats: PhantomData, _not_send: PhantomData }
    }
}

impl Drop for JsonParseScope<'_> {
    fn drop(&mut self) {
        let outer = self.outer.take();
        let ended = JSON_PARSES.with_borrow_mut(|scope| std::mem::replace(scope, outer));
        if let Some(ended) = ended.filter(|ended| !ended.handed_off) {
            ended.counter.count(ended.parses);
        }
    }
}

/// Hands the request of this thread's open [`JsonParseScope`] to the thread
/// that answers it (a line queued on its connection's control sequence):
/// that thread counts it, with the parses made here so far, so the request
/// still counts once. `None` outside a scope.
pub(crate) fn hand_off_json_parses() -> Option<JsonParseHandoff> {
    JSON_PARSES.with_borrow_mut(|scope| {
        let scope = scope.as_mut().filter(|scope| !scope.handed_off)?;
        scope.handed_off = true;
        Some(JsonParseHandoff { counter: Some(scope.counter.clone()), parses: scope.parses })
    })
}

/// A request's parse count on its way to the thread that answers it. A
/// request that never gets there (its connection closed while it was
/// queued) counts when this drops.
pub(crate) struct JsonParseHandoff {
    counter: Option<Arc<ParseCounter>>,
    parses: u64,
}

impl JsonParseHandoff {
    /// Opens the request's scope again on this thread with its parses so
    /// far; the scope counts the request when it ends.
    pub(crate) fn resume(mut self) -> JsonParseScope<'static> {
        let counter = self.counter.take().unwrap_or_default();
        JsonParseScope::open(counter, self.parses)
    }
}

impl Drop for JsonParseHandoff {
    fn drop(&mut self) {
        if let Some(counter) = self.counter.take() {
            counter.count(self.parses);
        }
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
