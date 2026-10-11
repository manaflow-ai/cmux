//! Surface attach for the ordered session: claims, the remote attach executor
//! handoff, and retired-surface reconciliation.

use cmux_tui_core::SurfaceId;

use crate::app::ordered_session::OrderedSession;
use crate::app::{
    MutationImpact, RemoteSurfaceAttachAdmission, RemoteSurfaceAttachExecutor,
    RemoteSurfaceAttachJob, SessionMutationOutcome, SurfaceAttachClaim, SurfaceAttachClaimState,
    next_surface_sync_failure, surface_sync_failure_blocks,
};
use crate::localization;
use crate::pty_input::PtyInputEnqueueResult;
use crate::session::{
    SurfaceAttach, TreeView, is_remote_surface_unavailable, is_remote_timeout,
    is_remote_transport_failure,
};

impl OrderedSession {
    pub(in crate::app) fn attach_surface(&self, id: SurfaceId, size: Option<(u16, u16)>) {
        if self.remote
            && let Some(size) = size
        {
            let promoted = {
                let mut claims = self.surface_attach_claims.lock().unwrap();
                claims.get_mut(&id).is_some_and(|claim| {
                    if claim.retired {
                        return false;
                    }
                    claim.requested_size = Some(size);
                    claim.revision = claim.revision.wrapping_add(1).max(1);
                    true
                })
            };
            if promoted {
                if let Some(executor) = self.remote_surface_attaches.lock().unwrap().as_ref() {
                    executor.promote(id);
                }
                return;
            }
        }
        if !self.can_attach_surface(id) {
            return;
        }
        {
            let retired_surfaces = self.retired_surfaces.lock().unwrap();
            if retired_surfaces.contains(&id) {
                return;
            }
            let mut attach_claims = self.surface_attach_claims.lock().unwrap();
            if attach_claims.contains_key(&id) {
                return;
            }
            attach_claims.insert(
                id,
                SurfaceAttachClaimState { retired: false, requested_size: size, revision: 1 },
            );
        }
        let claim = SurfaceAttachClaim {
            claims: self.surface_attach_claims.clone(),
            surface: id,
            active: true,
        };
        let attach_claims = self.surface_attach_claims.clone();
        let session = self.inner.clone();
        let retired_surfaces = self.retired_surfaces.clone();
        let attach_failures = self.surface_attach_failures.clone();
        #[cfg(test)]
        let attach_after_obsolete_check = self.surface_attach_after_obsolete_check.clone();

        if self.remote {
            // Attach is mirror synchronization, not an authoritative session
            // mutation. A fixed worker pool waits on progress-aware deadlines
            // independently, while size-bearing visible work stays ahead of
            // background tab prefetch.
            let job = RemoteSurfaceAttachJob {
                claim,
                session,
                retired_surfaces,
                attach_claims,
                attach_failures,
                resize_failures: self.surface_resize_failures.clone(),
                events: self.events.clone(),
                id,
                #[cfg(test)]
                after_obsolete_check: attach_after_obsolete_check,
            };
            let mut executor = self.remote_surface_attaches.lock().unwrap();
            if executor.is_none() {
                match RemoteSurfaceAttachExecutor::new() {
                    Ok(created) => *executor = Some(created),
                    Err(error) => {
                        drop(executor);
                        job.fail(
                            localization::catalog()
                                .attach
                                .remote_attach_workers_failed(&error.to_string()),
                        );
                        return;
                    }
                }
            }
            let admission = executor.as_ref().unwrap().enqueue(job, size.is_some());
            drop(executor);
            match admission {
                RemoteSurfaceAttachAdmission::Enqueued { displaced } => drop(displaced),
                RemoteSurfaceAttachAdmission::Rejected(job) => {
                    job.fail(localization::catalog().attach.remote_attach_queue_full.to_string());
                }
            }
            return;
        }

        let enqueue_failures = attach_failures.clone();
        let pending = self.pending_mutation_with_impact(MutationImpact::PointerMap);
        let superseded = pending.clone();
        let settlement = pending.clone();
        let enqueue_result = self.operations.enqueue_coalescing_mutation_with_settlement(
            "attach surface",
            ("attach surface", id, 0),
            self.remote,
            move || superseded.supersede(),
            move || settlement.publish_deferred(),
            move || {
                let _claim = claim;
                let retired_before_attach = {
                    let retired_surfaces = retired_surfaces.lock().unwrap();
                    retired_surfaces.contains(&id)
                        || attach_claims.lock().unwrap().get(&id).is_some_and(|claim| claim.retired)
                };
                if retired_before_attach {
                    pending.defer(SessionMutationOutcome::Success { tree: None });
                    return Ok(());
                }
                #[cfg(test)]
                if let Some(hook) = attach_after_obsolete_check.lock().unwrap().clone() {
                    hook();
                }
                let result = session.try_surface_sized(id, size);
                // Retirement can race after the preflight above while the
                // ordered worker is waiting to attach. In that case the
                // missing mirror is the expected result of teardown, not a
                // retryable synchronization failure.
                let attach_claims = attach_claims.lock().unwrap();
                let retired = attach_claims.get(&id).is_some_and(|claim| claim.retired);
                match result {
                    Ok(SurfaceAttach::Attached(_)) => {
                        attach_failures.lock().unwrap().remove(&id);
                        pending.defer(SessionMutationOutcome::Success { tree: None });
                        drop(attach_claims);
                        Ok(())
                    }
                    Ok(SurfaceAttach::Retired | SurfaceAttach::Deferred) => {
                        attach_failures.lock().unwrap().remove(&id);
                        pending.defer(SessionMutationOutcome::Success { tree: None });
                        drop(attach_claims);
                        Ok(())
                    }
                    Ok(SurfaceAttach::Missing) if retired => {
                        attach_failures.lock().unwrap().remove(&id);
                        pending.defer(SessionMutationOutcome::Success { tree: None });
                        drop(attach_claims);
                        Ok(())
                    }
                    Ok(SurfaceAttach::Missing) => {
                        let mut failures = attach_failures.lock().unwrap();
                        let state =
                            next_surface_sync_failure(failures.get(&id).copied(), false, false);
                        failures.insert(id, state);
                        drop(failures);
                        pending.defer(SessionMutationOutcome::SurfaceSyncFailed {
                            surface: id,
                            operation: "attach",
                            error: format!("surface {id} is unavailable"),
                            reconnect_required: false,
                        });
                        drop(attach_claims);
                        Ok(())
                    }
                    Err(error) if retired && is_remote_surface_unavailable(&error, id) => {
                        attach_failures.lock().unwrap().remove(&id);
                        pending.defer(SessionMutationOutcome::Success { tree: None });
                        drop(attach_claims);
                        Ok(())
                    }
                    Err(error) => {
                        let timed_out = is_remote_timeout(&error);
                        let transport_failed = is_remote_transport_failure(&error);
                        let mut failures = attach_failures.lock().unwrap();
                        let state = next_surface_sync_failure(
                            failures.get(&id).copied(),
                            transport_failed,
                            timed_out,
                        );
                        failures.insert(id, state);
                        drop(failures);
                        pending.defer(SessionMutationOutcome::SurfaceSyncFailed {
                            surface: id,
                            operation: "attach",
                            error: error.to_string(),
                            reconnect_required: timed_out,
                        });
                        drop(attach_claims);
                        if timed_out || transport_failed { Err(error) } else { Ok(()) }
                    }
                }
            },
        );
        if enqueue_result != PtyInputEnqueueResult::Accepted {
            let transient = enqueue_result != PtyInputEnqueueResult::Failed;
            let mut failures = enqueue_failures.lock().unwrap();
            let state = next_surface_sync_failure(failures.get(&id).copied(), transient, false);
            failures.insert(id, state);
        }
    }

    pub(in crate::app) fn can_attach_surface(&self, id: SurfaceId) -> bool {
        let failure_blocks = self
            .surface_attach_failures
            .lock()
            .unwrap()
            .get(&id)
            .copied()
            .is_some_and(surface_sync_failure_blocks);
        let attach_claimed = self.surface_attach_claims.lock().unwrap().contains_key(&id);
        self.inner.cached_surface(id).is_none()
            && self.inner.can_attach_after_overflow(id)
            && !self.retired_surfaces.lock().unwrap().contains(&id)
            && !failure_blocks
            && !attach_claimed
            && (!self.remote || !self.inner.remote_tree_is_stale())
    }

    pub(in crate::app) fn reconcile_retired_surfaces(&self, tree: &TreeView) {
        if !self.remote {
            return;
        }
        self.retired_surfaces.lock().unwrap().retain(|surface| {
            tree.workspaces()
                .iter()
                .flat_map(|workspace| workspace.screens.iter())
                .flat_map(|screen| screen.panes.iter())
                .flat_map(|pane| pane.tabs.iter())
                .any(|tab| tab.surface == *surface)
        });
    }
}
