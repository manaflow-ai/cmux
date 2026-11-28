//! The pane drop zones' C ABI (`cmux_pane_drop_*`, cmux-layout-reducer `pane_drop_zones`): where a dragged tab
//! drops on a screen and what its preview fills. The app builds one screen handle per layout from JSON
//! ([`pane_drop_zones::Screen`]) and asks per pointer move with numbers only: no JSON, no allocation.
//!
//! Targets cross as [`CmuxPaneDropTarget`]: `kind` 0 none, 1 a pane (`index` in the screen's panes, `zone` a
//! `CMUX_PANE_DROP_ZONE_*`), 2 a new column (`index` in its gaps), 3 a new dock (`zone` a `CMUX_TAB_DROP_EDGE_*`).
//! A previous pane of another screen is sent with an index past the panes.
//!
//! Each query returns 1 and writes its answer, 0 when there is none, or `CMUX_LAYOUT_REDUCER_ERR_NULL` /
//! `ERR_PANIC` with nothing written.

use crate::tab_drag::{
    EDGE_BOTTOM, EDGE_LEFT, EDGE_RIGHT, EDGE_TOP, ZONE_BOTTOM, ZONE_CENTER, ZONE_LEFT, ZONE_RIGHT,
    ZONE_TOP,
};
use crate::{ERR_NULL, ERR_PANIC, input};
use cmux_layout_reducer::pane_drop_zones::{self, Edge, Rect, Screen, Target, Zone};
use std::panic::{AssertUnwindSafe, catch_unwind};

pub const KIND_NONE: u8 = 0;
pub const KIND_PANE: u8 = 1;
pub const KIND_COLUMN: u8 = 2;
pub const KIND_DOCK: u8 = 3;

/// A drop target (`CmuxPaneDropTarget`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CmuxPaneDropTarget {
    pub index: u32,
    pub kind: u8,
    pub zone: u8,
    pub reserved: [u8; 2],
}

/// A flipped rect (`CmuxPaneDropRect`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxPaneDropRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// What a target's preview fills in view space (`CmuxPaneDropRects`); `body` counts only when `has_body` is 1.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxPaneDropRects {
    pub highlight: CmuxPaneDropRect,
    pub region: CmuxPaneDropRect,
    pub body: CmuxPaneDropRect,
    pub has_body: u8,
    pub reserved: [u8; 7],
}

impl From<Rect> for CmuxPaneDropRect {
    fn from(rect: Rect) -> Self {
        Self { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
    }
}

impl From<CmuxPaneDropRect> for Rect {
    fn from(rect: CmuxPaneDropRect) -> Self {
        Rect::new(rect.x, rect.y, rect.width, rect.height)
    }
}

fn zone_from(code: u8) -> Option<Zone> {
    Some(match code {
        ZONE_LEFT => Zone::Left,
        ZONE_RIGHT => Zone::Right,
        ZONE_TOP => Zone::Top,
        ZONE_BOTTOM => Zone::Bottom,
        ZONE_CENTER => Zone::Center,
        _ => return None,
    })
}

fn zone_code(zone: Zone) -> u8 {
    match zone {
        Zone::Left => ZONE_LEFT,
        Zone::Right => ZONE_RIGHT,
        Zone::Top => ZONE_TOP,
        Zone::Bottom => ZONE_BOTTOM,
        Zone::Center => ZONE_CENTER,
    }
}

fn edge_from(code: u8) -> Option<Edge> {
    Some(match code {
        EDGE_LEFT => Edge::Left,
        EDGE_RIGHT => Edge::Right,
        EDGE_TOP => Edge::Top,
        EDGE_BOTTOM => Edge::Bottom,
        _ => return None,
    })
}

fn edge_code(edge: Edge) -> u8 {
    match edge {
        Edge::Left => EDGE_LEFT,
        Edge::Right => EDGE_RIGHT,
        Edge::Top => EDGE_TOP,
        Edge::Bottom => EDGE_BOTTOM,
    }
}

impl CmuxPaneDropTarget {
    /// The target this names; `None` for kind 0 or an unknown kind or zone.
    pub fn target(&self) -> Option<Target> {
        let index = self.index as usize;
        match self.kind {
            KIND_PANE => Some(Target::Pane { pane: index, zone: zone_from(self.zone)? }),
            KIND_COLUMN => Some(Target::NewColumn { gap: index }),
            KIND_DOCK => Some(Target::NewDock { edge: edge_from(self.zone)? }),
            _ => None,
        }
    }
}

impl From<Target> for CmuxPaneDropTarget {
    fn from(target: Target) -> Self {
        let (index, kind, zone) = match target {
            Target::Pane { pane, zone } => (pane, KIND_PANE, zone_code(zone)),
            Target::NewColumn { gap } => (gap, KIND_COLUMN, ZONE_CENTER),
            Target::NewDock { edge } => (0, KIND_DOCK, edge_code(edge)),
        };
        Self { index: u32::try_from(index).unwrap_or(u32::MAX), kind, zone, reserved: [0; 2] }
    }
}

/// One screen's drop geometry (`CmuxPaneDropScreen`, opaque).
pub struct PaneDropScreen {
    screen: Screen,
}

/// # Safety
///
/// `previous` is null or points to a readable `CmuxPaneDropTarget`.
unsafe fn previous(previous: *const CmuxPaneDropTarget) -> Option<Target> {
    // SAFETY: guaranteed by the C caller.
    unsafe { previous.as_ref() }.and_then(CmuxPaneDropTarget::target)
}

fn answer<T: Copy>(found: Option<T>, out: &mut T) -> i32 {
    match found {
        Some(value) => {
            *out = value;
            1
        }
        None => 0,
    }
}

/// A screen handle from `request` (JSON of `pane_drop_zones::Screen`), or null when it does not parse.
///
/// # Safety
///
/// `request` points to `request_len` readable bytes, or `request_len` is 0.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_pane_drop_screen_new(
    request: *const u8,
    request_len: usize,
) -> *mut PaneDropScreen {
    // SAFETY: forwarded from this function's contract.
    let Some(bytes) = (unsafe { input(request, request_len) }) else { return std::ptr::null_mut() };
    match serde_json::from_slice::<Screen>(bytes) {
        Ok(screen) => Box::into_raw(Box::new(PaneDropScreen { screen })),
        Err(_) => std::ptr::null_mut(),
    }
}

/// # Safety
///
/// `screen` is null or a pointer from `cmux_pane_drop_screen_new` not freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_pane_drop_screen_free(screen: *mut PaneDropScreen) {
    if !screen.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(screen) });
    }
}

/// The drop target under view point (`x`, `y`) with the strip scrolled to `offset`; `previous` (nullable) is
/// the target the preview shows now. 0 when the screen has no pane there.
///
/// # Safety
///
/// `screen` is a live handle, `previous` is null or readable, `out` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_pane_drop_target(
    screen: *const PaneDropScreen,
    x: f64,
    y: f64,
    offset: f64,
    previous_target: *const CmuxPaneDropTarget,
    out: *mut CmuxPaneDropTarget,
) -> i32 {
    // SAFETY: guaranteed by the C caller.
    let (Some(screen), Some(out)) = (unsafe { screen.as_ref() }, unsafe { out.as_mut() }) else {
        return ERR_NULL;
    };
    // SAFETY: forwarded from this function's contract.
    let previous = unsafe { previous(previous_target) };
    catch_unwind(AssertUnwindSafe(|| {
        answer(screen.screen.target(x, y, offset, previous).map(CmuxPaneDropTarget::from), out)
    }))
    .unwrap_or(ERR_PANIC)
}

/// The drop target under content point (`x`, `y`) (strip coordinates, no dock covers): a column gap, else a
/// pane. 0 when the screen has no pane.
///
/// # Safety
///
/// As [`cmux_pane_drop_target`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_pane_drop_target_in_content(
    screen: *const PaneDropScreen,
    x: f64,
    y: f64,
    previous_target: *const CmuxPaneDropTarget,
    out: *mut CmuxPaneDropTarget,
) -> i32 {
    // SAFETY: guaranteed by the C caller.
    let (Some(screen), Some(out)) = (unsafe { screen.as_ref() }, unsafe { out.as_mut() }) else {
        return ERR_NULL;
    };
    // SAFETY: forwarded from this function's contract.
    let previous = unsafe { previous(previous_target) };
    catch_unwind(AssertUnwindSafe(|| {
        answer(screen.screen.target_in_content(x, y, previous).map(CmuxPaneDropTarget::from), out)
    }))
    .unwrap_or(ERR_PANIC)
}

/// The new dock whose edge band holds view point (`x`, `y`) below a `top_inset` tab bar and above a
/// `bottom_inset` one; 0 for none. A previous dock of another screen is sent as null.
///
/// # Safety
///
/// As [`cmux_pane_drop_target`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_pane_drop_dock(
    screen: *const PaneDropScreen,
    x: f64,
    y: f64,
    top_inset: f64,
    bottom_inset: f64,
    previous_target: *const CmuxPaneDropTarget,
    out: *mut CmuxPaneDropTarget,
) -> i32 {
    // SAFETY: guaranteed by the C caller.
    let (Some(screen), Some(out)) = (unsafe { screen.as_ref() }, unsafe { out.as_mut() }) else {
        return ERR_NULL;
    };
    // SAFETY: forwarded from this function's contract.
    let previous = unsafe { previous(previous_target) };
    catch_unwind(AssertUnwindSafe(|| {
        let found = screen.screen.dock_target(x, y, top_inset, bottom_inset, previous);
        answer(found.map(CmuxPaneDropTarget::from), out)
    }))
    .unwrap_or(ERR_PANIC)
}

/// The rects `target`'s preview fills in view space with the strip at `offset`; 0 when it names no pane, gap
/// or edge of this screen.
///
/// # Safety
///
/// `screen` is a live handle, `target` is readable, `out` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_pane_drop_rects(
    screen: *const PaneDropScreen,
    target: *const CmuxPaneDropTarget,
    offset: f64,
    out: *mut CmuxPaneDropRects,
) -> i32 {
    // SAFETY: guaranteed by the C caller.
    let (Some(screen), Some(target), Some(out)) =
        (unsafe { screen.as_ref() }, unsafe { target.as_ref() }, unsafe { out.as_mut() })
    else {
        return ERR_NULL;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let found = target.target().and_then(|target| screen.screen.rects(target, offset));
        answer(
            found.map(|rects| CmuxPaneDropRects {
                highlight: rects.highlight.into(),
                region: rects.region.into(),
                body: rects.body.unwrap_or_default().into(),
                has_body: u8::from(rects.body.is_some()),
                reserved: [0; 7],
            }),
            out,
        )
    }))
    .unwrap_or(ERR_PANIC)
}

/// The zone of pane cell `rect` under point (`x`, `y`) by `screen`'s style, with a `header`-point tab bar on
/// top and a `footer`-point one below; `previous` is the zone the preview shows in this pane now (a
/// `CMUX_PANE_DROP_ZONE_*`, any other value for none). Writes a `CMUX_PANE_DROP_ZONE_*` and returns 1.
///
/// # Safety
///
/// `screen` is a live handle, `out` is null or writable.
#[allow(
    clippy::too_many_arguments,
    reason = "a flat C signature: the point, the cell and its bars"
)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_pane_drop_zone(
    screen: *const PaneDropScreen,
    x: f64,
    y: f64,
    rect: CmuxPaneDropRect,
    header: f64,
    footer: f64,
    previous: u8,
    out: *mut u8,
) -> i32 {
    // SAFETY: guaranteed by the C caller.
    let (Some(screen), Some(out)) = (unsafe { screen.as_ref() }, unsafe { out.as_mut() }) else {
        return ERR_NULL;
    };
    catch_unwind(AssertUnwindSafe(|| {
        let style = &screen.screen.style;
        let zone =
            pane_drop_zones::zone(x, y, &rect.into(), header, footer, style, zone_from(previous));
        *out = zone_code(zone);
        1
    }))
    .unwrap_or(ERR_PANIC)
}

/// Classic cmux's pane drop overlay for `zone` (a `CMUX_PANE_DROP_ZONE_*`) inside `body`, inset `padding`
/// (the app's 4 pt); 0 for an unknown zone.
///
/// # Safety
///
/// `out` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_pane_drop_classic_highlight(
    body: CmuxPaneDropRect,
    zone: u8,
    padding: f64,
    out: *mut CmuxPaneDropRect,
) -> i32 {
    // SAFETY: guaranteed by the C caller.
    let Some(out) = (unsafe { out.as_mut() }) else { return ERR_NULL };
    catch_unwind(AssertUnwindSafe(|| {
        let found = zone_from(zone)
            .map(|zone| pane_drop_zones::classic_pane_highlight(&body.into(), zone, padding));
        answer(found.map(CmuxPaneDropRect::from), out)
    }))
    .unwrap_or(ERR_PANIC)
}
