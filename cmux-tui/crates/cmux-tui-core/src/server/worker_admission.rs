//! Server-wide admission for long-lived work: resource stream and wait
//! worker permits (per client and per server), and surface-operation
//! admission by worker count and retained bytes. The verified app's
//! connections can take [`FRONTEND_RESERVED_WORKER_PERMITS`] more workers than
//! each shared capacity, so automation holding every shared permit never
//! makes a frontend op wait or fail for a worker.

use super::SERVER_SURFACE_RETAINED_BYTE_CAPACITY;
use super::SERVER_SURFACE_WORKER_CAPACITY;
use crate::diagnostics::LockCaller;
use crate::panic_free::RecoverPoison;
use cmux_threads::sync::Condvar;
use cmux_threads::sync::Mutex;
use std::collections::HashMap;
use std::sync::Arc;
#[cfg(test)]
use std::time::Instant;

/// Worker permits only the verified app's connections can take, on top of
/// every shared server capacity (surface workers, resource streams, resource
/// waits). Chromium keeps its foreground workers out of reach of best-effort
/// work the same way: background tasks run in their own thread group and
/// never take a foreground worker (base/task/thread_pool/thread_pool_impl.cc).
pub(super) const FRONTEND_RESERVED_WORKER_PERMITS: usize = 2;

/// The class a worker permit is asked for under.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum WorkerClass {
    /// The verified app: the shared permits, then the reserved ones.
    Frontend,
    /// Every other connection: the shared permits only.
    Automation,
}

impl WorkerClass {
    /// The worker class of a connection whose caller class is `caller`
    /// (`connection_frame::connection_caller`).
    pub(super) const fn of(caller: LockCaller) -> Self {
        match caller {
            LockCaller::Frontend => Self::Frontend,
            LockCaller::Automation | LockCaller::Program => Self::Automation,
        }
    }

    /// The most permits active at once that still admit this class, for a
    /// pool of `shared` permits.
    const fn server_limit(self, shared: usize) -> usize {
        match self {
            Self::Frontend => shared + FRONTEND_RESERVED_WORKER_PERMITS,
            Self::Automation => shared,
        }
    }
}

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

    /// A permit for `client`, a connection of `class`: within its own
    /// per-client capacity and the server capacity of its class.
    pub(super) fn try_reserve(
        self: &Arc<Self>,
        client: u64,
        class: WorkerClass,
    ) -> Result<ResourceWorkerPermit, ResourceWorkerAdmissionError> {
        let mut state = self.state.lock().recover_poison();
        if state.active_by_client.get(&client).copied().unwrap_or_default()
            >= self.per_client_capacity
        {
            return Err(ResourceWorkerAdmissionError::ClientCapacity);
        }
        if state.active >= class.server_limit(self.server_capacity) {
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
pub(super) struct ServerSurfaceOperationState {
    pub(super) workers: usize,
    retained_bytes: usize,
}

#[derive(Default)]
pub(crate) struct ServerSurfaceOperationAdmission {
    pub(super) state: Mutex<ServerSurfaceOperationState>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ServerSurfaceAdmissionError {
    RetainedByteCapacity,
}

pub(super) struct ServerSurfaceWorkerPermit {
    admission: Arc<ServerSurfaceOperationAdmission>,
}

impl Drop for ServerSurfaceWorkerPermit {
    fn drop(&mut self) {
        let mut state = self.admission.state.lock().recover_poison();
        state.workers = state.workers.saturating_sub(1);
    }
}

pub(super) struct ServerSurfaceBytesPermit {
    pub(super) admission: Arc<ServerSurfaceOperationAdmission>,
    pub(super) retained_bytes: usize,
}

impl Drop for ServerSurfaceBytesPermit {
    fn drop(&mut self) {
        let mut state = self.admission.state.lock().recover_poison();
        state.retained_bytes = state.retained_bytes.saturating_sub(self.retained_bytes);
    }
}

impl ServerSurfaceOperationAdmission {
    /// A surface worker for a connection of `class`, within the server
    /// worker capacity of its class.
    pub(super) fn try_reserve_worker(
        self: &Arc<Self>,
        class: WorkerClass,
    ) -> Option<ServerSurfaceWorkerPermit> {
        let mut state = self.state.lock().recover_poison();
        if state.workers >= class.server_limit(SERVER_SURFACE_WORKER_CAPACITY) {
            return None;
        }
        state.workers += 1;
        Some(ServerSurfaceWorkerPermit { admission: self.clone() })
    }

    pub(super) fn try_reserve_bytes(
        self: &Arc<Self>,
        retained_bytes: usize,
    ) -> Result<ServerSurfaceBytesPermit, ServerSurfaceAdmissionError> {
        let mut state = self.state.lock().recover_poison();
        if retained_bytes
            > SERVER_SURFACE_RETAINED_BYTE_CAPACITY.saturating_sub(state.retained_bytes)
        {
            return Err(ServerSurfaceAdmissionError::RetainedByteCapacity);
        }
        state.retained_bytes += retained_bytes;
        Ok(ServerSurfaceBytesPermit { admission: self.clone(), retained_bytes })
    }
}

#[cfg(test)]
#[path = "worker_admission_tests.rs"]
mod tests;
