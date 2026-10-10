//! The ordered mutation queue: pending-mutation accounting, remote tree
//! refresh, and the `enqueue*` family every session mutation goes through.

use std::sync::atomic::Ordering;

use cmux_tui_core::SurfaceId;

use crate::app::ordered_session::{
    CreationCompletionKind, OrderedSession, PendingAmbiguousCreation,
};
use crate::app::{
    AppEvent, MutationImpact, RemoteRefreshClaim, SessionCompletion, SessionCompletionAction,
    SessionMutationOutcome,
};
use crate::pty_input::{PtyOperationDelivery, PtyOperationFailure};
use crate::session::{AmbiguousCreation, Session, is_remote_timeout};

impl OrderedSession {
    pub(in crate::app) fn has_pending_mutations(&self) -> bool {
        self.pending_mutations.load(Ordering::Acquire) > 0
    }

    pub(in crate::app) fn has_pending_pointer_mutations(&self) -> bool {
        self.pending_pointer_mutations.load(Ordering::Acquire) > 0
    }

    pub(in crate::app) fn pointer_map_generation(&self) -> u64 {
        self.pointer_map_generation.load(Ordering::Acquire)
    }

    pub(in crate::app) fn destination_mutation_started(&self) -> u64 {
        self.destination_mutation_started.load(Ordering::Acquire)
    }

    pub(in crate::app) fn destination_mutation_committed(&self) -> u64 {
        self.destination_mutation_committed.load(Ordering::Acquire)
    }

    pub(in crate::app) fn settle_pending_mutation(&self, impact: MutationImpact) {
        let result =
            self.pending_mutations.fetch_update(Ordering::AcqRel, Ordering::Acquire, |pending| {
                pending.checked_sub(1)
            });
        debug_assert!(result.is_ok(), "session mutation completion without a pending operation");
        if impact.blocks_pointer() {
            let result = self.pending_pointer_mutations.fetch_update(
                Ordering::AcqRel,
                Ordering::Acquire,
                |pending| pending.checked_sub(1),
            );
            debug_assert!(
                result.is_ok(),
                "pointer mutation completion without a pending operation"
            );
        }
    }

    pub(in crate::app) fn take_cancellation_pending(&self) -> bool {
        self.cancellation_pending.swap(false, Ordering::AcqRel)
    }

    pub(in crate::app) fn defer_cancellation(&self) {
        self.cancellation_pending.store(true, Ordering::Release);
    }

    pub(in crate::app) fn refresh_remote_tree_if_stale(&self) {
        if !self.inner.take_remote_tree_stale() {
            return;
        }
        if self.remote_refresh_queued.swap(true, Ordering::AcqRel) {
            self.inner.invalidate_remote_tree();
            return;
        }
        self.inner.invalidate_remote_tree();
        let session = self.inner.clone();
        let authoritative_generation = self.committed_mutation_generation.load(Ordering::Acquire);
        let destination_generation = self.destination_mutation_committed.load(Ordering::Acquire);
        let refresh_sequence = self.remote_refresh_sequence.fetch_add(1, Ordering::AcqRel) + 1;
        let pending = self.pending_mutation_with_impact(MutationImpact::PointerMap);
        let claim = RemoteRefreshClaim(self.remote_refresh_queued.clone());
        let spawn =
            std::thread::Builder::new().name("remote-tree-refresh".into()).spawn(move || {
                let result = session.refresh_tree();
                drop(claim);
                match result {
                    Ok(tree) => {
                        pending.settle(SessionMutationOutcome::IdentityRefreshSucceeded {
                            tree,
                            authoritative_generation,
                            destination_generation,
                            refresh_sequence,
                        });
                    }
                    Err(error) => {
                        pending.settle(SessionMutationOutcome::IdentityRefreshFailed {
                            error: error.to_string(),
                            refresh_sequence,
                        });
                    }
                }
            });
        if let Err(error) = spawn {
            self.remote_refresh_queued.store(false, Ordering::Release);
            self.inner.invalidate_remote_tree();
            let _ = self.events.send(AppEvent::PtyOperationFailed(PtyOperationFailure {
                session_generation: self.operations.session_generation(),
                surface_id: None,
                kind: None,
                reservation_id: None,
                label: "remote tree refresh",
                error: error.to_string(),
                lane_failed: false,
                delivery: PtyOperationDelivery::KnownNotDelivered,
            }));
        }
    }

    pub(in crate::app) fn refresh_remote_tree_background(&self) {
        if !self.remote {
            return;
        }
        if self.remote_refresh_queued.swap(true, Ordering::AcqRel) {
            self.remote_background_dirty.store(true, Ordering::Release);
            return;
        }
        let session = self.inner.clone();
        let events = self.events.clone();
        let refresh_sequence = self.remote_refresh_sequence.fetch_add(1, Ordering::AcqRel) + 1;
        let destination_generation = self.destination_mutation_committed.load(Ordering::Acquire);
        let claim = RemoteRefreshClaim(self.remote_refresh_queued.clone());
        let spawn =
            std::thread::Builder::new().name("remote-tree-refresh".into()).spawn(move || {
                let result = session.refresh_tree_background().map_err(|error| error.to_string());
                drop(claim);
                let _ = events.send(AppEvent::RemoteTreeUpdated {
                    refresh_sequence,
                    destination_generation,
                    result,
                });
            });
        if let Err(error) = spawn {
            self.remote_refresh_queued.store(false, Ordering::Release);
            let _ = self.events.send(AppEvent::RemoteTreeUpdated {
                refresh_sequence,
                destination_generation,
                result: Err(error.to_string()),
            });
        }
    }

    pub(in crate::app) fn take_background_refresh_dirty(&self) -> bool {
        self.remote_background_dirty.swap(false, Ordering::AcqRel)
    }

    pub(in crate::app) fn remote_tree_is_stale(&self) -> bool {
        self.inner.remote_tree_is_stale()
    }

    pub(in crate::app) fn enqueue(
        &self,
        label: &'static str,
        operation: impl FnOnce(Session) -> anyhow::Result<()> + Send + 'static,
    ) {
        self.enqueue_with_completion(label, MutationImpact::Ordered, move |session| {
            operation(session)?;
            Ok(None)
        });
    }

    pub(in crate::app) fn enqueue_pointer_mutation(
        &self,
        label: &'static str,
        operation: impl FnOnce(Session) -> anyhow::Result<()> + Send + 'static,
    ) {
        self.enqueue_with_completion(label, MutationImpact::PointerMap, move |session| {
            operation(session)?;
            Ok(None)
        });
    }

    pub(in crate::app) fn enqueue_destination_mutation(
        &self,
        label: &'static str,
        operation: impl FnOnce(Session) -> anyhow::Result<()> + Send + 'static,
    ) {
        self.enqueue_with_completion(label, MutationImpact::Destination, move |session| {
            operation(session)?;
            Ok(None)
        });
    }

    pub(in crate::app) fn enqueue_with_completion(
        &self,
        label: &'static str,
        impact: MutationImpact,
        operation: impl FnOnce(Session) -> anyhow::Result<Option<SessionCompletionAction>>
        + Send
        + 'static,
    ) {
        self.enqueue_with_completion_for_semantic_intent(label, impact, None, operation);
    }

    fn enqueue_with_completion_for_semantic_intent(
        &self,
        label: &'static str,
        impact: MutationImpact,
        semantic_intent: Option<u64>,
        operation: impl FnOnce(Session) -> anyhow::Result<Option<SessionCompletionAction>>
        + Send
        + 'static,
    ) {
        self.enqueue_with_completion_internal(label, impact, semantic_intent, None, operation);
    }

    pub(in crate::app) fn enqueue_creation_with_completion_for_semantic_intent(
        &self,
        label: &'static str,
        semantic_intent: Option<u64>,
        kind: CreationCompletionKind,
        operation: impl FnOnce(Session) -> anyhow::Result<SurfaceId> + Send + 'static,
    ) {
        self.enqueue_creation_attempt(label, semantic_intent, kind, operation);
    }

    fn enqueue_creation_attempt(
        &self,
        label: &'static str,
        semantic_intent: Option<u64>,
        kind: CreationCompletionKind,
        operation: impl FnOnce(Session) -> anyhow::Result<SurfaceId> + Send + 'static,
    ) {
        self.enqueue_with_completion_internal(
            label,
            MutationImpact::Destination,
            semantic_intent,
            Some(kind),
            move |session| {
                let surface = operation(session)?;
                Ok(Some(kind.completion(surface)))
            },
        );
    }

    fn enqueue_with_completion_internal(
        &self,
        label: &'static str,
        impact: MutationImpact,
        semantic_intent: Option<u64>,
        creation_attempt: Option<CreationCompletionKind>,
        operation: impl FnOnce(Session) -> anyhow::Result<Option<SessionCompletionAction>>
        + Send
        + 'static,
    ) {
        let session = self.inner.clone();
        let pending = self.pending_mutation_for_semantic_intent(impact, semantic_intent);
        let remote = self.remote;
        let ambiguous_creations = self.ambiguous_creations.clone();
        let committed_mutation_generation = self.committed_mutation_generation.clone();
        let destination_token = impact
            .creates_destination_intent()
            .then(|| self.destination_mutation_started.fetch_add(1, Ordering::AcqRel) + 1);
        let destination_mutation_committed = self.destination_mutation_committed.clone();
        let settlement = pending.clone();
        self.operations.enqueue_session_mutation_with_settlement(
            label,
            self.remote,
            move || settlement.publish_deferred(),
            move || {
                let completion = match operation(session.clone()) {
                    Ok(completion) => completion,
                    Err(error) => {
                        if let Some(kind) = creation_attempt
                            && let Some(creation) =
                                error.downcast_ref::<AmbiguousCreation>().cloned()
                        {
                            ambiguous_creations.lock().unwrap().push_back(
                                PendingAmbiguousCreation { creation, semantic_intent, kind, label },
                            );
                            session.invalidate_remote_tree();
                            pending.defer(SessionMutationOutcome::CreationResponseAmbiguous(
                                error.to_string(),
                            ));
                            return Err(error);
                        }
                        if remote && is_remote_timeout(&error) {
                            session.invalidate_remote_tree();
                            pending
                                .defer(SessionMutationOutcome::MutationTimedOut(error.to_string()));
                        } else {
                            pending.defer(SessionMutationOutcome::Failed(error.to_string()));
                        }
                        return Err(error);
                    }
                };
                let mutation_generation =
                    committed_mutation_generation.fetch_add(1, Ordering::AcqRel) + 1;
                if let Some(destination_token) = destination_token {
                    destination_mutation_committed.fetch_max(destination_token, Ordering::AcqRel);
                }
                let completion = completion.map(|action| SessionCompletion {
                    mutation_generation,
                    semantic_intent,
                    action,
                });
                session.invalidate_remote_tree();
                if remote {
                    pending.defer(SessionMutationOutcome::CommittedTreeStale {
                        error: None,
                        completion,
                    });
                } else {
                    match session.refresh_tree() {
                        Ok(tree) => {
                            let destination_generation =
                                destination_mutation_committed.load(Ordering::Acquire);
                            pending.defer(SessionMutationOutcome::AuthoritativeMutationSucceeded {
                                tree,
                                authoritative_generation: mutation_generation,
                                destination_generation,
                                completion,
                            });
                        }
                        Err(error) => pending.defer(SessionMutationOutcome::CommittedTreeStale {
                            error: Some(error.to_string()),
                            completion,
                        }),
                    }
                }
                Ok(())
            },
        );
    }

    pub(in crate::app) fn reconcile_ambiguous_creations(&self) -> usize {
        let retryable = {
            let mut pending = self.ambiguous_creations.lock().unwrap();
            pending.drain(..).collect::<Vec<_>>()
        };
        let count = retryable.len();
        for pending in retryable {
            let creation = pending.creation;
            self.enqueue_creation_attempt(
                pending.label,
                pending.semantic_intent,
                pending.kind,
                move |_| creation.retry(),
            );
        }
        count
    }

    #[cfg(test)]
    pub(in crate::app) fn enqueue_coalescing_session_mutation(
        &self,
        label: &'static str,
        key: (&'static str, u64),
        operation: impl FnOnce(Session) -> anyhow::Result<()> + Send + 'static,
    ) {
        self.enqueue_coalescing_session_mutation_with_impact(
            label,
            key,
            MutationImpact::Ordered,
            operation,
        );
    }

    pub(in crate::app) fn enqueue_coalescing_pointer_mutation(
        &self,
        label: &'static str,
        key: (&'static str, u64),
        operation: impl FnOnce(Session) -> anyhow::Result<()> + Send + 'static,
    ) {
        self.enqueue_coalescing_session_mutation_with_impact(
            label,
            key,
            MutationImpact::PointerMap,
            operation,
        );
    }

    fn enqueue_coalescing_session_mutation_with_impact(
        &self,
        label: &'static str,
        key: (&'static str, u64),
        impact: MutationImpact,
        operation: impl FnOnce(Session) -> anyhow::Result<()> + Send + 'static,
    ) {
        let session = self.inner.clone();
        let pending = self.pending_mutation_with_impact(impact);
        let remote = self.remote;
        let committed_mutation_generation = self.committed_mutation_generation.clone();
        let superseded = pending.clone();
        let settlement = pending.clone();
        self.operations.enqueue_coalescing_mutation_with_settlement(
            label,
            (key.0, key.1, 0),
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
                pending.defer(SessionMutationOutcome::Success { tree: None });
                Ok(())
            },
        );
    }

    pub(in crate::app) fn enqueue_coalescing_surface_operation(
        &self,
        label: &'static str,
        surface: SurfaceId,
        operation: impl FnOnce(Session) -> anyhow::Result<()> + Send + 'static,
    ) {
        let session = self.inner.clone();
        self.operations.enqueue_coalescing_surface_operation(
            label,
            surface,
            self.remote,
            move || operation(session),
        );
    }
}
