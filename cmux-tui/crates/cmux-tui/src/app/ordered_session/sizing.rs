//! Surface sizing through the ordered session: client sizing mutations,
//! resize claims, reclaim, and the resize retry decisions.

use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use cmux_tui_core::SurfaceId;

use crate::app::ordered_session::OrderedSession;
use crate::app::{
    MutationImpact, SessionMutationOutcome, SurfaceResizeClaim, SurfaceResizeClaimState,
    SurfaceResizeDecision, SurfaceResizeFailure, next_surface_sync_failure,
    surface_sync_failure_blocks,
};
use crate::pty_input::PtyInputEnqueueResult;
use crate::session::{Session, SurfaceHandle, is_remote_timeout, is_remote_transport_failure};

impl OrderedSession {
    pub(in crate::app) fn enqueue_client_sizing_mutation(
        &self,
        label: &'static str,
        key: (&'static str, SurfaceId, u64),
        operation: impl FnOnce(Session) -> anyhow::Result<()> + Send + 'static,
    ) {
        let session = self.inner.clone();
        let pending = self.pending_mutation_with_impact(MutationImpact::PointerMap);
        let remote = self.remote;
        let committed_mutation_generation = self.committed_mutation_generation.clone();
        let superseded = pending.clone();
        let settlement = pending.clone();
        self.operations.enqueue_coalescing_mutation_with_settlement(
            label,
            key,
            remote,
            move || superseded.supersede(),
            move || settlement.publish_deferred(),
            move || {
                if let Err(error) = operation(session.clone()) {
                    if remote && is_remote_timeout(&error) {
                        session.invalidate_remote_tree();
                        pending.defer(SessionMutationOutcome::MutationTimedOut(error.to_string()));
                    } else {
                        pending.defer(SessionMutationOutcome::Failed(error.to_string()));
                    }
                    return Err(error);
                }
                committed_mutation_generation.fetch_add(1, Ordering::AcqRel);
                pending.defer(SessionMutationOutcome::ClientSizingChanged);
                Ok(())
            },
        );
    }

    pub(in crate::app) fn release_surface_size(&self, surface: SurfaceId) -> bool {
        let session = self.inner.clone();
        let pending = self.pending_mutation_with_impact(MutationImpact::PointerMap);
        pending.cancel_with(SessionMutationOutcome::SurfaceSizeReleaseCanceled { surface });
        let committed_mutation_generation = self.committed_mutation_generation.clone();
        let superseded = pending.clone();
        let settlement = pending.clone();
        let result = self.operations.enqueue_coalescing_mutation_with_settlement(
            "release hidden surface sizing",
            ("surface size release", surface, 0),
            self.remote,
            move || superseded.supersede(),
            move || settlement.publish_deferred(),
            move || match session.release_surface_size(surface) {
                Ok(()) => {
                    committed_mutation_generation.fetch_add(1, Ordering::AcqRel);
                    pending.defer(SessionMutationOutcome::SurfaceSizeReleased { surface });
                    Ok(())
                }
                Err(error) => {
                    pending.defer(SessionMutationOutcome::SurfaceSizeReleaseFailed {
                        surface,
                        error: error.to_string(),
                    });
                    Err(error)
                }
            },
        );
        result == PtyInputEnqueueResult::Accepted
    }

    pub(in crate::app) fn resize_surface(
        &self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        cols: u16,
        rows: u16,
        reassert: bool,
        claim: SurfaceResizeClaim,
    ) -> bool {
        self.resize_surface_with_key(
            surface_id,
            surface,
            cols,
            rows,
            reassert,
            claim,
            "resize PTY surface",
            ("surface resize", surface_id, 0),
        )
    }

    pub(in crate::app) fn reclaim_surface_size(
        &self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        cols: u16,
        rows: u16,
        claim: SurfaceResizeClaim,
    ) -> bool {
        self.resize_surface_with_key(
            surface_id,
            surface,
            cols,
            rows,
            true,
            claim,
            "reclaim visible PTY surface sizing",
            ("surface size release", surface_id, 0),
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn resize_surface_with_key(
        &self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        cols: u16,
        rows: u16,
        reassert: bool,
        claim: SurfaceResizeClaim,
        label: &'static str,
        key: (&'static str, SurfaceId, u64),
    ) -> bool {
        let pending = self.pending_mutation_with_impact(MutationImpact::PointerMap);
        let failures = self.surface_resize_failures.clone();
        let enqueue_failures = failures.clone();
        let committed_mutation_generation = self.committed_mutation_generation.clone();
        let superseded = pending.clone();
        let settlement = pending.clone();
        let enqueue_result = self.operations.enqueue_coalescing_mutation_with_settlement(
            label,
            key,
            self.remote,
            move || superseded.supersede(),
            move || settlement.publish_deferred(),
            move || {
                let result = if reassert {
                    surface.reassert_size(cols, rows)
                } else {
                    surface.resize(cols, rows)
                };
                // Release local ownership before the worker publishes its
                // post-operation settlement barrier.
                drop(claim);
                match result {
                    Ok(_) => {
                        failures.lock().unwrap().remove(&surface_id);
                        committed_mutation_generation.fetch_add(1, Ordering::AcqRel);
                        pending.defer(SessionMutationOutcome::Success { tree: None });
                        Ok(())
                    }
                    Err(error) => {
                        let transient =
                            is_remote_timeout(&error) || is_remote_transport_failure(&error);
                        let mut failures = failures.lock().unwrap();
                        let previous = failures.get(&surface_id).map(|failure| failure.state);
                        let state = next_surface_sync_failure(previous, transient, false);
                        failures.insert(
                            surface_id,
                            SurfaceResizeFailure { desired: (cols, rows), state },
                        );
                        drop(failures);
                        pending.defer(SessionMutationOutcome::SurfaceSyncFailed {
                            surface: surface_id,
                            operation: "resize",
                            error: error.to_string(),
                            reconnect_required: state.sticky_until_reconnect,
                        });
                        if transient { Err(error) } else { Ok(()) }
                    }
                }
            },
        );
        if enqueue_result != PtyInputEnqueueResult::Accepted {
            let transient = enqueue_result != PtyInputEnqueueResult::Failed;
            let mut failures = enqueue_failures.lock().unwrap();
            let previous = failures.get(&surface_id).map(|failure| failure.state);
            let state = next_surface_sync_failure(previous, transient, false);
            failures.insert(surface_id, SurfaceResizeFailure { desired: (cols, rows), state });
        }
        enqueue_result == PtyInputEnqueueResult::Accepted
    }

    pub(in crate::app) fn confirm_surface_resize(
        &self,
        surface: SurfaceId,
        size: (u16, u16),
        reservation_id: Option<u64>,
    ) {
        let mut ownership = self.surface_resize_ownership.lock().unwrap();
        if ownership.get(&surface).is_some_and(|ownership| {
            ownership.desired == size
                && reservation_id.is_none_or(|id| ownership.reservation_id == Some(id))
        }) {
            ownership.remove(&surface);
        }
        drop(ownership);
        let mut failures = self.surface_resize_failures.lock().unwrap();
        if failures.get(&surface).is_some_and(|failure| failure.desired == size) {
            failures.remove(&surface);
        }
    }

    pub(in crate::app) fn note_surface_resize_failure(
        &self,
        surface: SurfaceId,
        desired: (u16, u16),
        retry_after_ms: Option<u64>,
        reservation_id: Option<u64>,
    ) -> bool {
        if self.surface_resize_ownership.lock().unwrap().get(&surface).is_none_or(|ownership| {
            ownership.desired != desired
                || reservation_id.is_some_and(|id| ownership.reservation_id != Some(id))
        }) {
            return false;
        }
        let mut failures = self.surface_resize_failures.lock().unwrap();
        let previous = failures
            .get(&surface)
            .filter(|failure| failure.desired == desired)
            .map(|failure| failure.state);
        let mut state = next_surface_sync_failure(previous, true, retry_after_ms.is_none());
        if let Some(delay) = retry_after_ms {
            state.retry_after = Some(Instant::now() + Duration::from_millis(delay));
            state.sticky_until_reconnect = false;
        }
        failures.insert(surface, SurfaceResizeFailure { desired, state });
        true
    }

    pub(in crate::app) fn surface_resize_retry_due(&self) -> bool {
        let now = Instant::now();
        self.surface_resize_failures.lock().unwrap().values().any(|failure| {
            !failure.state.sticky_until_reconnect
                && failure.state.retry_after.is_some_and(|retry_after| now >= retry_after)
        })
    }

    pub(in crate::app) fn surface_resize_decision(
        &self,
        surface_id: SurfaceId,
        desired: (u16, u16),
        surface_needs_resize: bool,
    ) -> SurfaceResizeDecision {
        self.surface_resize_decision_with_claim_policy(
            surface_id,
            desired,
            surface_needs_resize,
            false,
        )
    }

    pub(in crate::app) fn surface_resize_reclaim_decision(
        &self,
        surface_id: SurfaceId,
        desired: (u16, u16),
    ) -> SurfaceResizeDecision {
        self.surface_resize_decision_with_claim_policy(surface_id, desired, true, true)
    }

    fn surface_resize_decision_with_claim_policy(
        &self,
        surface_id: SurfaceId,
        desired: (u16, u16),
        surface_needs_resize: bool,
        supersede_existing_claim: bool,
    ) -> SurfaceResizeDecision {
        let mut failures = self.surface_resize_failures.lock().unwrap();
        if let Some(failure) = failures.get(&surface_id).copied()
            && failure.desired == desired
            && surface_sync_failure_blocks(failure.state)
        {
            return SurfaceResizeDecision::Failed;
        }
        if failures.get(&surface_id).is_some_and(|failure| failure.desired != desired) {
            failures.remove(&surface_id);
        }
        drop(failures);
        let mut claims = self.surface_resize_claims.lock().unwrap();
        if !supersede_existing_claim
            && claims.get(&surface_id).is_some_and(|claim| claim.desired == desired)
        {
            return SurfaceResizeDecision::AlreadyClaimed;
        }
        if !claims.contains_key(&surface_id) && !surface_needs_resize {
            return SurfaceResizeDecision::Noop;
        }
        let token = self.surface_resize_claim_sequence.fetch_add(1, Ordering::AcqRel) + 1;
        claims.insert(surface_id, SurfaceResizeClaimState { desired, token });
        SurfaceResizeDecision::NeedsQueue(SurfaceResizeClaim {
            claims: self.surface_resize_claims.clone(),
            surface: surface_id,
            token,
        })
    }
}
