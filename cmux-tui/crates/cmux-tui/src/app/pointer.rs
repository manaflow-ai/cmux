//! Pointer interaction types: drag state (tabs, scrollbars, pane resize),
//! PTY mouse press and release results, terminal pointer admission, and the
//! per-overlay pointer regions. The rendered pointer route and the deferred
//! input queue live in the child modules.

use cmux_tui_core::{PaneId, Rect, SplitId, SurfaceId, VirtualRect, WorkspaceId};
use crossterm::event::{KeyModifiers, MouseButton};
use ghostty_vt::{Scrollbar, TerminalPointerSemanticSnapshot};

use crate::app::layout::{PaneEdge, RailKind};
use crate::pty_input::PtyInputBytes;
use crate::session::SurfaceHandle;

pub(super) mod deferred;
pub(super) mod route;

#[derive(Debug, Clone, Copy)]
pub struct TabDragView {
    pub surface: SurfaceId,
    pub target: Option<(PaneId, usize)>,
}

#[derive(Clone, Copy)]
pub(super) struct ScrollbarDragState {
    pub(super) track: Rect,
    pub(super) anchor_y: u16,
    pub(super) anchor_offset: u64,
    pub(super) position_y: u16,
    pub(super) scrollbar: Scrollbar,
}

#[derive(Debug, Clone, Copy)]
pub(super) enum PaneResizeDragTarget {
    ViewportColumn {
        pane: PaneId,
        edge: PaneEdge,
        column_x: u64,
        viewport_x: u16,
        viewport_width: u16,
        /// Frozen at mouse-down so layout reveal motion cannot shift the drag origin.
        viewport_offset: u64,
    },
    Split {
        split: SplitId,
        edge: PaneEdge,
        area: VirtualRect,
        minimum_ratio: f32,
        maximum_ratio: f32,
        viewport_x: u16,
        /// Frozen at mouse-down so layout reveal motion cannot shift the drag origin.
        viewport_offset: u64,
    },
}

/// Mouse drag in progress.
pub(super) enum Drag {
    /// Left press on a tab chip; becomes `Tab` after moving cells.
    TabArm { surface: SurfaceId, at: (u16, u16) },
    /// Tab drag with the current drop target.
    Tab { surface: SurfaceId, target: Option<(PaneId, usize)> },
    /// Workspace reorder gesture armed after the entry activated on press.
    WorkspaceArm { workspace: WorkspaceId, at: (u16, u16) },
    /// Workspace drag with the current insertion index.
    Workspace { workspace: WorkspaceId, target: Option<usize> },
    /// Text selection inside a pane's content rect.
    Select { content: Rect, source_x: u16, auto_scroll: Option<i8>, col: u16 },
    /// Text selection inside the final-row status message.
    StatusMessage { rect: Rect },
    /// Browser mouse drag inside a pane's content rect.
    Browser { surface: SurfaceId, content: Rect, position: (u16, u16), frame_seq: u64 },
    /// Mouse reporting owned by the PTY application in this pane.
    PtyMouse {
        surface: SurfaceId,
        handle: Option<SurfaceHandle>,
        reservation_id: u64,
        release_bytes: PtyInputBytes,
        semantics: Option<TerminalPointerSemanticSnapshot>,
        content: Rect,
        button: MouseButton,
        position: (u16, u16),
        modifiers: KeyModifiers,
    },
    /// Scrollbar thumb drag.
    Scrollbar {
        surface: SurfaceId,
        track: Rect,
        anchor_y: u16,
        anchor_offset: u64,
        position_y: u16,
        scrollbar: Scrollbar,
    },
    /// Horizontal pane-column scrollbar drag.
    HorizontalScrollbar { track: Rect, anchor_x: u16, anchor_offset: u64 },
    /// Workspace viewport scrollbar thumb drag.
    WorkspaceScrollbar {
        track: Rect,
        total_rows: usize,
        visible_rows: usize,
        anchor_y: u16,
        anchor_offset: usize,
    },
    /// Independent rail width override drag.
    RailResize(RailKind),
    /// Pane split resize drag.
    ResizeSplit { horizontal: Option<PaneResizeDragTarget>, vertical: Option<PaneResizeDragTarget> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum PtyMousePressResult {
    NotOwned,
    Consumed,
    Started,
}

#[derive(Debug, Clone, Copy)]
pub(super) struct PtyInputForwardResult {
    pub(super) owned: bool,
    pub(super) accepted: bool,
    pub(super) reservation_id: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct TerminalPointerAdmission {
    pub(super) surface: SurfaceId,
    pub(super) semantics: TerminalPointerSemanticSnapshot,
    pub(super) encoding: TerminalPointerEncoding,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum TerminalPointerEncoding {
    None,
    Single(PtyInputBytes),
    PressPair { press: PtyInputBytes, release: PtyInputBytes },
}

pub(super) enum TerminalPointerAdmissionResult {
    NotTerminal,
    Ready(TerminalPointerAdmission),
    Contended,
    Rejected,
}

pub(super) enum PtyMouseReleaseCapture {
    Bytes(PtyInputBytes),
    NotReported,
    Failed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum PairingPointerRegion {
    Approve,
    Deny,
    Dialog,
    Outside,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum PromptPointerRegion {
    Input,
    Clear,
    Ok,
    Cancel,
    Dialog,
    Outside,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum MenuPointerRegion {
    Item { depth: usize, index: usize },
    Scrollbar { depth: usize },
    Chrome { depth: usize },
    Outside,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum PanePointerRegion {
    BrowserCell {
        column: u16,
        row: u16,
        content_generation: Option<u64>,
    },
    TerminalCell {
        column: u16,
        row: u16,
        semantics: Option<TerminalPointerSemanticSnapshot>,
        content_generation: Option<u64>,
    },
    ContentPadding,
    Chrome,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PaneContentGeneration {
    Terminal(u64),
    Browser(u64),
}
