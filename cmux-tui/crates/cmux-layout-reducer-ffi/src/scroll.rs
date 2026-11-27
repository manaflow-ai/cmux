//! The column scroll reducer's C ABI (`cmux_scroll_*`,
//! cmux-layout-reducer `scroll`): one handle per scrolling strip (a columns
//! screen, a column's rows or a scroll area) owns the reducer state. Per
//! scroll event and per frame: typed structs in, a typed reply out, no JSON.
//! A call on a handle allocates nothing in steady state (the handle reuses the
//! replaced strip and its snap buffers); a `cmux_scroll_clone` copies them.
//!
//! The spring stays in the caller's memory (the view steps it each display
//! frame through `cmux_motion_step`): every event call reads it from and
//! writes it back to the `CmuxScrollSpring` it gets.
//!
//! Ids are UTF-8 (or any) bytes: in a request, `CmuxScrollStr` ranges into
//! the strip's `bytes`; in a reply, a pointer and a length into the handle's
//! id table, valid until the next call on the same handle. The handle keeps
//! each id it has seen as a number and forgets those no state refers to.

use cmux_layout_reducer::scroll::{
    Axis, CenterFocusedColumn, ColumnFocusSource, ColumnScrollEffects, ColumnScrollEvent,
    ColumnScrollState, Rect, RowScroll, ScrollAreaScroll, Spring, StripPane,
};
use std::collections::{HashMap, HashSet};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// An absent string.
pub const NONE: u32 = u32::MAX;

pub const KIND_COLUMNS: u8 = 0;
pub const KIND_ROWS: u8 = 1;
pub const KIND_AREA: u8 = 2;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CmuxScrollStr {
    pub offset: u32,
    pub len: u32,
}

impl CmuxScrollStr {
    pub const ABSENT: CmuxScrollStr = CmuxScrollStr { offset: NONE, len: 0 };
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxScrollRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CmuxScrollSpring {
    pub value: f64,
    pub velocity: f64,
    pub target: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CmuxScrollPane {
    pub id: CmuxScrollStr,
    pub frame: CmuxScrollRect,
    pub has_frame: u8,
    pub listed: u8,
    pub reserved: [u8; 6],
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CmuxScrollColumn {
    pub id: CmuxScrollStr,
    pub frame: CmuxScrollRect,
    pub pane_start: u32,
    pub pane_count: u32,
}

#[repr(C)]
pub struct CmuxScrollStrip {
    pub bytes: *const u8,
    pub columns: *const CmuxScrollColumn,
    pub panes: *const CmuxScrollPane,
    pub bytes_len: u32,
    pub column_count: u32,
    pub pane_count: u32,
    pub axis: u8,
    pub reserved: [u8; 3],
    pub viewport_width: f64,
    pub content_width: f64,
    pub gap: f64,
    pub leading_cover: f64,
    pub trailing_cover: f64,
    /// Rows: the stack frame's min y. Scroll area: the window's min x.
    pub origin: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CmuxScrollSync {
    /// Ranges into the strip's bytes.
    pub focused: CmuxScrollStr,
    pub anchor: CmuxScrollStr,
    pub source: u8,
    pub animated: u8,
    pub reveals: u8,
    pub reserved: [u8; 5],
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CmuxScrollEffects {
    pub ok: u8,
    pub needs_frames: u8,
    pub report_on_settle: u8,
    pub snapped: u8,
    pub has_focus: u8,
    pub reserved: [u8; 3],
    pub focus: *const u8,
    pub focus_len: usize,
}

impl CmuxScrollEffects {
    const FAILED: CmuxScrollEffects = CmuxScrollEffects {
        ok: 0,
        needs_frames: 0,
        report_on_settle: 0,
        snapped: 0,
        has_focus: 0,
        reserved: [0; 3],
        focus: std::ptr::null(),
        focus_len: 0,
    };
}

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CmuxScrollStatus {
    pub ok: u8,
    pub gesture_active: u8,
    pub reveal_deferred: u8,
    pub has_restore: u8,
    pub has_strip: u8,
    pub has_focused_pane: u8,
    pub mode: u8,
    pub reserved: u8,
    pub gesture_raw: f64,
    pub focused_pane: *const u8,
    pub focused_pane_len: usize,
}

/// The ids a handle has seen, as numbers. Numbers are never reused.
#[derive(Clone, Default)]
struct Ids {
    by_name: HashMap<Box<[u8]>, u64>,
    names: HashMap<u64, Box<[u8]>>,
    next: u64,
}

impl Ids {
    fn intern(&mut self, name: &[u8]) -> u64 {
        if let Some(id) = self.by_name.get(name) {
            return *id;
        }
        let id = self.next;
        self.next += 1;
        self.by_name.insert(name.into(), id);
        self.names.insert(id, name.into());
        id
    }

    fn lookup(&self, name: &[u8]) -> Option<u64> {
        self.by_name.get(name).copied()
    }

    fn name(&self, id: u64) -> Option<&[u8]> {
        self.names.get(&id).map(|name| &name[..])
    }

    /// Forgets the ids `live` does not hold.
    fn retain(&mut self, live: &HashSet<u64>) {
        self.names.retain(|id, _| live.contains(id));
        self.by_name.retain(|_, id| live.contains(id));
    }
}

#[derive(Clone)]
enum Inner {
    Columns(ColumnScrollState),
    Rows(RowScroll),
    Area(ScrollAreaScroll),
}

/// One scrolling strip's reducer and its id table.
#[derive(Clone)]
pub struct Scroll {
    inner: Inner,
    ids: Ids,
}

/// A decoded request string: absent, or bytes.
fn text(bytes: &[u8], range: CmuxScrollStr) -> Result<Option<&[u8]>, ()> {
    if range.offset == NONE {
        return Ok(None);
    }
    let start = range.offset as usize;
    let end = start.checked_add(range.len as usize).ok_or(())?;
    bytes.get(start..end).map(Some).ok_or(())
}

fn rect(rect: CmuxScrollRect) -> Rect {
    Rect::new(rect.x, rect.y, rect.width, rect.height)
}

fn source(value: u8) -> Option<ColumnFocusSource> {
    Some(match value {
        0 => ColumnFocusSource::Keyboard,
        1 => ColumnFocusSource::Pointer,
        2 => ColumnFocusSource::Programmatic,
        3 => ColumnFocusSource::Scroll,
        _ => return None,
    })
}

/// The slices of a strip request.
pub struct StripRequest<'a> {
    pub strip: &'a CmuxScrollStrip,
    pub bytes: &'a [u8],
    pub columns: &'a [CmuxScrollColumn],
    pub panes: &'a [CmuxScrollPane],
}

impl Scroll {
    pub fn new(kind: u8) -> Option<Scroll> {
        let inner = match kind {
            KIND_COLUMNS => Inner::Columns(ColumnScrollState::new()),
            KIND_ROWS => Inner::Rows(RowScroll::new()),
            KIND_AREA => Inner::Area(ScrollAreaScroll::new()),
            _ => return None,
        };
        Some(Scroll { inner, ids: Ids::default() })
    }

    pub fn state(&self) -> &ColumnScrollState {
        match &self.inner {
            Inner::Columns(state) => state,
            Inner::Rows(rows) => &rows.state,
            Inner::Area(area) => &area.state,
        }
    }

    fn state_mut(&mut self) -> &mut ColumnScrollState {
        match &mut self.inner {
            Inner::Columns(state) => state,
            Inner::Rows(rows) => &mut rows.state,
            Inner::Area(area) => &mut area.state,
        }
    }

    pub fn set_mode(&mut self, mode: u8) {
        self.state_mut().mode = match mode {
            1 => CenterFocusedColumn::Always,
            2 => CenterFocusedColumn::OnOverflow,
            _ => CenterFocusedColumn::Never,
        };
    }

    /// Reduces `event` with the caller's spring.
    fn reduce(
        &mut self,
        spring: &mut CmuxScrollSpring,
        event: ColumnScrollEvent,
    ) -> CmuxScrollEffects {
        let state = self.state_mut();
        state.spring =
            Spring { value: spring.value, velocity: spring.velocity, target: spring.target };
        let effects = state.reduce(event);
        let out = state.spring;
        *spring = CmuxScrollSpring { value: out.value, velocity: out.velocity, target: out.target };
        self.effects(effects)
    }

    fn effects(&self, effects: ColumnScrollEffects) -> CmuxScrollEffects {
        let focus = effects.focus.and_then(|pane| self.ids.name(pane));
        CmuxScrollEffects {
            ok: 1,
            needs_frames: u8::from(effects.needs_frames),
            report_on_settle: u8::from(effects.report_on_settle),
            snapped: u8::from(effects.snapped),
            has_focus: u8::from(focus.is_some()),
            reserved: [0; 3],
            focus: focus.map_or(std::ptr::null(), <[u8]>::as_ptr),
            focus_len: focus.map_or(0, <[u8]>::len),
        }
    }

    /// Checks every range of the request before anything changes.
    fn validate(request: &StripRequest<'_>) -> Result<(), ()> {
        for column in request.columns {
            text(request.bytes, column.id)?.ok_or(())?;
            let start = column.pane_start as usize;
            let end = start.checked_add(column.pane_count as usize).ok_or(())?;
            if end > request.panes.len() {
                return Err(());
            }
        }
        for pane in request.panes {
            text(request.bytes, pane.id)?.ok_or(())?;
        }
        Ok(())
    }

    /// A model snapshot (`ColumnScrollEvent::Sync`) of the strip.
    pub fn sync(
        &mut self,
        spring: &mut CmuxScrollSpring,
        request: &StripRequest<'_>,
        sync: &CmuxScrollSync,
    ) -> CmuxScrollEffects {
        if Self::validate(request).is_err() {
            return CmuxScrollEffects::FAILED;
        }
        let (Ok(focused), Ok(anchor), Some(source)) = (
            text(request.bytes, sync.focused),
            text(request.bytes, sync.anchor),
            source(sync.source),
        ) else {
            return CmuxScrollEffects::FAILED;
        };
        let focused = focused.map(|name| self.ids.intern(name));
        // Interned, not looked up: Swift's `anchor ?? focused` never falls back to the focused
        // column for a named anchor, even one the strip does not hold (a docked column).
        let anchor = anchor.map(|name| self.ids.intern(name));
        let strip_info = request.strip;
        let mut strip = self.state_mut().take_spare_strip();
        strip.reset(strip_info.viewport_width, strip_info.content_width, strip_info.gap);
        strip.axis = if strip_info.axis == 1 { Axis::Vertical } else { Axis::Horizontal };
        strip.leading_cover = strip_info.leading_cover;
        strip.trailing_cover = strip_info.trailing_cover;
        for column in request.columns {
            let id = text(request.bytes, column.id)
                .ok()
                .flatten()
                .map_or(0, |name| self.ids.intern(name));
            let start = column.pane_start as usize;
            let panes = request.panes.get(start..start + column.pane_count as usize).unwrap_or(&[]);
            let ids = &mut self.ids;
            strip.push_column(
                id,
                rect(column.frame),
                panes.iter().filter(|pane| pane.has_frame != 0 || pane.listed != 0).map(|pane| {
                    StripPane {
                        id: text(request.bytes, pane.id)
                            .ok()
                            .flatten()
                            .map_or(0, |name| ids.intern(name)),
                        frame: (pane.has_frame != 0).then(|| rect(pane.frame)),
                        listed: pane.listed != 0,
                    }
                }),
            );
        }
        let origin = strip_info.origin;
        let strip = match &mut self.inner {
            Inner::Columns(_) => strip,
            Inner::Rows(rows) => rows.strip(strip, origin),
            Inner::Area(area) => area.strip(strip, origin),
        };
        let event = ColumnScrollEvent::Sync {
            strip,
            focused,
            source,
            animated: sync.animated != 0,
            reveals: sync.reveals != 0,
            anchor: if matches!(self.inner, Inner::Columns(_)) { anchor } else { None },
        };
        let effects = self.reduce(spring, event);
        self.forget_unused_ids();
        effects
    }

    /// Center (`center`) or reveal (`!center`) the column holding `pane` once.
    pub fn show(
        &mut self,
        spring: &mut CmuxScrollSpring,
        pane: &[u8],
        center: bool,
        animated: bool,
    ) -> CmuxScrollEffects {
        let Some(pane) = self.ids.lookup(pane) else {
            // An unknown pane is in no column: nothing changes, as in Swift.
            return CmuxScrollEffects { ok: 1, ..CmuxScrollEffects::FAILED };
        };
        let event = if center {
            ColumnScrollEvent::Center { pane, animated }
        } else {
            ColumnScrollEvent::Reveal { pane, animated }
        };
        self.reduce(spring, event)
    }

    pub fn event(
        &mut self,
        spring: &mut CmuxScrollSpring,
        event: ColumnScrollEvent,
    ) -> CmuxScrollEffects {
        self.reduce(spring, event)
    }

    pub fn status(&self) -> CmuxScrollStatus {
        let state = self.state();
        let focused = state.focused_pane.and_then(|pane| self.ids.name(pane));
        CmuxScrollStatus {
            ok: 1,
            gesture_active: u8::from(state.gesture.is_some()),
            reveal_deferred: u8::from(state.reveal_deferred),
            has_restore: u8::from(state.restore.is_some()),
            has_strip: u8::from(state.strip.is_some()),
            has_focused_pane: u8::from(focused.is_some()),
            mode: match state.mode {
                CenterFocusedColumn::Never => 0,
                CenterFocusedColumn::Always => 1,
                CenterFocusedColumn::OnOverflow => 2,
            },
            reserved: 0,
            gesture_raw: state.gesture.map_or(0., |gesture| gesture.raw),
            focused_pane: focused.map_or(std::ptr::null(), <[u8]>::as_ptr),
            focused_pane_len: focused.map_or(0, <[u8]>::len),
        }
    }

    /// The number of ids the handle keeps.
    pub fn id_count(&self) -> usize {
        self.ids.names.len()
    }

    /// Drops the ids no state refers to, once they outnumber the live ones
    /// four to one (an allocation only then, not per sync).
    fn forget_unused_ids(&mut self) {
        let state = self.state();
        let strip_ids = state.strip.as_ref().map_or(0, |s| s.columns.len() + s.panes.len());
        let count = self.ids.names.len();
        if count <= 64 || count <= 4 * (strip_ids + state.remembered.len() * 2 + 8) {
            return;
        }
        // A rows strip's column ids are row slots, not interned ids: its rows come from the
        // adapter. Pane ids are interned in every kind.
        let columns_are_ids = !matches!(self.inner, Inner::Rows(_));
        let mut live = HashSet::new();
        if let Some(strip) = &state.strip {
            if columns_are_ids {
                live.extend(strip.columns.iter().map(|c| c.id));
            }
            live.extend(strip.panes.iter().map(|p| p.id));
        }
        live.extend(state.focused_pane);
        for (column, pane) in &state.remembered {
            if columns_are_ids {
                live.insert(*column);
            }
            live.insert(*pane);
        }
        if columns_are_ids {
            live.extend(state.focused_column);
            if let Some(restore) = state.restore {
                live.extend([restore.column, restore.opened]);
            }
        }
        if let Inner::Rows(rows) = &self.inner {
            live.extend(rows.rows());
        }
        self.ids.retain(&live);
    }
}

/// The handle behind `scroll`, or `None` for null.
///
/// # Safety
///
/// `scroll` is null or a live handle used by one thread.
unsafe fn handle<'a>(scroll: *mut Scroll) -> Option<&'a mut Scroll> {
    // SAFETY: the caller's contract.
    unsafe { scroll.as_mut() }
}

/// # Safety
///
/// `pointer` is null with `len` 0, or points to `len` readable items.
unsafe fn slice<'a, T>(pointer: *const T, len: usize) -> Option<&'a [T]> {
    if len == 0 {
        return Some(&[]);
    }
    if pointer.is_null() {
        return None;
    }
    // SAFETY: the caller's contract.
    Some(unsafe { std::slice::from_raw_parts(pointer, len) })
}

/// Runs `body` on the handle and the spring; a null pointer or a panic
/// returns `ok == 0`.
///
/// # Safety
///
/// `scroll` is null or a live handle used by one thread; `spring` is null or
/// readable and writable.
unsafe fn with(
    scroll: *mut Scroll,
    spring: *mut CmuxScrollSpring,
    body: impl FnOnce(&mut Scroll, &mut CmuxScrollSpring) -> CmuxScrollEffects,
) -> CmuxScrollEffects {
    // SAFETY: the caller's contract.
    let (Some(scroll), Some(spring)) = (unsafe { handle(scroll) }, unsafe { spring.as_mut() })
    else {
        return CmuxScrollEffects::FAILED;
    };
    catch_unwind(AssertUnwindSafe(|| body(scroll, spring))).unwrap_or(CmuxScrollEffects::FAILED)
}

/// A new handle: kind 0 a columns screen, 1 a column's rows, 2 a scroll
/// area. Null for another kind.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_scroll_new(kind: u8) -> *mut Scroll {
    Scroll::new(kind).map_or(std::ptr::null_mut(), |scroll| Box::into_raw(Box::new(scroll)))
}

/// An independent copy of a handle (the app's copy-on-write of a value that
/// owns one). Null for a null handle.
///
/// # Safety
///
/// `scroll` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_scroll_clone(scroll: *const Scroll) -> *mut Scroll {
    // SAFETY: the caller's contract.
    match unsafe { scroll.as_ref() } {
        Some(scroll) => catch_unwind(AssertUnwindSafe(|| Box::into_raw(Box::new(scroll.clone()))))
            .unwrap_or(std::ptr::null_mut()),
        None => std::ptr::null_mut(),
    }
}

/// # Safety
///
/// `scroll` is null or a live handle from `cmux_scroll_new` or
/// `cmux_scroll_clone`, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_scroll_free(scroll: *mut Scroll) {
    if !scroll.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(scroll) });
    }
}

/// Sets `layout.centerFocusedColumn`: 0 never, 1 always, 2 on-overflow.
///
/// # Safety
///
/// `scroll` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_scroll_set_mode(scroll: *mut Scroll, mode: u8) {
    // SAFETY: the caller's contract.
    if let Some(scroll) = unsafe { handle(scroll) } {
        scroll.set_mode(mode);
    }
}

/// A model snapshot: the strip, the focused pane and what moved it.
///
/// # Safety
///
/// `scroll` and `spring` as in [`with`]; `strip` and `sync` are readable and
/// the strip's arrays hold their counts.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_scroll_sync(
    scroll: *mut Scroll,
    spring: *mut CmuxScrollSpring,
    strip: *const CmuxScrollStrip,
    sync: *const CmuxScrollSync,
) -> CmuxScrollEffects {
    // SAFETY: the caller's contract.
    let (Some(info), Some(sync)) = (unsafe { strip.as_ref() }, unsafe { sync.as_ref() }) else {
        return CmuxScrollEffects::FAILED;
    };
    // SAFETY: the caller's contract.
    let request = unsafe {
        match (
            slice(info.bytes, info.bytes_len as usize),
            slice(info.columns, info.column_count as usize),
            slice(info.panes, info.pane_count as usize),
        ) {
            (Some(bytes), Some(columns), Some(panes)) => {
                StripRequest { strip: info, bytes, columns, panes }
            }
            _ => return CmuxScrollEffects::FAILED,
        }
    };
    // SAFETY: the caller's contract.
    unsafe { with(scroll, spring, |scroll, spring| scroll.sync(spring, &request, sync)) }
}

/// Center the column holding `pane` once.
///
/// # Safety
///
/// As [`cmux_scroll_sync`]; `pane` points to `pane_len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_scroll_center(
    scroll: *mut Scroll,
    spring: *mut CmuxScrollSpring,
    pane: *const u8,
    pane_len: usize,
    animated: u8,
) -> CmuxScrollEffects {
    // SAFETY: the caller's contract.
    let Some(pane) = (unsafe { slice(pane, pane_len) }) else { return CmuxScrollEffects::FAILED };
    // SAFETY: the caller's contract.
    unsafe { with(scroll, spring, |scroll, spring| scroll.show(spring, pane, true, animated != 0)) }
}

/// Scroll the column holding `pane` into view once, without focusing it.
///
/// # Safety
///
/// As [`cmux_scroll_center`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_scroll_reveal(
    scroll: *mut Scroll,
    spring: *mut CmuxScrollSpring,
    pane: *const u8,
    pane_len: usize,
    animated: u8,
) -> CmuxScrollEffects {
    // SAFETY: the caller's contract.
    let Some(pane) = (unsafe { slice(pane, pane_len) }) else { return CmuxScrollEffects::FAILED };
    // SAFETY: the caller's contract.
    unsafe {
        with(scroll, spring, |scroll, spring| scroll.show(spring, pane, false, animated != 0))
    }
}

/// # Safety
///
/// As [`with`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_scroll_gesture_began(
    scroll: *mut Scroll,
    spring: *mut CmuxScrollSpring,
) -> CmuxScrollEffects {
    // SAFETY: the caller's contract.
    unsafe {
        with(scroll, spring, |scroll, spring| scroll.event(spring, ColumnScrollEvent::GestureBegan))
    }
}

/// One trackpad delta (points, positive moves the content right).
///
/// # Safety
///
/// As [`with`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_scroll_gesture_changed(
    scroll: *mut Scroll,
    spring: *mut CmuxScrollSpring,
    delta_x: f64,
    time: f64,
) -> CmuxScrollEffects {
    let event = ColumnScrollEvent::GestureChanged { delta_x, time };
    // SAFETY: the caller's contract.
    unsafe { with(scroll, spring, |scroll, spring| scroll.event(spring, event)) }
}

/// # Safety
///
/// As [`with`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_scroll_gesture_ended(
    scroll: *mut Scroll,
    spring: *mut CmuxScrollSpring,
    time: f64,
    animated: u8,
) -> CmuxScrollEffects {
    let event = ColumnScrollEvent::GestureEnded { time, animated: animated != 0 };
    // SAFETY: the caller's contract.
    unsafe { with(scroll, spring, |scroll, spring| scroll.event(spring, event)) }
}

/// One mouse-wheel notch, +1 forward.
///
/// # Safety
///
/// As [`with`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_scroll_wheel(
    scroll: *mut Scroll,
    spring: *mut CmuxScrollSpring,
    direction: i32,
    animated: u8,
) -> CmuxScrollEffects {
    let event = ColumnScrollEvent::Wheel { direction, animated: animated != 0 };
    // SAFETY: the caller's contract.
    unsafe { with(scroll, spring, |scroll, spring| scroll.event(spring, event)) }
}

/// Scroll to an offset the strip scrollbar chose (a track click's page).
///
/// # Safety
///
/// As [`with`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_scroll_page(
    scroll: *mut Scroll,
    spring: *mut CmuxScrollSpring,
    to: f64,
    animated: u8,
) -> CmuxScrollEffects {
    let event = ColumnScrollEvent::Page { to, animated: animated != 0 };
    // SAFETY: the caller's contract.
    unsafe { with(scroll, spring, |scroll, spring| scroll.event(spring, event)) }
}

/// 1 while a trackpad gesture is live, 0 otherwise or for null: the per-frame
/// query, without the status's focus lookup.
///
/// # Safety
///
/// `scroll` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_scroll_gesture_active(scroll: *const Scroll) -> u8 {
    // SAFETY: the caller's contract.
    unsafe { scroll.as_ref() }.map_or(0, |scroll| u8::from(scroll.state().gesture.is_some()))
}

/// The handle's gesture, focus and restore state; `ok == 0` for null.
///
/// # Safety
///
/// `scroll` is null or a live handle used by one thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_scroll_status(scroll: *const Scroll) -> CmuxScrollStatus {
    // SAFETY: the caller's contract.
    match unsafe { scroll.as_ref() } {
        Some(scroll) => scroll.status(),
        None => CmuxScrollStatus {
            ok: 0,
            gesture_active: 0,
            reveal_deferred: 0,
            has_restore: 0,
            has_strip: 0,
            has_focused_pane: 0,
            mode: 0,
            reserved: 0,
            gesture_raw: 0.,
            focused_pane: std::ptr::null(),
            focused_pane_len: 0,
        },
    }
}
