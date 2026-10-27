//! The per-connection surface scheduler: pending surface requests, the
//! connection's cancellation token, clear-history barriers, the stream
//! barrier, and the connection's control sequence on the daemon-wide
//! sequenced pool (sequenced_pool.rs, p05-ipc-073) that runs queued surface
//! operations in order.
//!
//! A connection holds no thread of its own: its control sequence runs one
//! request per task on the pool's control workers, as Chrome dispatches each
//! IPC message as a task on its bound sequence (docs/threading_and_tasks.md).
//! A request that blocks tells the pool at the blocking site itself (a
//! request-path note, or `request_path::will_block` around a PTY or host
//! input write and the wait of `wait-for`), so it starts a temporary worker
//! instead of holding one of the fixed ones. The streams a connection opens
//! are sequences of their own (stream_lanes.rs); a control command on a surface with an open stream
//! waits for the items that stream held when the command arrived.
//!
//! Request threads (the WebSocket connection thread) start through
//! [`spawn_request_thread`]: UserInitiated, blocking disallowed (p02-threads
//! task 211); the pool's control workers run the same way. A request task
//! then rests at its connection's class (connection_qos.rs, task 224). A
//! clear-history request runs as a `Mux::work` item at its cause's
//! priority, blocking disallowed (task 230).
//!
//! Lock order: the scheduler's `state`, then the pool's. A pool task or
//! fence callback takes `state` with no pool lock held.

use super::MessageWriter;
use crate::panic_free::RecoverPoison;

use super::CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY;
use super::CONNECTION_SURFACE_QUEUE_CAPACITY;
use super::ConnectionPermit;
use super::Request;
use super::RequestArrival;
use super::ResponseErrorDelivery;
use super::ServerSurfaceAdmissionError;
use super::ServerSurfaceBytesPermit;
use super::ServerSurfaceOperationAdmission;
use super::frame_dispatch::FrameCall;
use super::handle_request_with_cancellation;
use super::send_request_error;
use super::send_request_error_with_delivery;
use super::sequenced_pool::{Fenced, PostError, Sequence, SequencePriority};
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
use cmux_threads::work::{Lane, Shutdown};
use connection_qos::{ConnectionClassCell, ConnectionThread};
use std::collections::HashSet;
use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::Weak;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::thread::JoinHandle;
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
pub(super) fn spawn_request_thread<F, T>(name: &str, f: F) -> std::io::Result<JoinHandle<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    cmux_threads::spawn(name, REQUEST_THREAD_QOS, move || {
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

/// What the control sequence runs the connection's requests with: set by
/// its first request, dropped once the scheduler drained.
pub(super) struct ControlContext {
    pub(super) mux: Arc<Mux>,
    pub(super) client: u64,
    pub(super) writer: MessageWriter,
}

#[derive(Default)]
pub(super) struct ConnectionSurfaceState {
    pub(super) requests: VecDeque<PendingSurfaceRequest>,
    pub(super) queued_bytes: usize,
    pub(super) active_clear_surfaces: HashSet<SurfaceId>,
    /// Terminal creates handed to the terminal work pool and not yet answered (`terminal_create`).
    pub(super) active_creations: usize,
    /// The connection's control sequence on the mux's pool.
    pub(super) control: Option<Sequence>,
    pub(super) context: Option<ControlContext>,
    /// A pump task (one request) is posted or running on `control`.
    pub(super) pump_scheduled: bool,
    /// The connection's open streams.
    pub(super) streams: StreamLanes,
    pub(super) next_barrier: u64,
    /// Closed, every request run or dropped and no pump left: the
    /// connection permit is released.
    pub(super) drained: bool,
    pub(super) closed: bool,
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
        let mut state = self.state.lock().recover_poison();
        if state.closed {
            return Some(false);
        }
        let Some((is_clear_history, request_id)) =
            request.as_ref().map(|pending| (pending.cmd.is_clear_history(), pending.id.clone()))
        else {
            // Nothing to schedule; the connection stays open.
            return Some(true);
        };
        // The depth this request meets on arrival, itself included, recorded
        // also when the sequence is full and refuses it: those are the
        // saturation samples (`server-stats` `ipc` `sequence_depth`).
        let arrival_depth = state.requests.len() + 1;
        let over_count = state.requests.len() >= CONNECTION_SURFACE_QUEUE_CAPACITY;
        let over_bytes = retained_bytes
            > CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY.saturating_sub(state.queued_bytes);
        if over_count || over_bytes {
            drop(state);
            mux.ipc_stats().sequence_depth(arrival_depth);
            *request = None;
            return Some(send_request_error_with_delivery(
                &writer,
                request_id,
                "surface request queue is full; request was not executed",
                is_clear_history.then_some(ResponseErrorDelivery::KnownNotDelivered),
            ));
        }
        let bytes_permit = match self.admission.try_reserve_bytes(retained_bytes) {
            Ok(bytes) => bytes,
            Err(ServerSurfaceAdmissionError::RetainedByteCapacity) => {
                drop(state);
                mux.ipc_stats().sequence_depth(arrival_depth);
                *request = None;
                return Some(if is_clear_history {
                    send_request_error_with_delivery(
                        &writer,
                        request_id,
                        "server surface-operation byte budget is full; request was not executed",
                        Some(ResponseErrorDelivery::KnownNotDelivered),
                    )
                } else {
                    send_request_error(
                        &writer,
                        request_id,
                        "server surface-operation byte budget is full; request was not executed",
                    )
                });
            }
        };
        let Some(queued) = request.take() else {
            return Some(true);
        };
        if state.control.is_none() {
            state.control = Some(mux.sequenced_pool.sequence(SequencePriority::Control));
        }
        // The control sequence keeps the connection's writer: each request
        // answers on its own (`frame_call`).
        if state.context.is_none() {
            state.context = Some(ControlContext {
                mux: mux.clone(),
                client,
                writer: writer.connection_writer(),
            });
        }
        let stream_barrier = self.stream_barrier_locked(&mut state, &mux, &queued.cmd);
        state.queued_bytes = state.queued_bytes.saturating_add(retained_bytes);
        state.requests.push_back(PendingSurfaceRequest {
            request: queued,
            arrival,
            cause: EventCause::current(),
            frame_call: writer.frame_call().cloned(),
            retained_bytes,
            _bytes_permit: bytes_permit,
            stream_barrier,
        });
        let scheduled = self.schedule_locked(&mut state);
        self.changed.notify_all();
        drop(state);
        mux.ipc_stats().sequence_depth(arrival_depth);

        if let Err(error) = scheduled {
            self.close();
            return Some(send_request_error_with_delivery(
                &writer,
                request_id,
                &format!("could not queue on the connection's control sequence: {error}"),
                is_clear_history.then_some(ResponseErrorDelivery::KnownNotDelivered),
            ));
        }
        Some(true)
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
        if let Some(pending) =
            state.requests.iter_mut().find(|pending| pending.stream_barrier == Some(ticket))
        {
            pending.stream_barrier = None;
        }
        self.reschedule_locked(state);
    }

    /// Posts a pump for the next runnable request unless one is posted or
    /// running.
    fn schedule_locked(
        self: &Arc<Self>,
        state: &mut ConnectionSurfaceState,
    ) -> Result<(), PostError> {
        if state.pump_scheduled || Self::next_runnable_index(state).is_none() {
            return Ok(());
        }
        let Some(control) = state.control.as_ref() else { return Ok(()) };
        let scheduler = self.clone();
        control.post(move || scheduler.pump())?;
        state.pump_scheduled = true;
        Ok(())
    }

    /// [`Self::schedule_locked`] after a change that may let a request run
    /// (a pump ended, a clear or a stream barrier released), then settles a
    /// drained scheduler. A pool that shut down ends the connection.
    fn reschedule_locked(
        self: &Arc<Self>,
        mut state: std::sync::MutexGuard<'_, ConnectionSurfaceState>,
    ) {
        if self.schedule_locked(&mut state).is_err() {
            state.closed = true;
            state.requests.clear();
            state.queued_bytes = 0;
        }
        let drained = self.settle_locked(&mut state);
        self.changed.notify_all();
        drop(state);
        // The control sequence and its context drop outside the lock.
        drop(drained);
    }

    /// Marks the scheduler drained once it is closed, holds no request and
    /// runs no pump. The connection permit is released here, under the
    /// state lock and before `drained` is set, so no waiter sees a drained
    /// connection that still counts against the connection limit. The
    /// control sequence and its context leave with the returned value, for
    /// the caller to drop outside the lock.
    fn settle_locked(&self, state: &mut ConnectionSurfaceState) -> Option<Drained> {
        if state.drained || !state.closed || !state.requests.is_empty() || state.pump_scheduled {
            return None;
        }
        // Lock order: `state`, then the permit's (a leaf).
        drop(self.connection_permit.lock().recover_poison().take());
        state.drained = true;
        Some(Drained { _control: state.control.take(), _context: state.context.take() })
    }

    /// One task of the control sequence: runs the next runnable request.
    fn pump(self: Arc<Self>) {
        let _pump = PumpGuard(self.clone());
        let Some((pending, mux, client, writer)) = self.take_runnable() else { return };
        if !writer.is_open() {
            drop(pending);
            self.close();
            return;
        }
        // The task runs at its connection's class on the shared worker, and
        // the class ends with the task (connection_qos.rs, task 224). Not a
        // `RestingClass`: that asks the worker's registry row to stay there.
        let _class = mux.request_qos().enter_class(self.class.get().qos(ConnectionThread::Request));
        if !run_dispatched_request(&self, &mux, client, pending, &writer) {
            self.close();
        }
    }

    /// The pump ended (or unwound): the next runnable request gets its own.
    pub(super) fn finish_pump(self: &Arc<Self>) {
        let mut state = self.state.lock().recover_poison();
        state.pump_scheduled = false;
        self.reschedule_locked(state);
    }

    fn take_runnable(&self) -> Option<(PendingSurfaceRequest, Arc<Mux>, u64, MessageWriter)> {
        let mut state = self.state.lock().recover_poison();
        let context = state.context.as_ref()?;
        let (mux, client, writer) = (context.mux.clone(), context.client, context.writer.clone());
        let index = Self::next_runnable_index(&state)?;
        let pending = state.requests.remove(index)?;
        state.queued_bytes = state.queued_bytes.saturating_sub(pending.retained_bytes);
        // Clear-history is always ordered by a surface; a clear worker
        // never overlaps another on the same surface.
        if pending.request.cmd.is_clear_history()
            && let Some(surface) = pending.request.cmd.ordering_surface()
            && !state.active_clear_surfaces.insert(surface)
        {
            eprintln!("cmux: clear-history worker overlapped surface {surface}");
        }
        self.changed.notify_all();
        Some((pending, mux, client, writer))
    }

    /// The index of the request the control sequence runs next: the head,
    /// unless a clear-history barrier lets a later one overtake it or holds
    /// it. A request waiting on its stream barrier holds every later one:
    /// priority never reorders the control sequence.
    pub(super) fn next_runnable_index(state: &ConnectionSurfaceState) -> Option<usize> {
        let index = if state.active_clear_surfaces.is_empty() {
            (!state.requests.is_empty()).then_some(0)?
        } else {
            Self::next_past_clear_barrier(state)?
        };
        state.requests.get(index)?.stream_barrier.is_none().then_some(index)
    }

    fn next_past_clear_barrier(state: &ConnectionSurfaceState) -> Option<usize> {
        for (index, pending) in state.requests.iter().enumerate() {
            let surface = pending.request.cmd.ordering_surface()?;
            if state.active_clear_surfaces.contains(&surface) {
                continue;
            }
            if pending.request.cmd.can_overtake_clear_barrier() {
                return Some(index);
            }
            return None;
        }
        None
    }

    pub(super) fn finish_clear(self: &Arc<Self>, surface: SurfaceId) {
        let mut state = self.state.lock().recover_poison();
        state.active_clear_surfaces.remove(&surface);
        self.reschedule_locked(state);
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

    pub(super) fn wait_for_completion(&self, timeout: Option<Duration>) -> bool {
        // A timeout too large to represent waits without a deadline.
        let deadline = timeout.and_then(|timeout| Instant::now().checked_add(timeout));
        let settled = |state: &ConnectionSurfaceState| {
            state.drained && state.active_clear_surfaces.is_empty() && state.active_creations == 0
        };
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
    _control: Option<Sequence>,
    _context: Option<ControlContext>,
}

/// Ends a pump, unwinding included, so a panicking request never leaves
/// the connection without one.
struct PumpGuard(Arc<ConnectionSurfaceScheduler>);

impl Drop for PumpGuard {
    fn drop(&mut self) {
        self.0.finish_pump();
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

/// Runs one request the control sequence took: a clear-history on its own
/// worker, a create on the terminal work pool, anything else here. False
/// when the connection must close.
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
    let Some(worker_permit) = scheduler.admission.try_reserve_worker() else {
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
