//! Operation-specific protocol-v2 mutation plans.
//!
//! Plan construction validates input, allocates every new value, and reserves
//! the exact in-memory capacities before SQLite commits. The post-commit step
//! is an infallible closure over only the touched state. Plans must never clone
//! or project the full mux tree, with one exception: an operation that must
//! conserve tabs (see `mux::layout_invariants`) runs its state step before the
//! commit, under the same locks, keeping a clone of the previous state so the
//! layout checker can reject it and a failed commit can restore it. Plans that
//! already project a clone hand it over with [`ResourceMutationPlan::replacing`],
//! so staging them costs no second clone.

use serde_json::Value;

use crate::workspace_registry::{ResourcePatch, ResourcePatchCommit, ResourceWorkspaceLedger};
use crate::{PaneId, State, SurfaceId};

type StateApply = Box<dyn FnOnce(&mut State) + Send + 'static>;

/// How a plan changes the live state after its commit.
enum StateStep {
    /// Run this closure on the live state.
    Apply(StateApply),
    /// Replace the live state with this projected state.
    Replace(Box<State>),
    /// The step already ran before the commit (see
    /// [`ResourceMutationPlan::stage`]).
    Staged,
}

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
    pub(crate) workspace_ledger: Option<ResourceWorkspaceLedger>,
    /// Tab group state written in the same transaction as the patch.
    pub(crate) tab_groups: Option<crate::workspace_registry::TabGroupState>,
    /// Screen presentation and screen groups written in the same transaction.
    pub(crate) screen_state: Option<crate::workspace_registry::ScreenPresentationState>,
    /// The reducer op this plan performs, which the daemon checks the
    /// plan's result against before the commit.
    pub(crate) layout_op: Option<cmux_layout_reducer::LayoutOpKind>,
    state_step: StateStep,
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
            workspace_ledger: None,
            tab_groups: None,
            screen_state: None,
            layout_op: None,
            state_step: StateStep::Apply(Box::new(apply)),
        }
    }

    /// A plan whose post-commit step replaces the live state with
    /// `projected`, a clone the plan builder already mutated.
    pub(crate) fn replacing(
        patch: ResourcePatch,
        result: Value,
        deltas: Value,
        projected: State,
    ) -> Self {
        let mut plan = Self::new(patch, result, deltas, |_| {});
        plan.state_step = StateStep::Replace(Box::new(projected));
        plan
    }

    /// Run the state step on the live `state` now, before the commit, and
    /// return the state it replaced, which the caller restores if the change
    /// is rejected or the commit fails. A closure step costs one clone of the
    /// state; a projected state is swapped in without one. [`Self::apply`]
    /// then changes nothing but the revisions.
    pub(crate) fn stage(&mut self, state: &mut State) -> State {
        match std::mem::replace(&mut self.state_step, StateStep::Staged) {
            StateStep::Apply(apply) => {
                let before = state.clone();
                apply(state);
                before
            }
            StateStep::Replace(projected) => std::mem::replace(state, *projected),
            StateStep::Staged => {
                debug_assert!(false, "a plan's state step was staged twice");
                state.clone()
            }
        }
    }

    /// Declare the reducer op this plan performs.
    pub(crate) fn with_layout_op(mut self, op: cmux_layout_reducer::LayoutOpKind) -> Self {
        self.layout_op = Some(op);
        self
    }

    /// Declare that this plan moves `tab` to `index` of `pane`.
    pub(crate) fn moving_tab(self, tab: SurfaceId, pane: PaneId, index: usize) -> Self {
        self.with_layout_op(cmux_layout_reducer::LayoutOpKind::MoveTab { tab, pane, index })
    }

    /// [`Self::stage`] for `operation`, checked when it must conserve tabs:
    /// the layout reducer must accept the plan's op before the live state
    /// changes, and the live result must keep I1-I3 and match the reducer's
    /// placement, or the previous state is restored and the error returned.
    /// Returns the replaced state only for a checked operation.
    pub(crate) fn stage_checked(
        &mut self,
        state: &mut State,
        operation: &str,
    ) -> anyhow::Result<Option<State>> {
        use crate::mux::layout_invariants as layout;
        if !layout::conserves_tabs(operation) {
            return Ok(None);
        }
        let before_model = layout::project(state);
        let model = self
            .layout_op
            .as_ref()
            .map(|kind| layout::model_result(operation, &before_model, kind))
            .transpose()?;
        let before = self.stage(state);
        let result =
            layout::validate_layout_transition(operation, &before_model, model.as_ref(), state);
        if let Err(error) = result {
            *state = before;
            return Err(error);
        }
        Ok(Some(before))
    }

    /// Commit this tab group state with the patch.
    pub(crate) fn with_tab_groups(
        mut self,
        tab_groups: crate::workspace_registry::TabGroupState,
    ) -> Self {
        self.tab_groups = Some(tab_groups);
        self
    }

    /// Commit this screen presentation state with the patch.
    pub(crate) fn with_screen_state(
        mut self,
        screen_state: crate::workspace_registry::ScreenPresentationState,
    ) -> Self {
        self.screen_state = Some(screen_state);
        self
    }

    pub(crate) fn with_metrics(mut self, metrics: ResourceMutationMetrics) -> Self {
        self.metrics = metrics;
        self
    }

    /// Declare that this plan changes the workspace projection, so its commit
    /// must advance the legacy workspace ledger in the same transaction. The
    /// in-memory `state.workspace_revision` is then set to the committed
    /// ledger revision (never bumped independently), keeping the revision the
    /// daemon reports equal to the one the legacy CAS checks.
    pub(crate) fn with_workspace_ledger(mut self, ledger: ResourceWorkspaceLedger) -> Self {
        self.workspace_ledger = Some(ledger);
        self
    }

    /// This call occurs only after the matching durable transaction commits.
    /// Plan builders reserve all needed capacities before returning.
    pub(crate) fn apply(
        self,
        state: &mut State,
        commit: &ResourcePatchCommit,
        workspace_revision: Option<u64>,
    ) {
        if commit.replayed {
            return;
        }
        match self.state_step {
            StateStep::Apply(apply) => apply(state),
            StateStep::Replace(projected) => *state = *projected,
            StateStep::Staged => {}
        }
        if let Some(workspace_revision) = workspace_revision {
            state.workspace_revision = workspace_revision;
        }
        state.resource_revision = commit.revision;
    }
}
