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
//! Invariant: a screen keeps at least one tiled pane. `float-pane` refuses to
//! float the last one, and when the last tiled pane closes, the front
//! floating pane becomes tiled.

use cmux_layout_reducer::floating_panes::{
    FloatFrame, FloatMode, FloatRefusal, Floating, normalized, place,
};

use super::*;
use crate::model::{LayoutMutationKey, LayoutResizeOwner, Node, Screen};
use crate::resource::PanePublicId;

/// Internal journal operation name. It is not a public resource operation:
/// the command is reachable only through the JSON-lines `float-pane`.
const FLOAT_PANE_OPERATION: &str = "pane.float";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FloatPaneError {
    /// The pane is unknown.
    PaneNotFound { pane: PaneId },
    /// The pane is the only tiled pane of its screen.
    LastTiledPane,
    /// The pane is a member of a stack, or its column is docked or has rows.
    FixedPane,
    /// `mode` is not one of the documented strings, or a frame value is not a
    /// finite number.
    InvalidArgument { field: &'static str, value: String },
    /// The durable commit failed; details are reported as a status event.
    CommitFailed,
}

impl FloatPaneError {
    pub const PANE_MISSING_CODE: &'static str = "floating-pane-missing";
    pub const LAST_TILED_CODE: &'static str = "floating-pane-last-tiled";
    pub const FIXED_CODE: &'static str = "floating-pane-fixed";
    pub const INVALID_ARGUMENT_CODE: &'static str = "invalid-argument";

    pub fn code(&self) -> Option<&'static str> {
        match self {
            Self::PaneNotFound { .. } => Some(Self::PANE_MISSING_CODE),
            Self::LastTiledPane => Some(Self::LAST_TILED_CODE),
            Self::FixedPane => Some(Self::FIXED_CODE),
            Self::InvalidArgument { .. } => Some(Self::INVALID_ARGUMENT_CODE),
            Self::CommitFailed => None,
        }
    }
}

impl fmt::Display for FloatPaneError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PaneNotFound { pane } => write!(formatter, "no pane {pane}"),
            Self::LastTiledPane => {
                formatter.write_str("the last tiled pane of a screen cannot float")
            }
            Self::FixedPane => formatter.write_str(
                "a pane of a stack, of a docked column or of a column with rows cannot float",
            ),
            Self::InvalidArgument { field: "mode", value } => {
                write!(formatter, "bad mode {value:?} (want \"toggle\", \"on\" or \"off\")")
            }
            Self::InvalidArgument { field, value } => {
                write!(formatter, "bad {field} {value:?} (want four finite numbers: x, y, w, h)")
            }
            Self::CommitFailed => formatter.write_str("could not persist the floating pane"),
        }
    }
}

impl std::error::Error for FloatPaneError {}

/// Result of a `float-pane` request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FloatPaneOutcome {
    pub screen: ScreenId,
    /// The pane's frame after the request; `None` when the pane is tiled.
    pub frame: Option<FloatFrame>,
    /// False when the request matched the screen and committed nothing.
    pub changed: bool,
}

/// The durable form of a screen's floating panes: `list` as the rules read it
/// against the panes of `root`, with public pane ids.
pub(crate) fn registry_floating_panes(
    state: &State,
    root: &Node,
    list: &[Floating<PaneId>],
) -> anyhow::Result<Vec<Floating<PanePublicId>>> {
    if list.is_empty() {
        return Ok(Vec::new());
    }
    normalized(&root.pane_ids_vec(), list)
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
            let screen = &state.workspaces[workspace].screens[screen];
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
                    let target = &mut projected.workspaces[workspace].screens[screen];
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
