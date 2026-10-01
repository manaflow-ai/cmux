//! Sticky viewport columns (`sticky-columns-v1`).
//!
//! A screen with horizontal viewport columns may pin at most one column to
//! each viewport edge. The flag lives on the [`LayoutColumn`] record, so it
//! moves with the column, is part of the screen's durable viewport record,
//! and is restored by layout undo. Frontends render a sticky column at its
//! edge; the column order is unchanged, so clients without the capability
//! render it in place.
//!
//! Invariant: a screen with columns always keeps at least one scrolling
//! column. `set-column-sticky` refuses a change that would break it, and
//! [`crate::model::normalize_sticky_columns`] restores it after a removal.

use super::*;
use crate::model::{
    ColumnSticky, LayoutColumn, LayoutMutationKey, LayoutResizeOwner, StickyEdge, StickyMode,
    sticky_columns_are_consistent,
};

/// Internal journal operation name. It is not a public resource operation:
/// the command is reachable only through the JSON-lines `set-column-sticky`.
const COLUMN_STICKY_OPERATION: &str = "pane.column_sticky.set";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ColumnStickyError {
    /// The pane is unknown or its screen has no viewport columns.
    ColumnNotFound { pane: PaneId },
    /// The change would leave no scrolling column.
    LastScrollingColumn,
    /// An `edge` or `mode` value is not one of the documented strings.
    InvalidArgument { field: &'static str, value: String },
    /// The durable commit failed; details are reported as a status event.
    CommitFailed,
}

impl ColumnStickyError {
    pub const COLUMN_MISSING_CODE: &'static str = ViewportWidthError::COLUMN_MISSING_CODE;
    pub const LAST_SCROLLING_CODE: &'static str = "sticky-column-last-scrolling";
    pub const INVALID_ARGUMENT_CODE: &'static str = "invalid-argument";

    pub fn code(&self) -> Option<&'static str> {
        match self {
            Self::ColumnNotFound { .. } => Some(Self::COLUMN_MISSING_CODE),
            Self::LastScrollingColumn => Some(Self::LAST_SCROLLING_CODE),
            Self::InvalidArgument { .. } => Some(Self::INVALID_ARGUMENT_CODE),
            Self::CommitFailed => None,
        }
    }
}

impl fmt::Display for ColumnStickyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ColumnNotFound { pane } => {
                write!(formatter, "pane {pane} has no viewport column")
            }
            Self::LastScrollingColumn => formatter.write_str("at least one column must scroll"),
            Self::InvalidArgument { field: "edge", value } => {
                write!(formatter, "bad edge {value:?} (want \"left\" or \"right\")")
            }
            Self::InvalidArgument { field, value } => {
                write!(formatter, "bad {field} {value:?} (want \"docked\" or \"overlay\")")
            }
            Self::CommitFailed => formatter.write_str("could not persist the sticky column"),
        }
    }
}

impl std::error::Error for ColumnStickyError {}

/// Result of a `set-column-sticky` request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ColumnStickyOutcome {
    pub screen: ScreenId,
    /// The column's stable id (`Screen.columns[].id`).
    pub column: SplitId,
    /// The column's flag after the request.
    pub sticky: Option<ColumnSticky>,
    /// False when the request matched the current flags and committed nothing.
    pub changed: bool,
}

/// Parse the wire fields of `set-column-sticky`. `edge` defaults to right and
/// `mode` to docked. Values are validated even when `sticky` is false.
pub fn parse_column_sticky(
    sticky: bool,
    edge: Option<&str>,
    mode: Option<&str>,
) -> Result<Option<ColumnSticky>, ColumnStickyError> {
    let edge = edge
        .map(|value| {
            StickyEdge::parse(value).ok_or_else(|| ColumnStickyError::InvalidArgument {
                field: "edge",
                value: value.to_string(),
            })
        })
        .transpose()?
        .unwrap_or(StickyEdge::Right);
    let mode = mode
        .map(|value| {
            StickyMode::parse(value).ok_or_else(|| ColumnStickyError::InvalidArgument {
                field: "mode",
                value: value.to_string(),
            })
        })
        .transpose()?
        .unwrap_or(StickyMode::Docked);
    Ok(sticky.then_some(ColumnSticky { edge, mode }))
}

/// Set the flag of `columns[index]`. Setting an edge unsticks the column that
/// held it (replace). Fails without a usable result when no scrolling column
/// would remain; callers apply it to a copy.
fn apply_column_sticky(
    columns: &mut [LayoutColumn],
    index: usize,
    sticky: Option<ColumnSticky>,
) -> Result<(), ColumnStickyError> {
    if let Some(flag) = sticky {
        for (candidate, column) in columns.iter_mut().enumerate() {
            if candidate != index && column.sticky.is_some_and(|held| held.edge == flag.edge) {
                column.sticky = None;
            }
        }
    }
    columns[index].sticky = sticky;
    if columns.iter().all(|column| column.sticky.is_some()) {
        return Err(ColumnStickyError::LastScrollingColumn);
    }
    debug_assert!(sticky_columns_are_consistent(columns));
    Ok(())
}

fn sticky_column_location(
    state: &State,
    pane: PaneId,
) -> Result<(usize, usize, usize), ColumnStickyError> {
    let not_found = || ColumnStickyError::ColumnNotFound { pane };
    let (workspace, screen) = state.screen_of(pane).ok_or_else(not_found)?;
    let column = state.workspaces[workspace].screens[screen]
        .layout_columns
        .iter()
        .position(|column| column.root.contains(pane))
        .ok_or_else(not_found)?;
    Ok((workspace, screen, column))
}

impl Mux {
    /// `set-column-sticky`: pin the viewport column containing `pane` to an
    /// edge, or clear its flag with `None`. `transaction` is the requesting
    /// `(client, transaction)` pair; changes with the same pair coalesce into
    /// one layout-undo entry, like viewport resizes.
    pub fn set_column_sticky(
        self: &Arc<Self>,
        pane: PaneId,
        sticky: Option<ColumnSticky>,
        transaction: Option<(u64, u64)>,
    ) -> Result<ColumnStickyOutcome, ColumnStickyError> {
        let coalesce = transaction.map(|(client, transaction)| LayoutMutationKey::ColumnSticky {
            owner: LayoutResizeOwner::ControlClient(client),
            transaction,
        });
        let unchanged = self.with_state(|state| {
            let (workspace, screen, column) = sticky_column_location(state, pane)?;
            let screen = &state.workspaces[workspace].screens[screen];
            let mut columns = screen.layout_columns.clone();
            apply_column_sticky(&mut columns, column, sticky)?;
            let unchanged = columns
                .iter()
                .zip(&screen.layout_columns)
                .all(|(after, before)| after.sticky == before.sticky);
            let outcome = ColumnStickyOutcome {
                screen: screen.id,
                column: screen.layout_columns[column].id,
                sticky,
                changed: false,
            };
            Ok::<_, ColumnStickyError>(unchanged.then_some(outcome))
        })?;
        if let Some(outcome) = unchanged {
            return Ok(outcome);
        }

        let fingerprint = serde_json::json!({
            "operation": COLUMN_STICKY_OPERATION,
            "pane": pane,
            "sticky": sticky,
        });
        let mut committed = None;
        let commit = self
            .commit_resource_mutation_plan(
                &WorkspaceMutation::local("cmux-tui-column-sticky"),
                COLUMN_STICKY_OPERATION,
                &fingerprint,
                None,
                None,
                |state, registry| {
                    let (workspace, screen, column) = sticky_column_location(state, pane)?;
                    let mut projected = state.clone();
                    let target = &mut projected.workspaces[workspace].screens[screen];
                    let before = target.layout_snapshot_for_coalescing_change(coalesce);
                    apply_column_sticky(&mut target.layout_columns, column, sticky)?;
                    target.record_prepared_layout_change(before, Vec::new(), coalesce);
                    let outcome = ColumnStickyOutcome {
                        screen: target.id,
                        column: target.layout_columns[column].id,
                        sticky,
                        changed: true,
                    };
                    let pane_id = projected
                        .resource_indexes
                        .pane_ids
                        .get(&pane)
                        .cloned()
                        .context("sticky column pane has no public identity")?;
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
                if let Some(error) = error.downcast_ref::<ColumnStickyError>() {
                    return error.clone();
                }
                self.emit(MuxEvent::Status(format!("could not persist sticky column: {error:#}")));
                ColumnStickyError::CommitFailed
            })?;
        let outcome = committed.ok_or(ColumnStickyError::CommitFailed)?;
        if !commit.replayed {
            self.emit_screen_changed(&[outcome.screen]);
            self.emit(MuxEvent::LayoutChanged(outcome.screen));
        }
        Ok(outcome)
    }
}
