//! The per-connection surface scheduler: pending surface requests, the
//! connection's cancellation token, clear-history and long-read barriers, and
//! the dispatcher thread that runs queued surface operations in order.
//!
//! Requests of one surface run in arrival order. A person's input
//! (`Command::is_input`) runs before other surfaces' queued requests, as
//! Chrome's `kUserInput` queue outranks its other UI-thread queues
//! (content/browser/scheduler/browser_task_queues.h); input never passes
//! earlier input that can run, nor a request that names no surface. A long
//! read (`Command::is_long_read`) runs on a work item of the mux's Cpu lane
//! (`Mux::work`), not on the dispatcher and not on a thread of its own, so a
//! later Send for another surface answers while it runs.
//!
//! Request threads (this dispatcher, the WebSocket connection thread) start
//! through [`spawn_request_thread`]: UserInitiated, blocking disallowed
//! (p02-threads task 211). The dispatcher then rests at its connection's
//! class (connection_qos.rs, task 224). A clear-history request runs as a
//! `Mux::work` item at its cause's priority, blocking disallowed (task 230).

use super::MessageWriter;
use crate::panic_free::RecoverPoison;
use cmux_threads::checked::sync as waits;

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
use connection_qos::{ConnectionClassCell, ConnectionThread, RestingClass};
use std::collections::HashSet;
use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::Weak;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::AtomicU64;
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
pub(super) fn spawn_request_thread<F, T>(name: &str, f: F) -> std::io::Result<JoinHandle<T>>
where
    F: FnOnce() -> T + Send + 'static,
    T: Send + 'static,
{
    cmux_threads::spawn(name, REQUEST_THREAD_QOS, move || {
        cmux_threads::disallow_blocking();
        f()
    })
}

pub(super) struct PendingSurfaceRequest {
    pub(super) request: Request,
    /// When its line arrived and parsed: its request span starts there.
    pub(super) arrival: RequestArrival,
    /// The cause of the frame that queued it: its events keep that cause on
    /// whichever thread runs it (the dispatcher, a clear-history worker or
    /// a creation commit on the terminal work pool).
    pub(super) cause: EventCause,
    /// The REQUEST frame it came in, if any: its reply is that frame's
    /// REPLY or ERROR, and a CANCEL of it ends it.
    pub(super) frame_call: Option<Arc<FrameCall>>,
    pub(super) retained_bytes: usize,
    pub(super) _bytes_permit: ServerSurfaceBytesPermit,
}

#[derive(Default)]
pub(super) struct ConnectionSurfaceState {
    pub(super) requests: VecDeque<PendingSurfaceRequest>,
    pub(super) queued_bytes: usize,
    pub(super) active_clear_surfaces: HashSet<SurfaceId>,
    /// Surfaces whose long read runs on a work item (`Command::is_long_read`).
    pub(super) active_read_surfaces: HashSet<SurfaceId>,
    /// Terminal creates handed to the terminal work pool and not yet answered (`terminal_create`).
    pub(super) active_creations: usize,
    pub(super) dispatcher_started: bool,
    pub(super) dispatcher_done: bool,
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
    pub(super) dispatcher: Mutex<Option<JoinHandle<()>>>,
    pub(super) connection_permit: Mutex<Option<ConnectionPermit>>,
    pub(super) creations: terminal_create::ConnectionCreations,
    /// The connection's client class, set by its registry record; the
    /// dispatcher rests at it (connection_qos.rs).
    pub(super) class: Arc<ConnectionClassCell>,
    /// Request threads this scheduler started: its dispatcher and its
    /// clear-history workers. A long read starts none (`start_long_read`).
    pub(super) threads_started: AtomicU64,
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
            dispatcher: Mutex::new(None),
            connection_permit: Mutex::new(connection_permit),
            creations: terminal_create::ConnectionCreations::default(),
            class: Arc::default(),
            threads_started: AtomicU64::new(0),
        }
    }

    /// The scheduler of a connection whose client class is `class` (its
    /// registry record's cell, `ClientRegistry::connection_class`).
    pub(super) fn classed(mut self, class: Arc<ConnectionClassCell>) -> Self {
        self.class = class;
        self
    }

    fn resting_class(&self, mux: &Mux) -> RestingClass {
        RestingClass::new(self.class.clone(), ConnectionThread::Request, mux.request_qos())
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

    /// Queues `request`, whose line arrived and parsed at `arrival`, for the
    /// connection's dispatcher.
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
        let start_dispatcher = !state.dispatcher_started;
        state.dispatcher_started = true;
        state.queued_bytes = state.queued_bytes.saturating_add(retained_bytes);
        state.requests.push_back(PendingSurfaceRequest {
            request: queued,
            arrival,
            cause: EventCause::current(),
            frame_call: writer.frame_call().cloned(),
            retained_bytes,
            _bytes_permit: bytes_permit,
        });
        self.changed.notify_all();
        drop(state);
        mux.ipc_stats().sequence_depth(arrival_depth);

        // The dispatcher outlives this request: it gets the connection's
        // writer, and each request answers on its own (`frame_call`).
        if start_dispatcher
            && let Err(error) = self.start_dispatcher(mux, client, writer.connection_writer())
        {
            self.finish_dispatcher();
            self.close();
            return Some(send_request_error_with_delivery(
                &writer,
                request_id,
                &format!("could not start connection request dispatcher: {error}"),
                is_clear_history.then_some(ResponseErrorDelivery::KnownNotDelivered),
            ));
        }
        Some(true)
    }

    pub(super) fn start_dispatcher(
        self: &Arc<Self>,
        mux: Arc<Mux>,
        client: u64,
        writer: MessageWriter,
    ) -> std::io::Result<()> {
        let scheduler = self.clone();
        let handle = self.spawn_thread("mux-control-dispatch", move || {
            run_connection_surface_dispatcher(scheduler, mux, client, writer);
        })?;
        *self.dispatcher.lock().recover_poison() = Some(handle);
        Ok(())
    }

    /// Starts one of this scheduler's request threads (`spawn_request_thread`).
    fn spawn_thread<F, T>(&self, name: &str, f: F) -> std::io::Result<JoinHandle<T>>
    where
        F: FnOnce() -> T + Send + 'static,
        T: Send + 'static,
    {
        self.threads_started.fetch_add(1, Ordering::Relaxed);
        spawn_request_thread(name, f)
    }

    /// The queued request the dispatcher runs next, if one may run now.
    ///
    /// - A request waits for every earlier request of its surface, and for
    ///   that surface's clear-history or long-read worker.
    /// - Nothing passes a request that names no surface.
    /// - Input (`Command::is_input`) passes other surfaces' requests.
    /// - With no worker running, the first request runs unless input passes
    ///   it; while one runs, only a request that may overtake its barrier
    ///   runs, and a non-input one passes no request that could run.
    pub(super) fn next_runnable_index(state: &ConnectionSurfaceState) -> Option<usize> {
        let idle = state.active_clear_surfaces.is_empty() && state.active_read_surfaces.is_empty();
        if idle && state.requests.len() <= 1 {
            return (!state.requests.is_empty()).then_some(0);
        }
        let busy = |surface: &SurfaceId| {
            state.active_clear_surfaces.contains(surface)
                || state.active_read_surfaces.contains(surface)
        };
        // Surfaces with an earlier request still queued.
        let mut held = HashSet::new();
        // The non-input request that runs unless later input passes it.
        let mut candidate = None;
        // Whether a request that could run was passed.
        let mut passed = false;
        for (index, pending) in state.requests.iter().enumerate() {
            let cmd = &pending.request.cmd;
            let Some(surface) = cmd.ordering_surface() else {
                return candidate.or((idle && !passed).then_some(index));
            };
            if busy(&surface) || held.contains(&surface) {
                continue;
            }
            if cmd.is_input() {
                return Some(index);
            }
            if !passed && (idle || cmd.can_overtake_clear_barrier()) {
                candidate = Some(index);
            }
            passed = true;
            held.insert(surface);
        }
        candidate
    }

    pub(super) fn next_request(&self) -> Option<PendingSurfaceRequest> {
        let mut state = self.state.lock().recover_poison();
        loop {
            if let Some(index) = Self::next_runnable_index(&state)
                && let Some(pending) = state.requests.remove(index)
            {
                state.queued_bytes = state.queued_bytes.saturating_sub(pending.retained_bytes);
                // Clear-history and long reads are always ordered by a
                // surface; a worker never overlaps another on the same one.
                let cmd = &pending.request.cmd;
                let workers = if cmd.is_clear_history() {
                    Some(&mut state.active_clear_surfaces)
                } else if cmd.is_long_read() {
                    Some(&mut state.active_read_surfaces)
                } else {
                    None
                };
                if let Some(workers) = workers
                    && let Some(surface) = cmd.ordering_surface()
                    && !workers.insert(surface)
                {
                    eprintln!("cmux: surface worker overlapped surface {surface}");
                }
                return Some(pending);
            }
            if state.closed && state.requests.is_empty() {
                state.dispatcher_done = true;
                self.changed.notify_all();
                return None;
            }
            // Idle for the connection's next request: not blocking work.
            state = self.changed.idle().wait(state).recover_poison();
        }
    }

    pub(super) fn finish_clear(&self, surface: SurfaceId) {
        let mut state = self.state.lock().recover_poison();
        state.active_clear_surfaces.remove(&surface);
        self.changed.notify_all();
    }

    pub(super) fn finish_read(&self, surface: SurfaceId) {
        let mut state = self.state.lock().recover_poison();
        state.active_read_surfaces.remove(&surface);
        self.changed.notify_all();
    }

    /// Runs `pending`, a long read of `surface`, on the mux's Cpu work lane
    /// at its cause's priority. Its surface stays held until the item ends.
    fn start_long_read(
        self: &Arc<Self>,
        mux: &Arc<Mux>,
        client: u64,
        surface: SurfaceId,
        pending: PendingSurfaceRequest,
        writer: &MessageWriter,
    ) {
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
        let _ = mux.work.post(priority, Lane::Cpu, Shutdown::SkipOnShutdown, move || read.run());
    }

    pub(super) fn finish_dispatcher(&self) {
        {
            let mut state = self.state.lock().recover_poison();
            state.dispatcher_done = true;
            self.changed.notify_all();
        }
        self.connection_permit.lock().recover_poison().take();
    }

    pub(super) fn close(&self) {
        self.cancelled.cancel();
        let mut state = self.state.lock().recover_poison();
        state.closed = true;
        state.requests.clear();
        state.queued_bytes = 0;
        let dispatcher_never_started = !state.dispatcher_started;
        if dispatcher_never_started {
            state.dispatcher_done = true;
        }
        self.changed.notify_all();
        drop(state);
        if dispatcher_never_started {
            self.connection_permit.lock().recover_poison().take();
        }
    }

    pub(super) fn finish(&self) {
        let mut state = self.state.lock().recover_poison();
        state.closed = true;
        let dispatcher_never_started = !state.dispatcher_started;
        if dispatcher_never_started {
            state.dispatcher_done = true;
        }
        self.changed.notify_all();
        drop(state);
        if dispatcher_never_started {
            self.connection_permit.lock().recover_poison().take();
        }
    }

    pub(super) fn wait_for_completion(&self, timeout: Option<Duration>) -> bool {
        // A timeout too large to represent waits without a deadline.
        let deadline = timeout.and_then(|timeout| Instant::now().checked_add(timeout));
        let mut state = self.state.lock().recover_poison();
        while !state.dispatcher_done
            || !state.active_clear_surfaces.is_empty()
            || !state.active_read_surfaces.is_empty()
            || state.active_creations != 0
        {
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
        let drained = state.dispatcher_done
            && state.active_clear_surfaces.is_empty()
            && state.active_read_surfaces.is_empty()
            && state.active_creations == 0;
        drop(state);
        if drained && let Some(dispatcher) = self.dispatcher.lock().recover_poison().take() {
            let _ = waits::join(dispatcher);
        }
        drained
    }

    pub(super) fn finish_and_wait(&self) {
        self.finish();
        let drained = self.wait_for_completion(None);
        debug_assert!(drained, "unbounded graceful drain must settle");
    }

    pub(super) fn close_and_wait(&self, timeout: Duration) -> bool {
        self.close();
        self.wait_for_completion(Some(timeout))
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
    fn run(mut self) {
        let Some(mux) = self.mux.upgrade() else { return };
        let Some(pending) = self.pending.take() else { return };
        if !run_pending_request(&self.scheduler, &mux, self.client, pending, &self.writer) {
            self.scheduler.close();
        }
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

struct ConnectionDispatcherGuard(Arc<ConnectionSurfaceScheduler>);

impl Drop for ConnectionDispatcherGuard {
    fn drop(&mut self) {
        self.0.finish_dispatcher();
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
    // The dispatcher, a clear-history worker or a creation commit runs the
    // request: a request path like the reader's (`crate::request_path`).
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

fn run_connection_surface_dispatcher(
    scheduler: Arc<ConnectionSurfaceScheduler>,
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
) {
    let _dispatcher = ConnectionDispatcherGuard(scheduler.clone());
    let mut resting = scheduler.resting_class(&mux);
    while writer.is_open() {
        let Some(pending) = scheduler.next_request() else { return };
        resting.follow();
        if pending.request.cmd.is_clear_history()
            && let Some(surface) = pending.request.cmd.ordering_surface()
        {
            let Some(worker_permit) = scheduler.admission.try_reserve_worker() else {
                let (id, reply) = (pending.request.id.clone(), pending.reply_writer(&writer));
                drop(pending);
                scheduler.finish_clear(surface);
                if !send_request_error_with_delivery(
                    &reply,
                    id,
                    "too many clear-history operations are already in progress",
                    Some(ResponseErrorDelivery::KnownNotDelivered),
                ) {
                    scheduler.close();
                    return;
                }
                continue;
            };
            // A work item at the priority of the request it serves (its
            // cause), as Chrome posts a task at its caller's priority; it runs
            // the request as a request thread does, blocking disallowed. It
            // waits on the terminal and its PTY, so it is system-lane work.
            let priority = pending.cause.work_priority();
            let mut clear = ClearWork {
                reply: pending.reply_writer(&writer),
                pending: Some(pending),
                active: Some(ActiveClearGuard { scheduler: scheduler.clone(), surface }),
            };
            let worker_scheduler = scheduler.clone();
            let worker_mux = mux.clone();
            let worker_writer = writer.clone();
            let posted =
                mux.work.post(priority, Lane::System, Shutdown::SkipOnShutdown, move || {
                    // Drop the mux-wide permit before the barrier ends and wakes
                    // the next request queued behind it.
                    let _active = clear.active.take();
                    let _worker_permit = worker_permit;
                    let Some(pending) = clear.pending.take() else { return };
                    cmux_threads::blocking::with_blocking_disallowed(|| {
                        if !run_pending_request(
                            &worker_scheduler,
                            &worker_mux,
                            client,
                            pending,
                            &worker_writer,
                        ) {
                            worker_scheduler.close();
                        }
                    });
                });
            // Refused (shutdown began): the dropped item answered the request.
            if posted.is_err() {
                scheduler.close();
                return;
            }
        } else if pending.request.cmd.is_long_read()
            && let Some(surface) = pending.request.cmd.ordering_surface()
        {
            scheduler.start_long_read(&mux, client, surface, pending, &writer);
        } else if pending.request.cmd.creates_terminal() {
            if !scheduler.submit_creation(&mux, client, pending, &writer) {
                scheduler.close();
                return;
            }
        } else if !run_pending_request(&scheduler, &mux, client, pending, &writer) {
            scheduler.close();
            return;
        }
    }
    scheduler.close();
}

#[cfg(test)]
#[path = "request_threads_tests.rs"]
mod request_threads_tests;
