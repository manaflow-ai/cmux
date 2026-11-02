//! The agent cursor visibility rules' typed C ABI
//! (`cmux_agent_cursor_visibility`): one call per agent input event and per
//! frame of pane motion while a target is tracked, so no JSON, no handle and
//! no allocation. The caller numbers its ids (workspaces, panes, tabs,
//! windows) as `u32`s for the call; the rules compare ids only for identity,
//! so any numbering gives the same answer as the JSON operation
//! `agent_cursor_visibility`. `CMUX_FOCUS_NONE` is none. Variable-length
//! parts are ranges (`offset`, `count`) into the snapshot's flat arrays.

use crate::{ERR_NULL, OK};
use cmux_focus_core::agent_cursor_visibility::Rect;

pub const WINDOW_MINIMIZED: u32 = 1;
pub const WINDOW_ON_ACTIVE_SPACE: u32 = 2;
pub const WINDOW_SIDEBAR_HIDDEN: u32 = 4;

pub const PANE_HAS_FRAME: u32 = 1;
pub const PANE_HAS_CLIP: u32 = 2;
pub const PANE_HAS_STRIP: u32 = 4;
pub const PANE_HAS_PAGE: u32 = 8;
pub const PANE_HAS_SCALE: u32 = 16;

pub const KIND_VISIBLE: u32 = 0;
pub const KIND_HIDDEN: u32 = 1;
pub const KIND_NOT_DRAWN: u32 = 2;

/// A rect keyed by an id: a sidebar row (key: its workspace) or a tab chip (key: its tab).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CmuxCursorKeyedRect {
    pub key: u32,
    pub reserved: u32,
    pub rect: Rect,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CmuxCursorWindow {
    pub id: u32,
    /// `CMUX_FOCUS_NONE`: the window shows no workspace.
    pub shown_workspace: u32,
    /// `CMUX_CURSOR_WINDOW_*` bits.
    pub flags: u32,
    /// Listed workspaces: a range of `ids`.
    pub listed_offset: u32,
    pub listed_count: u32,
    /// Sidebar rows: a range of `rows`.
    pub rows_offset: u32,
    pub rows_count: u32,
    /// Measured panes: a range of `panes`.
    pub panes_offset: u32,
    pub panes_count: u32,
    pub reserved: u32,
    pub overlay: Rect,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CmuxCursorPane {
    pub id: u32,
    /// `CMUX_FOCUS_NONE`: no selected tab.
    pub selected_tab: u32,
    /// `CMUX_CURSOR_PANE_*` bits: which of the rects (and the page's scale) are present.
    pub flags: u32,
    /// Tab chips: a range of `chips`.
    pub chips_offset: u32,
    pub chips_count: u32,
    pub reserved: u32,
    pub frame: Rect,
    pub clip: Rect,
    pub strip: Rect,
    /// The selected tab's page viewport (`CMUX_CURSOR_PANE_HAS_PAGE`).
    pub viewport: Rect,
    pub zoom: f64,
    /// `CMUX_CURSOR_PANE_HAS_SCALE`; without it the scale is 1.
    pub scale: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CmuxCursorSnapshot {
    pub target: u32,
    /// The target tab's workspace; `CMUX_FOCUS_NONE`: no tab has the target id.
    pub tab_workspace: u32,
    pub tab_pane: u32,
    pub reserved: u32,
    /// Windows, front to back.
    pub windows: *const CmuxCursorWindow,
    pub windows_count: usize,
    pub ids: *const u32,
    pub ids_count: usize,
    pub rows: *const CmuxCursorKeyedRect,
    pub rows_count: usize,
    pub panes: *const CmuxCursorPane,
    pub panes_count: usize,
    pub chips: *const CmuxCursorKeyedRect,
    pub chips_count: usize,
}

/// The answer. `kind` `CMUX_CURSOR_VISIBLE`: `window`, `viewport`, `clip`,
/// `zoom`, `scale`. `CMUX_CURSOR_HIDDEN`: `window`, `anchor`, `rect`.
/// `CMUX_CURSOR_NOT_DRAWN`: `reason`. Other fields are zero.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxCursorVisibility {
    pub kind: u32,
    /// The window's id (`CmuxCursorWindow.id`).
    pub window: u32,
    /// 0 tabChip, 1 tabStrip, 2..5 columnEdge leading, trailing, top, bottom, 6 workspaceRow, 7 windowEdge.
    pub anchor: u32,
    /// 0 tabClosed, 1 notInAnyWindow, 2 minimized, 3 otherSpace.
    pub reason: u32,
    pub viewport: Rect,
    pub clip: Rect,
    pub rect: Rect,
    pub zoom: f64,
    pub scale: f64,
}

/// A stub until the rules move in the next commit: nothing draws.
///
/// # Safety
///
/// `snapshot` and `out` are null or valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_agent_cursor_visibility(
    snapshot: *const CmuxCursorSnapshot,
    out: *mut CmuxCursorVisibility,
) -> i32 {
    if snapshot.is_null() || out.is_null() {
        return ERR_NULL;
    }
    // SAFETY: `out` is non-null and writable, as the caller guarantees.
    unsafe {
        *out = CmuxCursorVisibility { kind: KIND_NOT_DRAWN, ..CmuxCursorVisibility::default() }
    };
    OK
}
