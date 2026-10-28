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
//!
//! The span also records its method's row of `server-stats` `ipc`
//! ([`MethodLatencyStats`]): the latency, the handler's time (its start to
//! `reply.queued`) and the time the handling thread waited for locks in
//! between (`cmux_threads::thread_lock_wait_nanos` before and after). A
//! method's slot is [`RequestMethod::slot`].

use std::io;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_ipc::{MethodId, MethodTables};
use cmux_trace::{trace_async_begin, trace_async_end, trace_instant, trace_scope};
use serde::Serialize;
use serde_json::Value;

use super::Command;
use super::command_names::{COMMANDS, MethodClass};
use crate::diagnostics::{
    LockOp, LockOpScope, LockScope, LockScopeGuard, MethodLatencyStats, MethodName, MethodSample,
    RequestStats,
};
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

/// The slots of [`MethodLatencyStats`]: every command, then every v2
/// resource operation, then one per class of feature-route lines.
pub(crate) const REQUEST_METHOD_SLOTS: usize =
    COMMANDS.len() + ResourceOperation::ALL.len() + MethodClass::ALL.len();

impl RequestMethod {
    pub(super) const RESOURCE_BASE: u16 = 0x4000;
    pub(super) const ROUTED_BASE: u16 = 0x8000;

    /// This method's slot in [`MethodLatencyStats`] (below
    /// [`REQUEST_METHOD_SLOTS`]).
    pub(super) fn slot(self) -> usize {
        let id = usize::from(self.id);
        if self.id >= Self::ROUTED_BASE {
            COMMANDS.len() + ResourceOperation::ALL.len() + (id - usize::from(Self::ROUTED_BASE))
        } else if self.id >= Self::RESOURCE_BASE {
            COMMANDS.len() + (id - usize::from(Self::RESOURCE_BASE))
        } else {
            id
        }
    }

    /// The method in `slot`: [`Self::slot`] read back, with its schema id
    /// (a scan of the operations; `server-stats` reads it, never a request).
    pub(super) fn of_slot(slot: usize) -> MethodName {
        let routes = COMMANDS.len() + ResourceOperation::ALL.len();
        let schema = MethodTables::schema();
        let (method, name, id) = if let Some(row) = COMMANDS.get(slot) {
            let id = u16::try_from(slot).unwrap_or(u16::MAX);
            (Self { id, class: row.class }, row.wire.to_owned(), schema.v12_id(row.wire))
        } else if let Some(&operation) = ResourceOperation::ALL
            .iter()
            .find(|operation| **operation as usize == slot - COMMANDS.len())
        {
            let name = operation.wire_name();
            (Self::of_resource(operation), name.to_owned(), schema.v2_id(name))
        } else {
            // A slot past the table reads as the last class, as Self::slot never makes one.
            let [.., last] = MethodClass::ALL;
            let class = MethodClass::ALL.get(slot - routes).copied().unwrap_or(last);
            let route = Self { id: Self::ROUTED_BASE + class as u16, class };
            (route, format!("route:{}", class.as_str()), None)
        };
        MethodName {
            method: name,
            id: id.map(MethodId::raw),
            trace_id: method.id,
            class: method.class.as_str(),
        }
    }

    pub(super) fn of_command(cmd: &Command) -> Self {
        Self { id: cmd.method_id(), class: cmd.method_class() }
    }

    /// A v2 `cmux.protocol/2` resource operation.
    pub(super) fn of_resource(operation: ResourceOperation) -> Self {
        Self { id: Self::RESOURCE_BASE + operation as u16, class: resource_class(operation) }
    }

    /// The dense op this method's lock acquisitions count under
    /// (`debug-daemon-locks`): 0 is no request, then every command, every
    /// resource operation and every routed class.
    pub(super) fn lock_op(self) -> LockOp {
        let commands = COMMANDS.len() as u16;
        let resources = ResourceOperation::ALL.len() as u16;
        LockOp(match self.id {
            id if id >= Self::ROUTED_BASE => 1 + commands + resources + (id - Self::ROUTED_BASE),
            id if id >= Self::RESOURCE_BASE => 1 + commands + (id - Self::RESOURCE_BASE),
            id => 1 + id,
        })
    }

    /// A line no `Command` names (its `cmd` is a feature route's, or absent).
    pub(super) fn routed(cmd: Option<&str>) -> Self {
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

/// The name of a [`RequestMethod::lock_op`]: a command's `cmd` tag, a
/// resource operation's wire name, `routed.<class>`, or `none` outside any
/// request.
pub(super) fn lock_op_name(op: LockOp) -> String {
    let Some(index) = op.0.checked_sub(1).map(usize::from) else { return "none".to_owned() };
    if let Some(row) = COMMANDS.get(index) {
        return row.wire.to_owned();
    }
    let index = index - COMMANDS.len();
    if index < ResourceOperation::ALL.len() {
        return ResourceOperation::ALL
            .iter()
            .find(|operation| **operation as usize == index)
            .map_or_else(
                || format!("resource.{index}"),
                |operation| operation.wire_name().to_owned(),
            );
    }
    let index = index - ResourceOperation::ALL.len();
    MethodClass::ALL
        .iter()
        .find(|class| **class as usize == index)
        .map_or_else(|| format!("op.{}", op.0), |class| format!("routed.{}", class.as_str()))
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
    /// The handler's start.
    dispatched: Instant,
    /// This thread's lock wait total at the handler's start.
    lock_wait_from: u64,
    reply: Reply,
    /// The op this thread's lock acquisitions count under until the span
    /// ends (`debug-daemon-locks`).
    _lock_op: LockOpScope,
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
        let dispatched = Instant::now();
        let queued = dispatched.saturating_duration_since(arrival.parsed);
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
        let lock_op = LockOpScope::enter(method.lock_op());
        Self {
            stats,
            method,
            arrival,
            dispatched,
            lock_wait_from: cmux_threads::thread_lock_wait_nanos(),
            reply: Reply::Pending,
            _lock_op: lock_op,
            _scope: scope,
        }
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
            method: self.method,
            arrived: self.arrival.arrived,
            dispatched: self.dispatched,
            lock_waited: Duration::ZERO,
            counting: Some(ThreadLockWait::since(self.lock_wait_from)),
            id,
            recorded: false,
            lock_scope: LockScope::current(),
        }
    }

    /// The lock wait of this thread since the handler started.
    fn lock_wait(&self) -> Duration {
        Duration::from_nanos(
            cmux_threads::thread_lock_wait_nanos().saturating_sub(self.lock_wait_from),
        )
    }

    fn record(&mut self) {
        if matches!(self.reply, Reply::Pending) {
            self.reply = Reply::Done;
            let now = Instant::now();
            record_request(
                self.stats,
                self.method,
                MethodSample {
                    latency: now.saturating_duration_since(self.arrival.arrived),
                    handler: now.saturating_duration_since(self.dispatched),
                    lock_wait: self.lock_wait(),
                },
            );
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
    method: RequestMethod,
    arrived: Instant,
    dispatched: Instant,
    /// The lock wait of the threads that handled the request before the one
    /// handling it now.
    lock_waited: Duration,
    /// The thread handling the request now and its lock wait total when it
    /// took the request; `None` between [`Self::hand_to_worker`] and
    /// [`WorkerReply::start`].
    counting: Option<ThreadLockWait>,
    id: u64,
    recorded: bool,
    /// The caller class and op of the request (`debug-daemon-locks`).
    lock_scope: LockScope,
}

/// A thread's lock wait total ([`cmux_threads::thread_lock_wait_nanos`]) when
/// it took a request; only that thread can read its change.
struct ThreadLockWait {
    thread: std::thread::ThreadId,
    from: u64,
}

impl ThreadLockWait {
    /// The calling thread, counting from its total `from`.
    fn since(from: u64) -> Self {
        Self { thread: std::thread::current().id(), from }
    }

    /// The calling thread, counting from now.
    fn here() -> Self {
        Self::since(cmux_threads::thread_lock_wait_nanos())
    }

    /// The lock wait since `from`, when the calling thread is the one that
    /// took the request; `None` on any other thread.
    fn waited_here(&self) -> Option<Duration> {
        (std::thread::current().id() == self.thread).then(|| {
            Duration::from_nanos(cmux_threads::thread_lock_wait_nanos().saturating_sub(self.from))
        })
    }
}

/// An [`AsyncReply`] on its way to the worker that answers it: the
/// dispatching thread's lock wait is counted, and [`Self::start`] on the
/// worker counts the worker's from then on. Only [`Self::start`] can reply.
#[must_use = "start it on the worker thread, which then replies"]
pub(super) struct WorkerReply(AsyncReply);

impl WorkerReply {
    /// The worker took the request: its lock waits count from now.
    pub(super) fn start(self) -> AsyncReply {
        let Self(mut reply) = self;
        reply.counting = Some(ThreadLockWait::here());
        reply
    }
}

impl AsyncReply {
    /// Hands the request to a worker thread. Call it on the thread that has
    /// handled the request so far, just before the hand-off, so the waits of
    /// both threads add up (each thread counts its own, as Chrome's per-task
    /// `ThreadTicks`, base/task/common/task_annotator.cc).
    pub(super) fn hand_to_worker(mut self) -> WorkerReply {
        self.settle_lock_wait();
        self.counting = None;
        WorkerReply(self)
    }

    /// Adds the calling thread's lock wait since it took the request, then
    /// counts it from now. A thread that did not take the request (a hand-off
    /// without [`Self::hand_to_worker`]) adds nothing.
    fn settle_lock_wait(&mut self) -> Duration {
        if let Some(counting) = self.counting.take()
            && let Some(waited) = counting.waited_here()
        {
            self.lock_waited = self.lock_waited.saturating_add(waited);
            self.counting = Some(ThreadLockWait::here());
        }
        self.lock_waited
    }

    /// Counts the worker's lock acquisitions under the request's caller
    /// class and op until the guard drops, as on the thread that started it.
    pub(super) fn enter_lock_scope(&self) -> LockScopeGuard {
        self.lock_scope.enter()
    }

    /// Sends the worker's reply with `send`.
    pub(super) fn reply(mut self, send: impl FnOnce() -> bool) -> bool {
        trace_instant!(daemon, "daemon.request.async.handled", self.id);
        let sent = send();
        trace_instant!(daemon, "daemon.request.async.reply.queued", self.id, sent);
        self.record();
        sent
    }

    fn record(&mut self) -> Duration {
        let now = Instant::now();
        let latency = now.saturating_duration_since(self.arrived);
        if !self.recorded {
            self.recorded = true;
            let lock_wait = self.settle_lock_wait();
            record_request(
                &self.stats,
                self.method,
                MethodSample {
                    latency,
                    handler: now.saturating_duration_since(self.dispatched),
                    lock_wait,
                },
            );
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

/// One answered request: its class's latency and its method's row.
fn record_request(stats: &RequestStats, method: RequestMethod, sample: MethodSample) {
    stats.record_latency(method.class as usize, sample.latency);
    stats.methods().record(method.slot(), sample);
}

/// A fresh per-method table, one slot per [`RequestMethod::slot`].
pub(crate) fn method_latency_stats() -> MethodLatencyStats {
    MethodLatencyStats::new(REQUEST_METHOD_SLOTS)
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
