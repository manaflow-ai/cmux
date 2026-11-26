//! Window docks, the Dock Column plan and the layout model's dock checks, moved from the app's Swift
//! (`Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Model/WindowDocks.swift`, `DockPlan.swift` and
//! `LayoutModel+Dock.swift`).
//!
//! - [`WindowDocks`]: a window's docked workspaces (plans/cmux-next/docked-workspace-DESIGN.md), up
//!   to four edge docks around the stage, rules W1 to W5. Pure value: the window controller places
//!   it and the window record persists it.
//! - [`DockDefaults`] and [`DockPlan`]: what one Dock Column request does (plans/cmux-next/
//!   layout-model.md), decided from the layout alone so every entry point behaves the same.
//! - [`validate_dock`], [`set_column_dock`], [`dock_column_containing`]: the checks the layout
//!   model runs before it sends a column's dock change to the daemon, which owns the flag.
//!
//! `schemas/dock-model/vectors.json` has the answers the Swift types gave (ops `dock_model_*`);
//! `dock_model_tests.rs` mirrors their tests.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashSet;

/// Which edge a dock holds (Swift `DockEdge`, in `CaseIterable` order).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DockEdge {
    Left,
    Right,
    Top,
    Bottom,
}

impl DockEdge {
    /// Every edge, in the Swift `allCases` order (the order docks keep).
    pub const ALL: [DockEdge; 4] =
        [DockEdge::Left, DockEdge::Right, DockEdge::Top, DockEdge::Bottom];

    /// Top and bottom: the dock is a horizontal band.
    pub fn is_band(self) -> bool {
        self == DockEdge::Top || self == DockEdge::Bottom
    }

    fn order(self) -> usize {
        DockEdge::ALL.iter().position(|edge| *edge == self).unwrap_or(0)
    }
}

/// How a dock shares the frame with the stage (Swift `DockMode`): `Overlay` is the UI's "Floating".
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DockMode {
    #[default]
    Docked,
    Overlay,
}

/// Which docks own the frame's corners (Swift `FrameOrientation`, W7).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FrameOrientation {
    #[default]
    ColumnMajor,
    RowMajor,
}

/// The extent a new dock gets: 30% of the frame.
pub const DEFAULT_EXTENT_PERMILLE: i64 = 300;
/// The extents the record may hold, `100...900`.
pub const EXTENT_RANGE: (i64, i64) = (100, 900);

/// `extent` clamped into [`EXTENT_RANGE`].
pub fn clamp_extent(extent: i64) -> i64 {
    extent.max(EXTENT_RANGE.0).min(EXTENT_RANGE.1)
}

/// One edge's docked workspace (Swift `WindowDocks.Dock`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Dock {
    pub edge: DockEdge,
    /// `WorkspaceModel.id` of the docked workspace.
    pub workspace: String,
    pub mode: DockMode,
    /// Width (left, right) or height (top, bottom) as permille of the frame, 100...900.
    pub extent_permille: i64,
    /// Toggled off: kept, not placed.
    pub hidden: bool,
    /// The Home Chief pane's no-tab-bar mode, per dock.
    #[serde(default)]
    pub hides_tab_bar: bool,
}

impl Dock {
    /// Whether a pane of this dock's workspace that shows `shown_tabs` tabs draws no tab bar.
    pub fn hides_tab_bar_for(&self, shown_tabs: i64) -> bool {
        self.hides_tab_bar && shown_tabs <= 1
    }
}

/// What Toggle did to an edge.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToggleResult {
    /// The dock was hidden and shows now.
    Shown,
    /// The dock showed and is hidden now.
    Hidden,
    /// The edge holds no dock: the caller docks a new workspace there.
    Empty,
}

/// A window's docked workspaces (Swift `WindowDocks`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowDocks {
    /// The docks in edge order (left, right, top, bottom).
    #[serde(default)]
    pub all: Vec<Dock>,
    /// Which docks own the frame's corners (W7).
    #[serde(default)]
    pub orientation: FrameOrientation,
}

impl WindowDocks {
    /// An empty frame.
    pub fn new(orientation: FrameOrientation) -> Self {
        WindowDocks { all: Vec::new(), orientation }
    }

    /// The docks drawn now: every one not hidden.
    pub fn visible(&self) -> Vec<&Dock> {
        self.all.iter().filter(|dock| !dock.hidden).collect()
    }

    /// No dock at all.
    pub fn is_empty(&self) -> bool {
        self.all.is_empty()
    }

    /// The dock at `edge`, hidden or not.
    pub fn dock_at(&self, edge: DockEdge) -> Option<&Dock> {
        self.all.iter().find(|dock| dock.edge == edge)
    }

    /// The edge that holds `workspace`.
    pub fn edge_of(&self, workspace: &str) -> Option<DockEdge> {
        self.all.iter().find(|dock| dock.workspace == workspace).map(|dock| dock.edge)
    }

    /// `workspace` is in a dock (hidden or not).
    pub fn is_docked(&self, workspace: &str) -> bool {
        self.edge_of(workspace).is_some()
    }

    /// Docks `workspace` at `edge` (W1, W2): it leaves any other edge, and the workspace the edge
    /// held goes back to the sidebar. Returns that displaced workspace.
    pub fn dock(
        &mut self,
        workspace: &str,
        edge: DockEdge,
        mode: DockMode,
        extent_permille: i64,
    ) -> Option<String> {
        let displaced = self
            .dock_at(edge)
            .and_then(|dock| (dock.workspace != workspace).then(|| dock.workspace.clone()));
        // The workspace keeps its own tab-bar mode when it moves to another edge.
        let hides_tab_bar = self
            .all
            .iter()
            .find(|dock| dock.workspace == workspace)
            .is_some_and(|dock| dock.hides_tab_bar);
        self.all.retain(|dock| !(dock.edge == edge || dock.workspace == workspace));
        self.all.push(Dock {
            edge,
            workspace: workspace.to_owned(),
            mode,
            extent_permille: clamp_extent(extent_permille),
            hidden: false,
            hides_tab_bar,
        });
        self.all.sort_by_key(|dock| dock.edge.order());
        displaced
    }

    /// Removes `workspace`'s dock; false when it has none.
    pub fn undock(&mut self, workspace: &str) -> bool {
        let before = self.all.len();
        self.all.retain(|dock| dock.workspace != workspace);
        self.all.len() != before
    }

    /// Hides or shows the dock at `edge`.
    pub fn toggle(&mut self, edge: DockEdge) -> ToggleResult {
        let Some(dock) = self.all.iter_mut().find(|dock| dock.edge == edge) else {
            return ToggleResult::Empty;
        };
        dock.hidden = !dock.hidden;
        if dock.hidden { ToggleResult::Hidden } else { ToggleResult::Shown }
    }

    /// Shows `workspace`'s dock when it is hidden (W4). True when it changed.
    pub fn reveal(&mut self, workspace: &str) -> bool {
        let Some(dock) =
            self.all.iter_mut().find(|dock| dock.workspace == workspace && dock.hidden)
        else {
            return false;
        };
        dock.hidden = false;
        true
    }

    /// Docked <-> Floating for `workspace`'s dock; the new mode, nil when it has no dock.
    pub fn toggle_floating(&mut self, workspace: &str) -> Option<DockMode> {
        let dock = self.all.iter_mut().find(|dock| dock.workspace == workspace)?;
        dock.mode =
            if dock.mode == DockMode::Overlay { DockMode::Docked } else { DockMode::Overlay };
        Some(dock.mode)
    }

    /// Moves `workspace`'s dock to `edge`, keeping its mode, extent and tab-bar mode, and shows it
    /// (W1). Returns the displaced workspace; nil, and nothing changes, when `workspace` has no dock.
    pub fn move_dock(&mut self, workspace: &str, edge: DockEdge) -> Option<String> {
        let current = self.all.iter().find(|dock| dock.workspace == workspace)?;
        let (mode, extent) = (current.mode, current.extent_permille);
        self.dock(workspace, edge, mode, extent)
    }

    /// Turns the no-tab-bar mode of `workspace`'s dock on or off; the new value, nil with no dock.
    pub fn toggle_tab_bar(&mut self, workspace: &str) -> Option<bool> {
        let dock = self.all.iter_mut().find(|dock| dock.workspace == workspace)?;
        dock.hides_tab_bar = !dock.hides_tab_bar;
        Some(dock.hides_tab_bar)
    }

    /// Sets the no-tab-bar mode of `workspace`'s dock; false when it has no dock.
    pub fn set_hides_tab_bar(&mut self, hides: bool, workspace: &str) -> bool {
        let Some(dock) = self.all.iter_mut().find(|dock| dock.workspace == workspace) else {
            return false;
        };
        dock.hides_tab_bar = hides;
        true
    }

    /// Whether a pane of `workspace` that shows `shown_tabs` tabs draws no tab bar because its dock
    /// is in the no-tab-bar mode; false for a workspace in no dock.
    pub fn hides_tab_bar(&self, workspace: &str, shown_tabs: i64) -> bool {
        self.all
            .iter()
            .find(|dock| dock.workspace == workspace)
            .is_some_and(|dock| dock.hides_tab_bar_for(shown_tabs))
    }

    /// The dock the window-dock actions act on: the one holding `focused`, else the first shown
    /// one, else the first hidden one; nil with no dock.
    pub fn target(&self, focused: Option<&str>) -> Option<&Dock> {
        self.all
            .iter()
            .find(|dock| Some(dock.workspace.as_str()) == focused)
            .or_else(|| self.all.iter().find(|dock| !dock.hidden))
            .or_else(|| self.all.first())
    }

    /// Keeps only the docks whose workspace `keeping` accepts (W3).
    pub fn prune(&mut self, keeping: impl Fn(&str) -> bool) {
        self.all.retain(|dock| keeping(&dock.workspace));
    }

    /// The workspace the stage shows (W5): the focused one unless it is docked; else the previous
    /// stage while the window lists it; else the most recent listed workspace not docked; else the
    /// first listed one not docked.
    pub fn stage(
        &self,
        focused: Option<&str>,
        previous: Option<&str>,
        recency: &[String],
        listed: &[String],
    ) -> Option<String> {
        let candidates: HashSet<&str> = listed.iter().map(String::as_str).collect();
        let free = |id: Option<&str>| -> Option<String> {
            let id = id?;
            (candidates.contains(id) && !self.is_docked(id)).then(|| id.to_owned())
        };
        free(focused)
            .or_else(|| free(previous))
            .or_else(|| recency.iter().find_map(|id| free(Some(id))))
            .or_else(|| listed.iter().find_map(|id| free(Some(id))))
    }

    /// Runs one [`DocksAction`] and returns its answer as JSON (the `dock_model_docks` op).
    pub fn apply(&mut self, action: &DocksAction) -> Value {
        match action {
            DocksAction::Dock { workspace, edge, mode, extent_permille } => json!(self.dock(
                workspace,
                *edge,
                mode.unwrap_or_default(),
                extent_permille.unwrap_or(DEFAULT_EXTENT_PERMILLE),
            )),
            DocksAction::Undock { workspace } => json!(self.undock(workspace)),
            DocksAction::Toggle { edge } => json!(self.toggle(*edge)),
            DocksAction::Reveal { workspace } => json!(self.reveal(workspace)),
            DocksAction::ToggleFloating { workspace } => json!(self.toggle_floating(workspace)),
            DocksAction::Move { workspace, edge } => json!(self.move_dock(workspace, *edge)),
            DocksAction::ToggleTabBar { workspace } => json!(self.toggle_tab_bar(workspace)),
            DocksAction::SetHidesTabBar { workspace, hides } => {
                json!(self.set_hides_tab_bar(*hides, workspace))
            }
            DocksAction::Prune { keeping } => {
                let keeping: HashSet<&str> = keeping.iter().map(String::as_str).collect();
                self.prune(|workspace| keeping.contains(workspace));
                Value::Null
            }
            DocksAction::DockAt { edge } => json!(self.dock_at(*edge)),
            DocksAction::EdgeOf { workspace } => json!(self.edge_of(workspace)),
            DocksAction::IsDocked { workspace } => json!(self.is_docked(workspace)),
            DocksAction::Visible => json!(self.visible()),
            DocksAction::IsEmpty => json!(self.is_empty()),
            DocksAction::HidesTabBar { workspace, shown_tabs } => {
                json!(self.hides_tab_bar(workspace, *shown_tabs))
            }
            DocksAction::DockHidesTabBar { edge, shown_tabs } => {
                json!(self.dock_at(*edge).map(|dock| dock.hides_tab_bar_for(*shown_tabs)))
            }
            DocksAction::Target { focused } => json!(self.target(focused.as_deref())),
            DocksAction::Stage { focused, previous, recency, listed } => {
                json!(self.stage(focused.as_deref(), previous.as_deref(), recency, listed))
            }
        }
    }
}

/// One call on a [`WindowDocks`], as the `dock_model_docks` op names it (`{"action": "dock", ...}`).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase")]
pub enum DocksAction {
    Dock {
        workspace: String,
        edge: DockEdge,
        #[serde(default)]
        mode: Option<DockMode>,
        #[serde(default, rename = "extentPermille")]
        extent_permille: Option<i64>,
    },
    Undock {
        workspace: String,
    },
    Toggle {
        edge: DockEdge,
    },
    Reveal {
        workspace: String,
    },
    ToggleFloating {
        workspace: String,
    },
    Move {
        workspace: String,
        edge: DockEdge,
    },
    ToggleTabBar {
        workspace: String,
    },
    SetHidesTabBar {
        workspace: String,
        hides: bool,
    },
    Prune {
        keeping: Vec<String>,
    },
    DockAt {
        edge: DockEdge,
    },
    EdgeOf {
        workspace: String,
    },
    IsDocked {
        workspace: String,
    },
    Visible,
    IsEmpty,
    HidesTabBar {
        workspace: String,
        #[serde(rename = "shownTabs")]
        shown_tabs: i64,
    },
    DockHidesTabBar {
        edge: DockEdge,
        #[serde(rename = "shownTabs")]
        shown_tabs: i64,
    },
    Target {
        #[serde(default)]
        focused: Option<String>,
    },
    Stage {
        #[serde(default)]
        focused: Option<String>,
        #[serde(default)]
        previous: Option<String>,
        #[serde(default)]
        recency: Vec<String>,
        #[serde(default)]
        listed: Vec<String>,
    },
}

// MARK: Dock Column (DockPlan.swift, LayoutModel+Dock.swift)

/// A column pinned to one edge of the viewport (Swift `DockColumn`, daemon `columns[].dock`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockColumn {
    pub edge: DockEdge,
    pub mode: DockMode,
    /// `DockRole` raw value (`agentChat`), nil for an ordinary dock.
    #[serde(default)]
    pub role: Option<String>,
    #[serde(default)]
    pub is_pinned: bool,
    #[serde(default)]
    pub allows_tabs: bool,
}

impl DockColumn {
    /// A dock at `edge` in `mode` with no role, not pinned (Swift `DockColumn(edge:mode:)`).
    pub fn new(edge: DockEdge, mode: DockMode) -> Self {
        DockColumn { edge, mode, role: None, is_pinned: false, allows_tabs: false }
    }
}

/// One column of a screen as the dock rules read it (Swift `LayoutColumn`): `panes` is its split
/// tree's panes in order (`root.panes`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LayoutColumn {
    pub id: String,
    pub width: f64,
    #[serde(default)]
    pub panes: Vec<String>,
    #[serde(default)]
    pub dock: Option<DockColumn>,
}

/// The content of one screen (Swift `ScreenLayout`): one split tree, or columns.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ScreenLayout {
    Splits(Vec<String>),
    Columns(Vec<LayoutColumn>),
}

impl ScreenLayout {
    /// The stored columns; none for a split tree.
    pub fn columns(&self) -> &[LayoutColumn] {
        match self {
            ScreenLayout::Columns(columns) => columns,
            ScreenLayout::Splits(_) => &[],
        }
    }

    /// Whether `pane` is a tiled pane of the layout.
    pub fn contains(&self, pane: &str) -> bool {
        match self {
            ScreenLayout::Splits(root) => root.iter().any(|p| p == pane),
            ScreenLayout::Columns(columns) => {
                columns.iter().any(|column| column.panes.iter().any(|p| p == pane))
            }
        }
    }

    /// A copy with `column`'s dock set to `dock`; another column at that edge scrolls again.
    pub fn setting_dock(&self, dock: Option<&DockColumn>, column: &str) -> ScreenLayout {
        let ScreenLayout::Columns(columns) = self else { return self.clone() };
        ScreenLayout::Columns(
            columns
                .iter()
                .map(|entry| {
                    let mut entry = entry.clone();
                    if entry.id == column {
                        entry.dock = dock.cloned();
                    } else if let Some(dock) = dock
                        && entry.dock.as_ref().is_some_and(|own| own.edge == dock.edge)
                    {
                        entry.dock = None;
                    }
                    entry
                })
                .collect(),
        )
    }
}

/// One screen (Swift `LayoutScreen`): its layout and its floating panes.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LayoutScreen {
    pub id: String,
    pub layout: ScreenLayout,
    #[serde(default)]
    pub floating: Vec<String>,
}

impl LayoutScreen {
    /// The id of the implicit column a screen stored as one split tree is.
    pub fn implicit_column_id(&self) -> String {
        format!("implicit:{}", self.id)
    }

    /// Whether `pane` is a pane of the screen, tiled or floating.
    pub fn contains(&self, pane: &str) -> bool {
        self.layout.contains(pane) || self.floating.iter().any(|p| p == pane)
    }

    /// The column holding `pane`: a stored column, or the implicit one.
    pub fn column_containing(&self, pane: &str) -> Option<LayoutColumn> {
        match &self.layout {
            ScreenLayout::Splits(root) => root.iter().any(|p| p == pane).then(|| LayoutColumn {
                id: self.implicit_column_id(),
                width: 1.0,
                panes: root.clone(),
                dock: None,
            }),
            ScreenLayout::Columns(columns) => {
                columns.iter().find(|column| column.panes.iter().any(|p| p == pane)).cloned()
            }
        }
    }

    /// The column with `id`, including the implicit one.
    pub fn column(&self, id: &str) -> Option<LayoutColumn> {
        match &self.layout {
            ScreenLayout::Splits(root) => (id == self.implicit_column_id()).then(|| LayoutColumn {
                id: id.to_owned(),
                width: 1.0,
                panes: root.clone(),
                dock: None,
            }),
            ScreenLayout::Columns(columns) => columns.iter().find(|c| c.id == id).cloned(),
        }
    }
}

/// What one dock request does (Swift `DockPlan`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DockPlan {
    /// Pin the column at the edge and size it to `width`, in one transaction.
    Pin { column: String, dock: DockColumn, width: f64 },
    /// The column scrolls again.
    Undock { column: String },
    /// The column is the screen's only scrolling column: the pane's active tab moves into a new
    /// column pinned at the edge.
    MoveTab { pane: String, dock: DockColumn, width: f64 },
}

/// The defaults a dock request uses when it names no edge or width (Swift `DockDefaults`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct DockDefaults;

impl DockDefaults {
    /// A dock's share of the window: the column's width, clamped here.
    pub const WIDTH_RANGE: (f64, f64) = (0.25, 0.40);

    pub fn width(&self, current: f64) -> f64 {
        current.max(Self::WIDTH_RANGE.0).min(Self::WIDTH_RANGE.1)
    }

    /// The edge a column docks to by default: left for the leftmost of several scrolling columns,
    /// else right. A side another column holds yields to the free side.
    pub fn edge(&self, column: &str, layout: &ScreenLayout) -> DockEdge {
        let columns = layout.columns();
        let scrolling: Vec<&LayoutColumn> = columns.iter().filter(|c| c.dock.is_none()).collect();
        let near = if scrolling.len() > 1 && scrolling.first().is_some_and(|c| c.id == column) {
            DockEdge::Left
        } else {
            DockEdge::Right
        };
        let held = |edge: DockEdge| {
            columns
                .iter()
                .any(|c| c.id != column && c.dock.as_ref().is_some_and(|d| d.edge == edge))
        };
        let far = if near == DockEdge::Left { DockEdge::Right } else { DockEdge::Left };
        if held(near) && !held(far) { far } else { near }
    }

    /// What docking `id` does. `edge` nil uses the column's own edge when it has one, else
    /// `default_edge`, else [`DockDefaults::edge`]. Asking for the state the column already has
    /// undocks it. `pane` is the pane whose tab moves when the column must keep scrolling. Nil
    /// only when the screen has no such column.
    pub fn plan(
        &self,
        screen: &LayoutScreen,
        id: &str,
        pane: Option<&str>,
        edge: Option<DockEdge>,
        default_edge: Option<DockEdge>,
        mode: DockMode,
    ) -> Option<DockPlan> {
        let column = screen.column(id)?;
        if let Some(current) = &column.dock
            && current.mode == mode
            && (edge.is_none() || edge == Some(current.edge))
        {
            return Some(DockPlan::Undock { column: id.to_owned() });
        }
        let chosen = edge
            .or(column.dock.as_ref().map(|d| d.edge))
            .or(default_edge)
            .unwrap_or_else(|| self.edge(id, &screen.layout));
        let target = DockColumn::new(chosen, mode);
        let width = self.width(column.width);
        // The implicit column, or the last scrolling one, must keep scrolling.
        let others_scroll = screen.layout.columns().iter().any(|c| c.id != id && c.dock.is_none());
        if id == screen.implicit_column_id() || (column.dock.is_none() && !others_scroll) {
            let anchor = pane
                .filter(|pane| column.panes.iter().any(|p| p == pane))
                .map(str::to_owned)
                .or_else(|| column.panes.first().cloned())?;
            return Some(DockPlan::MoveTab { pane: anchor, dock: target, width });
        }
        Some(DockPlan::Pin { column: id.to_owned(), dock: target, width })
    }
}

/// Why a column cannot become docked or change its dock (Swift `LayoutModel.DockRefusal`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DockRefusal {
    /// No screen shows a column with that id.
    UnknownColumn,
    /// The change would leave no column to scroll.
    LastScrollingColumn,
    /// The column already has that state.
    Unchanged,
}

/// The command [`set_column_dock`] sends the daemon (Swift `.setColumnDock`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SetColumnDock {
    pub column: String,
    pub any_pane: String,
    pub dock: Option<DockColumn>,
}

/// The column holding `pane` and its docked state (Swift `LayoutModel.dockColumn(containing:)`).
pub fn dock_column_containing(screens: &[LayoutScreen], pane: &str) -> Option<LayoutColumn> {
    screens.iter().find(|screen| screen.contains(pane))?.column_containing(pane)
}

/// Checks a change the way the daemon does before sending it (Swift `LayoutModel.validateDock`).
pub fn validate_dock(
    screens: &[LayoutScreen],
    dock: Option<&DockColumn>,
    column: &str,
) -> Option<DockRefusal> {
    let Some(screen) = screens.iter().find(|screen| screen.column(column).is_some()) else {
        return Some(DockRefusal::UnknownColumn);
    };
    let Some(current) = screen.column(column) else { return Some(DockRefusal::UnknownColumn) };
    if current.dock.as_ref() == dock {
        return Some(DockRefusal::Unchanged);
    }
    // The implicit column is a screen's only column: it must scroll.
    if column == screen.implicit_column_id() {
        return Some(DockRefusal::LastScrollingColumn);
    }
    let next = screen.layout.setting_dock(dock, column);
    if !next.columns().iter().any(|c| c.dock.is_none()) {
        return Some(DockRefusal::LastScrollingColumn);
    }
    None
}

/// The command that makes `column` docked at `dock`'s edge and mode, or scrolling for nil (Swift
/// `LayoutModel.setColumnDock`, which emits it); the refusal instead when the change is not allowed.
pub fn set_column_dock(
    screens: &[LayoutScreen],
    column: &str,
    dock: Option<&DockColumn>,
) -> Result<SetColumnDock, DockRefusal> {
    if let Some(refusal) = validate_dock(screens, dock, column) {
        return Err(refusal);
    }
    let any_pane = screens
        .iter()
        .find_map(|screen| {
            screen.layout.columns().iter().find(|c| c.id == column)?.panes.first().cloned()
        })
        .ok_or(DockRefusal::UnknownColumn)?;
    Ok(SetColumnDock { column: column.to_owned(), any_pane, dock: dock.cloned() })
}

#[cfg(test)]
#[path = "dock_model_tests.rs"]
mod tests;
