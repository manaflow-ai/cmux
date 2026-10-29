//! The per-connection surface scheduler: pending surface requests, the
//! connection's cancellation token, clear-history barriers, the stream
//! barrier, and the connection's one pump that runs queued requests in
//! order.
//!
//! The scheduler holds every request of the connection in arrival order:
//! its `Command`s and, since p05-ipc-086, its v2 operations, feature
//! routes and remote-relay lines ([`SequencedItem`]). The reader only
//! reads, cuts and sequences, as Chrome's IO thread only reads a Mojo
//! message and posts it to its receiver's sequence
//! (mojo/public/cpp/bindings/lib/multiplex_router.cc, `Accept` posting to
//! the endpoint's task runner).
//!
//! A connection holds no thread of its own. Its one pump is a `work` item
//! inside `will_block` (`Mux::post_connection_request`): the person's on
//! the User lane at `UserBlocking`, a may-block lane of its own so a key's
//! request never queues behind automation or background work; any other
//! connection's on the System lane at its request's cause priority
//! (`mux_work::ConnectionRoute`). The pump takes one
//! runnable request and runs it there, where it may read and commit
//! SQLite, read files and wait on a terminal host, as Chrome's IO thread
//! routes a message and a task runner that may block runs it
//! (content/browser/browser_thread_impl.cc, base/task/task_traits.h). One
//! pump exists at a time ([`ConnectionSurfaceState::pump_scheduled`]), so
//! the requests keep their order and run one at a time with no latch. A
//! pump that never runs (shutdown) answers every queued request and ends
//! the connection; a panicking one ends the connection.
//! The streams a connection opens are sequences of the daemon-wide
//! sequenced pool (stream_lanes.rs); a control command on a surface with an
//! open stream waits for the items that stream held when the command arrived.
//!
//! Requests of one surface run in arrival order. A person's input
//! (`Command::is_input`) runs before other surfaces' queued requests, as
//! Chrome's `kUserInput` queue outranks its other UI-thread queues
//! (content/browser/scheduler/browser_task_queues.h); input never passes
//! earlier input that can run, nor a request that names no surface.
//! A long read (`Command::is_long_read`) runs on a work item of the mux's Cpu
//! lane (`Mux::work`), not on the pump and not on a thread of its own, so a
//! later Send for another surface answers while it runs.
//!
//! Request threads (the WebSocket connection thread) start through
//! [`spawn_request_thread`]: UserInitiated, blocking disallowed (p02-threads
//! task 211). A pump task runs at its connection's class (connection_qos.rs,
//! task 224). A
//! clear-history request runs as a `Mux::work` item at its cause's
//! priority, blocking disallowed (task 230).
//!
//! Lock order: the scheduler's `state`, then the pool's. A pool task or
//! fence callback takes `state` with no pool lock held.

use super::MessageWriter;
use crate::panic_free::RecoverPoison;
use crate::supervised::{self, Fatal, ShutdownBehavior, SupervisedThread};

use super::CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY;
use super::CONNECTION_SURFACE_QUEUE_CAPACITY;
use super::ConnectionPermit;
use super::Request;
use super::RequestArrival;
use super::ResponseErrorDelivery;
use super::ServerSurfaceAdmissionError;
use super::ServerSurfaceBytesPermit;
use super::ServerSurfaceOperationAdmission;
use super::WorkerClass;
use super::connection_frame::PendingLine;
use super::frame_dispatch::FrameCall;
use super::handle_request_with_cancellation;
use super::send_request_error;
use super::send_request_error_with_delivery;
use super::sequenced_pool::{Fenced, SequencePriority};
use super::stream_lanes::{StreamLanes, StreamOpenError, StreamPostError, crosses_stream_ok};
use super::terminal_create;
use crate::Mux;
#[path = "connection_qos.rs"]
pub(super) mod connection_qos;
use crate::SurfaceId;
use crate::event_cause::EventCause;
use crate::stream_interrupt::InterruptSet;
use crate::stream_interrupt::StreamInterrupt;
use crate::thread_qos::ThreadType;
use cmux_threads::ThreadQos;
use cmux_threads::sync::Condvar;
use cmux_threads::sync::Mutex;
use cmux_threads::work::{Lane, Priority, Shutdown};
use connection_qos::{ConnectionClassCell, ConnectionThread};
use std::collections::HashSet;
use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::Weak;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::time::Duration;
use std::time::Instant;

/// The QoS of the threads that run a connection's requests and write its
/// replies and events: the person waits on them (Chromium's kDefault,
/// base/threading/platform_thread_apple.mm), [`ThreadType::Interactive`].
/// An automation connection's request threads rest at Utility once it is
/// classified (connection_qos.rs, task 224).
pub(super) const REQUEST_THREAD_QOS: ThreadQos = ThreadType::Interactive.qos();

/// Starts request thread `name` at [`REQUEST_THREAD_QOS`] with blocking
/// disallowed for its life, as Chrome's `DisallowBlocking` on its UI and IO
/// threads (base/threading/thread_restrictions.h). A checked blocking call
/// under it is a `server.blocking` site (recorded by default; panics under
/// `CMUX_DAEMON_BLOCKING=panic` in Debug), and its work moves to
/// `cmux_threads::work`.
///
/// The thread is registered with the release hang watch for its life; each
/// request it runs is one scope at its class deadline
/// (server/request_hang_watch.rs).
pub(super) fn spawn_request_thread<F, T>(name: &str, f: F) -> std::io::Result<SupervisedThread<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    supervised::spawn_at(name, REQUEST_THREAD_QOS, Fatal, ShutdownBehavior::Continue, move || {
        let thread = std::thread::current();
        let _hang_watch = cmux_hang_watch::register_thread(
            cmux_hang_watch::ThreadKind::Control,
            thread.name().unwrap_or("mux-request"),
        );
        cmux_threads::disallow_blocking();
        f()
    })
}

pub(super) struct PendingSurfaceRequest {
    pub(super) request: Request,
    /// When its line arrived and parsed: its request span starts there.
    pub(super) arrival: RequestArrival,
    /// The cause of the frame that queued it: its events keep that cause on
    /// whichever thread runs it (a control task, a clear-history worker or
    /// a creation commit on the terminal work pool).
    pub(super) cause: EventCause,
    /// The REQUEST frame it came in, if any: its reply is that frame's
    /// REPLY or ERROR, and a CANCEL of it ends it.
    pub(super) frame_call: Option<Arc<FrameCall>>,
    pub(super) retained_bytes: usize,
    pub(super) _bytes_permit: ServerSurfaceBytesPermit,
    /// The stream barrier's ticket while it waits for a stream of its
    /// target surface to run the items queued before it arrived.
    pub(super) stream_barrier: Option<u64>,
}

/// What an item of a connection's control sequence is charged to besides
/// its connection's own caps (`CONNECTION_SURFACE_QUEUE_CAPACITY` items and
/// `CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY` bytes, which every line the
/// reader accepts fits), and what the item holds for it while it lives.
pub(super) trait SequenceBudget {
    type Permit;
    fn reserve(
        admission: &Arc<ServerSurfaceOperationAdmission>,
        retained_bytes: usize,
    ) -> Result<Self::Permit, &'static str>;
}

/// A `Command`: also the daemon's surface-operation byte budget, which
/// every connection's `Command`s share.
pub(super) struct SurfaceOperationBudget;

impl SequenceBudget for SurfaceOperationBudget {
    type Permit = ServerSurfaceBytesPermit;

    fn reserve(
        admission: &Arc<ServerSurfaceOperationAdmission>,
        retained_bytes: usize,
    ) -> Result<ServerSurfaceBytesPermit, &'static str> {
        admission.try_reserve_bytes(retained_bytes).map_err(
            |ServerSurfaceAdmissionError::RetainedByteCapacity| {
                "server surface-operation byte budget is full; request was not executed"
            },
        )
    }
}

/// Any other line (a v2 operation, a feature route, a remote-relay line):
/// its connection's caps only. These lines never met the daemon's budget
/// before they were sequenced, and one connection's large
/// `fs-v1` write or transfer page must not refuse another connection's.
pub(super) struct ConnectionBudget;

impl SequenceBudget for ConnectionBudget {
    type Permit = ();

    fn reserve(_: &Arc<ServerSurfaceOperationAdmission>, _: usize) -> Result<(), &'static str> {
        Ok(())
    }
}

/// One item of a connection's control sequence.
pub(super) enum SequencedItem {
    /// A request whose line parsed as a `Command`.
    Request(PendingSurfaceRequest),
    /// Any other line (connection_frame.rs): its handler runs on the
    /// connection's pump, in arrival order with the
    /// connection's `Command`s.
    Line(PendingLine),
}

impl SequencedItem {
    fn request(&self) -> Option<&PendingSurfaceRequest> {
        match self {
            Self::Request(pending) => Some(pending),
            Self::Line(_) => None,
        }
    }

    fn cmd(&self) -> Option<&super::Command> {
        self.request().map(|pending| &pending.request.cmd)
    }

    /// The surface it is ordered by; a line is ordered by none, so it
    /// waits behind every clear-history barrier and long read, and nothing
    /// passes it.
    fn ordering_surface(&self) -> Option<SurfaceId> {
        self.cmd().and_then(super::Command::ordering_surface)
    }

    fn is_input(&self) -> bool {
        self.cmd().is_some_and(super::Command::is_input)
    }

    fn can_overtake_clear_barrier(&self) -> bool {
        self.cmd().is_some_and(super::Command::can_overtake_clear_barrier)
    }

    fn is_clear_history(&self) -> bool {
        self.cmd().is_some_and(super::Command::is_clear_history)
    }

    fn is_long_read(&self) -> bool {
        self.cmd().is_some_and(super::Command::is_long_read)
    }

    /// The stream barrier ticket it waits on; a line has none.
    fn stream_barrier(&self) -> Option<u64> {
        self.request().and_then(|pending| pending.stream_barrier)
    }

    /// The cause its line arrived with: the pump that runs it posts at its
    /// priority.
    fn cause(&self) -> EventCause {
        match self {
            Self::Request(pending) => pending.cause,
            Self::Line(line) => line.cause(),
        }
    }

    fn retained_bytes(&self) -> usize {
        match self {
            Self::Request(pending) => pending.retained_bytes,
            Self::Line(line) => line.retained_bytes(),
        }
    }

    #[cfg(test)]
    fn is_line(&self) -> bool {
        matches!(self, Self::Line(_))
    }
}

/// Why an item did not join its connection's control sequence.
#[derive(Debug)]
pub(super) enum NotSequenced {
    /// The sequence closed: the connection is ending.
    Closed,
    /// The sequence or the daemon's byte budget is full; the request was
    /// not executed.
    Full(&'static str),
}

impl NotSequenced {
    /// The error text of the request's refusal (none when closed).
    pub(super) fn refusal(&self) -> Option<String> {
        match self {
            Self::Closed => None,
            Self::Full(reason) => Some((*reason).to_owned()),
        }
    }
}

/// What the control sequence runs the connection's requests with: set by
/// its first request, dropped once the scheduler drained.
pub(super) struct ControlContext {
    pub(super) mux: Arc<Mux>,
    pub(super) client: u64,
    pub(super) writer: MessageWriter,
}

#[derive(Default)]
pub(super) struct ConnectionSurfaceState {
    pub(super) requests: VecDeque<SequencedItem>,
    pub(super) queued_bytes: usize,
    pub(super) active_clear_surfaces: HashSet<SurfaceId>,
    /// Surfaces whose long read runs on a work item (`Command::is_long_read`).
    pub(super) active_read_surfaces: HashSet<SurfaceId>,
    /// Terminal creates handed to the terminal work pool and not yet answered (`terminal_create`).
    pub(super) active_creations: usize,
    pub(super) context: Option<ControlContext>,
    /// A pump (one request) is posted or running
    /// (`Mux::post_connection_request`). It is the only thing that orders
    /// the connection's requests: one pump at a time runs one request at a
    /// time.
    pub(super) pump_scheduled: bool,
    /// The connection's open streams.
    pub(super) streams: StreamLanes,
    pub(super) next_barrier: u64,
    /// Closed, every request run or dropped and no pump left: the
    /// connection permit is released.
    pub(super) drained: bool,
    pub(super) closed: bool,
    /// Run once the scheduler is settled ([`ConnectionSurfaceScheduler::when_settled`]).
    pub(super) settled_hooks: Vec<SettledHook>,
    /// A line runs on the pump (tests wait for it to answer).
    #[cfg(test)]
    pub(super) line_running: bool,
}

/// What a connection does once its scheduler settled: its close, posted
/// back to its line sequence (server/line_connection.rs).
pub(super) type SettledHook = Box<dyn FnOnce() + Send>;

impl ConnectionSurfaceState {
    /// Drained, and no clear-history, long read or creation still runs.
    pub(super) fn settled(&self) -> bool {
        self.drained
            && self.active_clear_surfaces.is_empty()
            && self.active_read_surfaces.is_empty()
            && self.active_creations == 0
    }

    /// The hooks to run now that the state may have settled, to be run
    /// once its lock is released.
    pub(super) fn take_settled_hooks(&mut self) -> Vec<SettledHook> {
        if self.settled() { std::mem::take(&mut self.settled_hooks) } else { Vec::new() }
    }
}

/// Set when a connection's request scheduler closes. Request handlers that
/// wait (wait-for) register an interrupt instead of polling the flag.
#[derive(Default)]
pub(super) struct ConnectionCancellation {
    pub(super) flag: AtomicBool,
    pub(super) interrupts: InterruptSet,
}

impl ConnectionCancellation {
    pub(super) fn cancel(&self) {
        self.flag.store(true, Ordering::Release);
        self.interrupts.fire();
    }

    pub(super) fn is_cancelled(&self) -> bool {
        self.flag.load(Ordering::Acquire)
    }

    pub(super) fn register_interrupt(&self, interrupt: &Arc<StreamInterrupt>) {
        self.interrupts.register(interrupt);
    }

    /// Cancels `self` when `parent` cancels (at once if it has), for as long
    /// as the returned link lives: a request's own cancellation follows its
    /// connection's.
    pub(super) fn follow(
        self: &Arc<Self>,
        parent: &ConnectionCancellation,
    ) -> Arc<StreamInterrupt> {
        let link = StreamInterrupt::new();
        let child = Arc::downgrade(self);
        link.on_fire(move || {
            if let Some(child) = child.upgrade() {
                child.cancel();
            }
        });
        parent.register_interrupt(&link);
        link
    }
}

impl PendingSurfaceRequest {
    /// The writer its reply goes through: `writer`, answering its frame.
    pub(super) fn reply_writer(&self, writer: &MessageWriter) -> MessageWriter {
        match &self.frame_call {
            Some(call) => writer.replying_to(call.clone()),
            None => writer.clone(),
        }
    }
}

pub(super) struct ConnectionSurfaceScheduler {
    pub(super) state: Mutex<ConnectionSurfaceState>,
    pub(super) changed: Condvar,
    pub(super) admission: Arc<ServerSurfaceOperationAdmission>,
    pub(super) cancelled: ConnectionCancellation,
    pub(super) connection_permit: Mutex<Option<ConnectionPermit>>,
    pub(super) creations: terminal_create::ConnectionCreations,
    /// The connection's client class, set by its registry record; its
    /// request tasks rest at it (connection_qos.rs).
    pub(super) class: Arc<ConnectionClassCell>,
}

impl Default for ConnectionSurfaceScheduler {
    fn default() -> Self {
        Self::new(Arc::new(ServerSurfaceOperationAdmission::default()))
    }
}

impl ConnectionSurfaceScheduler {
    pub(super) fn new(admission: Arc<ServerSurfaceOperationAdmission>) -> Self {
        Self::new_inner(admission, None)
    }

    #[cfg(test)]
    pub(super) fn new_with_connection_permit(
        admission: Arc<ServerSurfaceOperationAdmission>,
        permit: ConnectionPermit,
    ) -> Self {
        Self::new_inner(admission, Some(permit))
    }

    pub(super) fn new_inner(
        admission: Arc<ServerSurfaceOperationAdmission>,
        connection_permit: Option<ConnectionPermit>,
    ) -> Self {
        Self {
            state: Mutex::new(ConnectionSurfaceState::default()),
            changed: Condvar::new(),
            admission,
            cancelled: ConnectionCancellation::default(),
            connection_permit: Mutex::new(connection_permit),
            creations: terminal_create::ConnectionCreations::default(),
            class: Arc::default(),
        }
    }

    /// The scheduler of a connection whose client class is `class` (its
    /// registry record's cell, `ClientRegistry::connection_class`).
    pub(super) fn classed(mut self, class: Arc<ConnectionClassCell>) -> Self {
        self.class = class;
        self
    }
}

impl ConnectionSurfaceScheduler {
    /// [`Self::dispatch_at`] for a request made in process.
    #[cfg(test)]
    pub(super) fn dispatch(
        self: &Arc<Self>,
        mux: Arc<Mux>,
        client: u64,
        request: &mut Option<Request>,
        retained_bytes: usize,
        writer: MessageWriter,
    ) -> Option<bool> {
        self.dispatch_at(mux, client, request, RequestArrival::now(), retained_bytes, writer)
    }

    /// Queues `request`, whose line arrived and parsed at `arrival`, on the
    /// connection's control sequence.
    pub(super) fn dispatch_at(
        self: &Arc<Self>,
        mux: Arc<Mux>,
        client: u64,
        request: &mut Option<Request>,
        arrival: RequestArrival,
        retained_bytes: usize,
        writer: MessageWriter,
    ) -> Option<bool> {
        // Nothing to schedule; the connection stays open.
        let Some(queued) = request.take() else { return Some(true) };
        let (request_id, is_clear_history) = (queued.id.clone(), queued.cmd.is_clear_history());
        let sequenced = self.sequence::<SurfaceOperationBudget>(
            &mux,
            client,
            retained_bytes,
            &writer,
            |bytes_permit| {
                SequencedItem::Request(PendingSurfaceRequest {
                    request: queued,
                    arrival,
                    cause: EventCause::current(),
                    frame_call: writer.frame_call().cloned(),
                    retained_bytes,
                    _bytes_permit: bytes_permit,
                    stream_barrier: None,
                })
            },
        );
        let Err(not_sequenced) = sequenced else { return Some(true) };
        let Some(refusal) = not_sequenced.refusal() else { return Some(false) };
        Some(send_request_error_with_delivery(
            &writer,
            request_id,
            &refusal,
            is_clear_history.then_some(ResponseErrorDelivery::KnownNotDelivered),
        ))
    }

    /// Appends the item `item` makes to the connection's control sequence,
    /// unless the sequence is closed or full, and schedules it. `item` gets
    /// what budget `B` reserved for it; it runs under the sequence's lock
    /// and does not block. A `Command` on a surface with an open stream
    /// gets its stream barrier here.
    pub(super) fn sequence<B: SequenceBudget>(
        self: &Arc<Self>,
        mux: &Arc<Mux>,
        client: u64,
        retained_bytes: usize,
        writer: &MessageWriter,
        item: impl FnOnce(B::Permit) -> SequencedItem,
    ) -> Result<(), NotSequenced> {
        // A connection whose writer closed answers nothing more.
        if !writer.is_open() {
            return Err(NotSequenced::Closed);
        }
        let mut state = self.state.lock().recover_poison();
        if state.closed {
            return Err(NotSequenced::Closed);
        }
        // The depth this request meets on arrival, itself included, recorded
        // also when the sequence is full and refuses it: those are the
        // saturation samples (`server-stats` `ipc` `sequence_depth`).
        let arrival_depth = state.requests.len() + 1;
        let over_count = state.requests.len() >= CONNECTION_SURFACE_QUEUE_CAPACITY;
        let over_bytes = retained_bytes
            > CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY.saturating_sub(state.queued_bytes);
        let admitted = if over_count || over_bytes {
            Err("surface request queue is full; request was not executed")
        } else {
            B::reserve(&self.admission, retained_bytes)
        };
        let bytes_permit = match admitted {
            Ok(bytes_permit) => bytes_permit,
            Err(reason) => {
                drop(state);
                mux.ipc_stats().sequence_depth(arrival_depth);
                return Err(NotSequenced::Full(reason));
            }
        };
        // The pump keeps the connection's writer: each request answers on
        // its own (`frame_call`).
        if state.context.is_none() {
            state.context = Some(ControlContext {
                mux: mux.clone(),
                client,
                writer: writer.connection_writer(),
            });
        }
        let mut item = item(bytes_permit);
        if let SequencedItem::Request(pending) = &mut item {
            pending.stream_barrier =
                self.stream_barrier_locked(&mut state, mux, &pending.request.cmd);
        }
        state.queued_bytes = state.queued_bytes.saturating_add(retained_bytes);
        state.requests.push_back(item);
        let pump = self.schedule_locked(&mut state);
        self.changed.notify_all();
        drop(state);
        mux.ipc_stats().sequence_depth(arrival_depth);
        // A refused pump (shutdown began) answers every queued request,
        // this one included, and closes the connection ([`PumpTicket`]).
        if let Some(pump) = pump {
            pump.post();
        }
        Ok(())
    }

    /// The stream barrier for `cmd`: a ticket when its target surface has an
    /// open stream holding items, released by the fence once they ran.
    fn stream_barrier_locked(
        self: &Arc<Self>,
        state: &mut ConnectionSurfaceState,
        mux: &Mux,
        cmd: &super::Command,
    ) -> Option<u64> {
        if state.streams.is_empty() {
            return None;
        }
        let surface = cmd.ordering_surface()?;
        if crosses_stream_ok(cmd.wire_name()) {
            return None;
        }
        let ticket = state.next_barrier;
        let scheduler: Weak<Self> = Arc::downgrade(self);
        let release = move || {
            if let Some(scheduler) = scheduler.upgrade() {
                scheduler.release_stream_barrier(ticket);
            }
        };
        match state.streams.barrier(&mux.sequenced_pool, surface, release) {
            Fenced::Waiting => {
                state.next_barrier += 1;
                Some(ticket)
            }
            Fenced::Drained(_) => None,
        }
    }

    /// The fence of `ticket` passed: its request may run.
    fn release_stream_barrier(self: &Arc<Self>, ticket: u64) {
        let mut state = self.state.lock().recover_poison();
        if let Some(SequencedItem::Request(pending)) =
            state.requests.iter_mut().find(|item| item.stream_barrier() == Some(ticket))
        {
            pending.stream_barrier = None;
        }
        self.reschedule_locked(state);
    }

    /// Marks a pump scheduled for the next runnable request unless one is
    /// posted or running; the caller posts it ([`PumpPost::post`]) once it
    /// released the state lock, since a refused post ends the connection
    /// under that lock.
    fn schedule_locked(self: &Arc<Self>, state: &mut ConnectionSurfaceState) -> Option<PumpPost> {
        if state.pump_scheduled {
            return None;
        }
        let index = Self::next_runnable_index(state)?;
        let mux = state.context.as_ref()?.mux.clone();
        let cause = state.requests.get(index).map_or(EventCause::Program, SequencedItem::cause);
        let person = self.class.get() == connection_qos::ConnectionClass::Person;
        let route = crate::mux::mux_work::ConnectionRoute::of(person, cause);
        state.pump_scheduled = true;
        Some(PumpPost { ticket: PumpTicket { scheduler: self.clone(), ran: false }, mux, route })
    }

    /// [`Self::schedule_locked`] after a change that may let a request run
    /// (a pump ended, a clear or a stream barrier released), then settles a
    /// drained scheduler.
    fn reschedule_locked(
        self: &Arc<Self>,
        mut state: std::sync::MutexGuard<'_, ConnectionSurfaceState>,
    ) {
        let pump = self.schedule_locked(&mut state);
        let drained = self.settle_locked(&mut state);
        let hooks = state.take_settled_hooks();
        self.changed.notify_all();
        drop(state);
        // The context drops outside the lock.
        drop(drained);
        if let Some(pump) = pump {
            pump.post();
        }
        for hook in hooks {
            hook();
        }
    }

    /// A pump that never ran (shutdown refused it or dropped it queued):
    /// every queued request is answered that it did not run, and the
    /// connection ends, so no client waits for a reply that cannot come.
    fn refuse_queued(self: &Arc<Self>) {
        self.cancelled.cancel();
        let (queued, writer) = {
            let mut state = self.state.lock().recover_poison();
            state.closed = true;
            state.queued_bytes = 0;
            let writer = state.context.as_ref().map(|context| context.writer.clone());
            (std::mem::take(&mut state.requests), writer)
        };
        let Some(writer) = writer else { return };
        for item in queued {
            if let SequencedItem::Request(pending) = item {
                let (id, reply) = (pending.request.id.clone(), pending.reply_writer(&writer));
                drop(pending);
                let _ = send_request_error(
                    &reply,
                    id,
                    "the daemon is shutting down; request was not executed",
                );
            }
        }
        // A line has no reply that can name it: its connection closes.
        writer.close_after_control();
    }

    /// A pump's request panicked: its connection ends, so its client is
    /// never left waiting.
    fn close_connection(self: &Arc<Self>) {
        let writer = self.state.lock().recover_poison().context.as_ref().map(|c| c.writer.clone());
        self.close();
        if let Some(writer) = writer {
            writer.close();
        }
    }

    /// Runs `then` once the scheduler is settled: closed ([`Self::finish`]
    /// or [`Self::close`]), drained, and no clear-history, long read or
    /// creation still running. At once when it is. It never waits, as
    /// [`Self::wait_for_completion`] does: the connection's line sequence
    /// ends on it.
    pub(super) fn when_settled(&self, then: SettledHook) {
        let mut state = self.state.lock().recover_poison();
        if state.settled() {
            drop(state);
            then();
            return;
        }
        state.settled_hooks.push(then);
    }

    /// Marks the scheduler drained once it is closed, holds no request and
    /// runs no pump. The connection permit is released here, under the
    /// state lock and before `drained` is set, so no waiter sees a drained
    /// connection that still counts against the connection limit. The
    /// context leaves with the returned value, for the caller to drop
    /// outside the lock.
    fn settle_locked(&self, state: &mut ConnectionSurfaceState) -> Option<Drained> {
        if state.drained || !state.closed || !state.requests.is_empty() || state.pump_scheduled {
            return None;
        }
        // Lock order: `state`, then the permit's (a leaf).
        drop(self.connection_permit.lock().recover_poison().take());
        state.drained = true;
        Some(Drained { _context: state.context.take() })
    }

    /// The connection's pump, a may-block `work` item: runs the next
    /// runnable item, here. A handler may block (SQLite, files, a terminal
    /// host), and this thread may: the reader only routed the item.
    fn pump(self: &Arc<Self>) {
        let Some((item, mux, client, writer)) = self.take_runnable() else { return };
        // R3 (Debug): a connection's requests never run on a thread that
        // disallows blocking (a reader, the person's IO loop, a control
        // worker), on any path and at any load.
        debug_assert!(
            !cmux_threads::blocking::is_blocking_disallowed(),
            "a connection's request ran on '{}', which disallows blocking",
            std::thread::current().name().unwrap_or("<unnamed>"),
        );
        if !writer.is_open() {
            drop(item);
            self.close();
            return;
        }
        // The task runs at its connection's class on the shared worker, and
        // the class ends with the task (connection_qos.rs, task 224). Not a
        // `RestingClass`: that asks the worker's registry row to stay there.
        let _class = mux.request_qos().enter_class(self.class.get().qos(ConnectionThread::Request));
        let running = match item {
            SequencedItem::Request(pending) => {
                run_dispatched_request(self, &mux, client, pending, &writer)
            }
            SequencedItem::Line(line) => {
                let connection = line.connection_writer();
                let keep_open = super::connection_frame::run_sequenced_line(self, &mux, line);
                if !keep_open {
                    // The handler closes its connection: the replies queued
                    // so far go out, then the socket shuts and the reader ends.
                    connection.close_after_control();
                }
                keep_open
            }
        };
        if !running {
            self.close();
        }
    }

    /// The pump ended (or unwound, or never ran): the next runnable request
    /// gets its own.
    pub(super) fn finish_pump(self: &Arc<Self>) {
        let mut state = self.state.lock().recover_poison();
        state.pump_scheduled = false;
        #[cfg(test)]
        {
            state.line_running = false;
        }
        self.reschedule_locked(state);
    }

    fn take_runnable(&self) -> Option<(SequencedItem, Arc<Mux>, u64, MessageWriter)> {
        let mut state = self.state.lock().recover_poison();
        let context = state.context.as_ref()?;
        let (mux, client, writer) = (context.mux.clone(), context.client, context.writer.clone());
        let index = Self::next_runnable_index(&state)?;
        let item = state.requests.remove(index)?;
        state.queued_bytes = state.queued_bytes.saturating_sub(item.retained_bytes());
        // Clear-history and long reads are always ordered by a surface; a
        // worker never overlaps another on the same one.
        let workers = if item.is_clear_history() {
            Some(&mut state.active_clear_surfaces)
        } else if item.is_long_read() {
            Some(&mut state.active_read_surfaces)
        } else {
            None
        };
        if let Some(workers) = workers
            && let Some(surface) = item.ordering_surface()
            && !workers.insert(surface)
        {
            eprintln!("cmux: surface worker overlapped surface {surface}");
        }
        #[cfg(test)]
        {
            state.line_running = item.is_line();
        }
        self.changed.notify_all();
        Some((item, mux, client, writer))
    }

    /// The queued request the control sequence runs next, if one may run now.
    ///
    /// - A request waits for every earlier request of its surface, and for
    ///   that surface's clear-history or long-read worker.
    /// - Nothing passes a request that names no surface, nor a line (a v2
    ///   operation, a feature route, a remote-relay line).
    /// - Input (`Command::is_input`) passes other surfaces' requests.
    /// - A request waiting on its stream barrier holds its surface and every
    ///   later non-input request; only other surfaces' input passes it.
    /// - With no worker running, the first request runs unless input passes
    ///   it; while one runs, only a request that may overtake its barrier
    ///   runs, and a non-input one passes no request that could run.
    pub(super) fn next_runnable_index(state: &ConnectionSurfaceState) -> Option<usize> {
        let idle = state.active_clear_surfaces.is_empty() && state.active_read_surfaces.is_empty();
        if idle && state.requests.len() <= 1 {
            return state.requests.front()?.stream_barrier().is_none().then_some(0);
        }
        let busy = |surface: &SurfaceId| {
            state.active_clear_surfaces.contains(surface)
                || state.active_read_surfaces.contains(surface)
        };
        // Surfaces with an earlier request still queued.
        let mut held = HashSet::new();
        // The non-input request that runs unless later input passes it.
        let mut candidate = None;
        // Whether a request that could run, or one waiting on its stream
        // barrier, was passed.
        let mut passed = false;
        for (index, item) in state.requests.iter().enumerate() {
            let Some(surface) = item.ordering_surface() else {
                return candidate.or((idle && !passed).then_some(index));
            };
            if busy(&surface) || held.contains(&surface) {
                continue;
            }
            if item.stream_barrier().is_none() {
                if item.is_input() {
                    return Some(index);
                }
                if !passed && (idle || item.can_overtake_clear_barrier()) {
                    candidate = Some(index);
                }
            }
            passed = true;
            held.insert(surface);
        }
        candidate
    }

    pub(super) fn finish_clear(self: &Arc<Self>, surface: SurfaceId) {
        let mut state = self.state.lock().recover_poison();
        state.active_clear_surfaces.remove(&surface);
        self.reschedule_locked(state);
    }

    pub(super) fn finish_read(self: &Arc<Self>, surface: SurfaceId) {
        let mut state = self.state.lock().recover_poison();
        state.active_read_surfaces.remove(&surface);
        self.reschedule_locked(state);
    }

    /// Runs `pending`, a long read of `surface`, on the mux's Cpu work lane
    /// at its cause's priority. Its surface stays held until the item ends.
    /// False when the lane refused it (shutdown began): the dropped read
    /// answered the request, and the connection closes.
    fn start_long_read(
        self: &Arc<Self>,
        mux: &Arc<Mux>,
        client: u64,
        surface: SurfaceId,
        pending: PendingSurfaceRequest,
        writer: &MessageWriter,
    ) -> bool {
        let priority = long_read_priority(pending.cause);
        let read = LongRead {
            scheduler: self.clone(),
            mux: Arc::downgrade(mux),
            client,
            surface,
            writer: writer.clone(),
            pending: Some(pending),
        };
        // A refused item drops `read`, which answers it and frees `surface`.
        mux.work.post(priority, Lane::Cpu, Shutdown::SkipOnShutdown, move || read.run()).is_ok()
    }

    /// Opens stream `stream` of this connection for `surface`: its items run
    /// in order on a sequence of their own at `priority`.
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "attach-streams (p05-ipc-074) opens the first stream")
    )]
    pub(super) fn open_stream(
        &self,
        mux: &Mux,
        stream: u16,
        surface: SurfaceId,
        priority: SequencePriority,
    ) -> Result<(), StreamOpenError> {
        let mut state = self.state.lock().recover_poison();
        state.streams.open(&mux.sequenced_pool, stream, surface, priority)
    }

    /// Closes stream `stream`; the items it holds still run.
    #[cfg_attr(not(test), expect(dead_code, reason = "attach-streams (p05-ipc-074) ends streams"))]
    pub(super) fn close_stream(&self, stream: u16) -> bool {
        self.state.lock().recover_poison().streams.close(stream)
    }

    /// Queues `item` on stream `stream`, after its earlier items. A full
    /// stream refuses it: known not delivered.
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "INPUT frames (p05-ipc-078) post the first stream items")
    )]
    pub(super) fn post_stream<F>(&self, stream: u16, item: F) -> Result<(), StreamPostError>
    where
        F: FnOnce() + Send + 'static,
    {
        let state = self.state.lock().recover_poison();
        if state.closed {
            return Err(StreamPostError::UnknownStream);
        }
        state.streams.post(stream, item)
    }

    /// Ends the connection's requests: the queued ones are dropped unrun,
    /// the running one is cancelled.
    pub(super) fn close(self: &Arc<Self>) {
        self.cancelled.cancel();
        let mut state = self.state.lock().recover_poison();
        state.closed = true;
        state.requests.clear();
        state.queued_bytes = 0;
        self.reschedule_locked(state);
    }

    /// No request comes after this one: the queued ones still run.
    pub(super) fn finish(self: &Arc<Self>) {
        let mut state = self.state.lock().recover_poison();
        state.closed = true;
        self.reschedule_locked(state);
    }

    /// Tests: whether the sequence closed (a handler closed its connection).
    #[cfg(test)]
    pub(super) fn is_closed(&self) -> bool {
        self.state.lock().recover_poison().closed
    }

    /// Tests: waits until every line sequenced so far is answered, as a
    /// caller that wants the reply of the line it just handed in.
    #[cfg(test)]
    pub(super) fn wait_for_lines(&self) {
        let mut state = self.state.lock().recover_poison();
        while !state.drained
            && (state.line_running || state.requests.iter().any(SequencedItem::is_line))
        {
            state = self.changed.wait(state).recover_poison();
        }
    }

    pub(super) fn wait_for_completion(&self, timeout: Option<Duration>) -> bool {
        // A timeout too large to represent waits without a deadline.
        let deadline = timeout.and_then(|timeout| Instant::now().checked_add(timeout));
        let settled = ConnectionSurfaceState::settled;
        let mut state = self.state.lock().recover_poison();
        while !settled(&state) {
            if let Some(deadline) = deadline {
                if Instant::now() >= deadline {
                    break;
                }
                let remaining = deadline.saturating_duration_since(Instant::now());
                let (next, _) = self.changed.wait_timeout(state, remaining).recover_poison();
                state = next;
            } else {
                state = self.changed.wait(state).recover_poison();
            }
        }
        settled(&state)
    }

    #[cfg(test)]
    pub(super) fn finish_and_wait(self: &Arc<Self>) {
        self.finish();
        let drained = self.wait_for_completion(None);
        debug_assert!(drained, "unbounded graceful drain must settle");
    }

    pub(super) fn close_and_wait(self: &Arc<Self>, timeout: Duration) -> bool {
        self.close();
        self.wait_for_completion(Some(timeout))
    }
}

/// What a drained scheduler lets go: dropped outside its lock.
struct Drained {
    _context: Option<ControlContext>,
}

/// A pump [`ConnectionSurfaceScheduler::schedule_locked`] marked
/// scheduled, to post once the state lock is released.
#[must_use]
struct PumpPost {
    ticket: PumpTicket,
    mux: Arc<Mux>,
    route: crate::mux::mux_work::ConnectionRoute,
}

impl PumpPost {
    /// Posts the pump ([`Mux::post_connection_request`]). A refused post
    /// drops its ticket, which answers the queued requests and ends the
    /// connection.
    fn post(self) {
        let PumpPost { ticket, mux, route } = self;
        let _ = mux.post_connection_request(route, move || ticket.run());
    }
}

/// The one pump of a connection, from its post to its end. However it ends
/// (run, unwound, or dropped unrun when shutdown refused or dropped it),
/// the scheduler learns, so the connection never keeps a pump that cannot
/// come: an unrun one answers the queued requests and ends the connection,
/// a panicking one ends the connection. Only locks that recover from
/// poison are taken here, so it is safe while unwinding.
struct PumpTicket {
    scheduler: Arc<ConnectionSurfaceScheduler>,
    ran: bool,
}

impl PumpTicket {
    fn run(mut self) {
        self.ran = true;
        let scheduler = self.scheduler.clone();
        scheduler.pump();
    }
}

impl Drop for PumpTicket {
    fn drop(&mut self) {
        if !self.ran {
            self.scheduler.refuse_queued();
        } else if std::thread::panicking() {
            self.scheduler.close_connection();
        }
        self.scheduler.finish_pump();
    }
}

struct ActiveClearGuard {
    scheduler: Arc<ConnectionSurfaceScheduler>,
    surface: SurfaceId,
}

impl Drop for ActiveClearGuard {
    fn drop(&mut self) {
        self.scheduler.finish_clear(self.surface);
    }
}

/// The work lane priority of a long read: a person waits for the app's,
/// nobody for automation's.
fn long_read_priority(cause: EventCause) -> Priority {
    match cause {
        EventCause::Frontend => Priority::UserBlocking,
        EventCause::Program => Priority::UserVisible,
        EventCause::Automation => Priority::BestEffort,
    }
}

/// A long read handed to the work lane. It holds its surface until it drops;
/// dropped unrun (the lane refused it or shut down first), it answers its
/// request with an error. It holds the mux weakly, as `Mux::post_mux_work`
/// items do, so a queued read never keeps a dropped mux alive.
struct LongRead {
    scheduler: Arc<ConnectionSurfaceScheduler>,
    mux: Weak<Mux>,
    client: u64,
    surface: SurfaceId,
    writer: MessageWriter,
    pending: Option<PendingSurfaceRequest>,
}

impl LongRead {
    /// Runs the read as a request task does, blocking disallowed.
    fn run(mut self) {
        let Some(mux) = self.mux.upgrade() else { return };
        let Some(pending) = self.pending.take() else { return };
        let (scheduler, client, writer) = (&self.scheduler, self.client, &self.writer);
        cmux_threads::blocking::with_blocking_disallowed(|| {
            if !run_pending_request(scheduler, &mux, client, pending, writer) {
                scheduler.close();
            }
        });
    }
}

impl Drop for LongRead {
    fn drop(&mut self) {
        if let Some(pending) = self.pending.take() {
            let (id, reply) = (pending.request.id.clone(), pending.reply_writer(&self.writer));
            drop(pending);
            if !send_request_error(
                &reply,
                id,
                "the daemon is shutting down; request was not executed",
            ) {
                self.scheduler.close();
            }
        }
        self.scheduler.finish_read(self.surface);
    }
}

/// A clear-history request on its way to its work item. Dropped unrun (a
/// refused post, a queued item dropped at shutdown) it ends the barrier and
/// answers that the request did not run, so no request goes unanswered.
struct ClearWork {
    reply: MessageWriter,
    pending: Option<PendingSurfaceRequest>,
    active: Option<ActiveClearGuard>,
}

impl Drop for ClearWork {
    fn drop(&mut self) {
        let Some(pending) = self.pending.take() else { return };
        let id = pending.request.id.clone();
        drop(pending);
        drop(self.active.take());
        let _ = send_request_error_with_delivery(
            &self.reply,
            id,
            "clear-history did not run: the daemon is shutting down",
            Some(ResponseErrorDelivery::KnownNotDelivered),
        );
    }
}

pub(super) fn run_pending_request(
    scheduler: &ConnectionSurfaceScheduler,
    mux: &Arc<Mux>,
    client: u64,
    pending: PendingSurfaceRequest,
    writer: &MessageWriter,
) -> bool {
    let writer = &pending.reply_writer(writer);
    let PendingSurfaceRequest { request, arrival, cause, frame_call, _bytes_permit, .. } = pending;
    // The request runs at its cause's class (crate::request_qos).
    let _cause = mux.request_qos().enter(cause);
    // A framed request ends on its own CANCEL or with its connection.
    let (cancellation, _follows_connection) = match &frame_call {
        Some(call) => {
            (&**call.cancellation(), Some(call.cancellation().follow(&scheduler.cancelled)))
        }
        None => (&scheduler.cancelled, None),
    };
    if frame_call.is_some() && cancellation.is_cancelled() {
        // Cancelled while queued: answered, never run.
        return send_request_error(writer, request.id, "request cancelled");
    }
    // The control sequence, a clear-history worker or a creation commit
    // runs the request: a request path like the reader's
    // (`crate::request_path`).
    let _request_path = crate::request_path::RequestPathScope::enter(mux.request_path_stats());
    // Its lock acquisitions count under the connection's caller class
    // (`debug-daemon-locks`), as on the reader.
    let _lock_caller = super::lock_caller_scope(writer);
    // Watched until the reply is queued: past 250 ms it lands in
    // server-stats `slow_requests` (request_watchdog.rs). This runs off the
    // connection thread, whose own watch ended with the hand-off.
    let _watched = mux.request_watchdog.begin_command(client, &request.cmd);
    handle_request_with_cancellation(mux, client, request, arrival, writer, Some(cancellation))
}

/// Runs one request the pump took: a clear-history or a long read on its
/// own work item, a create on the terminal work pool, anything else here,
/// on the connection's pump. False when the connection must close.
fn run_dispatched_request(
    scheduler: &Arc<ConnectionSurfaceScheduler>,
    mux: &Arc<Mux>,
    client: u64,
    pending: PendingSurfaceRequest,
    writer: &MessageWriter,
) -> bool {
    if pending.request.cmd.is_clear_history()
        && let Some(surface) = pending.request.cmd.ordering_surface()
    {
        return run_clear_history(scheduler, mux, client, pending, surface, writer);
    }
    if pending.request.cmd.is_long_read()
        && let Some(surface) = pending.request.cmd.ordering_surface()
    {
        return scheduler.start_long_read(mux, client, surface, pending, writer);
    }
    if pending.request.cmd.creates_terminal() {
        return scheduler.submit_creation(mux, client, pending, writer);
    }
    run_pending_request(scheduler, mux, client, pending, writer)
}

fn run_clear_history(
    scheduler: &Arc<ConnectionSurfaceScheduler>,
    mux: &Arc<Mux>,
    client: u64,
    pending: PendingSurfaceRequest,
    surface: SurfaceId,
    writer: &MessageWriter,
) -> bool {
    let class = WorkerClass::of(writer.lock_caller.get());
    let Some(worker_permit) = scheduler.admission.try_reserve_worker(class) else {
        let (id, reply) = (pending.request.id.clone(), pending.reply_writer(writer));
        drop(pending);
        scheduler.finish_clear(surface);
        return send_request_error_with_delivery(
            &reply,
            id,
            "too many clear-history operations are already in progress",
            Some(ResponseErrorDelivery::KnownNotDelivered),
        );
    };
    // A work item at the priority of the request it serves (its cause), as
    // Chrome posts a task at its caller's priority; it runs the request as a
    // request thread does, blocking disallowed. It waits on the terminal and
    // its PTY, so it is system-lane work (task 230).
    let priority = pending.cause.work_priority();
    let mut clear = ClearWork {
        reply: pending.reply_writer(writer),
        pending: Some(pending),
        active: Some(ActiveClearGuard { scheduler: scheduler.clone(), surface }),
    };
    let worker_scheduler = scheduler.clone();
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let posted = mux.work.post(priority, Lane::System, Shutdown::SkipOnShutdown, move || {
        // Drop the mux-wide permit before the barrier ends and wakes the next
        // request queued behind it.
        let _active = clear.active.take();
        let _worker_permit = worker_permit;
        let Some(pending) = clear.pending.take() else { return };
        cmux_threads::blocking::with_blocking_disallowed(|| {
            if !run_pending_request(&worker_scheduler, &worker_mux, client, pending, &worker_writer)
            {
                worker_scheduler.close();
            }
        });
    });
    // Refused (shutdown began): the dropped item answered the request, and
    // the connection closes.
    posted.is_ok()
}

#[cfg(test)]
#[path = "request_threads_tests.rs"]
mod request_threads_tests;

#[cfg(test)]
#[path = "connection_sequence_tests.rs"]
mod connection_sequence_tests;
