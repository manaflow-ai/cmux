//! Floating panes (`floating-panes-v1`): the `float-pane` request.
//!
//! A floating pane is a leaf of its screen's split tree that the tiled layout
//! leaves out; the screen lists its floating panes back to front, each with a
//! frame (model/floating_panes.rs). `float-pane` floats a pane, puts it back
//! or moves it. The list is part of the screen's durable record
//! (`resource_floating_panes`) and of its layout snapshot, so it is restored
//! by a restart and by layout undo. A client without the capability shows the
//! pane tiled at its leaf.
//!
//! Until the layout projection reads this list, a floating pane keeps its
//! tiled rectangle and each client shows it tiled.
//!
//! Invariant: a screen keeps at least one tiled pane. `float-pane` refuses to
//! float the last one, and when the last tiled pane closes, the front
//! floating pane becomes tiled.

use cmux_layout_reducer::floating_panes::{
    FloatFrame, FloatMode, FloatRefusal, Floating, normalized, place,
};

use super::*;
use crate::model::{LayoutColumn, LayoutMutationKey, LayoutResizeOwner, Node, Screen};
use crate::resource::PanePublicId;

/// Internal journal operation name. It is not a public resource operation:
/// the command is reachable only through the JSON-lines `float-pane`.
const FLOAT_PANE_OPERATION: &str = "pane.float";

/// The durable form of a screen's floating panes: `list` as the screen keeps
/// it against the layout of `root` and `columns`
/// ([`Screen::settled_floating_panes`]), with public pane ids. So the store
/// never has an entry that the live screen does not keep.
pub(crate) fn registry_floating_panes(
    state: &State,
    root: &Node,
    columns: &[LayoutColumn],
    list: &[Floating<PaneId>],
) -> anyhow::Result<Vec<Floating<PanePublicId>>> {
    Screen::settled_floating_panes(root, columns, list)
        .into_iter()
        .map(|entry| {
            let pane =
                state.resource_indexes.pane_ids.get(&entry.pane).cloned().with_context(|| {
                    format!("floating pane {} has no public identity", entry.pane)
                })?;
            Ok(Floating { pane, frame: entry.frame })
        })
        .collect()
}

/// Gives `pane` the focus of the stored `screen`, as [`Screen::set_active_pane`]
/// does it for the live screen: a floating pane that gets the focus comes to
/// the front. A plan that writes the focus into the stored record of a screen
/// calls this, so the store has the list of the live screen.
pub(crate) fn focus_registry_pane(screen: &mut RegistryScreen, pane: &PanePublicId) {
    screen.active_pane = pane.clone();
    if let Some(index) = screen.floating.iter().position(|entry| entry.pane == *pane) {
        let entry = screen.floating.remove(index);
        screen.floating.push(entry);
    }
}

/// The list `screen` has after the request, and the pane's frame in it.
fn planned_floating_panes(
    screen: &Screen,
    pane: PaneId,
    mode: FloatMode,
    frame: Option<FloatFrame>,
) -> Result<(Vec<Floating<PaneId>>, Option<FloatFrame>), FloatPaneError> {
    let panes = screen.root.pane_ids_vec();
    let current = normalized(&panes, &screen.floating);
    let floats = current.iter().any(|entry| entry.pane == pane);
    if !floats && mode != FloatMode::Off && panes.contains(&pane) && screen.pane_never_floats(pane)
    {
        return Err(FloatPaneError::FixedPane);
    }
    let next = place(&panes, &current, &pane, mode, frame).map_err(|refusal| match refusal {
        FloatRefusal::UnknownPane => FloatPaneError::PaneNotFound { pane },
        FloatRefusal::LastTiledPane => FloatPaneError::LastTiledPane,
    })?;
    let frame = next.iter().find(|entry| entry.pane == pane).map(|entry| entry.frame);
    Ok((next, frame))
}

impl Mux {
    /// `float-pane`: float `pane` above the tiled layout of its screen, put it
    /// back, or give a floating pane a frame (a move or a resize, which also
    /// brings it to the front). `transaction` is the requesting
    /// `(client, transaction)` pair; changes with the same pair coalesce into
    /// one layout-undo entry, like viewport resizes, so one drag is one undo.
    pub fn float_pane_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        mode: FloatMode,
        frame: Option<FloatFrame>,
        transaction: Option<(u64, u64)>,
    ) -> Result<FloatPaneOutcome, FloatPaneError> {
        let coalesce = transaction.map(|(client, transaction)| LayoutMutationKey::FloatingPane {
            owner: LayoutResizeOwner::ControlClient(client),
            transaction,
        });
        let unchanged = self.with_state(|state| {
            let (workspace, screen) =
                state.screen_of(pane).ok_or(FloatPaneError::PaneNotFound { pane })?;
            let screen = state
                .workspaces
                .get(workspace)
                .and_then(|item| item.screens.get(screen))
                .ok_or(FloatPaneError::PaneNotFound { pane })?;
            let (next, frame) = planned_floating_panes(screen, pane, mode, frame)?;
            let outcome = FloatPaneOutcome { screen: screen.id, frame, changed: false };
            Ok::<_, FloatPaneError>((next == screen.floating).then_some(outcome))
        })?;
        if let Some(outcome) = unchanged {
            return Ok(outcome);
        }

        let fingerprint = serde_json::json!({
            "operation": FLOAT_PANE_OPERATION,
            "pane": pane,
            "mode": mode.as_str(),
            "frame": frame.map(|frame| [frame.x, frame.y, frame.w, frame.h]),
        });
        let mut committed = None;
        let commit = self
            .commit_resource_mutation_plan(
                &WorkspaceMutation::local("cmux-tui-float-pane", actor.clone()),
                FLOAT_PANE_OPERATION,
                &fingerprint,
                None,
                None,
                |state, registry| {
                    let (workspace, screen) =
                        state.screen_of(pane).ok_or(FloatPaneError::PaneNotFound { pane })?;
                    let mut projected = state.clone();
                    let target = projected
                        .workspaces
                        .get_mut(workspace)
                        .and_then(|item| item.screens.get_mut(screen))
                        .ok_or(FloatPaneError::PaneNotFound { pane })?;
                    let (_, placed) = planned_floating_panes(target, pane, mode, frame)?;
                    let before = target.layout_snapshot_for_coalescing_change(coalesce);
                    target.place_floating_pane(pane, mode, frame).map_err(
                        |refusal| match refusal {
                            FloatRefusal::UnknownPane => FloatPaneError::PaneNotFound { pane },
                            FloatRefusal::LastTiledPane => FloatPaneError::LastTiledPane,
                        },
                    )?;
                    target.record_prepared_layout_change(before, Vec::new(), coalesce);
                    let outcome =
                        FloatPaneOutcome { screen: target.id, frame: placed, changed: true };
                    let pane_id = projected
                        .resource_indexes
                        .pane_ids
                        .get(&pane)
                        .cloned()
                        .context("floating pane has no public identity")?;
                    let projection = self.changed_state_projection_locked(
                        registry,
                        state,
                        &mut projected,
                        serde_json::json!({"pane": pane_id}),
                    )?;
                    committed = Some(outcome);
                    Ok(ResourceMutationPlan::new(
                        projection.patch,
                        projection.result,
                        projection.changes,
                        move |state| *state = projected,
                    )
                    .projected(projection.restates_all)
                    .restating(projection.restated))
                },
            )
            .map_err(|error| {
                if let Some(error) = error.downcast_ref::<FloatPaneError>() {
                    return error.clone();
                }
                self.emit(MuxEvent::Status(format!("could not persist floating pane: {error:#}")));
                FloatPaneError::CommitFailed
            })?;
        let outcome = committed.ok_or(FloatPaneError::CommitFailed)?;
        if !commit.replayed {
            // `TreeDelta.transaction` is a string; the numeric request
            // transaction travels as its decimal form.
            let transaction =
                transaction.map(|(_, transaction)| Arc::from(transaction.to_string()));
            self.emit_screen_changed_for_transaction(&[outcome.screen], transaction.clone());
            self.emit_layout_changed(outcome.screen, transaction);
        }
        Ok(outcome)
    }
}
