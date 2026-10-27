//! `move-column` (`column-move-v1`): a whole viewport column (every pane,
//! split and row inside it) trades places with its left or right neighbor in
//! one commit. Widths and docks travel with their columns; a docked column
//! never moves and is never crossed. Commits like `set-row-heights` and
//! records one layout-undo entry.

use super::*;
use crate::Actor;

/// Internal journal operation name, reachable only through the JSON-lines
/// `move-column`.
const COLUMN_MOVE_OPERATION: &str = "column.move";

/// Which neighbor a column trades places with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnMoveDirection {
    Left,
    Right,
}

impl ColumnMoveDirection {
    /// The wire value (`left` or `right`); anything else is an
    /// `invalid-argument` refusal.
    pub fn parse(value: &str) -> Result<Self, ColumnMoveError> {
        match value {
            "left" => Ok(Self::Left),
            "right" => Ok(Self::Right),
            _ => Err(ColumnMoveError::InvalidDirection { value: value.to_string() }),
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ColumnMoveError {
    /// No screen holds this pane.
    PaneNotFound { pane: PaneId },
    /// No scrolling column on that side: the strip's edge, a docked
    /// neighbor, or a screen that is one implicit column.
    AtEdge,
    /// The column is docked to a viewport edge.
    Docked,
    /// A direction other than `left` or `right`.
    InvalidDirection { value: String },
    /// The durable commit failed; details are reported as a status event.
    CommitFailed,
}

impl ColumnMoveError {
    pub const MISSING_CODE: &'static str = "column-move-missing";
    pub const EDGE_CODE: &'static str = "column-move-edge";
    pub const DOCKED_CODE: &'static str = "column-move-docked";
    pub const INVALID_ARGUMENT_CODE: &'static str = "invalid-argument";

    pub fn code(&self) -> Option<&'static str> {
        match self {
            Self::PaneNotFound { .. } => Some(Self::MISSING_CODE),
            Self::AtEdge => Some(Self::EDGE_CODE),
            Self::Docked => Some(Self::DOCKED_CODE),
            Self::InvalidDirection { .. } => Some(Self::INVALID_ARGUMENT_CODE),
            Self::CommitFailed => None,
        }
    }
}

impl fmt::Display for ColumnMoveError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PaneNotFound { pane } => write!(formatter, "unknown pane {pane}"),
            Self::AtEdge => formatter.write_str("no scrolling column on that side"),
            Self::Docked => formatter.write_str("a docked column does not move"),
            Self::InvalidDirection { value } => {
                write!(formatter, "direction must be left or right, not {value:?}")
            }
            Self::CommitFailed => formatter.write_str("could not persist the column move"),
        }
    }
}

impl std::error::Error for ColumnMoveError {}

/// Result of a `move-column` request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ColumnMoveOutcome {
    pub screen: ScreenId,
    pub column: SplitId,
    /// The column's index after the move.
    pub index: usize,
}

/// The workspace, screen, column index and target index of a move of the
/// column holding `pane`, or why it cannot move.
fn plan_column_move(
    state: &State,
    pane: PaneId,
    direction: ColumnMoveDirection,
) -> Result<(usize, usize, usize, usize), ColumnMoveError> {
    let (workspace, screen) =
        state.screen_of(pane).ok_or(ColumnMoveError::PaneNotFound { pane })?;
    let columns = &state
        .workspaces
        .get(workspace)
        .and_then(|workspace| workspace.screens.get(screen))
        .ok_or(ColumnMoveError::PaneNotFound { pane })?
        .layout_columns;
    // A screen stored as one split tree is one implicit column.
    let (index, column) = columns
        .iter()
        .enumerate()
        .find(|(_, column)| column.root.contains(pane))
        .ok_or(ColumnMoveError::AtEdge)?;
    if column.dock.is_some() {
        return Err(ColumnMoveError::Docked);
    }
    let target = match direction {
        ColumnMoveDirection::Left => index.checked_sub(1),
        ColumnMoveDirection::Right => Some(index + 1),
    }
    .filter(|target| columns.get(*target).is_some_and(|column| column.dock.is_none()))
    .ok_or(ColumnMoveError::AtEdge)?;
    Ok((workspace, screen, index, target))
}

impl Mux {
    /// `move-column`: the column holding `pane` trades places with its
    /// neighbor in `direction`. Focus, widths and every pane stay as they
    /// are; only the column order changes.
    #[track_caller]
    pub fn move_column_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        direction: ColumnMoveDirection,
    ) -> Result<ColumnMoveOutcome, ColumnMoveError> {
        self.with_state(|state| plan_column_move(state, pane, direction))?;
        let fingerprint = serde_json::json!({
            "operation": COLUMN_MOVE_OPERATION,
            "pane": pane,
            "direction": direction.as_str(),
        });
        let mut committed = None;
        let commit = self
            .commit_resource_mutation_plan(
                &WorkspaceMutation::local("cmux-tui-column-move", actor.clone()),
                COLUMN_MOVE_OPERATION,
                &fingerprint,
                None,
                None,
                |state, registry| {
                    let (workspace, screen, index, target_index) =
                        plan_column_move(state, pane, direction)?;
                    let mut projected = state.clone();
                    let target = projected
                        .workspaces
                        .get_mut(workspace)
                        .and_then(|workspace| workspace.screens.get_mut(screen))
                        .ok_or(ColumnMoveError::PaneNotFound { pane })?;
                    let before = target.layout_snapshot_for_coalescing_change(None);
                    target.layout_columns.swap(index, target_index);
                    target.sync_layout_column_projection();
                    target.record_prepared_layout_change(before, Vec::new(), None);
                    let column =
                        target.layout_columns.get(target_index).ok_or(ColumnMoveError::AtEdge)?.id;
                    let outcome =
                        ColumnMoveOutcome { screen: target.id, column, index: target_index };
                    let pane_id = projected
                        .resource_indexes
                        .pane_ids
                        .get(&pane)
                        .cloned()
                        .context("moved column pane has no public identity")?;
                    let projection = self.resource_effect_projection_locked(
                        registry,
                        &mut projected,
                        serde_json::json!({"pane": pane_id}),
                    )?;
                    committed = Some(outcome);
                    Ok(ResourceMutationPlan::new(
                        projection.patch,
                        projection.result,
                        projection.changes,
                        move |state| *state = projected,
                    ))
                },
            )
            .map_err(|error| {
                if let Some(error) = error.downcast_ref::<ColumnMoveError>() {
                    return error.clone();
                }
                self.emit(MuxEvent::Status(format!("could not persist column move: {error:#}")));
                ColumnMoveError::CommitFailed
            })?;
        let outcome = committed.ok_or(ColumnMoveError::CommitFailed)?;
        if !commit.replayed {
            self.emit_screen_changed_for_transaction(&[outcome.screen], None);
            self.emit_layout_changed(outcome.screen, None);
        }
        Ok(outcome)
    }
}
