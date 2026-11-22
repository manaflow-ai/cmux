//! Frame layout model: hit targets, focus targets, rail and sidebar layout,
//! pane areas with their viewport clips and size leases, and omnibar hits.
//! The renderer writes these each frame and the pointer and keyboard paths
//! read them back.

use std::collections::HashMap;

use cmux_tui_core::{FrontendFocusTarget, PaneId, Rect, ScreenId, SurfaceId, WorkspaceId};
use ghostty_vt::Scrollbar;

use crate::config::Action;
use crate::machine::{MachineKey, WorkspaceCreationMode};
use crate::session::tree::PaneView;
use crate::sidebar_projection::{ProjectionBranch, ProjectionTarget};

/// A clickable region of the current frame. The renderers rebuild the hit
/// map every draw, so hit-testing always matches what is on screen.
/// Left-click performs the action; right-click opens the matching context
/// menu where one exists (sidebar rows and divider, screens, panes).
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Hit {
    Machine {
        index: usize,
        key: MachineKey,
    },
    NewVm,
    ConnectMachine,
    /// Sidebar workspace entry.
    Workspace {
        index: usize,
        id: WorkspaceId,
    },
    /// A tab shown in the native detail column for the selected workspace.
    SidebarTab {
        workspace: usize,
        screen: usize,
        pane: PaneId,
        index: usize,
        surface: SurfaceId,
    },
    /// A row in a configurable multi-level native projection.
    ProjectionRow {
        view: usize,
        row: usize,
        target: ProjectionTarget,
    },
    ProjectionToggle {
        view: usize,
        branch: ProjectionBranch,
    },
    SidebarAction {
        view: usize,
        action: SidebarActionTarget,
    },
    RecoverableWorkspace {
        index: usize,
    },
    CreateWorkspace {
        mode: Option<WorkspaceCreationMode>,
    },
    /// A visible row in the built-in file browser.
    SidebarFile {
        index: usize,
    },
    /// The active filter editor in the built-in files sidebar footer.
    SidebarFilterInput,
    /// Status-bar screen entry.
    ScreenEntry {
        index: usize,
        id: ScreenId,
    },
    /// Visible status text on the final row.
    StatusMessage,
    /// Visible copy control next to the status text.
    CopyStatusMessage,
    NewScreen,
    /// Pane tab-bar entry.
    Tab {
        pane: PaneId,
        index: usize,
    },
    NewTab {
        pane: PaneId,
    },
    Clients {
        surface: SurfaceId,
    },
    /// A pane's scrollbar column (click/drag jumps the viewport).
    Scrollbar {
        surface: SurfaceId,
        track: Rect,
        scrollbar: Scrollbar,
    },
    /// Client-local horizontal pane-column viewport.
    HorizontalScrollbar {
        track: Rect,
    },
    /// The workspace rail's row viewport scrollbar.
    WorkspaceScrollbar {
        track: Rect,
        total_rows: usize,
        visible_rows: usize,
    },
    /// The one-row top pad of a rail: the pointer entrypoint for focusing
    /// the rail without activating one of its rows.
    RailPad(RailKind),
    /// A rail's right border.
    RailResize(RailKind),
    /// Pane border resize handle.
    PaneResize {
        horizontal: Option<(PaneId, PaneEdge)>,
        vertical: Option<(PaneId, PaneEdge)>,
    },
    /// Scroll a pane's tab bar left/right (overflow arrows, wheel).
    TabScroll {
        pane: PaneId,
        delta: isize,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SidebarActionTarget {
    Run(Action),
    CreateWorkspace(Option<WorkspaceCreationMode>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SidebarActionRow {
    pub label: String,
    pub target: SidebarActionTarget,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RailKind {
    Machine,
    Workspace,
    Tabs,
    Projection(usize),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SidebarTabTarget {
    pub workspace: usize,
    pub screen: usize,
    pub pane: PaneId,
    pub index: usize,
    pub surface: SurfaceId,
    pub name: String,
    pub subtitle: String,
    pub active: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum FocusTarget {
    #[default]
    Pane,
    MachineRail,
    WorkspaceRail,
    TabsRail,
    ProjectionRail(usize),
}

impl FocusTarget {
    pub(super) fn frontend_journal_target(self) -> FrontendFocusTarget {
        match self {
            Self::Pane => FrontendFocusTarget::Pane,
            Self::MachineRail => FrontendFocusTarget::MachineRail,
            Self::WorkspaceRail => FrontendFocusTarget::WorkspaceRail,
            Self::TabsRail => FrontendFocusTarget::TabsRail,
            Self::ProjectionRail(_) => FrontendFocusTarget::ProjectionRail,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RailPlacement {
    pub kind: RailKind,
    pub view_index: usize,
    pub rect: Rect,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SidebarLayout {
    pub machine: Option<Rect>,
    pub workspace: Option<Rect>,
    pub tabs: Option<Rect>,
    pub ordered: Vec<RailPlacement>,
    pub content: Rect,
}

impl SidebarLayout {
    pub fn total_width(&self) -> u16 {
        self.content.x
    }

    pub fn rail(&self, kind: RailKind) -> Option<Rect> {
        match kind {
            RailKind::Machine => self.machine,
            RailKind::Workspace => self.workspace,
            RailKind::Tabs => self.tabs,
            RailKind::Projection(_) => self
                .ordered
                .iter()
                .find(|placement| placement.kind == kind)
                .map(|placement| placement.rect),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaneEdge {
    Left,
    Right,
    Top,
    Bottom,
}

/// One pane's screen real estate for the current frame. Every pane draws
/// a border box in its rect; the top border row doubles as the tab bar
/// and the scrollbar is either inside the box or on the right border.
/// `content` is the terminal area inside the box. A short rect reserves
/// its first row for the tab bar and hides terminal content.
#[derive(Debug, Clone, Copy)]
pub struct PaneArea {
    pub pane: PaneId,
    pub surface: SurfaceId,
    pub rect: Rect,
    pub bar: Option<Rect>,
    pub omnibar: Option<Rect>,
    pub content: Rect,
    /// Scrollbar track (inside the box or on the right border).
    pub track: Option<Rect>,
    /// Horizontal crop applied by a screen viewport.
    pub viewport: Option<PaneViewportClip>,
}

#[derive(Debug, Clone, Copy)]
pub struct PaneViewportClip {
    /// First logical pane column represented by `rect`.
    pub rect_source_x: u16,
    pub full_rect_width: u16,
    /// First logical browser-toolbar column represented by `omnibar`.
    pub omnibar_source_x: u16,
    pub full_omnibar_width: u16,
    /// First logical terminal/browser-content column represented by `content`.
    pub content_source_x: u16,
    pub full_content_width: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct PaneSizeLease {
    pub(super) pane: PaneId,
    pub(super) surface: SurfaceId,
    pub(super) content_size: (u16, u16),
}

pub(super) fn first_pane_by_id(panes: &[PaneView]) -> HashMap<PaneId, &PaneView> {
    let mut index = HashMap::with_capacity(panes.len());
    for pane in panes {
        index.entry(pane.id).or_insert(pane);
    }
    index
}

impl PaneArea {
    pub(crate) fn logical_rect(&self) -> Rect {
        Rect {
            width: self.viewport.map_or(self.rect.width, |clip| clip.full_rect_width),
            ..self.rect
        }
    }

    pub(crate) fn content_size(&self) -> (u16, u16) {
        (
            self.viewport.map_or(self.content.width, |clip| clip.full_content_width),
            self.content.height,
        )
    }

    pub(crate) fn content_source_x(&self) -> u16 {
        self.viewport.map_or(0, |clip| clip.content_source_x)
    }

    pub(crate) fn omnibar_source_x(&self) -> u16 {
        self.viewport.map_or(0, |clip| clip.omnibar_source_x)
    }

    pub(crate) fn full_omnibar_width(&self) -> u16 {
        self.viewport.map_or_else(
            || self.omnibar.map_or(0, |rect| rect.width),
            |clip| clip.full_omnibar_width,
        )
    }

    pub(crate) fn logical_content_rect(&self) -> Rect {
        Rect { width: self.content_size().0, ..self.content }
    }

    pub(crate) fn logical_content_point(&self, x: u16, y: u16) -> (u16, u16) {
        let source_x = self.content_source_x();
        let logical_x = if x >= self.content.x {
            self.content.x.saturating_add(source_x).saturating_add(x - self.content.x)
        } else {
            self.content.x.saturating_add(source_x).saturating_sub(self.content.x - x)
        };
        (logical_x, y)
    }

    pub(crate) fn has_left_edge(&self) -> bool {
        self.viewport.is_none_or(|clip| clip.rect_source_x == 0)
    }

    pub(crate) fn has_right_edge(&self) -> bool {
        self.viewport.is_none_or(|clip| {
            clip.rect_source_x.saturating_add(self.rect.width) >= clip.full_rect_width
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OmnibarHit {
    Back,
    Forward,
    Reload,
    Edit,
}
