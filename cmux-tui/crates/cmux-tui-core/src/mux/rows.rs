//! Rows inside viewport columns (`rows-v1`, plans/cmux-next/rows.md):
//! `new-row` and `set-row-heights`. The model and its invariant owner are in
//! `model/layout_rows.rs`.
//!
//! `new-row` is the `pane.split` effect with a `row_height` field, so it
//! shares the terminal creation, journaling and recovery of every split.
//! `set-row-heights` validates through the layout reducer
//! (`LayoutOpKind::SetRowHeights`) on the model of the live state, then
//! commits like `set-column-dock` and records one layout-undo entry.

use super::*;
use crate::Actor;
use crate::model::{LayoutMutationKey, LayoutResizeOwner, ROW_HEIGHT_PERMILLE};
use cmux_layout_reducer::{LayoutOp, LayoutOpKind, Reject};

/// Internal journal operation name, reachable only through the JSON-lines
/// `set-row-heights`.
const ROW_HEIGHTS_OPERATION: &str = "column.row_heights.set";

/// `reason_code` of a layout document applied to a screen with rows.
pub(crate) const ROWS_LAYOUT_REPLACE_UNSUPPORTED: &str = "rows-layout-replace-unsupported";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RowsError {
    /// A row height outside 100..=1000 permille.
    HeightOutOfRange { height: u64 },
    /// No screen holds this column.
    ColumnNotFound { column: SplitId },
    /// The heights do not name exactly the column's rows.
    StaleRows { column: SplitId },
    /// `fit` heights that do not sum to 1000.
    FitSum { sum: u32 },
    /// The durable commit failed; details are reported as a status event.
    CommitFailed,
}

impl RowsError {
    pub const HEIGHT_OUT_OF_RANGE_CODE: &'static str = "row-height-out-of-range";
    pub const COLUMN_MISSING_CODE: &'static str = "row-column-missing";
    pub const STALE_ROWS_CODE: &'static str = "row-set-stale";
    pub const FIT_SUM_CODE: &'static str = "row-fit-sum";

    pub fn code(&self) -> Option<&'static str> {
        match self {
            Self::HeightOutOfRange { .. } => Some(Self::HEIGHT_OUT_OF_RANGE_CODE),
            Self::ColumnNotFound { .. } => Some(Self::COLUMN_MISSING_CODE),
            Self::StaleRows { .. } => Some(Self::STALE_ROWS_CODE),
            Self::FitSum { .. } => Some(Self::FIT_SUM_CODE),
            Self::CommitFailed => None,
        }
    }

    fn from_reject(reject: Reject, column: SplitId) -> Self {
        match reject {
            Reject::InvalidHeight(height) => Self::HeightOutOfRange { height: height.into() },
            Reject::FitSum(sum) => Self::FitSum { sum },
            Reject::UnknownColumn(_) => Self::ColumnNotFound { column },
            _ => Self::StaleRows { column },
        }
    }
}

impl fmt::Display for RowsError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::HeightOutOfRange { height } => {
                write!(formatter, "row height {height} must be between 100 and 1000 permille")
            }
            Self::ColumnNotFound { column } => write!(formatter, "unknown column {column}"),
            Self::StaleRows { column } => {
                write!(formatter, "the heights do not name exactly the rows of column {column}")
            }
            Self::FitSum { sum } => write!(formatter, "fitted heights sum to {sum}, not 1000"),
            Self::CommitFailed => formatter.write_str("could not persist the row heights"),
        }
    }
}

impl std::error::Error for RowsError {}

/// Result of a `set-row-heights` request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RowHeightsOutcome {
    pub screen: ScreenId,
    pub column: SplitId,
    /// False when the heights matched and nothing was committed.
    pub changed: bool,
}

fn checked_height(height: u64) -> Result<u16, RowsError> {
    u16::try_from(height)
        .ok()
        .filter(|height| ROW_HEIGHT_PERMILLE.contains(height))
        .ok_or(RowsError::HeightOutOfRange { height })
}

/// The `row_height` field of a `pane.split` effect.
pub(super) fn row_height_field(fields: &Map<String, Value>) -> anyhow::Result<Option<u16>> {
    fields
        .get("row_height")
        .map(|value| {
            let height = value.as_u64().context("row_height must be an integer")?;
            Ok(checked_height(height)?)
        })
        .transpose()
}

/// Validates `row_height` on a `pane.split` intent: a downward split only,
/// never combined with a ratio or a viewport width.
/// `workspace.layout.apply` replaces a screen's layout from a document that
/// has no rows yet, so a screen with rows refuses it and changes nothing
/// (plans/cmux-next/rows.md, decision 5).
pub(super) fn refuse_layout_replace(screen: &Screen) -> anyhow::Result<()> {
    if screen.layout_columns.iter().all(|column| column.rows.is_empty()) {
        return Ok(());
    }
    Err(ResourceError::operation_failed(
        "workspace.layout.apply",
        format!("{ROWS_LAYOUT_REPLACE_UNSUPPORTED}: layout documents do not carry rows yet"),
        serde_json::json!({"reason_code": ROWS_LAYOUT_REPLACE_UNSUPPORTED}),
    )
    .into())
}

pub(super) fn validate_row_height_field(
    fields: &Map<String, Value>,
    direction: &str,
) -> anyhow::Result<()> {
    if row_height_field(fields)?.is_some() {
        anyhow::ensure!(
            direction == "down"
                && !fields.contains_key("ratio")
                && !fields.contains_key("viewport_width"),
            "row_height requires direction down and no ratio or viewport_width"
        );
    }
    Ok(())
}

/// The screen and index of the column `column`.
fn column_location(state: &State, column: SplitId) -> Option<(usize, usize, usize)> {
    state.workspaces.iter().enumerate().find_map(|(workspace_index, workspace)| {
        workspace.screens.iter().enumerate().find_map(|(screen_index, screen)| {
            let index = screen.layout_columns.iter().position(|item| item.id == column)?;
            Some((workspace_index, screen_index, index))
        })
    })
}

impl Mux {
    /// `new-row`: one new terminal in a new pane, in a new row of `height`
    /// permille below the row of `target`. On a split screen the tree becomes
    /// the first row of one column. The screen's `screen-changed` delta after
    /// the commit echoes `transaction` (mutation-echo).
    pub fn new_row_with_options_as(
        self: &Arc<Self>,
        actor: &Actor,
        target: PaneId,
        height: u64,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
        transaction: Option<String>,
    ) -> anyhow::Result<Arc<Surface>> {
        let height = checked_height(height)?;
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let selectors = self
            .ordinary_pane_selectors(target)
            .with_context(|| format!("unknown pane {target}"))?;
        let mut fields = Map::from_iter([
            ("direction".into(), Value::String("down".into())),
            ("row_height".into(), Value::from(height)),
        ]);
        Self::insert_cell_size(&mut fields, size);
        Self::insert_spawn_options(&mut fields, spawn);
        let commit = self.commit_ordinary_topology_operation_by(
            actor,
            ResourceOperation::PaneSplit,
            selectors,
            fields,
        )?;
        self.emit_resource_topology_legacy_events(ResourceOperation::PaneSplit, &commit);
        let surface = self.ordinary_created_surface(&commit)?;
        let screen = self.with_state(|state| {
            let (workspace, screen) = state.screen_of(state.pane_of(surface.id)?)?;
            Some(state.workspaces[workspace].screens[screen].id)
        });
        if let Some(screen) = screen {
            self.emit_screen_changed_for_transaction(&[screen], transaction.map(Arc::from));
        }
        Ok(surface)
    }

    /// `set-row-heights`: every row height of one column at once. The row
    /// set must be exactly the column's rows; `fit` requires a sum of 1000.
    /// `transaction` coalesces undo entries like viewport resizes.
    pub fn set_row_heights(
        self: &Arc<Self>,
        column: SplitId,
        heights: &[(SplitId, u64)],
        fit: bool,
        transaction: Option<(u64, u64)>,
    ) -> Result<RowHeightsOutcome, RowsError> {
        let heights = heights
            .iter()
            .map(|(row, height)| Ok((*row, checked_height(*height)?)))
            .collect::<Result<Vec<_>, RowsError>>()?;
        let op = LayoutOp {
            key: String::new(),
            kind: LayoutOpKind::SetRowHeights { column, heights: heights.clone(), fit },
        };
        let unchanged = self.with_state(|state| {
            let (workspace, screen, index) =
                column_location(state, column).ok_or(RowsError::ColumnNotFound { column })?;
            cmux_layout_reducer::apply(&layout_invariants::project(state), &op)
                .map_err(|reject| RowsError::from_reject(reject, column))?;
            let screen = &state.workspaces[workspace].screens[screen];
            let rows = &screen.layout_columns[index].rows;
            let unchanged = rows.iter().all(|row| heights.contains(&(row.id, row.height)));
            Ok::<_, RowsError>(unchanged.then_some(screen.id))
        })?;
        if let Some(screen) = unchanged {
            return Ok(RowHeightsOutcome { screen, column, changed: false });
        }
        let coalesce = transaction.map(|(client, transaction)| LayoutMutationKey::Resize {
            owner: LayoutResizeOwner::ControlClient(client),
            transaction,
        });
        let fingerprint = serde_json::json!({
            "operation": ROW_HEIGHTS_OPERATION,
            "column": column,
            "heights": heights,
            "fit": fit,
        });
        let mut committed = None;
        let commit = self
            .commit_resource_mutation_plan(
                &WorkspaceMutation::daemon_local("cmux-tui-row-heights"),
                ROW_HEIGHTS_OPERATION,
                &fingerprint,
                None,
                None,
                |state, registry| {
                    let (workspace, screen, index) = column_location(state, column)
                        .ok_or(RowsError::ColumnNotFound { column })?;
                    let mut projected = state.clone();
                    let target = &mut projected.workspaces[workspace].screens[screen];
                    let before = target.layout_snapshot_for_coalescing_change(coalesce);
                    target.layout_columns[index].write_row_heights(&heights);
                    target.sync_layout_column_projection();
                    target.record_prepared_layout_change(before, Vec::new(), coalesce);
                    let outcome = RowHeightsOutcome { screen: target.id, column, changed: true };
                    let pane = target.layout_columns[index].root.first_visible_pane();
                    let pane_id = projected
                        .resource_indexes
                        .pane_ids
                        .get(&pane)
                        .cloned()
                        .context("row column pane has no public identity")?;
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
                if let Some(error) = error.downcast_ref::<RowsError>() {
                    return error.clone();
                }
                self.emit(MuxEvent::Status(format!("could not persist row heights: {error:#}")));
                RowsError::CommitFailed
            })?;
        let outcome = committed.ok_or(RowsError::CommitFailed)?;
        if !commit.replayed {
            let transaction =
                transaction.map(|(_, transaction)| Arc::from(transaction.to_string()));
            self.emit_screen_changed_for_transaction(&[outcome.screen], transaction);
            self.emit(MuxEvent::LayoutChanged(outcome.screen));
        }
        Ok(outcome)
    }
}
