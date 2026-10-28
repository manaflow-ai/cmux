//! Fuzz driver for the PTY input scheduler (`crate::fuzzing`).
//!
//! The driver owns the worker's side: it dequeues with the worker's own
//! `dequeue_ready_event` and completes operations with `process_event`, so
//! producers (enqueue, retire, cancel, generation switches) interleave with
//! in-flight work exactly as they do across threads, but in input order.
//! Surfaces are `RemoteBrowserUnsupported` handles, whose writes fail without
//! I/O; operation outcomes (timeouts, transport failures) come from the input.

use super::*;
use crate::fuzzing::FuzzBytes;
use crate::session::{
    test_remote_rejected_error, test_remote_timeout_error, test_remote_transport_error,
};
use std::sync::PoisonError;

const SURFACES: u8 = 4;
const MAX_GENERATION: u64 = 4;
const MAX_TRACKED_RESERVATIONS: usize = 1024;
/// Every drain step completes or dequeues one event; a queue at capacity
/// with its retried releases drains in far fewer.
const DRAIN_STEPS: usize = 1 << 16;

const KINDS: [PtyInputKind; 4] =
    [PtyInputKind::Ordered, PtyInputKind::Press, PtyInputKind::Motion, PtyInputKind::Release];
const LABELS: [&str; 3] = ["fuzz session mutation", "fuzz coalescing mutation", "fuzz surface op"];

#[derive(Clone, Copy)]
enum Outcome {
    Ok,
    Timeout,
    Transport,
    Rejected,
    Failed,
    KnownNotDelivered,
}

const OUTCOMES: [Outcome; 6] = [
    Outcome::Ok,
    Outcome::Timeout,
    Outcome::Transport,
    Outcome::Rejected,
    Outcome::Failed,
    Outcome::KnownNotDelivered,
];

impl Outcome {
    fn result(self) -> anyhow::Result<()> {
        match self {
            Outcome::Ok => Ok(()),
            Outcome::Timeout => Err(test_remote_timeout_error()),
            Outcome::Transport => Err(test_remote_transport_error()),
            Outcome::Rejected => Err(test_remote_rejected_error()),
            Outcome::Failed => Err(anyhow::anyhow!("fuzz operation failed")),
            Outcome::KnownNotDelivered => {
                Err(mark_operation_known_not_delivered(anyhow::anyhow!("fuzz not delivered")))
            }
        }
    }
}

/// One terminal input event, rebuilt for each copy of a burst.
#[derive(Clone, Copy)]
struct InputSpec {
    surface_id: SurfaceId,
    kind: PtyInputKind,
    len: usize,
    remote: bool,
    outcome: Option<Outcome>,
    reservation_id: Option<u64>,
}

impl InputSpec {
    fn build(self) -> PtyInputEvent {
        let bytes = PtyInputBytes::from_elem(b'x', self.len);
        let surface = SurfaceHandle::RemoteBrowserUnsupported;
        let mut event = match (self.kind, self.reservation_id) {
            (PtyInputKind::Release, Some(id)) => {
                PtyInputEvent::release(self.surface_id, surface, bytes, id)
            }
            _ => PtyInputEvent::input(self.surface_id, surface, bytes, self.kind),
        };
        event.remote = self.remote;
        if let Some(outcome) = self.outcome {
            // As `test_remote_timeout_input`: the outcome stands in for the write.
            event.mutation = Some(Box::new(move || outcome.result()));
        }
        event
    }
}

struct Driver {
    queue: Arc<SharedQueue>,
    on_failure: Arc<dyn Fn(PtyOperationFailure) + Send + Sync>,
    sender: PtyInputSender,
    active_generation: u64,
    /// The worker's synchronous operation (`state.in_flight`).
    serial: Option<PtyInputEvent>,
    /// Concurrent surface operations a worker thread would hold.
    concurrent: Vec<PtyInputEvent>,
    reservations: Vec<u64>,
}

pub(crate) fn one_input(data: &[u8]) {
    let mut input = FuzzBytes::new(data);
    let mut driver = Driver::new();
    while let Some(op) = input.byte() {
        if driver.step(op, &mut input).is_none() {
            break;
        }
        driver.check();
    }
    driver.drain();
}

impl Driver {
    fn new() -> Self {
        let queue = Arc::new(SharedQueue::default());
        let on_failure: Arc<dyn Fn(PtyOperationFailure) + Send + Sync> =
            Arc::new(|failure: PtyOperationFailure| {
                assert!(!failure.error.is_empty(), "a failure report carries its reason");
            });
        let sender = PtyInputSender {
            queue: queue.clone(),
            on_failure: on_failure.clone(),
            session_generation: 1,
        };
        Self {
            queue,
            on_failure,
            sender,
            active_generation: 1,
            serial: None,
            concurrent: Vec::new(),
            reservations: Vec::new(),
        }
    }

    fn step(&mut self, op: u8, input: &mut FuzzBytes<'_>) -> Option<()> {
        match op % 10 {
            0 => {
                let spec = self.input_spec(input)?;
                self.enqueue(spec.build());
            }
            1 => {
                // A burst reaches the count and byte bounds in one op.
                let spec = self.input_spec(input)?;
                let copies = usize::from(input.byte()?) * 4 + 1;
                for _ in 0..copies {
                    self.enqueue(spec.build());
                }
            }
            2 => self.enqueue_mutation(input)?,
            3 => {
                self.dequeue();
            }
            4 => {
                if let Some(event) = self.serial.take() {
                    process_event(self.queue.clone(), self.on_failure.clone(), event);
                }
            }
            5 => {
                let index = usize::from(input.byte()?);
                if !self.concurrent.is_empty() {
                    let event = self.concurrent.swap_remove(index % self.concurrent.len());
                    process_event(self.queue.clone(), self.on_failure.clone(), event);
                }
            }
            6 => self.sender.retire_surface(surface(input)?),
            7 => {
                let pick = usize::from(input.byte()?);
                let id = match self.reservations.get(pick % self.reservations.len().max(1)) {
                    Some(id) => *id,
                    None => pick as u64,
                };
                self.sender.cancel_release_reservation(id);
            }
            8 => {
                // As `PtyInputDispatcher::activate_session_generation`: a new
                // session replaces the old one; generations only grow.
                if self.active_generation < MAX_GENERATION {
                    self.active_generation += 1;
                    self.queue.activate_session_generation(self.active_generation);
                    self.sender = self.sender.for_session_generation(self.active_generation);
                }
            }
            _ => {
                // A sender kept from an older session (or the current one).
                let generation = 1 + u64::from(input.byte()?) % self.active_generation;
                self.sender = self.sender.for_session_generation(generation);
            }
        }
        Some(())
    }

    fn input_spec(&self, input: &mut FuzzBytes<'_>) -> Option<InputSpec> {
        let surface_id = surface(input)?;
        let kind = input.pick(&KINDS)?;
        let len = usize::from(input.byte()?);
        // A release is a mouse sequence its press reserved room for.
        let len = if kind == PtyInputKind::Release { len.min(RESERVED_RELEASE_BYTES) } else { len };
        let flags = input.byte()?;
        let outcome =
            (flags & 0b10 != 0).then(|| OUTCOMES[usize::from(flags >> 2) % OUTCOMES.len()]);
        let reservation_id = if flags & 0x80 != 0 && !self.reservations.is_empty() {
            Some(self.reservations[usize::from(input.byte()?) % self.reservations.len()])
        } else {
            None
        };
        Some(InputSpec { surface_id, kind, len, remote: flags & 1 != 0, outcome, reservation_id })
    }

    fn enqueue(&mut self, event: PtyInputEvent) {
        let (_, reservation_id) = self.sender.enqueue_with_reservation(event);
        if let Some(id) = reservation_id
            && self.reservations.len() < MAX_TRACKED_RESERVATIONS
        {
            self.reservations.push(id);
        }
    }

    fn enqueue_mutation(&mut self, input: &mut FuzzBytes<'_>) -> Option<()> {
        let variant = input.byte()?;
        let outcome = input.pick(&OUTCOMES)?;
        let remote = input.flag()?;
        let surface_id = surface(input)?;
        let operation = move || outcome.result();
        match variant % 4 {
            0 => self.sender.enqueue_session_mutation_with_settlement(
                LABELS[0],
                remote,
                || {},
                operation,
            ),
            1 => {
                let key = (LABELS[1], u64::from(input.byte()? % 4), 0);
                let _ = self.sender.enqueue_coalescing_mutation_with_settlement(
                    LABELS[1],
                    key,
                    remote,
                    || {},
                    || {},
                    operation,
                );
            }
            2 => {
                let _ = self
                    .sender
                    .enqueue_coalescing_surface_operation(LABELS[2], surface_id, remote, operation);
            }
            _ => {
                // Up to just past MAX_QUEUED_BYTES, so Oversized is reachable.
                let retained = usize::from(input.byte()?) * 17_000;
                let _ = self.sender.enqueue_surface_operation_with_retained_bytes(
                    LABELS[2], surface_id, remote, retained, operation,
                );
            }
        }
        Some(())
    }

    /// The worker loop's dequeue; it never dequeues while its synchronous
    /// operation runs.
    fn dequeue(&mut self) -> bool {
        if self.serial.is_some() {
            return false;
        }
        let event = dequeue_ready_event(
            &mut self.queue.state.lock().unwrap_or_else(PoisonError::into_inner),
        );
        match event {
            Some(event) if event.concurrent_surface_operation => self.concurrent.push(event),
            Some(event) => self.serial = Some(event),
            None => return false,
        }
        true
    }

    fn check(&self) {
        let state = self.queue.state.lock().unwrap_or_else(PoisonError::into_inner);
        let queued = state.events.iter().map(PtyInputEvent::queued_byte_len).sum::<usize>();
        assert_eq!(state.queued_bytes, queued, "queued byte accounting drifted");
        // An ambiguous release requeued after its timeout may overrun the
        // bound by itself, once.
        assert!(
            state.events.len() <= PTY_OPERATION_QUEUE_CAPACITY + 1,
            "the PTY queue grew past its capacity: {}",
            state.events.len()
        );
        assert!(
            state.queued_bytes <= MAX_QUEUED_BYTES + RESERVED_RELEASE_BYTES,
            "the PTY queue grew past its byte bound: {}",
            state.queued_bytes
        );
        assert_eq!(state.in_flight.is_some(), self.serial.is_some(), "in-flight slot drifted");
        assert_eq!(
            state.in_flight_surface_operations.len(),
            self.concurrent.len(),
            "concurrent surface operation accounting drifted"
        );
    }

    /// With nothing in flight, the head of the queue is always ready, so the
    /// queue must drain to empty.
    fn drain(&mut self) {
        for _ in 0..DRAIN_STEPS {
            if let Some(event) = self.serial.take().or_else(|| self.concurrent.pop()) {
                process_event(self.queue.clone(), self.on_failure.clone(), event);
            } else if !self.dequeue() {
                break;
            }
            self.check();
        }
        assert!(self.serial.is_none() && self.concurrent.is_empty(), "the drain did not finish");
        let state = self.queue.state.lock().unwrap_or_else(PoisonError::into_inner);
        assert!(
            state.events.is_empty(),
            "{} events stayed queued with nothing in flight",
            state.events.len()
        );
        assert_eq!(state.queued_bytes, 0);
    }
}

fn surface(input: &mut FuzzBytes<'_>) -> Option<SurfaceId> {
    Some(SurfaceId::from(input.byte()? % SURFACES))
}
