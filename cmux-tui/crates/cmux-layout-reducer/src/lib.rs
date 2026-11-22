//! Pure layout reducer for the cmux workspace store.
//!
//! [`apply`] maps a [`LayoutState`] and a [`LayoutOp`] to the next state and
//! its events, or to a [`Reject`]. It does no I/O and knows nothing about
//! terminals beyond an opaque [`TabContent`] identity, so the workspace store
//! can run it anywhere (see plans/cmux-next/OWNERSHIP-PRINCIPLES.md).
//!
//! The model abstracts split geometry: a screen is an ordered list of
//! columns, and a column is the ordered list of panes in its split tree. An
//! ordinary screen (no strip columns) is one column with `columns_active`
//! false.
//!
//! Invariants, checked by [`apply`] on every result, by the property tests
//! and by an exhaustive check of every small layout (`exhaustive_tests.rs`):
//!
//! - **I1, tab conservation.** A move, split drop, column drop, reorder or
//!   tear-off never changes the set of tabs or the content behind a tab.
//!   Only [`LayoutOpKind::CloseTab`] removes a tab, exactly the one it names.
//! - **I2, single placement.** Every tab is in exactly one pane, every pane
//!   is in exactly one layout position, and every column has a pane.
//! - **I3, no empty panes.** Every pane has a tab; a pane that loses its last
//!   tab is removed in the same step, and so are a column and a screen left
//!   without panes.
//! - **I4, own position.** Moving a tab onto its own position is a no-op
//!   (`Ok` without events); splitting a pane's only tab out of that pane is
//!   [`Reject::OnlyTabSplitOutOfOwnPane`], unless the split respawns a new
//!   tab in that pane ([`LayoutOpKind::MoveTabToSplit`] `respawn`). The
//!   respawned tab is an explicit creation of the op, the only tab I1 lets
//!   appear.
//! - **Runtime death (invariant 3 of OWNERSHIP-PRINCIPLES).** A terminal
//!   host's death ([`LayoutOpKind::RuntimeExited`]) never closes a workspace
//!   or removes a tab; it only marks the tab dead.
//! - **I5, idempotency.** [`apply_once`] with a [`Ledger`]: replaying an op
//!   with the same key has no further effect; reusing a key for another op is
//!   [`Reject::IdempotencyConflict`].
//!
//! Focus (active screen, pane and tab) is per-client view state and is not
//! part of the model; ops name their destination explicitly.

// The crash ratchet keeps this crate at zero production panics
// (plans/cmux-next/crash-elimination.md section 6).
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::exit
    )
)]

use std::collections::{BTreeMap, BTreeSet};

mod rows;
mod tab_moves;
pub use rows::{ROW_HEIGHT_PERMILLE, Row, RowId, row_layout_is_valid};
use std::fmt;

pub type TabId = u64;
pub type PaneId = u64;
pub type ColumnId = u64;
pub type ScreenId = u64;
pub type WorkspaceId = u64;
pub type IdempotencyKey = String;

/// The content behind a tab: an opaque runtime identity, its terminal, and
/// whether the runtime exited. Identity is `runtime` and `terminal`; `dead`
/// is lifecycle state that only [`LayoutOpKind::RuntimeExited`] sets.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct TabContent {
    pub runtime: u64,
    pub terminal: Option<String>,
    pub dead: bool,
}

impl TabContent {
    fn same_identity(&self, other: &Self) -> bool {
        self.runtime == other.runtime && self.terminal == other.terminal
    }
}

/// The layout document: workspaces, screens, columns, panes and tabs. It
/// holds the arrangement only; the replay ledger is a separate [`Ledger`].
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct LayoutState {
    pub workspaces: Vec<Workspace>,
    /// Every pane and its tabs in strip order.
    pub panes: BTreeMap<PaneId, Vec<TabId>>,
    /// Every tab and its content.
    pub tabs: BTreeMap<TabId, TabContent>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Workspace {
    pub id: WorkspaceId,
    pub screens: Vec<Screen>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Screen {
    pub id: ScreenId,
    pub columns: Vec<Column>,
    /// Whether the columns are strip columns. When false the screen has one
    /// column, its split tree, whose id is not a column id.
    pub columns_active: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Column {
    pub id: ColumnId,
    pub panes: Vec<PaneId>,
    /// Rows partitioning `panes` top to bottom; empty is one implicit row
    /// ([`rows`] module).
    pub rows: Vec<Row>,
}

/// A pane edge for a split drop.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}

impl Edge {
    fn before(self) -> bool {
        matches!(self, Self::Left | Self::Top)
    }
}

/// One op with its client-chosen idempotency key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LayoutOp {
    pub key: IdempotencyKey,
    pub kind: LayoutOpKind,
}

/// The layout ops. Ids of entities an op creates (`new_*`, `base_column`)
/// are chosen by the caller, so a model result can be compared exactly with
/// the store's own result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LayoutOpKind {
    /// Move `tab` to insertion `index` of `pane`. Within its own pane an
    /// index after the tab counts the tab itself, as in a drag.
    MoveTab { tab: TabId, pane: PaneId, index: usize },
    /// Move `tab` into a new pane `new_pane` beside `pane` on `edge`. With
    /// `respawn`, `pane` must be the tab's own pane holding only `tab`: the
    /// new tab is created in it first, so the pane never empties (a split
    /// of a pane's only tab that keeps a fresh tab of the same kind there).
    MoveTabToSplit {
        tab: TabId,
        pane: PaneId,
        edge: Edge,
        new_pane: PaneId,
        respawn: Option<NewTab>,
    },
    /// Move `tab` into a new column `new_column` (holding `new_pane`) on
    /// `anchor`'s screen, after `after_column` (default: the last column),
    /// `width_permille` thousandths of the viewport wide. A screen without
    /// columns turns its split tree into the column `base_column` first.
    MoveTabToColumn {
        tab: TabId,
        anchor: PaneId,
        after_column: Option<ColumnId>,
        width_permille: u16,
        new_pane: PaneId,
        new_column: ColumnId,
        base_column: ColumnId,
    },
    /// Move `tab` into a new workspace at `index` (default: the end).
    /// Sidebar groups are personal state outside this model.
    MoveTabToNewWorkspace {
        tab: TabId,
        index: Option<usize>,
        new_workspace: WorkspaceId,
        new_screen: ScreenId,
        new_pane: PaneId,
    },
    /// Move `tab` to another workspace: to the end of `pane` when the
    /// workspace has screens (the caller resolves which pane, since focus
    /// is client state), or into a new screen and pane when it has none.
    MoveTabToWorkspace {
        tab: TabId,
        workspace: WorkspaceId,
        pane: Option<PaneId>,
        new_screen: ScreenId,
        new_pane: PaneId,
    },
    /// A new row below `after_pane`'s row, holding pane `new_pane` with the
    /// tab `new_tab` (an existing terminal). `base_column` names a split
    /// screen's tree when it becomes a column, `base_row` an implicit row
    /// when it becomes explicit (rows.md).
    InsertRow {
        after_pane: PaneId,
        height_permille: u16,
        new_row: RowId,
        new_pane: PaneId,
        new_tab: NewTab,
        base_column: ColumnId,
        base_row: RowId,
    },
    /// Move `tab` into a new row above (`before`) or below `anchor`'s row,
    /// with the optional respawn of `MoveTabToSplit`.
    MoveTabToRow {
        tab: TabId,
        anchor: PaneId,
        before: bool,
        height_permille: u16,
        new_row: RowId,
        new_pane: PaneId,
        base_column: ColumnId,
        base_row: RowId,
        respawn: Option<NewTab>,
    },
    /// Set every row height of `column` at once; `fit` requires a sum of 1000.
    SetRowHeights { column: ColumnId, heights: Vec<(RowId, u16)>, fit: bool },
    /// Fold `column`'s rows into one implicit row.
    FlattenRows { column: ColumnId },
    /// Close `tab`.
    CloseTab { tab: TabId },
    /// The session host reports that `runtime` exited. Its tabs stay where
    /// they are and are marked dead. In the daemon this is
    /// `TerminalEnd::HostLost` (host died, outcome unknown, or a signal
    /// during a session shutdown) and a process end under a keep policy; a
    /// process end without keep is a [`Self::CloseTab`] of each of its tabs
    /// (cmux-tui-core `terminal_end.rs`).
    RuntimeExited { runtime: u64 },
}

/// A tab an op creates explicitly (a respawn), with caller-chosen id and
/// content.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewTab {
    pub tab: TabId,
    pub content: TabContent,
}

/// Narrowest and widest column, in thousandths of the viewport.
pub const COLUMN_WIDTH_PERMILLE: std::ops::RangeInclusive<u16> = 100..=1000;

impl LayoutOpKind {
    /// The tabs this op removes.
    pub fn closed_tabs(&self) -> BTreeSet<TabId> {
        match self {
            Self::CloseTab { tab } => BTreeSet::from([*tab]),
            _ => BTreeSet::new(),
        }
    }

    /// The tabs this op creates explicitly.
    pub fn created_tabs(&self) -> BTreeSet<TabId> {
        match self {
            Self::MoveTabToSplit { respawn: Some(respawn), .. }
            | Self::MoveTabToRow { respawn: Some(respawn), .. } => BTreeSet::from([respawn.tab]),
            Self::InsertRow { new_tab, .. } => BTreeSet::from([new_tab.tab]),
            _ => BTreeSet::new(),
        }
    }
}

/// What an applied op changed, in order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LayoutEvent {
    TabMoved { tab: TabId, from: PaneId, to: PaneId, index: usize },
    TabCreated { tab: TabId, pane: PaneId },
    TabClosed { tab: TabId, pane: PaneId },
    TabDied { tab: TabId },
    PaneCreated { pane: PaneId, screen: ScreenId },
    PaneRemoved { pane: PaneId },
    ColumnCreated { column: ColumnId, screen: ScreenId },
    ColumnRemoved { column: ColumnId },
    RowCreated { row: RowId, column: ColumnId, index: usize },
    RowRemoved { row: RowId },
    RowsResized { column: ColumnId },
    ScreenCreated { screen: ScreenId, workspace: WorkspaceId },
    ScreenRemoved { screen: ScreenId },
    WorkspaceCreated { workspace: WorkspaceId, index: usize },
}

/// Why an op was not applied. A rejected op changes nothing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reject {
    UnknownTab(TabId),
    UnknownPane(PaneId),
    UnknownWorkspace(WorkspaceId),
    UnknownColumn(ColumnId),
    /// The pane is not in the destination workspace, or the workspace has
    /// screens and no destination pane was named.
    PaneNotInWorkspace {
        pane: Option<PaneId>,
        workspace: WorkspaceId,
    },
    /// A column width outside [`COLUMN_WIDTH_PERMILLE`].
    InvalidWidth(u16),
    /// A pane's only tab cannot be split or columned out of that pane.
    OnlyTabSplitOutOfOwnPane,
    /// A respawn applies only to a split of the tab's own pane that holds
    /// only that tab.
    RespawnNotNeeded,
    /// A caller-chosen id for a new entity is already in use.
    IdInUse(u64),
    /// A row height outside [`ROW_HEIGHT_PERMILLE`].
    InvalidHeight(u16),
    /// `SetRowHeights` named a row set other than the column's rows.
    RowSetMismatch(ColumnId),
    /// `SetRowHeights { fit: true }` heights that do not sum to 1000.
    FitSum(u32),
    /// `InsertRow` names content that this tab already places.
    ContentPlaced(TabId),
    /// The key was already used for a different op.
    IdempotencyConflict(IdempotencyKey),
    /// The result would break an invariant.
    Invariant(Vec<Violation>),
}

impl fmt::Display for Reject {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownTab(tab) => write!(f, "unknown tab {tab}"),
            Self::UnknownPane(pane) => write!(f, "unknown pane {pane}"),
            Self::UnknownWorkspace(workspace) => write!(f, "unknown workspace {workspace}"),
            Self::UnknownColumn(column) => write!(f, "unknown column {column}"),
            Self::PaneNotInWorkspace { pane, workspace } => {
                write!(f, "pane {pane:?} is not a destination in workspace {workspace}")
            }
            Self::InvalidWidth(width) => write!(f, "column width {width}\u{2030} is out of range"),
            Self::OnlyTabSplitOutOfOwnPane => {
                write!(f, "a pane's only tab cannot be split out of that pane")
            }
            Self::RespawnNotNeeded => {
                write!(f, "a respawn applies only to a split of the pane's only tab")
            }
            Self::IdInUse(id) => write!(f, "id {id} is already in use"),
            Self::InvalidHeight(height) => write!(f, "row height {height}\u{2030} is out of range"),
            Self::RowSetMismatch(column) => {
                write!(f, "the rows named are not column {column}'s rows")
            }
            Self::ContentPlaced(tab) => write!(f, "tab {tab} already places this content"),
            Self::FitSum(sum) => write!(f, "fitted row heights sum to {sum}\u{2030}, not 1000"),
            Self::IdempotencyConflict(key) => {
                write!(f, "idempotency key {key} was used for another op")
            }
            Self::Invariant(violations) => {
                write!(f, "invariant violated:")?;
                for violation in violations {
                    write!(f, " {violation};")?;
                }
                Ok(())
            }
        }
    }
}

impl std::error::Error for Reject {}

/// One broken invariant.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub enum Violation {
    /// I1: a tab disappeared without a close.
    TabLost { tab: TabId },
    /// I1: a tab appeared.
    TabAdded { tab: TabId },
    /// I1: a tab now shows other content.
    TabContentChanged { tab: TabId },
    /// I1: a closed tab is still present.
    TabNotClosed { tab: TabId },
    /// I2: a tab is listed more than once.
    TabPlacedTwice { tab: TabId },
    /// I2: a tab is in no pane.
    TabWithoutPane { tab: TabId },
    /// I2: a pane lists a tab that has no content.
    TabWithoutContent { tab: TabId, pane: PaneId },
    /// I2: a pane is in no layout.
    PaneOutsideLayout { pane: PaneId },
    /// I2: a pane is in more than one layout position.
    PanePlacedTwice { pane: PaneId },
    /// I2: a layout names a pane that does not exist.
    LayoutPaneMissing { pane: PaneId },
    /// I2: a column has no pane.
    EmptyColumn { column: ColumnId, screen: ScreenId },
    /// I2: a screen has no column.
    EmptyScreen { screen: ScreenId },
    /// I3: a pane has no tab.
    EmptyPane { pane: PaneId },
    /// R1/R2/R4: a column's rows do not partition its panes.
    RowLayout { column: ColumnId },
}

impl fmt::Display for Violation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TabLost { tab } => write!(f, "tab {tab} was lost"),
            Self::TabAdded { tab } => write!(f, "tab {tab} appeared"),
            Self::TabContentChanged { tab } => write!(f, "tab {tab} changed its content"),
            Self::TabNotClosed { tab } => write!(f, "closed tab {tab} remains"),
            Self::TabPlacedTwice { tab } => write!(f, "tab {tab} is placed twice"),
            Self::TabWithoutPane { tab } => write!(f, "tab {tab} has no pane"),
            Self::TabWithoutContent { tab, pane } => {
                write!(f, "pane {pane} lists tab {tab} without content")
            }
            Self::PaneOutsideLayout { pane } => write!(f, "pane {pane} is in no layout"),
            Self::PanePlacedTwice { pane } => write!(f, "pane {pane} is placed twice"),
            Self::LayoutPaneMissing { pane } => write!(f, "layout names missing pane {pane}"),
            Self::EmptyColumn { column, screen } => {
                write!(f, "column {column} of screen {screen} has no pane")
            }
            Self::EmptyScreen { screen } => write!(f, "screen {screen} has no column"),
            Self::EmptyPane { pane } => write!(f, "pane {pane} has no tabs"),
            Self::RowLayout { column } => {
                write!(f, "column {column}'s rows do not partition its panes")
            }
        }
    }
}

/// I2 and I3 on one state.
pub fn check_state(state: &LayoutState) -> BTreeSet<Violation> {
    let mut violations = BTreeSet::new();
    let mut placed = BTreeSet::new();
    for (pane, tabs) in &state.panes {
        if tabs.is_empty() {
            violations.insert(Violation::EmptyPane { pane: *pane });
        }
        for tab in tabs {
            if !placed.insert(*tab) {
                violations.insert(Violation::TabPlacedTwice { tab: *tab });
            }
            if !state.tabs.contains_key(tab) {
                violations.insert(Violation::TabWithoutContent { tab: *tab, pane: *pane });
            }
        }
    }
    for tab in state.tabs.keys() {
        if !placed.contains(tab) {
            violations.insert(Violation::TabWithoutPane { tab: *tab });
        }
    }
    let mut positions = BTreeMap::<PaneId, usize>::new();
    for workspace in &state.workspaces {
        for screen in &workspace.screens {
            if screen.columns.is_empty() {
                violations.insert(Violation::EmptyScreen { screen: screen.id });
            }
            for column in &screen.columns {
                if column.panes.is_empty() {
                    violations
                        .insert(Violation::EmptyColumn { column: column.id, screen: screen.id });
                }
                if !row_layout_is_valid(column) {
                    violations.insert(Violation::RowLayout { column: column.id });
                }
                for pane in &column.panes {
                    *positions.entry(*pane).or_default() += 1;
                }
            }
        }
    }
    for (pane, count) in &positions {
        if !state.panes.contains_key(pane) {
            violations.insert(Violation::LayoutPaneMissing { pane: *pane });
        }
        if *count > 1 {
            violations.insert(Violation::PanePlacedTwice { pane: *pane });
        }
    }
    for pane in state.panes.keys() {
        if !positions.contains_key(pane) {
            violations.insert(Violation::PaneOutsideLayout { pane: *pane });
        }
    }
    violations
}

/// I1 from `before` to `after`, where exactly the tabs in `closed` close.
pub fn check_conservation(
    before: &LayoutState,
    after: &LayoutState,
    closed: &BTreeSet<TabId>,
) -> BTreeSet<Violation> {
    check_conservation_creating(before, after, closed, &BTreeSet::new())
}

/// I1 from `before` to `after`, where exactly the tabs in `closed` close
/// and exactly the tabs in `created` appear (an op's explicit creations).
pub fn check_conservation_creating(
    before: &LayoutState,
    after: &LayoutState,
    closed: &BTreeSet<TabId>,
    created: &BTreeSet<TabId>,
) -> BTreeSet<Violation> {
    let mut violations = BTreeSet::new();
    for (tab, content) in &before.tabs {
        match (closed.contains(tab), after.tabs.get(tab)) {
            (true, Some(_)) => {
                violations.insert(Violation::TabNotClosed { tab: *tab });
            }
            (false, None) => {
                violations.insert(Violation::TabLost { tab: *tab });
            }
            (false, Some(after)) if !after.same_identity(content) => {
                violations.insert(Violation::TabContentChanged { tab: *tab });
            }
            _ => {}
        }
    }
    for tab in after.tabs.keys() {
        if !before.tabs.contains_key(tab) && !created.contains(tab) {
            violations.insert(Violation::TabAdded { tab: *tab });
        }
    }
    for tab in created {
        if !after.tabs.contains_key(tab) {
            violations.insert(Violation::TabLost { tab: *tab });
        }
    }
    violations
}

/// Every I1 violation from `before` to `after`, and every I2/I3 violation
/// of `after` that `before` did not already have. A state restored from an
/// older build that already breaks an invariant does not block later ops.
pub fn introduced_violations(
    before: &LayoutState,
    after: &LayoutState,
    closed: &BTreeSet<TabId>,
) -> BTreeSet<Violation> {
    introduced_violations_creating(before, after, closed, &BTreeSet::new())
}

/// [`introduced_violations`] where exactly the tabs in `created` may appear.
pub fn introduced_violations_creating(
    before: &LayoutState,
    after: &LayoutState,
    closed: &BTreeSet<TabId>,
    created: &BTreeSet<TabId>,
) -> BTreeSet<Violation> {
    let mut violations = check_conservation_creating(before, after, closed, created);
    let existing = check_state(before);
    violations.extend(check_state(after).into_iter().filter(|v| !existing.contains(v)));
    violations
}

/// Where a tab is: workspace, screen, pane, and index in the pane's strip.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Placement {
    pub workspace: WorkspaceId,
    pub screen: ScreenId,
    pub pane: PaneId,
    pub index: usize,
}

/// Every placed tab's [`Placement`].
pub fn placements(state: &LayoutState) -> BTreeMap<TabId, Placement> {
    let mut placements = BTreeMap::new();
    for workspace in &state.workspaces {
        for screen in &workspace.screens {
            for column in &screen.columns {
                for pane in &column.panes {
                    for (index, tab) in state.panes.get(pane).into_iter().flatten().enumerate() {
                        placements.insert(
                            *tab,
                            Placement {
                                workspace: workspace.id,
                                screen: screen.id,
                                pane: *pane,
                                index,
                            },
                        );
                    }
                }
            }
        }
    }
    placements
}

/// A difference between a model result and the store's own result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlacementMismatch {
    Content { tab: TabId },
    Placement { tab: TabId, model: Option<Placement>, live: Option<Placement> },
}

impl fmt::Display for PlacementMismatch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Content { tab } => write!(f, "tab {tab} has other content"),
            Self::Placement { tab, model, live } => {
                write!(f, "tab {tab} is at {model:?} in the model and at {live:?} live")
            }
        }
    }
}

/// Compare tab identity and tab placement (workspace, screen, pane, strip
/// index) of a model result with the live result. Split geometry, column
/// order and the `dead` flag (a runtime may exit at any moment) are not
/// compared.
pub fn placement_mismatches(model: &LayoutState, live: &LayoutState) -> Vec<PlacementMismatch> {
    let mut mismatches = Vec::new();
    let tabs = model.tabs.keys().chain(live.tabs.keys()).copied().collect::<BTreeSet<_>>();
    let model_placements = placements(model);
    let live_placements = placements(live);
    for tab in tabs {
        let same = match (model.tabs.get(&tab), live.tabs.get(&tab)) {
            (Some(model), Some(live)) => model.same_identity(live),
            (model, live) => model.is_none() && live.is_none(),
        };
        if !same {
            mismatches.push(PlacementMismatch::Content { tab });
        }
        let (model, live) = (model_placements.get(&tab), live_placements.get(&tab));
        if model != live {
            mismatches.push(PlacementMismatch::Placement {
                tab,
                model: model.copied(),
                live: live.copied(),
            });
        }
    }
    mismatches
}

/// Apply `op` to `state`, ignoring its key. The result never introduces a
/// violation: an op whose result would is rejected with
/// [`Reject::Invariant`].
pub fn apply(
    state: &LayoutState,
    op: &LayoutOp,
) -> Result<(LayoutState, Vec<LayoutEvent>), Reject> {
    let mut next = state.clone();
    let mut events = Vec::new();
    apply_kind(&mut next, &op.kind, &mut events)?;
    let violations = introduced_violations_creating(
        state,
        &next,
        &op.kind.closed_tabs(),
        &op.kind.created_tabs(),
    );
    if !violations.is_empty() {
        return Err(Reject::Invariant(violations.into_iter().collect()));
    }
    Ok((next, events))
}

/// The keys of recently applied ops, oldest first, at most
/// [`Ledger::CAPACITY`]. The store keeps its own durable ledger; this one
/// serves the model and its tests.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Ledger {
    applied: std::collections::VecDeque<(IdempotencyKey, LayoutOpKind)>,
}

impl Ledger {
    pub const CAPACITY: usize = 1024;

    pub fn get(&self, key: &str) -> Option<&LayoutOpKind> {
        self.applied.iter().find(|(candidate, _)| candidate == key).map(|(_, kind)| kind)
    }

    fn record(&mut self, op: &LayoutOp) {
        if self.applied.len() == Self::CAPACITY {
            self.applied.pop_front();
        }
        self.applied.push_back((op.key.clone(), op.kind.clone()));
    }
}

/// [`apply`] with idempotency: an op whose key `ledger` already holds for an
/// equal kind returns the state unchanged with no events, and a key held for
/// another kind is [`Reject::IdempotencyConflict`].
pub fn apply_once(
    state: &LayoutState,
    ledger: &Ledger,
    op: &LayoutOp,
) -> Result<(LayoutState, Ledger, Vec<LayoutEvent>), Reject> {
    if let Some(previous) = ledger.get(&op.key) {
        return if *previous == op.kind {
            Ok((state.clone(), ledger.clone(), Vec::new()))
        } else {
            Err(Reject::IdempotencyConflict(op.key.clone()))
        };
    }
    let (next, events) = apply(state, op)?;
    let mut ledger = ledger.clone();
    ledger.record(op);
    Ok((next, ledger, events))
}

/// Position of a pane in the layout: workspace, screen, column, slot.
#[derive(Debug, Clone, Copy)]
struct Slot {
    workspace: usize,
    screen: usize,
    column: usize,
    pane: usize,
}

impl LayoutState {
    /// The pane that holds `tab`.
    pub fn pane_of(&self, tab: TabId) -> Option<PaneId> {
        self.panes.iter().find(|(_, tabs)| tabs.contains(&tab)).map(|(pane, _)| *pane)
    }

    fn slot(&self, pane: PaneId) -> Option<Slot> {
        for (wi, workspace) in self.workspaces.iter().enumerate() {
            for (si, screen) in workspace.screens.iter().enumerate() {
                for (ci, column) in screen.columns.iter().enumerate() {
                    if let Some(pi) = column.panes.iter().position(|id| *id == pane) {
                        return Some(Slot { workspace: wi, screen: si, column: ci, pane: pi });
                    }
                }
            }
        }
        None
    }

    fn screen_mut(&mut self, slot: Slot) -> &mut Screen {
        &mut self.workspaces[slot.workspace].screens[slot.screen]
    }

    /// Whether `id` names any pane, real column, screen, workspace or tab.
    /// The daemon allocates all of them from one counter.
    fn id_in_use(&self, id: u64) -> bool {
        self.panes.contains_key(&id)
            || self.tabs.contains_key(&id)
            || self.workspaces.iter().any(|workspace| {
                workspace.id == id
                    || workspace.screens.iter().any(|screen| {
                        screen.id == id
                            || (screen.columns_active
                                && screen.columns.iter().any(|column| column.id == id))
                            || screen.columns.iter().any(|c| c.rows.iter().any(|row| row.id == id))
                    })
            })
    }

    fn ensure_fresh(&self, ids: &[u64]) -> Result<(), Reject> {
        for (index, id) in ids.iter().enumerate() {
            if self.id_in_use(*id) || ids[..index].contains(id) {
                return Err(Reject::IdInUse(*id));
            }
        }
        Ok(())
    }

    fn require_pane(&self, pane: PaneId) -> Result<Slot, Reject> {
        if !self.panes.contains_key(&pane) {
            return Err(Reject::UnknownPane(pane));
        }
        self.slot(pane).ok_or(Reject::UnknownPane(pane))
    }

    fn insert_pane(&mut self, pane: PaneId) {
        self.panes.insert(pane, Vec::new());
    }
}

fn apply_kind(
    state: &mut LayoutState,
    kind: &LayoutOpKind,
    events: &mut Vec<LayoutEvent>,
) -> Result<(), Reject> {
    match kind {
        LayoutOpKind::MoveTab { tab, pane, index } => {
            let source = state.pane_of(*tab).ok_or(Reject::UnknownTab(*tab))?;
            state.require_pane(*pane)?;
            state.move_tab(*tab, source, *pane, *index, events)?;
        }
        LayoutOpKind::MoveTabToSplit { tab, pane, edge, new_pane, respawn } => {
            let source = state.pane_of(*tab).ok_or(Reject::UnknownTab(*tab))?;
            let slot = state.require_pane(*pane)?;
            let only = source == *pane && state.panes[&source].len() == 1;
            match respawn {
                None if only => return Err(Reject::OnlyTabSplitOutOfOwnPane),
                None => state.ensure_fresh(&[*new_pane])?,
                Some(_) if !only => return Err(Reject::RespawnNotNeeded),
                Some(respawn) => {
                    state.ensure_fresh(&[*new_pane, respawn.tab])?;
                    // The fresh tab first: the pane keeps a tab throughout.
                    state.tabs.insert(respawn.tab, respawn.content.clone());
                    state
                        .panes
                        .get_mut(&source)
                        .ok_or(Reject::UnknownPane(source))?
                        .push(respawn.tab);
                    events.push(LayoutEvent::TabCreated { tab: respawn.tab, pane: source });
                }
            }
            let screen = state.screen_mut(slot);
            let at = if edge.before() { slot.pane } else { slot.pane + 1 };
            screen.columns[slot.column].note_inserted(slot.pane);
            screen.columns[slot.column].panes.insert(at, *new_pane);
            let screen_id = screen.id;
            state.insert_pane(*new_pane);
            events.push(LayoutEvent::PaneCreated { pane: *new_pane, screen: screen_id });
            state.move_tab(*tab, source, *new_pane, 0, events)?;
        }
        LayoutOpKind::MoveTabToColumn {
            tab,
            anchor,
            after_column,
            width_permille,
            new_pane,
            new_column,
            base_column,
        } => {
            if !COLUMN_WIDTH_PERMILLE.contains(width_permille) {
                return Err(Reject::InvalidWidth(*width_permille));
            }
            let source = state.pane_of(*tab).ok_or(Reject::UnknownTab(*tab))?;
            let slot = state.require_pane(*anchor)?;
            if source == *anchor && state.panes[&source].len() == 1 {
                return Err(Reject::OnlyTabSplitOutOfOwnPane);
            }
            let screen = &state.workspaces[slot.workspace].screens[slot.screen];
            let position = match after_column {
                Some(column) if screen.columns_active => {
                    screen
                        .columns
                        .iter()
                        .position(|candidate| candidate.id == *column)
                        .ok_or(Reject::UnknownColumn(*column))?
                        + 1
                }
                Some(column) => return Err(Reject::UnknownColumn(*column)),
                None => screen.columns.len(),
            };
            if screen.columns_active {
                state.ensure_fresh(&[*new_pane, *new_column])?;
            } else {
                state.ensure_fresh(&[*new_pane, *new_column, *base_column])?;
            }
            let screen = state.screen_mut(slot);
            if !screen.columns_active {
                screen.columns_active = true;
                screen.columns[0].id = *base_column;
                events.push(LayoutEvent::ColumnCreated { column: *base_column, screen: screen.id });
            }
            screen.columns.insert(position, Column::single(*new_column, vec![*new_pane]));
            let screen_id = screen.id;
            state.insert_pane(*new_pane);
            events.push(LayoutEvent::ColumnCreated { column: *new_column, screen: screen_id });
            events.push(LayoutEvent::PaneCreated { pane: *new_pane, screen: screen_id });
            state.move_tab(*tab, source, *new_pane, 0, events)?;
        }
        LayoutOpKind::MoveTabToNewWorkspace { tab, index, new_workspace, new_screen, new_pane } => {
            let source = state.pane_of(*tab).ok_or(Reject::UnknownTab(*tab))?;
            state.ensure_fresh(&[*new_workspace, *new_screen, *new_pane])?;
            state.take_tab(*tab, source, events)?;
            let position = index.unwrap_or(state.workspaces.len()).min(state.workspaces.len());
            state.workspaces.insert(
                position,
                Workspace {
                    id: *new_workspace,
                    screens: vec![single_pane_screen(*new_screen, *new_pane)],
                },
            );
            state.panes.insert(*new_pane, vec![*tab]);
            events
                .push(LayoutEvent::WorkspaceCreated { workspace: *new_workspace, index: position });
            events.push(LayoutEvent::ScreenCreated {
                screen: *new_screen,
                workspace: *new_workspace,
            });
            events.push(LayoutEvent::PaneCreated { pane: *new_pane, screen: *new_screen });
            events.push(LayoutEvent::TabMoved { tab: *tab, from: source, to: *new_pane, index: 0 });
        }
        LayoutOpKind::MoveTabToWorkspace { tab, workspace, pane, new_screen, new_pane } => {
            let source = state.pane_of(*tab).ok_or(Reject::UnknownTab(*tab))?;
            let target = state
                .workspaces
                .iter()
                .position(|candidate| candidate.id == *workspace)
                .ok_or(Reject::UnknownWorkspace(*workspace))?;
            let source_workspace = state.slot(source).map(|slot| slot.workspace);
            if source_workspace == Some(target) {
                return Ok(());
            }
            if !state.workspaces[target].screens.is_empty() {
                let destination = pane
                    .filter(|pane| {
                        state.panes.contains_key(pane)
                            && state.slot(*pane).is_some_and(|slot| slot.workspace == target)
                    })
                    .ok_or(Reject::PaneNotInWorkspace { pane: *pane, workspace: *workspace })?;
                let end = state.panes[&destination].len();
                state.move_tab(*tab, source, destination, end, events)?;
            } else {
                state.ensure_fresh(&[*new_screen, *new_pane])?;
                state.take_tab(*tab, source, events)?;
                let target = state
                    .workspaces
                    .iter()
                    .position(|candidate| candidate.id == *workspace)
                    .ok_or(Reject::UnknownWorkspace(*workspace))?;
                state.workspaces[target].screens.push(single_pane_screen(*new_screen, *new_pane));
                state.panes.insert(*new_pane, vec![*tab]);
                events.push(LayoutEvent::ScreenCreated {
                    screen: *new_screen,
                    workspace: *workspace,
                });
                events.push(LayoutEvent::PaneCreated { pane: *new_pane, screen: *new_screen });
                events.push(LayoutEvent::TabMoved {
                    tab: *tab,
                    from: source,
                    to: *new_pane,
                    index: 0,
                });
            }
        }
        LayoutOpKind::InsertRow { .. }
        | LayoutOpKind::MoveTabToRow { .. }
        | LayoutOpKind::SetRowHeights { .. }
        | LayoutOpKind::FlattenRows { .. } => rows::apply(state, kind, events)?,
        LayoutOpKind::CloseTab { tab } => {
            let pane = state.pane_of(*tab).ok_or(Reject::UnknownTab(*tab))?;
            state.tabs.remove(tab);
            events.push(LayoutEvent::TabClosed { tab: *tab, pane });
            state.take_tab(*tab, pane, events)?;
        }
        LayoutOpKind::RuntimeExited { runtime } => {
            // A runtime with no tab (a detached terminal) is not an error:
            // the store never rejects a host's lifecycle fact.
            for (tab, content) in &mut state.tabs {
                if content.runtime == *runtime && !content.dead {
                    content.dead = true;
                    events.push(LayoutEvent::TabDied { tab: *tab });
                }
            }
        }
    }
    Ok(())
}

fn single_pane_screen(screen: ScreenId, pane: PaneId) -> Screen {
    Screen { id: screen, columns: vec![Column::single(0, vec![pane])], columns_active: false }
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod exhaustive_tests;

#[cfg(test)]
mod rows_tests;

#[cfg(kani)]
mod proofs;
pub mod sidebar_drop;
