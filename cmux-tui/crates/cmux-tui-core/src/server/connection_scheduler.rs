//! The per-connection surface scheduler: pending surface requests, the
//! connection's cancellation token, clear-history barriers, and the
//! dispatcher thread that runs queued surface operations in order.
//!
//! Request threads (this dispatcher, its clear-history workers, the WebSocket
//! connection thread) start through [`spawn_request_thread`]: UserInitiated,
//! blocking disallowed (p02-threads task 211). The dispatcher and its workers
//! then rest at their connection's class (connection_qos.rs, task 224).

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
use connection_qos::{ConnectionClassCell, ConnectionThread, RestingClass};
use std::collections::HashSet;
use std::collections::VecDeque;
use std::sync::Arc;
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
    /// dispatcher and clear workers rest at it (connection_qos.rs).
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
            dispatcher: Mutex::new(None),
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
        let handle = spawn_request_thread("mux-control-dispatch", move || {
            run_connection_surface_dispatcher(scheduler, mux, client, writer);
        })?;
        *self.dispatcher.lock().recover_poison() = Some(handle);
        Ok(())
    }

    pub(super) fn next_runnable_index(state: &ConnectionSurfaceState) -> Option<usize> {
        if state.active_clear_surfaces.is_empty() {
            return (!state.requests.is_empty()).then_some(0);
        }
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

    pub(super) fn next_request(&self) -> Option<PendingSurfaceRequest> {
        let mut state = self.state.lock().recover_poison();
        loop {
            if let Some(index) = Self::next_runnable_index(&state)
                && let Some(pending) = state.requests.remove(index)
            {
                state.queued_bytes = state.queued_bytes.saturating_sub(pending.retained_bytes);
                // Clear-history is always ordered by a surface; a clear
                // worker never overlaps another on the same surface.
                if pending.request.cmd.is_clear_history()
                    && let Some(surface) = pending.request.cmd.ordering_surface()
                    && !state.active_clear_surfaces.insert(surface)
                {
                    eprintln!("cmux: clear-history worker overlapped surface {surface}");
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
            let shared_pending = Arc::new(Mutex::new(Some(pending)));
            let worker_pending = shared_pending.clone();
            let worker_scheduler = scheduler.clone();
            let worker_mux = mux.clone();
            let worker_writer = writer.clone();
            let spawn = spawn_request_thread("mux-surface-control", move || {
                let _active = ActiveClearGuard { scheduler: worker_scheduler.clone(), surface };
                // Drop the mux-wide permit before `_active` wakes the next
                // request queued behind this surface barrier.
                let _worker_permit = worker_permit;
                let mut resting = worker_scheduler.resting_class(&worker_mux);
                resting.follow();
                // The request is handed over exactly once: here, or to
                // the spawn-failure path below.
                let Some(pending) = worker_pending.lock().recover_poison().take() else {
                    return;
                };
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
            if let Err(error) = spawn {
                let Some(pending) = shared_pending.lock().recover_poison().take() else {
                    scheduler.finish_clear(surface);
                    continue;
                };
                let (id, reply) = (pending.request.id.clone(), pending.reply_writer(&writer));
                drop(pending);
                scheduler.finish_clear(surface);
                if !send_request_error_with_delivery(
                    &reply,
                    id,
                    &format!("could not start clear-history worker: {error}"),
                    Some(ResponseErrorDelivery::KnownNotDelivered),
                ) {
                    scheduler.close();
                    return;
                }
            }
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
