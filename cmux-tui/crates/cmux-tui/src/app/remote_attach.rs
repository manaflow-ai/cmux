//! Surface attach execution: `perform_surface_attach` and the bounded remote
//! attach executor (worker threads plus an admission queue) that runs remote
//! attaches off the UI thread.

use std::collections::{HashMap, HashSet, VecDeque};
use std::panic::AssertUnwindSafe;
use std::sync::{Arc, Mutex};

use cmux_threads::sync::Condvar;
use cmux_tui_core::SurfaceId;

#[cfg(test)]
use crate::app::surface_sync::SurfaceAttachAfterObsoleteCheckHook;
use crate::app::surface_sync::{
    SurfaceAttachClaim, SurfaceAttachClaimState, SurfaceAttachOutcome, SurfaceAttachResult,
    SurfaceResizeFailure, SurfaceSyncFailureState, next_surface_sync_failure,
    retire_missing_surface_attach,
};
use crate::app::{AppEvent, SessionEventSender};
use crate::localization;
use crate::session::{
    Session, SurfaceAttach, is_remote_surface_unavailable, is_remote_timeout,
    is_remote_transport_failure,
};

pub(super) fn perform_surface_attach(
    session: &Session,
    retired_surfaces: &Mutex<HashSet<SurfaceId>>,
    attach_claims: &Mutex<HashMap<SurfaceId, SurfaceAttachClaimState>>,
    attach_failures: &Mutex<HashMap<SurfaceId, SurfaceSyncFailureState>>,
    id: SurfaceId,
    size: Option<(u16, u16)>,
    after_obsolete_check: impl FnOnce(),
) -> SurfaceAttachResult {
    let retired_before_attach = {
        let retired_surfaces =
            retired_surfaces.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        retired_surfaces.contains(&id)
            || attach_claims
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .get(&id)
                .is_some_and(|claim| claim.retired)
    };
    if retired_before_attach {
        return SurfaceAttachResult {
            outcome: SurfaceAttachOutcome::Retired { surface: id },
            surface: None,
            requested_size: size,
        };
    }
    after_obsolete_check();
    let result = session.try_surface_sized(id, size);
    let retired = attach_claims
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(&id)
        .is_some_and(|claim| claim.retired);
    match result {
        Ok(SurfaceAttach::Attached(_)) if retired => {
            attach_failures.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&id);
            SurfaceAttachResult {
                outcome: SurfaceAttachOutcome::Retired { surface: id },
                surface: None,
                requested_size: size,
            }
        }
        Ok(SurfaceAttach::Attached(surface)) => {
            attach_failures.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&id);
            SurfaceAttachResult {
                outcome: SurfaceAttachOutcome::Attached,
                surface: Some(surface),
                requested_size: size,
            }
        }
        Ok(SurfaceAttach::Retired) => {
            retire_missing_surface_attach(
                session,
                retired_surfaces,
                attach_claims,
                attach_failures,
                id,
            );
            SurfaceAttachResult {
                outcome: SurfaceAttachOutcome::Retired { surface: id },
                surface: None,
                requested_size: size,
            }
        }
        Ok(SurfaceAttach::Deferred) => {
            attach_failures.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&id);
            SurfaceAttachResult {
                outcome: SurfaceAttachOutcome::Deferred,
                surface: None,
                requested_size: size,
            }
        }
        Ok(SurfaceAttach::Missing) if retired => {
            attach_failures.lock().unwrap_or_else(std::sync::PoisonError::into_inner).remove(&id);
            SurfaceAttachResult {
                outcome: SurfaceAttachOutcome::Retired { surface: id },
                surface: None,
                requested_size: size,
            }
        }
        Ok(SurfaceAttach::Missing) => {
            let mut failures =
                attach_failures.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let state = next_surface_sync_failure(failures.get(&id).copied(), false, false);
            failures.insert(id, state);
            SurfaceAttachResult {
                outcome: SurfaceAttachOutcome::Failed {
                    surface: id,
                    operation: "attach",
                    error: format!("surface {id} is unavailable"),
                    reconnect_required: false,
                },
                surface: None,
                requested_size: size,
            }
        }
        Err(error) if is_remote_surface_unavailable(&error, id) => {
            retire_missing_surface_attach(
                session,
                retired_surfaces,
                attach_claims,
                attach_failures,
                id,
            );
            SurfaceAttachResult {
                outcome: SurfaceAttachOutcome::Retired { surface: id },
                surface: None,
                requested_size: size,
            }
        }
        Err(error) => {
            let timed_out = is_remote_timeout(&error);
            let transport_failed = is_remote_transport_failure(&error);
            let message = error.to_string();
            let mut failures =
                attach_failures.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let state =
                next_surface_sync_failure(failures.get(&id).copied(), transport_failed, timed_out);
            failures.insert(id, state);
            SurfaceAttachResult {
                outcome: SurfaceAttachOutcome::Failed {
                    surface: id,
                    operation: "attach",
                    error: message,
                    reconnect_required: timed_out,
                },
                surface: None,
                requested_size: size,
            }
        }
    }
}

pub(super) const REMOTE_ATTACH_WORKER_LIMIT: usize = 4;
pub(super) const REMOTE_ATTACH_QUEUE_CAPACITY: usize = 512;

pub(super) struct RemoteSurfaceAttachJob {
    pub(super) claim: SurfaceAttachClaim,
    pub(super) session: Session,
    pub(super) retired_surfaces: Arc<Mutex<HashSet<SurfaceId>>>,
    pub(super) attach_claims: Arc<Mutex<HashMap<SurfaceId, SurfaceAttachClaimState>>>,
    pub(super) attach_failures: Arc<Mutex<HashMap<SurfaceId, SurfaceSyncFailureState>>>,
    pub(super) resize_failures: Arc<Mutex<HashMap<SurfaceId, SurfaceResizeFailure>>>,
    pub(super) events: SessionEventSender,
    pub(super) id: SurfaceId,
    #[cfg(test)]
    pub(super) after_obsolete_check: SurfaceAttachAfterObsoleteCheckHook,
}

impl RemoteSurfaceAttachJob {
    fn run(self) {
        let Self {
            mut claim,
            session,
            retired_surfaces,
            attach_claims,
            attach_failures,
            resize_failures,
            events,
            id,
            #[cfg(test)]
            after_obsolete_check,
        } = self;
        let initial = claim.snapshot().unwrap_or_default();
        let mut result = perform_surface_attach(
            &session,
            &retired_surfaces,
            &attach_claims,
            &attach_failures,
            id,
            initial.requested_size,
            || {
                #[cfg(test)]
                if let Some(hook) = { after_obsolete_check.lock().unwrap().clone() } {
                    hook();
                }
            },
        );
        let mut applied_revision = initial.revision;
        while let Some(latest) = claim.snapshot() {
            if latest.revision != applied_revision {
                if !latest.retired
                    && latest.requested_size != result.requested_size
                    && let (Some(surface), Some((cols, rows))) =
                        (result.surface.as_ref(), latest.requested_size)
                {
                    match surface.resize(cols, rows) {
                        Ok(_) => {
                            resize_failures
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner)
                                .remove(&id);
                            result.outcome = SurfaceAttachOutcome::Attached;
                            result.requested_size = latest.requested_size;
                        }
                        Err(error) => {
                            let transient =
                                is_remote_timeout(&error) || is_remote_transport_failure(&error);
                            let mut failures = resize_failures
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner);
                            let previous = failures
                                .get(&id)
                                .filter(|failure| failure.desired == (cols, rows))
                                .map(|failure| failure.state);
                            let state = next_surface_sync_failure(previous, transient, false);
                            failures
                                .insert(id, SurfaceResizeFailure { desired: (cols, rows), state });
                            result.outcome = SurfaceAttachOutcome::Failed {
                                surface: id,
                                operation: "resize",
                                error: error.to_string(),
                                reconnect_required: state.sticky_until_reconnect,
                            };
                        }
                    }
                }
                applied_revision = latest.revision;
            }
            if claim.complete_if_revision(applied_revision) {
                break;
            }
        }
        let _ = events.send(AppEvent::SurfaceAttachSettled { outcome: result.outcome });
    }

    /// [`Self::run`] on a pool worker. A panic in the job's remote calls
    /// settles it as a failed attach and the worker takes the next job: no
    /// shared lock is held across those calls, and the unwind already
    /// released the job's claim.
    fn run_on_worker(self) {
        let id = self.id;
        let events = self.events.clone();
        let attach_failures = self.attach_failures.clone();
        if let Err(payload) = std::panic::catch_unwind(AssertUnwindSafe(|| self.run())) {
            let message = payload
                .downcast_ref::<&str>()
                .copied()
                .or_else(|| payload.downcast_ref::<String>().map(String::as_str))
                .unwrap_or("non-text panic payload");
            crate::client_log::error(
                "surface-attach",
                &format!("surface {id}: attach job panicked: {message}"),
            );
            settle_failed_attach(
                &attach_failures,
                &events,
                id,
                localization::catalog().attach.remote_attach_worker_panicked.to_string(),
            );
        }
    }

    pub(super) fn fail(self, error: String) {
        settle_failed_attach(&self.attach_failures, &self.events, self.id, error);
    }
}

fn settle_failed_attach(
    attach_failures: &Mutex<HashMap<SurfaceId, SurfaceSyncFailureState>>,
    events: &SessionEventSender,
    id: SurfaceId,
    error: String,
) {
    let mut failures = attach_failures.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let state = next_surface_sync_failure(failures.get(&id).copied(), true, false);
    failures.insert(id, state);
    drop(failures);
    let _ = events.send(AppEvent::SurfaceAttachSettled {
        outcome: SurfaceAttachOutcome::Failed {
            surface: id,
            operation: "attach",
            error,
            reconnect_required: false,
        },
    });
}

#[derive(Default)]
pub(super) struct RemoteSurfaceAttachQueue {
    pub(super) visible: VecDeque<RemoteSurfaceAttachJob>,
    background: VecDeque<RemoteSurfaceAttachJob>,
    background_running: usize,
    background_limit: usize,
    stopped: bool,
}

pub(super) struct RemoteSurfaceAttachExecutor {
    pub(super) shared: Arc<(Mutex<RemoteSurfaceAttachQueue>, Condvar)>,
    pub(super) worker_count: usize,
}

pub(super) fn remote_attach_background_limit(worker_count: usize) -> usize {
    worker_count.saturating_sub(1)
}

pub(super) enum RemoteSurfaceAttachAdmission {
    Enqueued { displaced: Option<RemoteSurfaceAttachJob> },
    Rejected(RemoteSurfaceAttachJob),
}

impl RemoteSurfaceAttachExecutor {
    pub(super) fn new() -> std::io::Result<Self> {
        let shared = Arc::new((Mutex::new(RemoteSurfaceAttachQueue::default()), Condvar::new()));
        let mut worker_count: usize = 0;
        for worker in 0..REMOTE_ATTACH_WORKER_LIMIT {
            let worker_shared = shared.clone();
            // supervise-allow: one of REMOTE_ATTACH_WORKER_LIMIT pool workers owned by the executor and stopped with it; run_on_worker settles a panicking job as a failed attach, so the worker releases its background slot and takes the next job.
            let spawned = cmux_threads::spawn(
                format!("surface-attach-{worker}"),
                cmux_tui_core::thread_qos::ThreadType::Interactive.qos(),
                move || {
                    loop {
                        let (job, background) = {
                            let (queue, ready) = &*worker_shared;
                            let mut queue =
                                queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                            while !queue.stopped && queue.visible.is_empty() && {
                                queue.background.is_empty()
                                    || queue.background_running >= queue.background_limit
                            } {
                                queue = ready
                                    .wait(queue)
                                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                            }
                            if queue.stopped {
                                return;
                            }
                            if let Some(job) = queue.visible.pop_front() {
                                (Some(job), false)
                            } else {
                                let job = queue.background.pop_front();
                                if job.is_some() {
                                    queue.background_running += 1;
                                }
                                (job, true)
                            }
                        };
                        if let Some(job) = job {
                            job.run_on_worker();
                        }
                        if background {
                            let (queue, ready) = &*worker_shared;
                            let mut queue =
                                queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                            queue.background_running = queue.background_running.saturating_sub(1);
                            ready.notify_all();
                        }
                    }
                },
            );
            match spawned {
                Ok(_) => worker_count += 1,
                Err(error) if worker_count == 0 => return Err(error),
                Err(_) => break,
            }
        }
        {
            let (queue, ready) = &*shared;
            let mut queue = queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            queue.background_limit = remote_attach_background_limit(worker_count);
            ready.notify_all();
        }
        Ok(Self { shared, worker_count })
    }

    /// Returns work that was not admitted. Visible work may displace the
    /// newest background prefetch. Dropping either job releases its attach
    /// claim so a later layout pass can retry it.
    pub(super) fn enqueue(
        &self,
        job: RemoteSurfaceAttachJob,
        visible: bool,
    ) -> RemoteSurfaceAttachAdmission {
        debug_assert!(self.worker_count > 0);
        let (queue, ready) = &*self.shared;
        let mut queue = queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if queue.stopped {
            return RemoteSurfaceAttachAdmission::Rejected(job);
        }
        let queued = queue.visible.len() + queue.background.len();
        let displaced = if queued >= REMOTE_ATTACH_QUEUE_CAPACITY {
            if visible {
                let Some(displaced) = queue.background.pop_back() else {
                    return RemoteSurfaceAttachAdmission::Rejected(job);
                };
                Some(displaced)
            } else {
                return RemoteSurfaceAttachAdmission::Rejected(job);
            }
        } else {
            None
        };
        if visible {
            queue.visible.push_back(job);
        } else {
            queue.background.push_back(job);
        }
        ready.notify_one();
        RemoteSurfaceAttachAdmission::Enqueued { displaced }
    }

    pub(super) fn promote(&self, surface: SurfaceId) {
        let (queue, ready) = &*self.shared;
        let mut queue = queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(job) = queue
            .background
            .iter()
            .position(|job| job.id == surface)
            .and_then(|index| queue.background.remove(index))
        else {
            return;
        };
        queue.visible.push_back(job);
        ready.notify_one();
    }

    pub(super) fn shutdown(&self) {
        let (queue, ready) = &*self.shared;
        let mut queue = queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        queue.stopped = true;
        queue.visible.clear();
        queue.background.clear();
        ready.notify_all();
    }
}

impl Drop for RemoteSurfaceAttachExecutor {
    fn drop(&mut self) {
        self.shutdown();
    }
}
