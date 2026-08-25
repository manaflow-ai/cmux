//! Operation-specific protocol-v2 mutation plans.
//!
//! Plan construction validates input, allocates every new value, and reserves
//! the exact in-memory capacities before SQLite commits. The post-commit step
//! is an infallible closure over only the touched state. Plans must never clone
//! or project the full mux tree.

use serde_json::Value;

use crate::State;
use crate::workspace_registry::{ResourcePatch, ResourcePatchCommit};

type StateApply = Box<dyn FnOnce(&mut State) + Send + 'static>;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct ResourceMutationMetrics {
    pub(crate) touched_resources: usize,
    pub(crate) order_entries: usize,
    pub(crate) terminal_queries: usize,
    pub(crate) changed_rows: usize,
}

pub(crate) struct ResourceMutationPlan {
    pub(crate) patch: ResourcePatch,
    pub(crate) result: Value,
    pub(crate) deltas: Value,
    pub(crate) metrics: ResourceMutationMetrics,
    apply: StateApply,
}

impl ResourceMutationPlan {
    pub(crate) fn new(
        patch: ResourcePatch,
        result: Value,
        deltas: Value,
        apply: impl FnOnce(&mut State) + Send + 'static,
    ) -> Self {
        Self {
            patch,
            result,
            deltas,
            metrics: ResourceMutationMetrics::default(),
            apply: Box::new(apply),
        }
    }

    pub(crate) fn with_metrics(mut self, metrics: ResourceMutationMetrics) -> Self {
        self.metrics = metrics;
        self
    }

    /// This call occurs only after the matching durable transaction commits.
    /// Plan builders reserve all needed capacities before returning.
    pub(crate) fn apply(self, state: &mut State, commit: &ResourcePatchCommit) {
        if commit.replayed {
            return;
        }
        (self.apply)(state);
        state.resource_revision = commit.revision;
    }
}
