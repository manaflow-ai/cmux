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
    sticky_columns_are_consistent, sticky_flags_are_consistent,
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
    /// The reducer was given a column index outside the screen.
    NoSuchColumn { index: usize },
    /// The durable commit failed; details are reported as a status event.
    CommitFailed,
}

impl ColumnStickyError {
    pub const COLUMN_MISSING_CODE: &'static str = ViewportWidthError::COLUMN_MISSING_CODE;
    pub const LAST_SCROLLING_CODE: &'static str = "sticky-column-last-scrolling";
    pub const INVALID_ARGUMENT_CODE: &'static str = "invalid-argument";

    pub fn code(&self) -> Option<&'static str> {
        match self {
            Self::ColumnNotFound { .. } | Self::NoSuchColumn { .. } => {
                Some(Self::COLUMN_MISSING_CODE)
            }
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
                write!(formatter, "bad edge {value:?} (want left, right, top or bottom)")
            }
            Self::InvalidArgument { field, value } => {
                write!(formatter, "bad {field} {value:?} (want \"docked\" or \"overlay\")")
            }
            Self::NoSuchColumn { index } => write!(formatter, "no viewport column {index}"),
            Self::CommitFailed => formatter.write_str("could not persist the sticky column"),
        }
    }
}

impl std::error::Error for ColumnStickyError {}

/// Result of a `set-column-sticky` request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ColumnStickyOutcome {
    pub screen: ScreenId,
    /// The column's stable id (`Screen.columns[].id`), 0 for the implicit
    /// column of a screen without `columns`.
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

/// The pure reducer of `set-column-sticky`: the screen's column flags in
/// order, plus the op (`index` gets `sticky`), give the flags after the op or
/// the reject. Setting an edge unsticks the column that held it (replace).
/// It reads and returns flags only, so pane membership, tabs, widths and
/// column order cannot change.
pub(crate) fn reduce_column_sticky(
    flags: &[Option<ColumnSticky>],
    index: usize,
    sticky: Option<ColumnSticky>,
) -> Result<Vec<Option<ColumnSticky>>, ColumnStickyError> {
    if index >= flags.len() {
        return Err(ColumnStickyError::NoSuchColumn { index });
    }
    let mut next = flags.to_vec();
    if let Some(flag) = sticky {
        for (candidate, held) in next.iter_mut().enumerate() {
            if candidate != index && held.is_some_and(|held| held.edge == flag.edge) {
                *held = None;
            }
        }
    }
    next[index] = sticky;
    if next.iter().all(Option::is_some) {
        return Err(ColumnStickyError::LastScrollingColumn);
    }
    debug_assert!(sticky_flags_are_consistent(&next));
    Ok(next)
}

/// Sets the flag of `columns[index]` through [`reduce_column_sticky`] and
/// writes the resulting flags back. On a reject the columns are unchanged.
/// Shared by `set-column-sticky` and the resource op `column.update`.
pub(crate) fn apply_column_sticky(
    columns: &mut [LayoutColumn],
    index: usize,
    sticky: Option<ColumnSticky>,
) -> Result<(), ColumnStickyError> {
    let flags = reduce_column_sticky(&column_flags(columns), index, sticky)?;
    write_column_flags(columns, flags);
    Ok(())
}

fn column_flags(columns: &[LayoutColumn]) -> Vec<Option<ColumnSticky>> {
    columns.iter().map(|column| column.sticky).collect()
}

fn write_column_flags(columns: &mut [LayoutColumn], flags: Vec<Option<ColumnSticky>>) {
    debug_assert_eq!(columns.len(), flags.len());
    for (column, flag) in columns.iter_mut().zip(flags) {
        column.sticky = flag;
    }
    debug_assert!(sticky_columns_are_consistent(columns));
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
            // A screen stored as one split tree is one implicit column: the
            // only column cannot be pinned, and unpinning it changes nothing.
            if let Some((workspace, screen)) = state.screen_of(pane) {
                let screen = &state.workspaces[workspace].screens[screen];
                if screen.layout_columns.is_empty() {
                    if sticky.is_some() {
                        return Err(ColumnStickyError::LastScrollingColumn);
                    }
                    let outcome = ColumnStickyOutcome {
                        screen: screen.id,
                        column: 0,
                        sticky,
                        changed: false,
                    };
                    return Ok(Some(outcome));
                }
            }
            let (workspace, screen, column) = sticky_column_location(state, pane)?;
            let screen = &state.workspaces[workspace].screens[screen];
            let flags = column_flags(&screen.layout_columns);
            let unchanged = reduce_column_sticky(&flags, column, sticky)? == flags;
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

    fn all_flags() -> Vec<Option<ColumnSticky>> {
        let mut flags = vec![None];
        for edge in StickyEdge::ALL {
            for mode in [StickyMode::Docked, StickyMode::Overlay] {
                flags.push(Some(ColumnSticky { edge, mode }));
            }
        }
        flags
    }

    /// Every flag assignment of `count` columns, consistent or not.
    fn assignments(count: usize) -> Vec<Vec<Option<ColumnSticky>>> {
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
    fn check_op(
        flags: &[Option<ColumnSticky>],
        index: usize,
        sticky: Option<ColumnSticky>,
    ) -> bool {
        let replaced = |candidate: usize| {
            candidate != index
                && sticky.zip(flags[candidate]).is_some_and(|(set, held)| set.edge == held.edge)
        };
        let scrolls_after = |candidate: usize| {
            if candidate == index {
                sticky.is_none()
            } else {
                flags[candidate].is_none() || replaced(candidate)
            }
        };
        let Ok(next) = reduce_column_sticky(flags, index, sticky) else {
            assert_eq!(
                reduce_column_sticky(flags, index, sticky),
                Err(ColumnStickyError::LastScrollingColumn)
            );
            assert!(!(0..flags.len()).any(scrolls_after), "{flags:?} {index} {sticky:?}");
            return false;
        };
        assert_eq!(next.len(), flags.len());
        assert!(sticky_flags_are_consistent(&next), "{flags:?} -> {next:?}");
        assert!(next.iter().any(Option::is_none), "one column must scroll");
        assert_eq!(next[index], sticky);
        for candidate in (0..flags.len()).filter(|candidate| *candidate != index) {
            let expected = if replaced(candidate) { None } else { flags[candidate] };
            assert_eq!(next[candidate], expected, "{flags:?} {index} {sticky:?}");
        }
        let replayed = reduce_column_sticky(&next, index, sticky).unwrap();
        assert_eq!(replayed, next, "replaying an op changes nothing");
        true
    }

    /// Exhaustive check of the reducer for screens of up to five columns:
    /// from every consistent state, every op either yields a consistent
    /// state that differs only where the op says, or is rejected exactly
    /// when no scrolling column would remain. Replaying an accepted op is a
    /// no-op.
    #[test]
    fn sticky_column_reducer_keeps_invariants_for_every_state_and_op() {
        let (mut accepted, mut rejected) = (0, 0);
        for count in 1..=5 {
            let states = assignments(count);
            for flags in states.iter().filter(|flags| sticky_flags_are_consistent(flags)) {
                for index in 0..count {
                    for sticky in all_flags() {
                        if check_op(flags, index, sticky) {
                            accepted += 1;
                        } else {
                            rejected += 1;
                        }
                    }
                }
            }
        }
        assert_eq!((accepted, rejected), (238111, 2216), "every state and op was checked");
    }

    #[test]
    fn sticky_column_reducer_rejects_an_index_outside_the_screen() {
        assert_eq!(
            reduce_column_sticky(&[None, None], 2, None),
            Err(ColumnStickyError::NoSuchColumn { index: 2 })
        );
    }

    #[test]
    fn sticky_column_normalization_restores_invariants_after_any_removal() {
        let column = |sticky| LayoutColumn {
            id: 1,
            width: 0.5,
            root: Node::Leaf(1),
            zellij_auto_layout: None,
            sticky,
        };
        for count in 0..=4 {
            for flags in assignments(count) {
                let mut columns = flags.iter().copied().map(column).collect::<Vec<_>>();
                crate::model::normalize_sticky_columns(&mut columns);
                assert!(sticky_columns_are_consistent(&columns), "{flags:?}");
                for (before, after) in flags.iter().zip(&columns) {
                    assert!(after.sticky.is_none() || after.sticky == *before);
                }
            }
        }
    }
}
