//! Session mutation bookkeeping: the outcome and completion types a mutation
//! reports back to the app, its impact class, and the pending-mutation guard
//! that settles the ordered session's counters when it drops.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use cmux_tui_core::{LayoutUndoError, PaneId, SurfaceId};

use crate::app::{AppEvent, SessionEventSender, SessionTrySendError};
use crate::session::TreeView;

pub enum SessionMutationOutcome {
    SemanticIntent {
        intent: u64,
        outcome: Box<SessionMutationOutcome>,
    },
    Success {
        tree: Option<TreeView>,
    },
    AuthoritativeMutationSucceeded {
        tree: TreeView,
        authoritative_generation: u64,
        destination_generation: u64,
        completion: Option<SessionCompletion>,
    },
    IdentityRefreshSucceeded {
        tree: TreeView,
        authoritative_generation: u64,
        destination_generation: u64,
        refresh_sequence: u64,
    },
    CommittedTreeStale {
        error: Option<String>,
        completion: Option<SessionCompletion>,
    },
    IdentityRefreshFailed {
        error: String,
        refresh_sequence: u64,
    },
    SurfaceSyncFailed {
        surface: SurfaceId,
        operation: &'static str,
        error: String,
        reconnect_required: bool,
    },
    SurfaceSizeReleased {
        surface: SurfaceId,
    },
    SurfaceSizeReleaseFailed {
        surface: SurfaceId,
        error: String,
    },
    SurfaceSizeReleaseCanceled {
        surface: SurfaceId,
    },
    ClientSizingChanged,
    CreationResponseAmbiguous(String),
    MutationTimedOut(String),
    Failed(String),
    Canceled,
}

pub struct SessionCompletion {
    pub(super) mutation_generation: u64,
    pub(super) semantic_intent: Option<u64>,
    pub(super) action: SessionCompletionAction,
}

pub(super) enum SessionCompletionAction {
    SurfaceMoved { surface: SurfaceId },
    SurfaceCreated { surface: SurfaceId },
    BrowserTabCreated { surface: SurfaceId },
    LayoutUndoConfirmation { pane: PaneId, revision: u64, closes_panes: Vec<PaneId> },
    LayoutUndoUnavailable,
    LayoutUndoStale,
}

pub(super) fn layout_undo_error_completion(
    error: &anyhow::Error,
) -> Option<SessionCompletionAction> {
    match error.downcast_ref::<LayoutUndoError>() {
        Some(LayoutUndoError::Unavailable) => Some(SessionCompletionAction::LayoutUndoUnavailable),
        Some(LayoutUndoError::Stale(_)) => Some(SessionCompletionAction::LayoutUndoStale),
        None => None,
    }
}

pub(super) struct PendingSessionMutationState {
    pub(super) events: SessionEventSender,
    pub(super) pending_mutations: Arc<AtomicUsize>,
    pub(super) pending_pointer_mutations: Arc<AtomicUsize>,
    pub(super) impact: MutationImpact,
    pub(super) semantic_intent: Option<u64>,
    pub(super) cancellation_pending: Arc<AtomicBool>,
    pub(super) settled: AtomicBool,
    pub(super) deferred_outcome: Mutex<Option<SessionMutationOutcome>>,
    pub(super) canceled_outcome: Mutex<Option<SessionMutationOutcome>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MutationImpact {
    Ordered,
    PointerMap,
    Destination,
}

impl MutationImpact {
    pub(super) fn blocks_pointer(self) -> bool {
        self != Self::Ordered
    }

    pub(super) fn creates_destination_intent(self) -> bool {
        self == Self::Destination
    }
}

#[derive(Clone)]
pub(super) struct PendingSessionMutation(pub(super) Arc<PendingSessionMutationState>);

impl PendingSessionMutation {
    pub(super) fn settle(self, outcome: SessionMutationOutcome) {
        if !self.0.settled.swap(true, Ordering::AcqRel) {
            let outcome = match self.0.semantic_intent {
                Some(intent) => {
                    SessionMutationOutcome::SemanticIntent { intent, outcome: Box::new(outcome) }
                }
                None => outcome,
            };
            let _ = self
                .0
                .events
                .send(AppEvent::SessionMutationSettled { outcome, impact: self.0.impact });
        }
    }

    pub(super) fn defer(&self, outcome: SessionMutationOutcome) {
        let mut deferred = self.0.deferred_outcome.lock().unwrap();
        debug_assert!(deferred.is_none(), "session mutation outcome deferred twice");
        *deferred = Some(outcome);
    }

    pub(super) fn cancel_with(&self, outcome: SessionMutationOutcome) {
        *self.0.canceled_outcome.lock().unwrap() = Some(outcome);
    }

    pub(super) fn publish_deferred(self) {
        let outcome = self.0.deferred_outcome.lock().unwrap().take();
        if let Some(outcome) = outcome {
            self.settle(outcome);
        }
    }

    pub(super) fn supersede(self) {
        if !self.0.settled.swap(true, Ordering::AcqRel) {
            let _ = self.0.pending_mutations.fetch_update(
                Ordering::AcqRel,
                Ordering::Acquire,
                |pending| pending.checked_sub(1),
            );
            if self.0.impact.blocks_pointer() {
                let _ = self.0.pending_pointer_mutations.fetch_update(
                    Ordering::AcqRel,
                    Ordering::Acquire,
                    |pending| pending.checked_sub(1),
                );
            }
        }
    }
}

impl Drop for PendingSessionMutationState {
    fn drop(&mut self) {
        if !self.settled.load(Ordering::Acquire) {
            let outcome = self
                .canceled_outcome
                .lock()
                .unwrap()
                .take()
                .unwrap_or(SessionMutationOutcome::Canceled);
            let outcome = match self.semantic_intent {
                Some(intent) => {
                    SessionMutationOutcome::SemanticIntent { intent, outcome: Box::new(outcome) }
                }
                None => outcome,
            };
            match self
                .events
                .try_send(AppEvent::SessionMutationSettled { outcome, impact: self.impact })
            {
                Ok(()) => {}
                Err(SessionTrySendError::Full | SessionTrySendError::Disconnected) => {
                    let _ = self.pending_mutations.fetch_update(
                        Ordering::AcqRel,
                        Ordering::Acquire,
                        |pending| pending.checked_sub(1),
                    );
                    if self.impact.blocks_pointer() {
                        let _ = self.pending_pointer_mutations.fetch_update(
                            Ordering::AcqRel,
                            Ordering::Acquire,
                            |pending| pending.checked_sub(1),
                        );
                    }
                    self.cancellation_pending.store(true, Ordering::Release);
                }
            }
        }
    }
}
