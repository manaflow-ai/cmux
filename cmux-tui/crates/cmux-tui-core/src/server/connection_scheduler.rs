//! The per-connection surface scheduler: pending surface requests, the
//! connection's cancellation token, clear-history barriers, and the
//! dispatcher thread that runs queued surface operations in order.

use super::MessageWriter;
use crate::panic_free::RecoverPoison;

use super::CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY;
use super::CONNECTION_SURFACE_QUEUE_CAPACITY;
use super::ConnectionPermit;
use super::Request;
use super::ResponseErrorDelivery;
use super::ServerSurfaceAdmissionError;
use super::ServerSurfaceBytesPermit;
use super::ServerSurfaceOperationAdmission;
use super::attach_frames::ClientStreamId;
use super::handle_request_with_cancellation;
use super::send_request_error;
use super::send_request_error_with_delivery;
use super::stream_lanes::LaneRefusal;
use super::stream_lanes::StreamLanes;
use super::terminal_create;
use crate::Mux;
use crate::SurfaceId;
use crate::stream_interrupt::InterruptSet;
use crate::stream_interrupt::StreamInterrupt;
use std::collections::BTreeSet;
use std::collections::HashMap;
use std::collections::HashSet;
use std::collections::VecDeque;
use std::sync::Arc;
use std::sync::Condvar;
use std::sync::Mutex;
use std::sync::OnceLock;
use std::sync::Weak;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::thread::JoinHandle;
use std::time::Duration;
use std::time::Instant;

pub(super) struct PendingSurfaceRequest {
    pub(super) request: Request,
    pub(super) retained_bytes: usize,
    pub(super) _bytes_permit: ServerSurfaceBytesPermit,
    /// The request's place in its surface's order across the connection's
    /// lanes, held until the request finished (see [`SurfaceOrder`]).
    pub(super) order: Option<OrderTicket>,
}

/// Which lane a request runs on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum OrderLane {
    Control,
    Stream,
}

/// The requests of one surface that have not finished, by lane, as their
/// arrival numbers on the connection. Requests of one surface keep their wire
/// order across the control lane and the client streams' lanes (as on one
/// serial connection): a stream request waits for the surface's earlier
/// control requests (a clear-history barrier, a close, a read), and a control
/// request is held behind the surface's earlier stream requests (the input a
/// clear-history must follow). Requests of different surfaces never wait for
/// each other.
#[derive(Default)]
pub(super) struct SurfaceOrder {
    pub(super) control: BTreeSet<u64>,
    pub(super) streams: BTreeSet<u64>,
}

/// A request's entry in its surface's [`SurfaceOrder`]; dropping it (the
/// request finished, or was dropped unrun) removes the entry and wakes the
/// requests waiting on it. Never dropped under the scheduler's state lock.
pub(super) struct OrderTicket {
    scheduler: Weak<ConnectionSurfaceScheduler>,
    surface: SurfaceId,
    arrival: u64,
    lane: OrderLane,
}

impl OrderTicket {
    pub(super) fn arrival(&self) -> u64 {
        self.arrival
    }
}

impl Drop for OrderTicket {
    fn drop(&mut self) {
        let Some(scheduler) = self.scheduler.upgrade() else { return };
        let mut state = scheduler.state.lock().recover_poison();
        if let Some(order) = state.surface_orders.get_mut(&self.surface) {
            match self.lane {
                OrderLane::Control => order.control.remove(&self.arrival),
                OrderLane::Stream => order.streams.remove(&self.arrival),
            };
            if order.control.is_empty() && order.streams.is_empty() {
                state.surface_orders.remove(&self.surface);
            }
        }
        drop(state);
        scheduler.changed.notify_all();
    }
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
    /// The next request's arrival number on the connection (both lanes).
    pub(super) next_arrival: u64,
    /// The unfinished requests of each surface, by lane.
    pub(super) surface_orders: HashMap<SurfaceId, SurfaceOrder>,
}

impl ConnectionSurfaceState {
    /// Whether `surface` has an unfinished request on `lane` that arrived
    /// before `arrival`.
    pub(super) fn earlier_on(&self, surface: SurfaceId, lane: OrderLane, arrival: u64) -> bool {
        self.surface_orders.get(&surface).is_some_and(|order| {
            let set = match lane {
                OrderLane::Control => &order.control,
                OrderLane::Stream => &order.streams,
            };
            set.first().is_some_and(|first| *first < arrival)
        })
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
}

pub(super) struct ConnectionSurfaceScheduler {
    pub(super) state: Mutex<ConnectionSurfaceState>,
    pub(super) changed: Condvar,
    pub(super) admission: Arc<ServerSurfaceOperationAdmission>,
    pub(super) cancelled: ConnectionCancellation,
    pub(super) dispatcher: Mutex<Option<JoinHandle<()>>>,
    pub(super) connection_permit: Mutex<Option<ConnectionPermit>>,
    pub(super) creations: terminal_create::ConnectionCreations,
    /// The lanes of the connection's client streams (`attach-streams-v1`),
    /// made at the first request that names a stream.
    pub(super) stream_lanes: OnceLock<StreamLanes<PendingSurfaceRequest>>,
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
            stream_lanes: OnceLock::new(),
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
        let over_count = state.requests.len() >= CONNECTION_SURFACE_QUEUE_CAPACITY;
        let over_bytes = retained_bytes
            > CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY.saturating_sub(state.queued_bytes);
        if over_count || over_bytes {
            drop(state);
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
        let order =
            self.take_order_ticket(&mut state, queued.cmd.ordering_surface(), OrderLane::Control);
        state.requests.push_back(PendingSurfaceRequest {
            request: queued,
            retained_bytes,
            _bytes_permit: bytes_permit,
            order,
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

    /// Queues a per-view request on its client stream's lane: after that
    /// stream's earlier requests, never behind another stream's or the
    /// control lane's (server/stream_lanes.rs). Returns whether the
    /// connection stays open.
    pub(super) fn dispatch_on_stream(
        self: &Arc<Self>,
        mux: Arc<Mux>,
        client: u64,
        stream: ClientStreamId,
        request: Request,
        retained_bytes: usize,
        writer: &MessageWriter,
    ) -> bool {
        let request_id = request.id.clone();
        if self.state.lock().recover_poison().closed {
            return false;
        }
        let bytes_permit = match self.admission.try_reserve_bytes(retained_bytes) {
            Ok(bytes) => bytes,
            Err(ServerSurfaceAdmissionError::RetainedByteCapacity) => {
                return send_request_error(
                    writer,
                    request_id,
                    "server surface-operation byte budget is full; request was not executed",
                );
            }
        };
        let lanes = self.stream_lanes.get_or_init(|| {
            let scheduler = Arc::downgrade(self);
            let writer = writer.clone();
            StreamLanes::new(
                CONNECTION_SURFACE_QUEUE_CAPACITY,
                CONNECTION_SURFACE_QUEUE_BYTE_CAPACITY,
                move |pending: PendingSurfaceRequest| {
                    // The scheduler outlives its lanes (it owns them); a gone
                    // one means the connection ended.
                    let Some(scheduler) = scheduler.upgrade() else { return false };
                    if let Some(ticket) = &pending.order
                        && !scheduler.wait_for_earlier_control(ticket)
                    {
                        return false;
                    }
                    let keep_open = run_pending_request(&scheduler, &mux, client, pending, &writer);
                    if !keep_open {
                        // As on the control lane: a request that ends the
                        // connection closes its scheduler, and the reader stops.
                        scheduler.close();
                    }
                    keep_open
                },
            )
        });
        let order = {
            let mut state = self.state.lock().recover_poison();
            if state.closed {
                return false;
            }
            self.take_order_ticket(&mut state, request.cmd.ordering_surface(), OrderLane::Stream)
        };
        let pending =
            PendingSurfaceRequest { request, retained_bytes, _bytes_permit: bytes_permit, order };
        match lanes.submit(stream, pending, retained_bytes) {
            Ok(()) => true,
            Err(LaneRefusal::Closed) => false,
            Err(LaneRefusal::Full) => send_request_error_with_delivery(
                writer,
                request_id,
                "stream request queue is full; request was not executed",
                Some(ResponseErrorDelivery::KnownNotDelivered),
            ),
            Err(LaneRefusal::Spawn) => send_request_error_with_delivery(
                writer,
                request_id,
                "could not start a stream request worker; request was not executed",
                Some(ResponseErrorDelivery::KnownNotDelivered),
            ),
        }
    }

    /// The request's arrival number and its entry in `surface`'s order, for a
    /// request that orders by a surface. Caller holds the state lock.
    pub(super) fn take_order_ticket(
        self: &Arc<Self>,
        state: &mut ConnectionSurfaceState,
        surface: Option<SurfaceId>,
        lane: OrderLane,
    ) -> Option<OrderTicket> {
        let surface = surface?;
        let arrival = state.next_arrival;
        state.next_arrival += 1;
        let order = state.surface_orders.entry(surface).or_default();
        match lane {
            OrderLane::Control => order.control.insert(arrival),
            OrderLane::Stream => order.streams.insert(arrival),
        };
        Some(OrderTicket { scheduler: Arc::downgrade(self), surface, arrival, lane })
    }

    /// Blocks a stream lane's worker until the surface's earlier control
    /// requests finished (a clear-history, a close, a read issued before this
    /// request). False when the connection closed meanwhile. Never runs on the
    /// reader thread: lane workers only.
    pub(super) fn wait_for_earlier_control(&self, ticket: &OrderTicket) -> bool {
        let mut state = self.state.lock().recover_poison();
        loop {
            // A closed connection runs nothing more; a finishing one drains.
            if self.cancelled.is_cancelled() {
                return false;
            }
            if !state.earlier_on(ticket.surface, OrderLane::Control, ticket.arrival) {
                return true;
            }
            state = self.changed.wait(state).recover_poison();
        }
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
        *self.dispatcher.lock().recover_poison() = Some(handle);
        Ok(())
    }

    /// The next control request to run. A request waits while its surface has
    /// a clear-history running or an earlier unfinished stream request (the
    /// cross-lane order, [`SurfaceOrder`]); only requests that may overtake a
    /// barrier run past a waiting one.
    pub(super) fn next_runnable_index(state: &ConnectionSurfaceState) -> Option<usize> {
        let waits_for_streams = |pending: &PendingSurfaceRequest| {
            pending.order.as_ref().is_some_and(|ticket| {
                state.earlier_on(ticket.surface, OrderLane::Stream, ticket.arrival)
            })
        };
        if state.active_clear_surfaces.is_empty()
            && state.requests.front().is_none_or(|head| !waits_for_streams(head))
        {
            return (!state.requests.is_empty()).then_some(0);
        }
        for (index, pending) in state.requests.iter().enumerate() {
            let surface = pending.request.cmd.ordering_surface()?;
            if state.active_clear_surfaces.contains(&surface) || waits_for_streams(pending) {
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
            state = self.changed.wait(state).recover_poison();
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
        if let Some(lanes) = self.stream_lanes.get() {
            lanes.close();
        }
        let mut state = self.state.lock().recover_poison();
        state.closed = true;
        // Dropped after the lock: their order tickets take it.
        let dropped = std::mem::take(&mut state.requests);
        state.queued_bytes = 0;
        let dispatcher_never_started = !state.dispatcher_started;
        if dispatcher_never_started {
            state.dispatcher_done = true;
        }
        self.changed.notify_all();
        drop(state);
        drop(dropped);
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
            let _ = dispatcher.join();
        }
        drained
    }

    pub(super) fn finish_and_wait(&self) {
        self.finish();
        if let Some(lanes) = self.stream_lanes.get() {
            lanes.finish_and_wait();
        }
        let drained = self.wait_for_completion(None);
        debug_assert!(drained, "unbounded graceful drain must settle");
    }

    pub(super) fn close_and_wait(&self, timeout: Duration) -> bool {
        let deadline = Instant::now().checked_add(timeout);
        self.close();
        let lanes_done = self.stream_lanes.get().is_none_or(|lanes| lanes.close_and_wait(timeout));
        let remaining =
            deadline.map_or(timeout, |deadline| deadline.saturating_duration_since(Instant::now()));
        self.wait_for_completion(Some(remaining)) && lanes_done
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
    // The ticket lives until the request finished: later requests of its
    // surface on the other lane wait for that.
    let PendingSurfaceRequest { request, _bytes_permit, order: _order, .. } = pending;
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
        if pending.request.cmd.is_clear_history()
            && let Some(surface) = pending.request.cmd.ordering_surface()
        {
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
