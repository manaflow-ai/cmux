//! The `daemon.request` span of every control request: Chrome's per-task
//! trace event and queue timing (`base/task/common/task_annotator.cc`,
//! `RunTaskImpl`: one trace slice per task, its queueing delay from its post
//! time), with a request line as the task.
//!
//! The connection's reader stamps the line's arrival and its parse
//! ([`RequestArrival`]); the handler opens a [`RequestSpan`] when it starts.
//! The span is the slice `daemon.request` (method id, request id hash) on the
//! handling thread with four instants, `parsed`, `dispatched`, `reply.queued`
//! and `reply.sent`, and it records the request's latency in its
//! [`MethodClass`] histogram. Dropping the span ends both, so every return
//! path of the handler closes it. A command answered later by a worker
//! (`url-open`, `chief-inspect`, the cloud commands) moves its latency to an
//! [`AsyncReply`], an async slice that ends when the worker drops it.

use std::io;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_trace::{trace_async_begin, trace_async_end, trace_instant, trace_scope};
use serde_json::Value;

use super::Command;
use super::command_names::MethodClass;
use crate::diagnostics::RequestStats;

/// When a request line arrived at its connection's reader and when it parsed
/// into a command.
#[derive(Clone, Copy, Debug)]
pub(super) struct RequestArrival {
    pub(super) arrived: Instant,
    pub(super) parsed: Instant,
}

impl RequestArrival {
    /// A line that arrived at `arrived` and parsed now.
    pub(super) fn parsed_now(arrived: Instant) -> Self {
        Self { arrived, parsed: Instant::now() }
    }

    /// A request made in process (a relay, a test): it arrives as it parses.
    pub(super) fn now() -> Self {
        let now = Instant::now();
        Self { arrived: now, parsed: now }
    }
}

/// Where a request's latency is recorded.
enum Reply {
    /// The handler answers on this thread; recorded at `reply.sent` or drop.
    Pending,
    /// Recorded already, or handed to an [`AsyncReply`].
    Done,
}

/// One request being handled. Not `Send`: its slice ends on its own thread.
pub(super) struct RequestSpan<'a> {
    stats: &'a Arc<RequestStats>,
    class: MethodClass,
    method: u16,
    arrival: RequestArrival,
    reply: Reply,
    /// Declared last: the slice's end comes after every instant above.
    _scope: cmux_trace::ScopeGuard,
}

impl<'a> RequestSpan<'a> {
    /// Opens the span of `cmd` (request `id`) as its handler starts, and
    /// records its dispatch queue: the time from its parse to now.
    pub(super) fn open(
        stats: &'a Arc<RequestStats>,
        cmd: &Command,
        id: Option<&Value>,
        arrival: RequestArrival,
    ) -> Self {
        let (class, method) = (cmd.method_class(), cmd.method_id());
        let scope = trace_scope!(daemon, "daemon.request", method, request_id_hash(id));
        let now = Instant::now();
        let queued = now.saturating_duration_since(arrival.parsed);
        stats.record_dispatch_queue(queued);
        // The parse came before the slice: arg0 is the line's arrival to its
        // parse, arg1 its parse to now (the dispatch queue).
        trace_instant!(
            daemon,
            "daemon.request.parsed",
            micros(arrival.parsed.saturating_duration_since(arrival.arrived)),
            micros(queued)
        );
        trace_instant!(daemon, "daemon.request.dispatched", class as u8);
        Self { stats, class, method, arrival, reply: Reply::Pending, _scope: scope }
    }

    /// Sends the request's reply with `send`: `reply.queued` before (the
    /// reply is built), `reply.sent` after (the connection's writer took it
    /// or refused it), and the latency sample then.
    pub(super) fn reply(&mut self, send: impl FnOnce() -> bool) -> bool {
        trace_instant!(daemon, "daemon.request.reply.queued");
        let sent = send();
        trace_instant!(daemon, "daemon.request.reply.sent", sent);
        self.record();
        sent
    }

    /// Hands the latency to a worker that answers later: an async slice
    /// `daemon.request.async` that ends when the returned reply drops.
    pub(super) fn start_async(&mut self) -> AsyncReply {
        self.reply = Reply::Done;
        let id = self.stats.next_async_id();
        trace_async_begin!(daemon, "daemon.request.async", id, self.method);
        AsyncReply {
            stats: self.stats.clone(),
            class: self.class,
            arrived: self.arrival.arrived,
            id,
        }
    }

    fn record(&mut self) {
        if matches!(self.reply, Reply::Pending) {
            self.reply = Reply::Done;
            self.stats.record_latency(self.class as usize, self.arrival.arrived.elapsed());
        }
    }
}

impl Drop for RequestSpan<'_> {
    /// A handler that sent its reply on its own (or none) is answered now.
    fn drop(&mut self) {
        self.record();
    }
}

/// The latency of a request a worker thread answers: its async slice ends
/// and its sample is recorded when this drops, after the worker's reply.
#[must_use = "the request's async slice ends when this drops: move it into the worker"]
pub(super) struct AsyncReply {
    stats: Arc<RequestStats>,
    class: MethodClass,
    arrived: Instant,
    id: u64,
}

impl Drop for AsyncReply {
    fn drop(&mut self) {
        let latency = self.arrived.elapsed();
        self.stats.record_latency(self.class as usize, latency);
        trace_async_end!(daemon, "daemon.request.async", self.id, micros(latency));
    }
}

fn micros(duration: Duration) -> u64 {
    u64::try_from(duration.as_micros()).unwrap_or(u64::MAX)
}

/// FNV-1a over the request id's JSON text (0 for no id), so a client can
/// name its request's slice from the id it sent.
pub(super) fn request_id_hash(id: Option<&Value>) -> u64 {
    let Some(id) = id else { return 0 };
    let mut hash = Fnv1a(Fnv1a::OFFSET);
    // Writing into the hasher cannot fail.
    let _ = serde_json::to_writer(&mut hash, id);
    hash.0
}

struct Fnv1a(u64);

impl Fnv1a {
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;
}

impl io::Write for Fnv1a {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        for byte in bytes {
            self.0 = (self.0 ^ u64::from(*byte)).wrapping_mul(Self::PRIME);
        }
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
#[path = "request_spans_tests.rs"]
mod tests;
