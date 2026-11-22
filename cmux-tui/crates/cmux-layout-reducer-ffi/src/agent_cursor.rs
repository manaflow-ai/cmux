//! The agent cursor visibility rules' typed C ABI
//! (`cmux_agent_cursor_visibility`): one call per agent input event and per
//! frame of pane motion while a target is tracked, so no JSON, no handle and
//! no allocation. The caller numbers its ids (workspaces, panes, tabs,
//! windows) as `u32`s for the call; the rules compare ids only for identity,
//! so any numbering gives the same answer as the JSON operation
//! `agent_cursor_visibility`. `CMUX_FOCUS_NONE` is none. Variable-length
//! parts are ranges (`offset`, `count`) into the snapshot's flat arrays.

use crate::focus::NONE;
use crate::{ERR_INVALID, ERR_NULL, ERR_PANIC, OK};
use cmux_focus_core::agent_cursor_visibility::{
    Anchor, Edge, NotDrawnReason, Outcome, Page, PaneFacts, Rect, SnapshotView, WindowFacts,
    resolve_view,
};
use std::panic::{AssertUnwindSafe, catch_unwind};

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

pub const ANCHOR_TAB_CHIP: u32 = 0;
pub const ANCHOR_TAB_STRIP: u32 = 1;
pub const ANCHOR_COLUMN_EDGE_LEADING: u32 = 2;
pub const ANCHOR_COLUMN_EDGE_TRAILING: u32 = 3;
pub const ANCHOR_COLUMN_EDGE_TOP: u32 = 4;
pub const ANCHOR_COLUMN_EDGE_BOTTOM: u32 = 5;
pub const ANCHOR_WORKSPACE_ROW: u32 = 6;
pub const ANCHOR_WINDOW_EDGE: u32 = 7;

pub const REASON_TAB_CLOSED: u32 = 0;
pub const REASON_NOT_IN_ANY_WINDOW: u32 = 1;
pub const REASON_MINIMIZED: u32 = 2;
pub const REASON_OTHER_SPACE: u32 = 3;

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
    /// `ANCHOR_*`.
    pub anchor: u32,
    /// `REASON_*`.
    pub reason: u32,
    pub viewport: Rect,
    pub clip: Rect,
    pub rect: Rect,
    pub zoom: f64,
    pub scale: f64,
}

/// `ptr` points to `count` readable items, or `count` is 0.
unsafe fn items<'a, T>(ptr: *const T, count: usize) -> Option<&'a [T]> {
    if count == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: guaranteed by the C caller.
    Some(unsafe { std::slice::from_raw_parts(ptr, count) })
}

/// The range `offset..offset + count` of `all`, when it lies inside it.
fn range<T>(all: &[T], offset: u32, count: u32) -> Option<&[T]> {
    let start = usize::try_from(offset).ok()?;
    all.get(start..start.checked_add(usize::try_from(count).ok()?)?)
}

fn present(id: u32) -> Option<u32> {
    (id != NONE).then_some(id)
}

/// The caller's arrays, every range checked once before the rules read them.
struct Typed<'a> {
    snapshot: &'a CmuxCursorSnapshot,
    windows: &'a [CmuxCursorWindow],
    ids: &'a [u32],
    rows: &'a [CmuxCursorKeyedRect],
    panes: &'a [CmuxCursorPane],
    chips: &'a [CmuxCursorKeyedRect],
}

impl<'a> Typed<'a> {
    /// # Safety
    ///
    /// Every pointer of `snapshot` points to its count of readable items (or the count is 0).
    unsafe fn from_snapshot(snapshot: &'a CmuxCursorSnapshot) -> Option<Typed<'a>> {
        let typed = unsafe {
            Typed {
                snapshot,
                windows: items(snapshot.windows, snapshot.windows_count)?,
                ids: items(snapshot.ids, snapshot.ids_count)?,
                rows: items(snapshot.rows, snapshot.rows_count)?,
                panes: items(snapshot.panes, snapshot.panes_count)?,
                chips: items(snapshot.chips, snapshot.chips_count)?,
            }
        };
        for window in typed.windows {
            range(typed.ids, window.listed_offset, window.listed_count)?;
            range(typed.rows, window.rows_offset, window.rows_count)?;
            for pane in range(typed.panes, window.panes_offset, window.panes_count)? {
                range(typed.chips, pane.chips_offset, pane.chips_count)?;
            }
        }
        Some(typed)
    }

    fn window_record(&self, window: usize) -> Option<&'a CmuxCursorWindow> {
        let windows: &'a [CmuxCursorWindow] = self.windows;
        windows.get(window)
    }
}

fn rect_if(flags: u32, bit: u32, rect: Rect) -> Option<Rect> {
    (flags & bit != 0).then_some(rect)
}

impl SnapshotView for Typed<'_> {
    type Id = u32;

    fn tab(&self) -> Option<(u32, u32)> {
        present(self.snapshot.tab_workspace).map(|workspace| (workspace, self.snapshot.tab_pane))
    }

    fn window_count(&self) -> usize {
        self.windows.len()
    }

    fn window(&self, window: usize) -> Option<WindowFacts<u32>> {
        let record = self.window_record(window)?;
        Some(WindowFacts {
            minimized: record.flags & WINDOW_MINIMIZED != 0,
            on_active_space: record.flags & WINDOW_ON_ACTIVE_SPACE != 0,
            overlay: record.overlay,
            shown_workspace: present(record.shown_workspace),
            sidebar_hidden: record.flags & WINDOW_SIDEBAR_HIDDEN != 0,
        })
    }

    fn lists(&self, window: usize, workspace: u32) -> bool {
        self.window_record(window)
            .and_then(|record| range(self.ids, record.listed_offset, record.listed_count))
            .is_some_and(|listed| listed.contains(&workspace))
    }

    fn sidebar_row(&self, window: usize, workspace: u32) -> Option<Rect> {
        let record = self.window_record(window)?;
        range(self.rows, record.rows_offset, record.rows_count)?
            .iter()
            .find(|row| row.key == workspace)
            .map(|row| row.rect)
    }

    fn pane(&self, window: usize, pane: u32) -> Option<(usize, PaneFacts<u32>)> {
        let record = self.window_record(window)?;
        let panes = range(self.panes, record.panes_offset, record.panes_count)?;
        let (index, found) =
            panes.iter().enumerate().find(|(_, candidate)| candidate.id == pane)?;
        // A handle into all panes, so `chip` reads the pane without the window.
        let handle = usize::try_from(record.panes_offset).ok()?.checked_add(index)?;
        let page = (found.flags & PANE_HAS_PAGE != 0).then_some(Page {
            viewport: found.viewport,
            zoom: found.zoom,
            scale: (found.flags & PANE_HAS_SCALE != 0).then_some(found.scale),
        });
        Some((
            handle,
            PaneFacts {
                frame: rect_if(found.flags, PANE_HAS_FRAME, found.frame),
                clip: rect_if(found.flags, PANE_HAS_CLIP, found.clip),
                selected_tab: present(found.selected_tab),
                strip: rect_if(found.flags, PANE_HAS_STRIP, found.strip),
                page,
            },
        ))
    }

    fn chip(&self, _window: usize, pane: usize, tab: u32) -> Option<Rect> {
        let record = self.panes.get(pane)?;
        range(self.chips, record.chips_offset, record.chips_count)?
            .iter()
            .find(|chip| chip.key == tab)
            .map(|chip| chip.rect)
    }
}

/// The anchor's wire number (the header's list).
pub fn anchor_number(anchor: Anchor) -> u32 {
    match anchor {
        Anchor::TabChip => ANCHOR_TAB_CHIP,
        Anchor::TabStrip => ANCHOR_TAB_STRIP,
        Anchor::ColumnEdge(Edge::Leading) => ANCHOR_COLUMN_EDGE_LEADING,
        Anchor::ColumnEdge(Edge::Trailing) => ANCHOR_COLUMN_EDGE_TRAILING,
        Anchor::ColumnEdge(Edge::Top) => ANCHOR_COLUMN_EDGE_TOP,
        Anchor::ColumnEdge(Edge::Bottom) => ANCHOR_COLUMN_EDGE_BOTTOM,
        Anchor::WorkspaceRow => ANCHOR_WORKSPACE_ROW,
        Anchor::WindowEdge => ANCHOR_WINDOW_EDGE,
    }
}

/// The reason's wire number (the header's list).
pub fn reason_number(reason: NotDrawnReason) -> u32 {
    match reason {
        NotDrawnReason::TabClosed => REASON_TAB_CLOSED,
        NotDrawnReason::NotInAnyWindow => REASON_NOT_IN_ANY_WINDOW,
        NotDrawnReason::Minimized => REASON_MINIMIZED,
        NotDrawnReason::OtherSpace => REASON_OTHER_SPACE,
    }
}

/// The answer for `outcome`; None when it names a window past the list (the
/// rules name only windows they read, so never).
fn answer(typed: &Typed<'_>, outcome: Outcome) -> Option<CmuxCursorVisibility> {
    let window_id = |window: usize| typed.windows.get(window).map(|record| record.id);
    Some(match outcome {
        Outcome::Visible { window, viewport, clip, zoom, scale } => CmuxCursorVisibility {
            kind: KIND_VISIBLE,
            window: window_id(window)?,
            viewport,
            clip,
            zoom,
            scale,
            ..CmuxCursorVisibility::default()
        },
        Outcome::Hidden { window, anchor, rect } => CmuxCursorVisibility {
            kind: KIND_HIDDEN,
            window: window_id(window)?,
            anchor: anchor_number(anchor),
            rect,
            ..CmuxCursorVisibility::default()
        },
        Outcome::NotDrawn { reason } => CmuxCursorVisibility {
            kind: KIND_NOT_DRAWN,
            reason: reason_number(reason),
            ..CmuxCursorVisibility::default()
        },
    })
}

/// Where the agent cursor for `snapshot.target` draws: writes `out` and
/// returns `CMUX_LAYOUT_REDUCER_OK`; `ERR_NULL` for a null pointer (or a
/// null array with a nonzero count), `ERR_INVALID` for a range outside its
/// array, `ERR_PANIC` for a panic. `out` is written only on OK.
///
/// # Safety
///
/// `snapshot` and `out` are null or valid; every array of `snapshot` points
/// to its count of readable items (or its count is 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_agent_cursor_visibility(
    snapshot: *const CmuxCursorSnapshot,
    out: *mut CmuxCursorVisibility,
) -> i32 {
    if snapshot.is_null() || out.is_null() {
        return ERR_NULL;
    }
    // SAFETY: non-null and valid, as the caller guarantees.
    let snapshot = unsafe { &*snapshot };
    let result = catch_unwind(AssertUnwindSafe(|| {
        let has_null = (snapshot.windows.is_null() && snapshot.windows_count != 0)
            || (snapshot.ids.is_null() && snapshot.ids_count != 0)
            || (snapshot.rows.is_null() && snapshot.rows_count != 0)
            || (snapshot.panes.is_null() && snapshot.panes_count != 0)
            || (snapshot.chips.is_null() && snapshot.chips_count != 0);
        if has_null {
            return Err(ERR_NULL);
        }
        // SAFETY: every array points to its count of items (checked non-null above).
        let typed = unsafe { Typed::from_snapshot(snapshot) }.ok_or(ERR_INVALID)?;
        answer(&typed, resolve_view(snapshot.target, &typed)).ok_or(ERR_INVALID)
    }));
    match result {
        Ok(Ok(visibility)) => {
            // SAFETY: `out` is non-null and writable, as the caller guarantees.
            unsafe { *out = visibility };
            OK
        }
        Ok(Err(code)) => code,
        Err(_) => ERR_PANIC,
    }
}
