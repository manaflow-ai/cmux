//! Rows inside a column (plans/cmux-next/rows.md, plans/cmux-next/layout-model.md).
//!
//! A column's panes stay one ordered list, [`Column::panes`]. [`Column::rows`]
//! partitions that list into consecutive runs, top to bottom: row `i` holds
//! the next `rows[i].len` panes. An empty `rows` is one implicit full-height
//! row, which is every column without rows. The partition is valid when it
//! is empty or has at least two rows, every row holds a pane, the lengths add
//! up to the pane count and every height is in [`ROW_HEIGHT_PERMILLE`]
//! ([`row_layout_is_valid`], checked by `check_state` as R1/R2/R4).
//!
//! Heights are not required to sum to 1000: at or below 1000 the rows fill
//! the column, above it the column scrolls (client rendering). Only
//! `SetRowHeights { fit: true }` writes exactly 1000.

use std::ops::Range;

use crate::{
    Column, ColumnId, LayoutEvent, LayoutOpKind, LayoutState, NewTab, PaneId, Reject, TabId,
};

pub type RowId = u64;

/// Shortest and tallest row, in thousandths of the column's viewport height.
pub const ROW_HEIGHT_PERMILLE: std::ops::RangeInclusive<u16> = 100..=1000;

/// One row of a column: `len` consecutive panes of [`Column::panes`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub id: RowId,
    pub height_permille: u16,
    pub len: usize,
}

impl Column {
    /// A column of one implicit row.
    pub fn single(id: ColumnId, panes: Vec<PaneId>) -> Self {
        Self { id, panes, rows: Vec::new() }
    }

    /// The index of the row holding pane position `position` (0 for the
    /// implicit row).
    pub(crate) fn row_index(&self, position: usize) -> usize {
        let mut start = 0;
        for (index, row) in self.rows.iter().enumerate() {
            if position < start + row.len {
                return index;
            }
            start += row.len;
        }
        0
    }

    /// The pane positions of row `index`.
    pub(crate) fn row_range(&self, index: usize) -> Range<usize> {
        if self.rows.is_empty() {
            return 0..self.panes.len();
        }
        let start = self.rows[..index].iter().map(|row| row.len).sum();
        start..start + self.rows[index].len
    }

    /// A pane was inserted into the row of pane position `anchor`.
    pub(crate) fn note_inserted(&mut self, anchor: usize) {
        if !self.rows.is_empty() {
            let index = self.row_index(anchor);
            self.rows[index].len += 1;
        }
    }

    /// The pane at `position` is about to be removed. An emptied row is
    /// removed, and a column left with one row goes back to the implicit row
    /// (a partition never has exactly one row). Removed row ids are pushed as
    /// events.
    pub(crate) fn note_removed(&mut self, position: usize, events: &mut Vec<LayoutEvent>) {
        if self.rows.is_empty() {
            return;
        }
        let index = self.row_index(position);
        self.rows[index].len -= 1;
        if self.rows[index].len == 0 {
            let row = self.rows.remove(index);
            events.push(LayoutEvent::RowRemoved { row: row.id });
        }
        if self.rows.len() == 1 {
            let row = self.rows.remove(0);
            events.push(LayoutEvent::RowRemoved { row: row.id });
        }
    }
}

/// R1/R2/R4 on one column's partition.
pub fn row_layout_is_valid(column: &Column) -> bool {
    column.rows.is_empty()
        || (column.rows.len() >= 2
            && column
                .rows
                .iter()
                .all(|row| row.len > 0 && ROW_HEIGHT_PERMILLE.contains(&row.height_permille))
            && column.rows.iter().map(|row| row.len).sum::<usize>() == column.panes.len())
}

/// Where a pane sits: indexes of workspace, screen, column and position.
#[derive(Debug, Clone, Copy)]
pub(crate) struct At {
    pub workspace: usize,
    pub screen: usize,
    pub column: usize,
    pub position: usize,
}

impl LayoutState {
    pub(crate) fn locate(&self, pane: PaneId) -> Result<At, Reject> {
        if !self.panes.contains_key(&pane) {
            return Err(Reject::UnknownPane(pane));
        }
        for (workspace, w) in self.workspaces.iter().enumerate() {
            for (screen, s) in w.screens.iter().enumerate() {
                for (column, c) in s.columns.iter().enumerate() {
                    if let Some(position) = c.panes.iter().position(|id| *id == pane) {
                        return Ok(At { workspace, screen, column, position });
                    }
                }
            }
        }
        Err(Reject::UnknownPane(pane))
    }

    fn column_mut(&mut self, at: At) -> &mut Column {
        &mut self.workspaces[at.workspace].screens[at.screen].columns[at.column]
    }

    /// Turns a split screen into columns mode (its tree becomes
    /// `base_column`) and an implicit row into an explicit one (`base_row`),
    /// so a new row can sit next to it.
    fn open_rows(
        &mut self,
        at: At,
        base_column: ColumnId,
        base_row: RowId,
        events: &mut Vec<LayoutEvent>,
    ) {
        let screen = &mut self.workspaces[at.workspace].screens[at.screen];
        if !screen.columns_active {
            screen.columns_active = true;
            screen.columns[0].id = base_column;
            events.push(LayoutEvent::ColumnCreated { column: base_column, screen: screen.id });
        }
        let column = self.column_mut(at);
        if column.rows.is_empty() {
            column.rows.push(Row { id: base_row, height_permille: 1000, len: column.panes.len() });
        }
    }

    /// Ids a row op would create, given whether the screen still needs a
    /// base column and the column a base row.
    fn row_op_ids(
        &self,
        at: At,
        mut ids: Vec<u64>,
        base_column: ColumnId,
        base_row: RowId,
    ) -> Vec<u64> {
        let screen = &self.workspaces[at.workspace].screens[at.screen];
        if !screen.columns_active {
            ids.push(base_column);
        }
        if screen.columns[at.column].rows.is_empty() {
            ids.push(base_row);
        }
        ids
    }

    /// Inserts row `new_row` holding the empty pane `new_pane` at row index
    /// `slot` of the column at `at` (after `open_rows`). Returns the column id.
    fn insert_row(
        &mut self,
        at: At,
        slot: usize,
        new_row: RowId,
        height: u16,
        new_pane: PaneId,
        events: &mut Vec<LayoutEvent>,
    ) {
        let column = self.column_mut(at);
        let position = if slot == column.rows.len() {
            column.panes.len()
        } else {
            column.row_range(slot).start
        };
        column.panes.insert(position, new_pane);
        column.rows.insert(slot, Row { id: new_row, height_permille: height, len: 1 });
        let column_id = column.id;
        let screen_id = self.workspaces[at.workspace].screens[at.screen].id;
        self.panes.insert(new_pane, Vec::new());
        events.push(LayoutEvent::RowCreated { row: new_row, column: column_id, index: slot });
        events.push(LayoutEvent::PaneCreated { pane: new_pane, screen: screen_id });
    }

    fn column_by_id(&mut self, id: ColumnId) -> Option<&mut Column> {
        self.workspaces
            .iter_mut()
            .flat_map(|workspace| workspace.screens.iter_mut())
            .filter(|screen| screen.columns_active)
            .flat_map(|screen| screen.columns.iter_mut())
            .find(|column| column.id == id)
    }
}

fn check_height(height: u16) -> Result<(), Reject> {
    if ROW_HEIGHT_PERMILLE.contains(&height) { Ok(()) } else { Err(Reject::InvalidHeight(height)) }
}

/// `InsertRow`: a new row below `after_pane`'s row, holding one pane with the
/// tab `new_tab`, which references an existing terminal (the reducer never
/// creates one).
#[allow(clippy::too_many_arguments)]
pub(crate) fn insert_row(
    state: &mut LayoutState,
    after_pane: PaneId,
    height_permille: u16,
    new_row: RowId,
    new_pane: PaneId,
    new_tab: &NewTab,
    base_column: ColumnId,
    base_row: RowId,
    events: &mut Vec<LayoutEvent>,
) -> Result<(), Reject> {
    check_height(height_permille)?;
    let at = state.locate(after_pane)?;
    let ids = state.row_op_ids(at, vec![new_row, new_pane, new_tab.tab], base_column, base_row);
    state.ensure_fresh(&ids)?;
    state.open_rows(at, base_column, base_row, events);
    let slot = state.workspaces[at.workspace].screens[at.screen].columns[at.column]
        .row_index(at.position)
        + 1;
    state.insert_row(at, slot, new_row, height_permille, new_pane, events);
    state.panes.get_mut(&new_pane).expect("new pane").push(new_tab.tab);
    state.tabs.insert(new_tab.tab, new_tab.content.clone());
    events.push(LayoutEvent::TabCreated { tab: new_tab.tab, pane: new_pane });
    Ok(())
}

/// The arguments of `MoveTabToRow`.
pub(crate) struct RowMove<'a> {
    pub tab: TabId,
    pub anchor: PaneId,
    pub before: bool,
    pub height_permille: u16,
    pub new_row: RowId,
    pub new_pane: PaneId,
    pub base_column: ColumnId,
    pub base_row: RowId,
    pub respawn: Option<&'a NewTab>,
}

/// `MoveTabToRow`: `tab` into a new row above (`before`) or below `anchor`'s
/// row. A move whose result equals the current layout up to fresh ids (the
/// pane's only tab, alone in its row, onto either boundary of that row at its
/// height, no respawn) is a no-op (rows.md R6). With `respawn`, the source
/// pane must hold only `tab` and keeps the respawned tab.
pub(crate) fn move_tab_to_row(
    state: &mut LayoutState,
    op: RowMove<'_>,
    events: &mut Vec<LayoutEvent>,
) -> Result<(), Reject> {
    check_height(op.height_permille)?;
    let source = state.pane_of(op.tab).ok_or(Reject::UnknownTab(op.tab))?;
    let anchor = state.locate(op.anchor)?;
    let only = state.panes[&source].len() == 1;
    if op.respawn.is_some() && !only {
        return Err(Reject::RespawnNotNeeded);
    }
    let column = &state.workspaces[anchor.workspace].screens[anchor.screen].columns[anchor.column];
    let target = column.row_index(anchor.position) + usize::from(!op.before);
    if op.respawn.is_none() && only {
        let from = state.locate(source)?;
        let same_column = (from.workspace, from.screen, from.column)
            == (anchor.workspace, anchor.screen, anchor.column);
        let row = column.row_index(from.position);
        let alone = column.row_range(row).len() == 1;
        let height = column.rows.get(row).map_or(1000, |row| row.height_permille);
        if same_column
            && alone
            && (target == row || target == row + 1)
            && height == op.height_permille
        {
            return Ok(());
        }
    }
    let mut ids = vec![op.new_row, op.new_pane];
    if let Some(respawn) = op.respawn {
        ids.push(respawn.tab);
    }
    let ids = state.row_op_ids(anchor, ids, op.base_column, op.base_row);
    state.ensure_fresh(&ids)?;
    if let Some(respawn) = op.respawn {
        state.panes.get_mut(&source).expect("source pane").push(respawn.tab);
        state.tabs.insert(respawn.tab, respawn.content.clone());
        events.push(LayoutEvent::TabCreated { tab: respawn.tab, pane: source });
    }
    // `open_rows` may add a base row before the target index; the index was
    // computed against the implicit row, which becomes row 0.
    state.open_rows(anchor, op.base_column, op.base_row, events);
    state.insert_row(anchor, target, op.new_row, op.height_permille, op.new_pane, events);
    state.move_tab(op.tab, source, op.new_pane, 0, events);
    Ok(())
}

/// `SetRowHeights`: every row of `column` at once. The row set must be the
/// column's current rows; `fit` requires the heights to sum to 1000.
pub(crate) fn set_row_heights(
    state: &mut LayoutState,
    column: ColumnId,
    heights: &[(RowId, u16)],
    fit: bool,
    events: &mut Vec<LayoutEvent>,
) -> Result<(), Reject> {
    let target = state.column_by_id(column).ok_or(Reject::UnknownColumn(column))?;
    let mut current: Vec<RowId> = target.rows.iter().map(|row| row.id).collect();
    let mut named: Vec<RowId> = heights.iter().map(|(row, _)| *row).collect();
    current.sort_unstable();
    named.sort_unstable();
    if current.is_empty() || current != named {
        return Err(Reject::RowSetMismatch(column));
    }
    for (_, height) in heights {
        check_height(*height)?;
    }
    let sum: u32 = heights.iter().map(|(_, height)| u32::from(*height)).sum();
    if fit && sum != 1000 {
        return Err(Reject::FitSum(sum));
    }
    let mut changed = false;
    for row in &mut target.rows {
        let height = heights
            .iter()
            .find(|(id, _)| *id == row.id)
            .map(|(_, height)| *height)
            .expect("row named");
        changed |= row.height_permille != height;
        row.height_permille = height;
    }
    if changed {
        events.push(LayoutEvent::RowsResized { column });
    }
    Ok(())
}

/// `FlattenRows`: the column's rows become one implicit row; panes and tabs
/// stay where they are.
pub(crate) fn flatten_rows(
    state: &mut LayoutState,
    column: ColumnId,
    events: &mut Vec<LayoutEvent>,
) -> Result<(), Reject> {
    let target = state.column_by_id(column).ok_or(Reject::UnknownColumn(column))?;
    for row in target.rows.drain(..) {
        events.push(LayoutEvent::RowRemoved { row: row.id });
    }
    Ok(())
}

/// The row ops of [`LayoutOpKind`]; every other kind is not a row op.
pub(crate) fn apply(
    state: &mut LayoutState,
    kind: &LayoutOpKind,
    events: &mut Vec<LayoutEvent>,
) -> Result<(), Reject> {
    match kind {
        LayoutOpKind::InsertRow {
            after_pane,
            height_permille,
            new_row,
            new_pane,
            new_tab,
            base_column,
            base_row,
        } => insert_row(
            state,
            *after_pane,
            *height_permille,
            *new_row,
            *new_pane,
            new_tab,
            *base_column,
            *base_row,
            events,
        ),
        LayoutOpKind::MoveTabToRow {
            tab,
            anchor,
            before,
            height_permille,
            new_row,
            new_pane,
            base_column,
            base_row,
            respawn,
        } => {
            let op = RowMove {
                tab: *tab,
                anchor: *anchor,
                before: *before,
                height_permille: *height_permille,
                new_row: *new_row,
                new_pane: *new_pane,
                base_column: *base_column,
                base_row: *base_row,
                respawn: respawn.as_ref(),
            };
            move_tab_to_row(state, op, events)
        }
        LayoutOpKind::SetRowHeights { column, heights, fit } => {
            set_row_heights(state, *column, heights, *fit, events)
        }
        LayoutOpKind::FlattenRows { column } => flatten_rows(state, *column, events),
        // `apply_kind` routes only the four row ops here.
        _ => Ok(()),
    }
}
