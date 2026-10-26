//! The daemon's IPC layer, counted: streams, the per-connection sequence
//! depth, messages and bytes by kind in each direction, JSON parses per
//! request, write syscalls per message, write stalls, bad_message closes,
//! and shared output ring resyncs and laps. `server-stats` reports them when
//! `include` names `ipc` (plans/cmux-next/chrome-parity/p05-ipc.md, 3.7).
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
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use cmux_ipc::frame::FrameKind;
use serde::Serialize;

use super::{HistogramSnapshot, LogLinearHistogram};

/// One write syscall that blocked this long found the peer's receive buffer
/// full: a write stall.
pub const WRITE_STALL_THRESHOLD: Duration = Duration::from_millis(1);

/// The name of a JSON line in `received` and `sent`; frames use
/// [`FrameKind::name`].
const LINE_KIND: &str = "line";

/// One slot per message kind: slot 0 is a JSON line, a frame's slot is its
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

/// Every IPC counter of one daemon, over all of its connections.
pub struct IpcStats {
    streams_open: AtomicU64,
    streams_peak: AtomicU64,
    streams_opened: AtomicU64,
    sequence_depth: LogLinearHistogram,
    received: [KindCounter; KIND_SLOTS],
    sent: [KindCounter; KIND_SLOTS],
    line_parses: ParseCounter,
    frame_parses: ParseCounter,
    messages_written: AtomicU64,
    write_syscalls: AtomicU64,
    write_stalls: AtomicU64,
    bad_message: AtomicU64,
    ring_resyncs: AtomicU64,
    ring_laps: AtomicU64,
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
            line_parses: ParseCounter::default(),
            frame_parses: ParseCounter::default(),
            messages_written: AtomicU64::new(0),
            write_syscalls: AtomicU64::new(0),
            write_stalls: AtomicU64::new(0),
            bad_message: AtomicU64::new(0),
            ring_resyncs: AtomicU64::new(0),
            ring_laps: AtomicU64::new(0),
        }
    }
}

impl IpcStats {
    /// A stream opened (a connection's stream 0, or a client-minted stream);
    /// it counts as open until the guard drops.
    #[must_use = "the stream counts as open until the guard drops"]
    pub fn stream_opened(&self) -> OpenStream<'_> {
        self.streams_opened.fetch_add(1, Ordering::Relaxed);
        let open = self.streams_open.fetch_add(1, Ordering::AcqRel) + 1;
        self.streams_peak.fetch_max(open, Ordering::Relaxed);
        OpenStream { stats: self }
    }

    /// A request entered its connection's sequence, which now holds `depth`
    /// requests (itself included).
    pub fn sequence_depth(&self, depth: usize) {
        self.sequence_depth.record(depth as u64);
    }

    /// A JSON line of `bytes` (its delimiter included) arrived.
    pub fn line_received(&self, bytes: usize) {
        self.received[0].add(bytes);
    }

    /// A JSON line of `bytes` (its delimiter included) went to the writer.
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

    /// A shared output ring reader found a gap and resynchronized.
    pub fn ring_resynced(&self) {
        self.ring_resyncs.fetch_add(1, Ordering::Relaxed);
    }

    /// A shared output ring writer overwrote a span a reader still held.
    pub fn ring_lapped(&self) {
        self.ring_laps.fetch_add(1, Ordering::Relaxed);
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
            ring: IpcRingSnapshot {
                resyncs: self.ring_resyncs.load(Ordering::Relaxed),
                laps: self.ring_laps.load(Ordering::Relaxed),
            },
        }
    }

    fn parses(&self, transport: IpcTransport) -> &ParseCounter {
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

thread_local! {
    /// JSON parses of request messages on this thread that no request has
    /// taken yet; the next [`JsonParseScope`] to end on it takes them.
    static JSON_PARSES: Cell<u64> = const { Cell::new(0) };
}

/// Count one JSON parse of a request message's bytes on this thread. A
/// connection's reader parses a line before it knows the line's request
/// (the hello gate), so a parse counts toward the request that ends next.
pub(crate) fn note_json_parse() {
    JSON_PARSES.with(|parses| parses.set(parses.get().wrapping_add(1)));
}

/// One request message from arrival to dispatch: when it ends it counts as
/// one request of its transport, with the parses noted on this thread since
/// the last request ended.
pub struct JsonParseScope<'a> {
    counter: &'a ParseCounter,
}

impl<'a> JsonParseScope<'a> {
    pub fn enter(stats: &'a IpcStats, transport: IpcTransport) -> Self {
        Self { counter: stats.parses(transport) }
    }
}

impl Drop for JsonParseScope<'_> {
    fn drop(&mut self) {
        let parses = JSON_PARSES.with(|parses| parses.replace(0));
        self.counter.requests.fetch_add(1, Ordering::Relaxed);
        self.counter.json_parses.fetch_add(parses, Ordering::Relaxed);
    }
}

/// [`IpcStats`] read at one moment (`server-stats` `ipc`).
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct IpcSnapshot {
    pub streams: IpcStreamsSnapshot,
    /// Requests in their connection's sequence as each one entered it.
    pub sequence_depth: HistogramSnapshot,
    /// Messages and bytes that arrived, by kind; kinds never seen are absent.
    pub received: Vec<IpcKindSnapshot>,
    /// Messages and bytes handed to the writers, by kind.
    pub sent: Vec<IpcKindSnapshot>,
    pub parses: IpcParsesSnapshot,
    pub writes: IpcWritesSnapshot,
    /// Connections closed for a malformed message.
    pub bad_message: u64,
    pub ring: IpcRingSnapshot,
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

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct IpcRingSnapshot {
    pub resyncs: u64,
    pub laps: u64,
}

#[cfg(test)]
#[path = "ipc_tests.rs"]
mod tests;
