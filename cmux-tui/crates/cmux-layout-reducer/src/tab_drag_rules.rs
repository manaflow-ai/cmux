//! The tab drag's decision rules, moved out of the app's Swift (cmux NEXT
//! `TabDragOutcome.swift`, `TabDropVerdict.swift`, `TabDropResolution.swift`,
//! and the rule parts of `TabMoves.swift` and `TabDragSession+Commit.swift`).
//!
//! The app hit-tests its surfaces (sidebar, strips, layout) and sends the
//! first proposal's kind with the drag's source facts; these rules say what
//! the drag previews there and the one outcome a release commits (tab-dnd,
//! Lawrence 2026-10-04: every point shows a preview, and the drop does
//! exactly what the preview shows).

use serde::{Deserialize, Serialize};

/// A pane edge a tab drops on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}

impl Edge {
    /// The edge across the pane.
    #[must_use]
    pub fn opposite(self) -> Self {
        match self {
            Self::Left => Self::Right,
            Self::Right => Self::Left,
            Self::Top => Self::Bottom,
            Self::Bottom => Self::Top,
        }
    }
}

/// Where a surface proposes the drop lands (`TabDropKind`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DropKind {
    /// Into a tab strip at `index` (final index in the strip's display
    /// order), joining `group_id` when set.
    Strip {
        strip_id: String,
        index: i64,
        #[serde(default)]
        group_id: Option<String>,
    },
    NewSplit {
        pane_id: String,
        edge: Edge,
    },
    /// A new strip column on `screen_id` after `after_column_id`; none
    /// before the first column.
    NewColumn {
        screen_id: String,
        #[serde(default)]
        after_column_id: Option<String>,
    },
    /// A new dock on `screen_id` (`edge` "top", "bottom", ...).
    NewDock {
        screen_id: String,
        edge: String,
    },
    /// A new workspace at root `index` (negative: no slot), inside
    /// `group_id` when set.
    NewWorkspace {
        #[serde(default)]
        group_id: Option<String>,
        index: i64,
    },
    Workspace {
        id: String,
    },
}

/// What the rules need to know about the drag's source (`TabDragContext`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Context {
    /// Layout pane id of the source pane.
    pub source_pane_id: String,
    /// Tabs in the source pane, the dragged ones included.
    pub source_pane_tab_count: i64,
    pub source_workspace_id: String,
    /// Tabs in the whole source workspace, the dragged ones included.
    pub source_workspace_tab_count: i64,
    /// Tabs being dragged (1, or a group's member count).
    pub dragged_tab_count: i64,
    /// Workspaces the source window lists (1 when it shows only this one).
    #[serde(default = "one")]
    pub source_window_workspace_count: i64,
    /// The source strip and the dragged tab's (or group's first tab's) index
    /// in its display order; none for workspace drags.
    #[serde(default)]
    pub source_strip_id: Option<String>,
    #[serde(default)]
    pub source_index: Option<i64>,
    /// The tab group the dragged tab is in (none: none, or a group drag).
    #[serde(default)]
    pub source_group_id: Option<String>,
    /// The drag carries a whole tab group.
    #[serde(default)]
    pub is_group_drag: bool,
    /// The dragged tabs stay in their workspace (Home's own tab, Leo
    /// 2026-10-09): never a new workspace or a new window.
    #[serde(default)]
    pub source_stays_put: bool,
}

fn one() -> i64 {
    1
}

impl Context {
    /// Whether a strip drop at final `index` (clamped to the strip without
    /// the dragged tabs) joining `group_id` leaves the tabs where they are.
    #[must_use]
    pub fn is_own_place(&self, strip: &str, index: i64, group_id: Option<&str>) -> bool {
        let (Some(source_strip), Some(source_index)) = (&self.source_strip_id, self.source_index)
        else {
            return false;
        };
        if source_strip != strip {
            return false;
        }
        let last = self.source_pane_tab_count.saturating_sub(self.dragged_tab_count).max(0);
        let fin = index.max(0).min(last);
        fin == source_index && group_id == self.source_group_id.as_deref()
    }

    /// The drag carries every tab of its pane: the pane closes when they leave.
    #[must_use]
    pub fn empties_source_pane(&self) -> bool {
        self.dragged_tab_count >= self.source_pane_tab_count
    }

    /// The drag carries every tab of its workspace: the workspace moves with
    /// it, or closes once they land in another workspace (coordinator
    /// decision 2026-09-30).
    #[must_use]
    pub fn empties_source_workspace(&self) -> bool {
        self.dragged_tab_count >= self.source_workspace_tab_count
    }

    /// A split onto `pane` with every tab it holds: the tabs stay and the New
    /// Tab page opens on the far side (`split_behind`; #22287). Never refused.
    #[must_use]
    pub fn splits_behind(&self, pane: &str) -> bool {
        pane == self.source_pane_id && self.empties_source_pane()
    }
}

/// Why a drop target cannot take the dragged tabs (`TabDropRefusal`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "code", rename_all = "snake_case")]
pub enum Refusal {
    /// A new column before the first one: no daemon command expresses it.
    ColumnBeforeFirst,
    /// A tab group on a dock edge: groups have no dock move yet.
    GroupDock,
    /// A new workspace for a tab that stays in its workspace.
    StaysPut,
    /// The surface refused it with this localized reason.
    Surface { reason: String },
}

/// What a proposal means for this drag (`TabDropVerdict`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "verdict", rename_all = "snake_case")]
pub enum Verdict {
    /// The drop runs the proposal.
    Accept,
    /// The tabs' own place: the preview shows it, the drop changes nothing.
    Stay,
    /// Nothing highlights and the drop springs back.
    Refuse { refusal: Refusal },
}

/// A screen point (a tear-off's or a moved window's place).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// How a tab drag ends (`TabDragOutcome`): the app maps each to exactly one
/// daemon command, or to a window move.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub enum Outcome {
    Strip {
        strip_id: String,
        index: i64,
        group_id: Option<String>,
    },
    NewSplit {
        pane_id: String,
        edge: Edge,
    },
    NewColumn {
        screen_id: String,
        after_column_id: String,
    },
    NewDock {
        screen_id: String,
        edge: String,
    },
    NewWorkspace {
        group_id: Option<String>,
        index: Option<i64>,
    },
    Workspace {
        id: String,
    },
    /// Released outside every window: a new workspace in a new window.
    TearOff {
        point: Point,
    },
    /// Outside every window with all its workspace's tabs, the only
    /// workspace of its window: the window moves under the pointer.
    MoveWindow {
        point: Point,
    },
    /// Outside every window with all its workspace's tabs, whose window
    /// lists others too: the workspace moves to a new window.
    MoveWorkspaceToNewWindow {
        point: Point,
    },
    /// A sidebar gap with all its workspace's tabs: the workspace itself
    /// moves to that slot.
    MoveWorkspace {
        group_id: Option<String>,
        index: Option<i64>,
    },
    /// No valid target: spring back to the origin.
    Cancel,
}

/// What the drag shows at the pointer (`TabDropPreview`, without the
/// proposal the app keeps).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Preview {
    /// The outline sits on the proposal; the drop runs it.
    Target,
    /// The outline sits on the tabs' own place; the drop changes nothing.
    Stay,
    /// Nothing highlights (Lawrence 2026-10-05); the drop springs back.
    Refused,
    /// Outside every app window: a new window opens under the pointer.
    NewWindow,
    /// Inside a window where no surface answered (a defect).
    None,
}

/// One resolved pointer position (`TabDropResolution`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Resolution {
    pub preview: Preview,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refusal: Option<Refusal>,
    pub outcome: Outcome,
}

/// The verdict for `kind`; `accepts` is `verdict == Accept`.
#[must_use]
pub fn verdict(kind: &DropKind, context: &Context) -> Verdict {
    match kind {
        DropKind::Strip { strip_id, index, group_id } => {
            if context.is_own_place(strip_id, *index, group_id.as_deref()) {
                Verdict::Stay
            } else {
                Verdict::Accept
            }
        }
        // Every tab of the source pane on its own edge splits behind them.
        DropKind::NewSplit { .. } => Verdict::Accept,
        DropKind::NewColumn { after_column_id, .. } => match after_column_id {
            None => Verdict::Refuse { refusal: Refusal::ColumnBeforeFirst },
            Some(_) => Verdict::Accept,
        },
        DropKind::NewDock { .. } => {
            if context.is_group_drag {
                Verdict::Refuse { refusal: Refusal::GroupDock }
            } else {
                Verdict::Accept
            }
        }
        DropKind::NewWorkspace { .. } => {
            if context.source_stays_put {
                Verdict::Refuse { refusal: Refusal::StaysPut }
            } else {
                Verdict::Accept
            }
        }
        DropKind::Workspace { id } => {
            if *id == context.source_workspace_id {
                Verdict::Stay
            } else {
                Verdict::Accept
            }
        }
    }
}

/// Whether the drop runs `kind`: not its own place, not its own workspace,
/// not a column before the first, not a group on a dock, not a new
/// workspace for a tab that stays put.
#[must_use]
pub fn accepts(kind: &DropKind, context: &Context) -> bool {
    verdict(kind, context) == Verdict::Accept
}

/// Whether a rejected `kind` ends the search: the tabs' own strip place is
/// no drop target, and the surfaces behind it (the own pane, whose top edge
/// band holds the strip) must not take the drop either.
#[must_use]
pub fn blocks(kind: &DropKind, context: &Context) -> bool {
    match kind {
        DropKind::Strip { strip_id, index, group_id } => {
            context.is_own_place(strip_id, *index, group_id.as_deref())
        }
        _ => false,
    }
}

/// Index of the winning proposal: the first present accepted one, unless one
/// before it `blocks`.
#[must_use]
pub fn winner(kinds: &[Option<DropKind>], context: &Context) -> Option<usize> {
    for (index, kind) in kinds.iter().enumerate() {
        let Some(kind) = kind else { continue };
        if accepts(kind, context) {
            return Some(index);
        }
        if blocks(kind, context) {
            return None;
        }
    }
    None
}

/// The outcome for the winning proposal. `inside_window` is false when the
/// pointer is outside every app window (tear-off).
#[must_use]
pub fn outcome(
    kind: Option<&DropKind>,
    inside_window: bool,
    point: Point,
    context: &Context,
) -> Outcome {
    if !inside_window {
        // Home's tabs never leave for a new window, nor Home with them.
        if context.source_stays_put {
            return Outcome::Cancel;
        }
        if !context.empties_source_workspace() {
            return Outcome::TearOff { point };
        }
        return if context.source_window_workspace_count <= 1 {
            Outcome::MoveWindow { point }
        } else {
            Outcome::MoveWorkspaceToNewWindow { point }
        };
    }
    let Some(kind) = kind.filter(|kind| accepts(kind, context)) else {
        return Outcome::Cancel;
    };
    match kind {
        DropKind::Strip { strip_id, index, group_id } => {
            if context.is_own_place(strip_id, *index, group_id.as_deref()) {
                return Outcome::Cancel;
            }
            Outcome::Strip { strip_id: strip_id.clone(), index: *index, group_id: group_id.clone() }
        }
        DropKind::NewSplit { pane_id, edge } => {
            Outcome::NewSplit { pane_id: pane_id.clone(), edge: *edge }
        }
        DropKind::NewColumn { screen_id, after_column_id } => match after_column_id {
            Some(after) => {
                Outcome::NewColumn { screen_id: screen_id.clone(), after_column_id: after.clone() }
            }
            None => Outcome::Cancel,
        },
        DropKind::NewDock { screen_id, edge } => {
            Outcome::NewDock { screen_id: screen_id.clone(), edge: edge.clone() }
        }
        DropKind::NewWorkspace { group_id, index } => {
            let slot = (*index >= 0).then_some(*index);
            if context.empties_source_workspace() {
                Outcome::MoveWorkspace { group_id: group_id.clone(), index: slot }
            } else {
                Outcome::NewWorkspace { group_id: group_id.clone(), index: slot }
            }
        }
        DropKind::Workspace { id } => Outcome::Workspace { id: id.clone() },
    }
}

/// The preview and the outcome for the first surface that answered (`kind`,
/// none when none did). An accepted target commits its outcome; a stay, a
/// refusal or no answer commits nothing. `refused_reason`: the surface's own
/// refusal, which wins over the verdict.
#[must_use]
pub fn resolve(
    kind: Option<&DropKind>,
    refused_reason: Option<&str>,
    inside_window: bool,
    point: Point,
    context: &Context,
) -> Resolution {
    if !inside_window {
        return Resolution {
            preview: Preview::NewWindow,
            refusal: None,
            outcome: outcome(None, false, point, context),
        };
    }
    let Some(kind) = kind else {
        return Resolution { preview: Preview::None, refusal: None, outcome: Outcome::Cancel };
    };
    if let Some(reason) = refused_reason {
        return Resolution {
            preview: Preview::Refused,
            refusal: Some(Refusal::Surface { reason: reason.to_owned() }),
            outcome: Outcome::Cancel,
        };
    }
    match verdict(kind, context) {
        Verdict::Accept => Resolution {
            preview: Preview::Target,
            refusal: None,
            outcome: outcome(Some(kind), true, point, context),
        },
        Verdict::Stay => {
            Resolution { preview: Preview::Stay, refusal: None, outcome: Outcome::Cancel }
        }
        Verdict::Refuse { refusal } => Resolution {
            preview: Preview::Refused,
            refusal: Some(refusal),
            outcome: Outcome::Cancel,
        },
    }
}

/// Every tab of a pane dropped on its own `edge` (#22287): one commit puts
/// the New Tab page right of or below the pane, so for a drop there the page
/// opens on that side and the panes swap back; for left or top it opens on
/// the far side. Answers the edge the page opens on and whether they swap.
#[must_use]
pub fn split_behind(edge: Edge) -> (Edge, bool) {
    let near = matches!(edge, Edge::Right | Edge::Bottom);
    (if near { edge } else { edge.opposite() }, near)
}

/// A split's direction for an old daemon's split-then-move fallback.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SplitDirection {
    Right,
    Down,
}

/// The fallback split for a drop on `edge`: the daemon splits right or down,
/// so a left or top drop swaps the new pane with its target afterwards (the
/// app swaps only when the target still exists and is not the new pane).
#[must_use]
pub fn fallback_split(edge: Edge) -> (SplitDirection, bool) {
    let direction = match edge {
        Edge::Left | Edge::Right => SplitDirection::Right,
        Edge::Top | Edge::Bottom => SplitDirection::Down,
    };
    (direction, matches!(edge, Edge::Left | Edge::Top))
}

/// A left dock's share of the window (cx-ihyx2, Lawrence 2026-10-14: "docked
/// left columns needs to be 50% by default").
pub const LEFT_DOCK_WIDTH: f64 = 0.5;

/// A dock's width when nothing else names one.
pub const DOCK_FALLBACK_WIDTH: f64 = 0.3;

/// A new dock's width: the asked `width`, else half the window for a left
/// dock, else for a right dock the width of a new column beside the anchor
/// (`beside`, which the app measures only when asked), else 0.3. A band (top,
/// bottom) is a share of the screen height and never asks `beside`. None asks
/// the app for `beside`; `asked_beside` says it measured and found none.
#[must_use]
pub fn dock_width(
    edge: &str,
    width: Option<f64>,
    beside: Option<f64>,
    asked_beside: bool,
) -> Option<f64> {
    if let Some(width) = width {
        return Some(width);
    }
    if edge == "left" {
        return Some(LEFT_DOCK_WIDTH);
    }
    if edge == "top" || edge == "bottom" {
        return Some(DOCK_FALLBACK_WIDTH);
    }
    beside.or(asked_beside.then_some(DOCK_FALLBACK_WIDTH))
}

/// The pane a new column is anchored on: the last pane of the column it
/// follows that is not `avoiding` (the pane the drag empties, whose only tab
/// cannot leave through itself), else the first such pane of the screen.
#[must_use]
pub fn column_anchor<'a>(
    column_panes: &'a [String],
    screen_panes: &'a [String],
    avoiding: Option<&str>,
) -> Option<&'a String> {
    let free = |pane: &&String| Some(pane.as_str()) != avoiding;
    column_panes.iter().rev().find(free).or_else(|| screen_panes.iter().find(free))
}

#[cfg(test)]
#[path = "tab_drag_rules_tests.rs"]
mod tests;
