//! The `daemon.request` span of every control request: Chrome's per-task
//! trace event and queue timing (`base/task/common/task_annotator.cc`,
//! `RunTaskImpl`: one trace slice per task, its queueing delay from its post
//! time), with a request line as the task. A line's method is read from its
//! head before any route parses it, as a Mojo receiver reads a message's
//! header to name its trace event
//! (`mojo/public/cpp/bindings/lib/interface_endpoint_client.cc`).
//!
//! The connection's reader stamps the line's arrival as its read returns;
//! the frame handler stamps its parse ([`RequestArrival`]). A
//! [`RequestSpan`] is the slice `daemon.request` (method id, request id
//! hash) on the handling thread, with the instants `parsed`, `dispatched`,
//! `handled` (the reply is built) and `reply.queued` (the reply is in the
//! connection's outbound queue). A route that sends its own reply has no
//! `handled`. The span records the request's latency in its [`MethodClass`]
//! histogram; dropping it ends both, so every return path closes it. A
//! command a worker answers later (`url-open`, `chief-inspect`, the cloud
//! commands) moves its latency to an [`AsyncReply`]: the async slice
//! `daemon.request.async`, which the worker's reply ends.
//!
//! The writer thread's socket write is not stamped: a reply's time in the
//! outbound queue is outside the latency.

use std::borrow::Cow;
use std::io;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_trace::{trace_async_begin, trace_async_end, trace_instant, trace_scope};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::Command;
use super::command_names::MethodClass;
use crate::diagnostics::RequestStats;
use crate::resource::{OperationClass, ResourceOperation};

/// When a request line arrived at its connection's reader and when it parsed.
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

    /// A request a test makes in process: it arrives as it parses.
    #[cfg(test)]
    pub(super) fn now() -> Self {
        let now = Instant::now();
        Self { arrived: now, parsed: now }
    }
}

/// The method a request's slice names and the class its latency counts in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct RequestMethod {
    /// A `Command`'s row in `COMMANDS`; [`Self::RESOURCE_BASE`] plus a v2
    /// resource operation's index; [`Self::ROUTED_BASE`] plus the class of a
    /// line a feature route answers before the `Command` parse.
    pub(super) id: u16,
    pub(super) class: MethodClass,
}

impl RequestMethod {
    pub(super) const RESOURCE_BASE: u16 = 0x4000;
    pub(super) const ROUTED_BASE: u16 = 0x8000;

    pub(super) fn of_command(cmd: &Command) -> Self {
        Self { id: cmd.method_id(), class: cmd.method_class() }
    }

    /// A v2 `cmux.protocol/2` resource operation.
    pub(super) fn of_resource(operation: ResourceOperation) -> Self {
        Self { id: Self::RESOURCE_BASE + operation as u16, class: resource_class(operation) }
    }

    /// A line no `Command` names (its `cmd` is a feature route's, or absent).
    fn routed(cmd: Option<&str>) -> Self {
        let class = match cmd {
            Some(cmd) if cmd.starts_with("agent-") || cmd.starts_with("access-request") => {
                MethodClass::Agent
            }
            Some(cmd) if cmd.starts_with("browser-") => MethodClass::Browser,
            _ => MethodClass::Other,
        };
        Self { id: Self::ROUTED_BASE + class as u16, class }
    }
}

/// The class of a v2 resource operation, on the `Command` table's rules:
/// creates first, then the browser and agent namespaces, then reads, then
/// terminal input and model changes.
fn resource_class(operation: ResourceOperation) -> MethodClass {
    use ResourceOperation as Op;
    if matches!(
        operation,
        Op::WorkspaceCreate
            | Op::WorkspaceEnsureHome
            | Op::WorkspaceEnsureApp
            | Op::ScreenCreate
            | Op::PaneCreate
            | Op::PaneSplit
            | Op::TabCreateTerminal
            | Op::TabCreateBrowser
    ) {
        return MethodClass::Create;
    }
    let name = operation.wire_name();
    let namespace = name.split_once('.').map_or(name, |(namespace, _)| namespace);
    match namespace {
        "browser" => MethodClass::Browser,
        "agent" | "chief" | "conversation" | "participant" => MethodClass::Agent,
        _ if operation.class() == OperationClass::Read => MethodClass::Query,
        "terminal" => MethodClass::TerminalIo,
        "workspace" | "workspace_group" | "screen" | "screen_group" | "pane" | "column" | "tab"
        | "tab_group" | "layout" | "sidebar" | "room" => MethodClass::Topology,
        _ => MethodClass::Other,
    }
}

/// A request line's `id` and `cmd`, read before any route parses it.
pub(super) struct RequestHead {
    id: Option<Value>,
    method: RequestMethod,
    /// Whether `cmd` names a `Command`, or the head did not parse (the
    /// `Command` parse then answers the line).
    command: bool,
}

impl RequestHead {
    pub(super) fn parse(message: &str) -> Self {
        #[derive(Deserialize)]
        struct Head<'a> {
            #[serde(default)]
            id: Option<Value>,
            #[serde(default, borrow)]
            cmd: Option<Cow<'a, str>>,
        }
        let Ok(Head { id, cmd }) = serde_json::from_str::<Head>(message) else {
            return Self { id: None, method: RequestMethod::routed(None), command: true };
        };
        match cmd.as_deref().and_then(Command::method_of_wire) {
            Some((method, class)) => {
                Self { id, method: RequestMethod { id: method, class }, command: true }
            }
            None => Self { id, method: RequestMethod::routed(cmd.as_deref()), command: false },
        }
    }

    /// Whether the `Command` path answers this line (and opens its span).
    pub(super) fn is_command(&self) -> bool {
        self.command
    }

    pub(super) fn open<'a>(
        &self,
        stats: &'a Arc<RequestStats>,
        arrival: RequestArrival,
    ) -> RequestSpan<'a> {
        RequestSpan::open_method(stats, self.method, request_id_hash(self.id.as_ref()), arrival)
    }
}

/// Where a request's latency is recorded.
enum Reply {
    /// The handler answers on this thread; recorded at its reply or drop.
    Pending,
    /// Recorded already.
    Done,
    /// Handed to an [`AsyncReply`], which records it at the real reply.
    Async,
}

/// One request being handled. Not `Send`: its slice ends on its own thread.
pub(super) struct RequestSpan<'a> {
    stats: &'a Arc<RequestStats>,
    method: RequestMethod,
    arrival: RequestArrival,
    reply: Reply,
    /// Declared last: the slice's end comes after every instant above.
    _scope: cmux_trace::ScopeGuard,
}

impl<'a> RequestSpan<'a> {
    /// Opens the span of `cmd` (request `id`) as its handler starts.
    pub(super) fn open(
        stats: &'a Arc<RequestStats>,
        cmd: &Command,
        id: Option<&Value>,
        arrival: RequestArrival,
    ) -> Self {
        Self::open_method(stats, RequestMethod::of_command(cmd), request_id_hash(id), arrival)
    }

    /// Opens the span of a request of `method` whose id hashes to
    /// `id_hash`, and records its dispatch queue: its parse to now.
    pub(super) fn open_method(
        stats: &'a Arc<RequestStats>,
        method: RequestMethod,
        id_hash: u64,
        arrival: RequestArrival,
    ) -> Self {
        let scope = trace_scope!(daemon, "daemon.request", method.id, id_hash);
        let queued = Instant::now().saturating_duration_since(arrival.parsed);
        stats.record_dispatch_queue(queued);
        // The parse came before the slice: arg0 is the line's arrival to its
        // parse, arg1 its parse to now (the dispatch queue).
        trace_instant!(
            daemon,
            "daemon.request.parsed",
            micros(arrival.parsed.saturating_duration_since(arrival.arrived)),
            micros(queued)
        );
        trace_instant!(daemon, "daemon.request.dispatched", method.class as u8);
        Self { stats, method, arrival, reply: Reply::Pending, _scope: scope }
    }

    /// The span of a resource request that arrives now (tests).
    #[cfg(test)]
    pub(super) fn for_resource(stats: &'a Arc<RequestStats>, operation: ResourceOperation) -> Self {
        Self::open_method(
            stats,
            RequestMethod::of_resource(operation),
            0,
            RequestArrival::parsed_now(Instant::now()),
        )
    }

    /// Sends the reply the handler built with `send`: `handled` before,
    /// `reply.queued` after (the outbound queue took it, or refused it), and
    /// the latency sample then.
    pub(super) fn reply(&mut self, send: impl FnOnce() -> bool) -> bool {
        trace_instant!(daemon, "daemon.request.handled");
        let sent = send();
        self.answered(sent)
    }

    /// A route sent its own reply and returned `keep_open`: `reply.queued`
    /// and the latency sample now.
    /// A span handed to an [`AsyncReply`] stamps nothing here: its worker
    /// stamps the reply.
    pub(super) fn answered(&mut self, keep_open: bool) -> bool {
        if matches!(self.reply, Reply::Async) {
            return keep_open;
        }
        trace_instant!(daemon, "daemon.request.reply.queued", keep_open);
        self.record();
        keep_open
    }

    /// Hands the latency to a worker that answers later: an async slice
    /// `daemon.request.async` that its [`AsyncReply`] ends.
    pub(super) fn start_async(&mut self) -> AsyncReply {
        self.reply = Reply::Async;
        let id = self.stats.next_async_id();
        trace_async_begin!(daemon, "daemon.request.async", id, self.method.id);
        AsyncReply {
            stats: self.stats.clone(),
            class: self.method.class,
            arrived: self.arrival.arrived,
            id,
            recorded: false,
        }
    }

    fn record(&mut self) {
        if matches!(self.reply, Reply::Pending) {
            self.reply = Reply::Done;
            self.stats.record_latency(self.method.class as usize, self.arrival.arrived.elapsed());
        }
    }
}

impl Drop for RequestSpan<'_> {
    /// A handler that returned with no reply is answered now.
    fn drop(&mut self) {
        self.record();
    }
}

/// The reply of a request a worker thread answers. [`Self::reply`] stamps
/// `daemon.request.async.handled` and `.reply.queued` (arg0 the slice id)
/// and records the latency; the drop ends the async slice, and records the
/// latency of a worker that never replied.
#[must_use = "the request's async slice ends when this drops: move it into the worker"]
pub(super) struct AsyncReply {
    stats: Arc<RequestStats>,
    class: MethodClass,
    arrived: Instant,
    id: u64,
    recorded: bool,
}

impl AsyncReply {
    /// Sends the worker's reply with `send`.
    pub(super) fn reply(mut self, send: impl FnOnce() -> bool) -> bool {
        trace_instant!(daemon, "daemon.request.async.handled", self.id);
        let sent = send();
        trace_instant!(daemon, "daemon.request.async.reply.queued", self.id, sent);
        self.record();
        sent
    }

    fn record(&mut self) -> Duration {
        let latency = self.arrived.elapsed();
        if !self.recorded {
            self.recorded = true;
            self.stats.record_latency(self.class as usize, latency);
        }
        latency
    }
}

impl Drop for AsyncReply {
    fn drop(&mut self) {
        let latency = self.record();
        trace_async_end!(daemon, "daemon.request.async", self.id, micros(latency));
    }
}

fn micros(duration: Duration) -> u64 {
    u64::try_from(duration.as_micros()).unwrap_or(u64::MAX)
}

/// FNV-1a over the request id's compact JSON text (0 for no id), so a
/// client can name its request's slice from the id it sent.
pub(super) fn request_id_hash<T: Serialize + ?Sized>(id: Option<&T>) -> u64 {
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

#[cfg(test)]
#[path = "request_spans_swift_names_tests.rs"]
mod swift_names_tests;
