//! The per-connection surface scheduler: pending surface requests, the
//! connection's cancellation token, clear-history barriers, and the
//! dispatcher thread that runs queued surface operations in order.

use super::MessageWriter;

use super::CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY;
use super::CONNECTION_SURFACE_QUEUE_CAPACITY;
use super::ConnectionPermit;
use super::Request;
use super::ResponseErrorDelivery;
use super::ServerSurfaceAdmissionError;
use super::ServerSurfaceBytesPermit;
use super::ServerSurfaceOperationAdmission;
use super::handle_request_with_cancellation;
use super::send_request_error;
use super::send_request_error_with_delivery;
use super::terminal_create;
use crate::Mux;
use crate::SurfaceId;
use crate::stream_interrupt::InterruptSet;
use crate::stream_interrupt::StreamInterrupt;
use std::collections::HashSet;
use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::Condvar;
use std::sync::Mutex;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::thread::JoinHandle;
use std::time::Duration;
use std::time::Instant;

pub(super) struct PendingSurfaceRequest {
    pub(super) request: Request,
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
}

pub(super) struct ConnectionSurfaceScheduler {
    pub(super) state: Mutex<ConnectionSurfaceState>,
    pub(super) changed: Condvar,
    pub(super) admission: Arc<ServerSurfaceOperationAdmission>,
    pub(super) cancelled: ConnectionCancellation,
    pub(super) dispatcher: Mutex<Option<JoinHandle<()>>>,
    pub(super) connection_permit: Mutex<Option<ConnectionPermit>>,
    pub(super) creations: terminal_create::ConnectionCreations,
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
        }
    }
}

impl ConnectionSurfaceScheduler {
    pub(super) fn dispatch(
        self: &Arc<Self>,
        mux: Arc<Mux>,
        client: u64,
        request: &mut Option<Request>,
        retained_bytes: usize,
        writer: MessageWriter,
    ) -> Option<bool> {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return Some(false);
        }
        let is_clear_history = request.as_ref().unwrap().cmd.is_clear_history();
        let over_count = state.requests.len() >= CONNECTION_SURFACE_QUEUE_CAPACITY;
        let over_bytes = retained_bytes
            > CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY.saturating_sub(state.queued_bytes);
        if over_count || over_bytes {
            drop(state);
            return Some(send_request_error_with_delivery(
                &writer,
                request.take().unwrap().id,
                "surface request queue is full; request was not executed",
                is_clear_history.then_some(ResponseErrorDelivery::KnownNotDelivered),
            ));
        }
        let request_id = request.as_ref().unwrap().id.clone();
        let bytes_permit = match self.admission.try_reserve_bytes(retained_bytes) {
            Ok(bytes) => bytes,
            Err(ServerSurfaceAdmissionError::RetainedByteCapacity) => {
                drop(state);
                let request_id = request.take().unwrap().id;
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
        let start_dispatcher = !state.dispatcher_started;
        state.dispatcher_started = true;
        state.queued_bytes = state.queued_bytes.saturating_add(retained_bytes);
        state.requests.push_back(PendingSurfaceRequest {
            request: request.take().unwrap(),
            retained_bytes,
            _bytes_permit: bytes_permit,
        });
        self.changed.notify_all();
        drop(state);

        if start_dispatcher && let Err(error) = self.start_dispatcher(mux, client, writer.clone()) {
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
        let handle = std::thread::Builder::new()
            .name("mux-control-dispatch".into())
            .spawn(move || run_connection_surface_dispatcher(scheduler, mux, client, writer))?;
        *self.dispatcher.lock().unwrap() = Some(handle);
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
        let mut state = self.state.lock().unwrap();
        loop {
            if let Some(index) = Self::next_runnable_index(&state) {
                let pending = state.requests.remove(index).unwrap();
                state.queued_bytes = state.queued_bytes.saturating_sub(pending.retained_bytes);
                if pending.request.cmd.is_clear_history() {
                    let surface = pending
                        .request
                        .cmd
                        .ordering_surface()
                        .expect("clear-history is ordered by surface");
                    let inserted = state.active_clear_surfaces.insert(surface);
                    assert!(inserted, "a clear worker cannot overlap its surface");
                }
                return Some(pending);
            }
            if state.closed && state.requests.is_empty() {
                state.dispatcher_done = true;
                self.changed.notify_all();
                return None;
            }
            state = self.changed.wait(state).unwrap();
        }
    }

    pub(super) fn finish_clear(&self, surface: SurfaceId) {
        let mut state = self.state.lock().unwrap();
        state.active_clear_surfaces.remove(&surface);
        self.changed.notify_all();
    }

    pub(super) fn finish_dispatcher(&self) {
        {
            let mut state = self.state.lock().unwrap();
            state.dispatcher_done = true;
            self.changed.notify_all();
        }
        self.connection_permit.lock().unwrap().take();
    }

    pub(super) fn close(&self) {
        self.cancelled.cancel();
        let mut state = self.state.lock().unwrap();
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
            self.connection_permit.lock().unwrap().take();
        }
    }

    pub(super) fn finish(&self) {
        let mut state = self.state.lock().unwrap();
        state.closed = true;
        let dispatcher_never_started = !state.dispatcher_started;
        if dispatcher_never_started {
            state.dispatcher_done = true;
        }
        self.changed.notify_all();
        drop(state);
        if dispatcher_never_started {
            self.connection_permit.lock().unwrap().take();
        }
    }

    pub(super) fn wait_for_completion(&self, timeout: Option<Duration>) -> bool {
        let deadline = timeout.map(|timeout| Instant::now() + timeout);
        let mut state = self.state.lock().unwrap();
        while !state.dispatcher_done
            || !state.active_clear_surfaces.is_empty()
            || state.active_creations != 0
        {
            if let Some(deadline) = deadline {
                if Instant::now() >= deadline {
                    break;
                }
                let remaining = deadline.saturating_duration_since(Instant::now());
                let (next, _) = self.changed.wait_timeout(state, remaining).unwrap();
                state = next;
            } else {
                state = self.changed.wait(state).unwrap();
            }
        }
        let drained = state.dispatcher_done
            && state.active_clear_surfaces.is_empty()
            && state.active_creations == 0;
        drop(state);
        if drained && let Some(dispatcher) = self.dispatcher.lock().unwrap().take() {
            let _ = dispatcher.join();
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
    let PendingSurfaceRequest { request, _bytes_permit, .. } = pending;
    handle_request_with_cancellation(mux, client, request, writer, Some(&scheduler.cancelled))
}

fn run_connection_surface_dispatcher(
    scheduler: Arc<ConnectionSurfaceScheduler>,
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
) {
    let _dispatcher = ConnectionDispatcherGuard(scheduler.clone());
    while writer.is_open() {
        let Some(pending) = scheduler.next_request() else { return };
        if pending.request.cmd.is_clear_history() {
            let surface = pending
                .request
                .cmd
                .ordering_surface()
                .expect("clear-history is ordered by surface");
            let Some(worker_permit) = scheduler.admission.try_reserve_worker() else {
                let id = pending.request.id.clone();
                drop(pending);
                scheduler.finish_clear(surface);
                if !send_request_error_with_delivery(
                    &writer,
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
            let spawn =
                std::thread::Builder::new().name("mux-surface-control".into()).spawn(move || {
                    let _active = ActiveClearGuard { scheduler: worker_scheduler.clone(), surface };
                    // Drop the mux-wide permit before `_active` wakes the next
                    // request queued behind this surface barrier.
                    let _worker_permit = worker_permit;
                    let pending = worker_pending.lock().unwrap().take().unwrap();
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
                let pending = shared_pending.lock().unwrap().take().unwrap();
                let id = pending.request.id.clone();
                drop(pending);
                scheduler.finish_clear(surface);
                if !send_request_error_with_delivery(
                    &writer,
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
