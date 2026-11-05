//! Server-wide admission for long-lived work: resource stream and wait
//! worker permits (per client and per server), and surface-operation
//! admission by worker count and retained bytes.

use super::SERVER_SURFACE_RETAINED_BYTE_CAPACITY;
use super::SERVER_SURFACE_WORKER_CAPACITY;
use crate::panic_free::RecoverPoison;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Condvar;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
#[cfg(test)]
use std::time::Instant;

/// `agent.message.wait` workers: one wake hook per connection, one per idle
/// terminal agent on the daemon (agent_message_wait.rs).
pub(super) const AGENT_MESSAGE_WAITS_PER_CLIENT_CAPACITY: usize = 1;
pub(super) const AGENT_MESSAGE_WAITS_SERVER_CAPACITY: usize = 256;

#[derive(Default)]
struct ResourceWorkerAdmissionState {
    active: usize,
    active_by_client: HashMap<u64, usize>,
}

pub(super) struct ResourceWorkerAdmission {
    pub(super) per_client_capacity: usize,
    pub(super) server_capacity: usize,
    state: Mutex<ResourceWorkerAdmissionState>,
    pub(super) changed: Condvar,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ResourceWorkerAdmissionError {
    ClientCapacity,
    ServerCapacity,
}

#[derive(Clone)]
pub(super) struct ResourceWorkerPermit {
    _lease: Arc<ResourceWorkerPermitLease>,
}

struct ResourceWorkerPermitLease {
    admission: Arc<ResourceWorkerAdmission>,
    client: u64,
}

impl Drop for ResourceWorkerPermitLease {
    fn drop(&mut self) {
        let mut state = self.admission.state.lock().recover_poison();
        state.active = state.active.saturating_sub(1);
        let remove_client = state.active_by_client.get_mut(&self.client).is_some_and(|active| {
            *active = active.saturating_sub(1);
            *active == 0
        });
        if remove_client {
            state.active_by_client.remove(&self.client);
        }
        self.admission.changed.notify_all();
    }
}

impl ResourceWorkerAdmission {
    pub(super) fn new(per_client_capacity: usize, server_capacity: usize) -> Arc<Self> {
        Arc::new(Self {
            per_client_capacity,
            server_capacity,
            state: Mutex::new(ResourceWorkerAdmissionState::default()),
            changed: Condvar::new(),
        })
    }

    pub(super) fn try_reserve(
        self: &Arc<Self>,
        client: u64,
    ) -> Result<ResourceWorkerPermit, ResourceWorkerAdmissionError> {
        let mut state = self.state.lock().recover_poison();
        if state.active_by_client.get(&client).copied().unwrap_or_default()
            >= self.per_client_capacity
        {
            return Err(ResourceWorkerAdmissionError::ClientCapacity);
        }
        if state.active >= self.server_capacity {
            return Err(ResourceWorkerAdmissionError::ServerCapacity);
        }
        state.active += 1;
        *state.active_by_client.entry(client).or_default() += 1;
        Ok(ResourceWorkerPermit {
            _lease: Arc::new(ResourceWorkerPermitLease { admission: self.clone(), client }),
        })
    }

    #[cfg(test)]
    pub(super) fn active(&self) -> usize {
        self.state.lock().recover_poison().active
    }

    #[cfg(test)]
    pub(super) fn wait_until_idle(&self, deadline: Instant) -> bool {
        let mut state = self.state.lock().recover_poison();
        while state.active != 0 {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            let (next, timeout) = self.changed.wait_timeout(state, remaining).recover_poison();
            state = next;
            if timeout.timed_out() && state.active != 0 {
                return false;
            }
        }
        true
    }
}

#[derive(Default)]
struct ServerSurfaceOperationState {
    workers: usize,
    retained_bytes: usize,
}

/// Daemon-wide admission of surface operations: clear-history workers by count and queued requests by retained bytes.
/// Every request a connection's surface scheduler queues reserves here before it is queued and releases after it ran
/// (the person's `send` and `send-key` lines among them; pings, identify, v2 resource lines and the frame handlers
/// that answer on the reader thread do not reserve).
///
/// R-DAEMON-STATE stage S1 (`CMUX_TUI_RDS_INPUT`): with the lane on, the counters are atomics with compare-and-swap
/// reservations, so no request, and no key of the person, waits for another connection's reservation. With it off,
/// the old mutex counts (deleted with the switch when the stage passes).
#[derive(Default)]
pub(crate) struct ServerSurfaceOperationAdmission {
    /// The old arm's counters (stage S1 off).
    state: Mutex<ServerSurfaceOperationState>,
    /// The lane's counters (stage S1 on).
    workers: AtomicUsize,
    retained_bytes: AtomicUsize,
    /// Which arm reserves; fixed when the mux is built (`Mux::set_input_lane_for_test` sets it before any request).
    lock_free: AtomicBool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ServerSurfaceAdmissionError {
    RetainedByteCapacity,
}

pub(super) struct ServerSurfaceWorkerPermit {
    admission: Arc<ServerSurfaceOperationAdmission>,
    /// The arm it reserved from; it releases to the same one.
    lock_free: bool,
}

impl Drop for ServerSurfaceWorkerPermit {
    fn drop(&mut self) {
        if self.lock_free {
            release(&self.admission.workers, 1);
        } else {
            let mut state = self.admission.state.lock().recover_poison();
            state.workers = state.workers.saturating_sub(1);
        }
    }
}

pub(super) struct ServerSurfaceBytesPermit {
    pub(super) admission: Arc<ServerSurfaceOperationAdmission>,
    pub(super) retained_bytes: usize,
    /// The arm it reserved from; it releases to the same one.
    lock_free: bool,
}

impl Drop for ServerSurfaceBytesPermit {
    fn drop(&mut self) {
        if self.lock_free {
            release(&self.admission.retained_bytes, self.retained_bytes);
        } else {
            let mut state = self.admission.state.lock().recover_poison();
            state.retained_bytes = state.retained_bytes.saturating_sub(self.retained_bytes);
        }
    }
}

/// Adds `amount` to `counter` when the sum stays within `capacity`; false (and nothing added) otherwise.
fn reserve(counter: &AtomicUsize, amount: usize, capacity: usize) -> bool {
    counter
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |held| {
            held.checked_add(amount).filter(|total| *total <= capacity)
        })
        .is_ok()
}

/// Subtracts what a permit reserved; a release never goes below zero.
fn release(counter: &AtomicUsize, amount: usize) {
    let _ = counter.fetch_update(Ordering::AcqRel, Ordering::Acquire, |held| {
        Some(held.saturating_sub(amount))
    });
}

impl ServerSurfaceOperationAdmission {
    /// The admission of a mux whose stage S1 switch is `lock_free` (R-DAEMON-STATE).
    pub(crate) fn new(lock_free: bool) -> Self {
        Self { lock_free: AtomicBool::new(lock_free), ..Self::default() }
    }

    /// Turns stage S1 on or off (tests, before any request reserves).
    #[cfg(test)]
    pub(crate) fn set_lock_free_for_test(&self, on: bool) {
        self.lock_free.store(on, Ordering::Relaxed);
    }

    /// The clear-history workers reserved now, on either arm (tests).
    #[cfg(test)]
    pub(super) fn reserved_workers(&self) -> usize {
        self.workers.load(Ordering::Acquire) + self.state.lock().recover_poison().workers
    }

    /// Runs `hold` while this thread holds the old arm's lock (test hook: a person's key must not wait for it,
    /// R-DAEMON-STATE stage S1).
    #[cfg(test)]
    pub(super) fn hold_for_test(&self, hold: impl FnOnce()) {
        let _state = self.state.lock().recover_poison();
        hold();
    }

    pub(super) fn try_reserve_worker(self: &Arc<Self>) -> Option<ServerSurfaceWorkerPermit> {
        if self.lock_free.load(Ordering::Relaxed) {
            return reserve(&self.workers, 1, SERVER_SURFACE_WORKER_CAPACITY)
                .then(|| ServerSurfaceWorkerPermit { admission: self.clone(), lock_free: true });
        }
        let mut state = self.state.lock().recover_poison();
        if state.workers >= SERVER_SURFACE_WORKER_CAPACITY {
            return None;
        }
        state.workers += 1;
        Some(ServerSurfaceWorkerPermit { admission: self.clone(), lock_free: false })
    }

    pub(super) fn try_reserve_bytes(
        self: &Arc<Self>,
        retained_bytes: usize,
    ) -> Result<ServerSurfaceBytesPermit, ServerSurfaceAdmissionError> {
        if self.lock_free.load(Ordering::Relaxed) {
            if !reserve(&self.retained_bytes, retained_bytes, SERVER_SURFACE_RETAINED_BYTE_CAPACITY)
            {
                return Err(ServerSurfaceAdmissionError::RetainedByteCapacity);
            }
            return Ok(ServerSurfaceBytesPermit {
                admission: self.clone(),
                retained_bytes,
                lock_free: true,
            });
        }
        let mut state = self.state.lock().recover_poison();
        if retained_bytes
            > SERVER_SURFACE_RETAINED_BYTE_CAPACITY.saturating_sub(state.retained_bytes)
        {
            return Err(ServerSurfaceAdmissionError::RetainedByteCapacity);
        }
        state.retained_bytes += retained_bytes;
        Ok(ServerSurfaceBytesPermit { admission: self.clone(), retained_bytes, lock_free: false })
    }
}
