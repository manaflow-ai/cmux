//! Docked viewport columns (`dock-columns-v1`).
//!
//! A screen with horizontal viewport columns may pin at most one column to
//! each viewport edge. The flag lives on the [`LayoutColumn`] record, so it
//! moves with the column, is part of the screen's durable viewport record,
//! and is restored by layout undo. Frontends render a docked column at its
//! edge; the column order is unchanged, so clients without the capability
//! render it in place.
//!
//! Invariant: a screen with columns always keeps at least one scrolling
//! column. `set-column-dock` refuses a change that would break it, and
//! `normalize_dock_columns` (model/layout_columns.rs) restores it after a removal.

use super::*;
use crate::model::{
    ColumnDock, DockEdge, DockMode, LayoutColumn, LayoutMutationKey, LayoutResizeOwner,
    dock_columns_are_consistent, dock_flags_are_consistent,
};

/// Internal journal operation name. It is not a public resource operation:
/// the command is reachable only through the JSON-lines `set-column-dock`.
const COLUMN_DOCK_OPERATION: &str = "pane.column_dock.set";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ColumnDockError {
    /// The pane is unknown or its screen has no viewport columns.
    ColumnNotFound { pane: PaneId },
    /// The change would leave no scrolling column.
    LastScrollingColumn,
    /// An `edge` or `mode` value is not one of the documented strings.
    InvalidArgument { field: &'static str, value: String },
    /// The reducer was given a column index outside the screen.
    NoSuchColumn { index: usize },
    /// The durable commit failed; details are reported as a status event.
    CommitFailed,
    /// `app-screens-v1`: the change would touch an app screen
    /// (`app-screen-fixed`).
    AppRule { code: &'static str, message: String },
}

impl ColumnDockError {
    pub const COLUMN_MISSING_CODE: &'static str = ViewportWidthError::COLUMN_MISSING_CODE;
    pub const LAST_SCROLLING_CODE: &'static str = "dock-column-last-scrolling";
    pub const INVALID_ARGUMENT_CODE: &'static str = "invalid-argument";

    pub fn code(&self) -> Option<&'static str> {
        match self {
            Self::ColumnNotFound { .. } | Self::NoSuchColumn { .. } => {
                Some(Self::COLUMN_MISSING_CODE)
            }
            Self::LastScrollingColumn => Some(Self::LAST_SCROLLING_CODE),
            Self::InvalidArgument { .. } => Some(Self::INVALID_ARGUMENT_CODE),
            Self::CommitFailed => None,
            Self::AppRule { code, .. } => Some(code),
        }
    }
}

impl fmt::Display for ColumnDockError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ColumnNotFound { pane } => {
                write!(formatter, "pane {pane} has no viewport column")
            }
            Self::LastScrollingColumn => formatter.write_str("at least one column must scroll"),
            Self::InvalidArgument { field: "sticky", .. } => {
                write!(formatter, "sticky was renamed to dock (dock-columns-v1)")
            }
            Self::InvalidArgument { field: "edge", value } => {
                write!(formatter, "bad edge {value:?} (want left, right, top or bottom)")
            }
            Self::InvalidArgument { field, value } => {
                write!(formatter, "bad {field} {value:?} (want \"docked\" or \"overlay\")")
            }
            Self::NoSuchColumn { index } => write!(formatter, "no viewport column {index}"),
            Self::CommitFailed => formatter.write_str("could not persist the dock column"),
            Self::AppRule { message, .. } => formatter.write_str(message),
        }
    }
}

impl std::error::Error for ColumnDockError {}

/// Result of a `set-column-dock` request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ColumnDockOutcome {
    pub screen: ScreenId,
    /// The column's stable id (`Screen.columns[].id`), 0 for the implicit
    /// column of a screen without `columns`.
    pub column: SplitId,
    /// The column's flag after the request.
    pub dock: Option<ColumnDock>,
    /// False when the request matched the current flags and committed nothing.
    pub changed: bool,
}

/// Parse the wire fields of `set-column-dock`. `edge` defaults to right and
/// `mode` to docked. Values are validated even when `dock` is false.
pub fn parse_column_dock(
    dock: bool,
    edge: Option<&str>,
    mode: Option<&str>,
) -> Result<Option<ColumnDock>, ColumnDockError> {
    let edge = edge
        .map(|value| {
            DockEdge::parse(value).ok_or_else(|| ColumnDockError::InvalidArgument {
                field: "edge",
                value: value.to_string(),
            })
        })
        .transpose()?
        .unwrap_or(DockEdge::Right);
    let mode = mode
        .map(|value| {
            DockMode::parse(value).ok_or_else(|| ColumnDockError::InvalidArgument {
                field: "mode",
                value: value.to_string(),
            })
        })
        .transpose()?
        .unwrap_or(DockMode::Docked);
    Ok(dock.then_some(ColumnDock { edge, mode }))
}

/// The pure reducer of `set-column-dock`: the screen's column flags in
/// order, plus the op (`index` gets `dock`), give the flags after the op or
/// the reject. Setting an edge undocks the column that held it (replace).
/// It reads and returns flags only, so pane membership, tabs, widths and
/// column order cannot change.
pub(crate) fn reduce_column_dock(
    flags: &[Option<ColumnDock>],
    index: usize,
    dock: Option<ColumnDock>,
) -> Result<Vec<Option<ColumnDock>>, ColumnDockError> {
    if index >= flags.len() {
        return Err(ColumnDockError::NoSuchColumn { index });
    }
    let mut next = flags.to_vec();
    if let Some(flag) = dock {
        for (candidate, held) in next.iter_mut().enumerate() {
            if candidate != index && held.is_some_and(|held| held.edge == flag.edge) {
                *held = None;
            }
        }
    }
    next[index] = dock;
    if next.iter().all(Option::is_some) {
        return Err(ColumnDockError::LastScrollingColumn);
    }
    debug_assert!(dock_flags_are_consistent(&next));
    Ok(next)
}

/// Sets the flag of `columns[index]` through [`reduce_column_dock`] and
/// writes the resulting flags back. On a reject the columns are unchanged.
/// Shared by `set-column-dock` and the resource op `column.update`.
pub(crate) fn apply_column_dock(
    columns: &mut [LayoutColumn],
    index: usize,
    dock: Option<ColumnDock>,
) -> Result<(), ColumnDockError> {
    let flags = reduce_column_dock(&column_flags(columns), index, dock)?;
    write_column_flags(columns, flags);
    Ok(())
}

fn column_flags(columns: &[LayoutColumn]) -> Vec<Option<ColumnDock>> {
    columns.iter().map(|column| column.dock).collect()
}

fn write_column_flags(columns: &mut [LayoutColumn], flags: Vec<Option<ColumnDock>>) {
    debug_assert_eq!(columns.len(), flags.len());
    for (column, flag) in columns.iter_mut().zip(flags) {
        column.dock = flag;
    }
    debug_assert!(dock_columns_are_consistent(columns));
}

fn dock_column_location(
    state: &State,
    pane: PaneId,
) -> Result<(usize, usize, usize), ColumnDockError> {
    let not_found = || ColumnDockError::ColumnNotFound { pane };
    let (workspace, screen) = state.screen_of(pane).ok_or_else(not_found)?;
    let column = state.workspaces[workspace].screens[screen]
        .layout_columns
        .iter()
        .position(|column| column.root.contains(pane))
        .ok_or_else(not_found)?;
    Ok((workspace, screen, column))
}

/// The app rules of a dock change of `pane`'s column (`app-screens-v1`).
fn refuse_app_column(state: &State, pane: PaneId) -> Result<(), ColumnDockError> {
    let place = app_rules::AppPlace::Pane(pane);
    app_rules::refuse(state, place, cmux_layout_reducer::AppAction::Dock).map_err(|error| {
        ColumnDockError::AppRule {
            code: crate::state::app_screens_store::raw_error_code(&error).unwrap_or_default(),
            message: error.to_string(),
        }
    })
}

impl Mux {
    /// `set-column-dock`: pin the viewport column containing `pane` to an
    /// edge, or clear its flag with `None`. `transaction` is the requesting
    /// `(client, transaction)` pair; changes with the same pair coalesce into
    /// one layout-undo entry, like viewport resizes.
    pub fn set_column_dock(
        self: &Arc<Self>,
        pane: PaneId,
        dock: Option<ColumnDock>,
        transaction: Option<(u64, u64)>,
    ) -> Result<ColumnDockOutcome, ColumnDockError> {
        let coalesce = transaction.map(|(client, transaction)| LayoutMutationKey::ColumnDock {
            owner: LayoutResizeOwner::ControlClient(client),
            transaction,
        });
        let unchanged = self.with_state(|state| {
            refuse_app_column(state, pane)?;
            // A screen stored as one split tree is one implicit column: the
            // only column cannot be pinned, and unpinning it changes nothing.
            if let Some((workspace, screen)) = state.screen_of(pane) {
                let screen = &state.workspaces[workspace].screens[screen];
                if screen.layout_columns.is_empty() {
                    if dock.is_some() {
                        return Err(ColumnDockError::LastScrollingColumn);
                    }
                    let outcome =
                        ColumnDockOutcome { screen: screen.id, column: 0, dock, changed: false };
                    return Ok(Some(outcome));
                }
            }
            let (workspace, screen, column) = dock_column_location(state, pane)?;
            let screen = &state.workspaces[workspace].screens[screen];
            let flags = column_flags(&screen.layout_columns);
            let unchanged = reduce_column_dock(&flags, column, dock)? == flags;
            let outcome = ColumnDockOutcome {
                screen: screen.id,
                column: screen.layout_columns[column].id,
                dock,
                changed: false,
            };
            Ok::<_, ColumnDockError>(unchanged.then_some(outcome))
        })?;
        if let Some(outcome) = unchanged {
            return Ok(outcome);
        }

        let fingerprint = serde_json::json!({
            "operation": COLUMN_DOCK_OPERATION,
            "pane": pane,
            "dock": dock,
        });
        let mut committed = None;
        let commit = self
            .commit_resource_mutation_plan(
                &WorkspaceMutation::local("cmux-tui-column-dock"),
                COLUMN_DOCK_OPERATION,
                &fingerprint,
                None,
                None,
                |state, registry| {
                    let (workspace, screen, column) = dock_column_location(state, pane)?;
                    let mut projected = state.clone();
                    let target = &mut projected.workspaces[workspace].screens[screen];
                    let before = target.layout_snapshot_for_coalescing_change(coalesce);
                    apply_column_dock(&mut target.layout_columns, column, dock)?;
                    target.record_prepared_layout_change(before, Vec::new(), coalesce);
                    let outcome = ColumnDockOutcome {
                        screen: target.id,
                        column: target.layout_columns[column].id,
                        dock,
                        changed: true,
                    };
                    let pane_id = projected
                        .resource_indexes
                        .pane_ids
                        .get(&pane)
                        .cloned()
                        .context("dock column pane has no public identity")?;
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
                if let Some(error) = error.downcast_ref::<ColumnDockError>() {
                    return error.clone();
                }
                self.emit(MuxEvent::Status(format!("could not persist dock column: {error:#}")));
                ColumnDockError::CommitFailed
            })?;
        let outcome = committed.ok_or(ColumnDockError::CommitFailed)?;
        if !commit.replayed {
            // `TreeDelta.transaction` is a string; the numeric request
            // transaction travels as its decimal form.
            let transaction =
                transaction.map(|(_, transaction)| Arc::from(transaction.to_string()));
            self.emit_screen_changed_for_transaction(&[outcome.screen], transaction);
            self.emit(MuxEvent::LayoutChanged(outcome.screen));
        }
        Ok(outcome)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_flags() -> Vec<Option<ColumnDock>> {
        let mut flags = vec![None];
        for edge in DockEdge::ALL {
            for mode in [DockMode::Docked, DockMode::Overlay] {
                flags.push(Some(ColumnDock { edge, mode }));
            }
        }
        flags
    }

    /// Every flag assignment of `count` columns, consistent or not.
    fn assignments(count: usize) -> Vec<Vec<Option<ColumnDock>>> {
        (0..count).fold(vec![Vec::new()], |prefixes, _| {
            prefixes
                .into_iter()
                .flat_map(|prefix| {
                    all_flags().into_iter().map(move |flag| {
                        let mut next = prefix.clone();
                        next.push(flag);
                        next
                    })
                })
                .collect()
        })
    }

    /// Checks one op from one consistent state; returns whether it was
    /// accepted.
    fn check_op(flags: &[Option<ColumnDock>], index: usize, dock: Option<ColumnDock>) -> bool {
        let replaced = |candidate: usize| {
            candidate != index
                && dock.zip(flags[candidate]).is_some_and(|(set, held)| set.edge == held.edge)
        };
        let scrolls_after = |candidate: usize| {
            if candidate == index {
                dock.is_none()
            } else {
                flags[candidate].is_none() || replaced(candidate)
            }
        };
        let Ok(next) = reduce_column_dock(flags, index, dock) else {
            assert_eq!(
                reduce_column_dock(flags, index, dock),
                Err(ColumnDockError::LastScrollingColumn)
            );
            assert!(!(0..flags.len()).any(scrolls_after), "{flags:?} {index} {dock:?}");
            return false;
        };
        assert_eq!(next.len(), flags.len());
        assert!(dock_flags_are_consistent(&next), "{flags:?} -> {next:?}");
        assert!(next.iter().any(Option::is_none), "one column must scroll");
        assert_eq!(next[index], dock);
        for candidate in (0..flags.len()).filter(|candidate| *candidate != index) {
            let expected = if replaced(candidate) { None } else { flags[candidate] };
            assert_eq!(next[candidate], expected, "{flags:?} {index} {dock:?}");
        }
        let replayed = reduce_column_dock(&next, index, dock).unwrap();
        assert_eq!(replayed, next, "replaying an op changes nothing");
        true
    }

    /// Exhaustive check of the reducer for screens of up to five columns:
    /// from every consistent state, every op either yields a consistent
    /// state that differs only where the op says, or is rejected exactly
    /// when no scrolling column would remain. Replaying an accepted op is a
    /// no-op.
    #[test]
    fn dock_column_reducer_keeps_invariants_for_every_state_and_op() {
        let (mut accepted, mut rejected) = (0, 0);
        for count in 1..=5 {
            let states = assignments(count);
            for flags in states.iter().filter(|flags| dock_flags_are_consistent(flags)) {
                for index in 0..count {
                    for dock in all_flags() {
                        if check_op(flags, index, dock) {
                            accepted += 1;
                        } else {
                            rejected += 1;
                        }
                    }
                }
            }
        }
        // Derived by counting, independently of the reducer (4 edges x 2
        // modes = 8 flags, 9 ops per column). Rejected = the target column is
        // the only scrolling one and the other n-1 hold distinct edges other
        // than the new one: sum 8*n*P(3,n-1)*2^(n-1) = 8+96+576+1536+0 = 2216.
        // Consistent states with n columns: 1 + sum_k C(n,k)*P(4,k)*2^k for
        // 1 <= k < n = 1, 17, 169, 1089, 4361; ops = sum states*n*9 = 240327;
        // accepted = 240327 - 2216 = 238111.
        assert_eq!((accepted, rejected), (238111, 2216), "every state and op was checked");
    }

    #[test]
    fn dock_column_reducer_rejects_an_index_outside_the_screen() {
        assert_eq!(
            reduce_column_dock(&[None, None], 2, None),
            Err(ColumnDockError::NoSuchColumn { index: 2 })
        );
    }

    #[test]
    fn dock_column_normalization_restores_invariants_after_any_removal() {
        let column = |dock| LayoutColumn { dock, ..LayoutColumn::new(1, 0.5, Node::Leaf(1), None) };
        for count in 0..=4 {
            for flags in assignments(count) {
                let mut columns = flags.iter().copied().map(column).collect::<Vec<_>>();
                crate::model::normalize_dock_columns(&mut columns);
                assert!(dock_columns_are_consistent(&columns), "{flags:?}");
                for (before, after) in flags.iter().zip(&columns) {
                    assert!(after.dock.is_none() || after.dock == *before);
                }
            }
        }
    }
}
