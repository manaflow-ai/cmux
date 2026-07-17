use std::ffi::c_void;
use std::ptr;
use std::sync::atomic::{AtomicU64, Ordering};

use ghostty_vt_sys as sys;

use crate::render::{Cell, CursorShape, read_grid_ref_cell, terminal_palette};
use crate::{Result, check};

static NEXT_TERMINAL_ID: AtomicU64 = AtomicU64::new(1);
const VT_REPLAY_ESTIMATED_BYTES_PER_CELL: u64 = 32;

/// RGB color triple.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl From<sys::GhosttyColorRgb> for Rgb {
    fn from(c: sys::GhosttyColorRgb) -> Self {
        Rgb { r: c.r, g: c.g, b: c.b }
    }
}

/// Parse a color with Ghostty's config semantics.
///
/// This accepts Ghostty's hex, X11 name, `rgb:`, and `rgbi:` forms.
pub fn parse_color(value: &str) -> Option<Rgb> {
    let mut color = sys::GhosttyColorRgb::default();
    check(unsafe { sys::ghostty_color_parse(value.as_ptr().cast(), value.len(), &mut color) })
        .ok()?;
    Some(color.into())
}

/// Parse one Ghostty `palette = N=COLOR` value.
pub fn parse_palette_entry(value: &str) -> Option<(u8, Rgb)> {
    let mut index = 0;
    let mut color = sys::GhosttyColorRgb::default();
    check(unsafe {
        sys::ghostty_color_parse_palette_entry(
            value.as_ptr().cast(),
            value.len(),
            &mut index,
            &mut color,
        )
    })
    .ok()?;
    Some((index, color.into()))
}

/// Which screen buffer is active.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Screen {
    Primary,
    Alternate,
}

/// Scrollbar geometry for the viewport, in rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Scrollbar {
    /// Total scrollable rows (scrollback + screen).
    pub total: u64,
    /// Row offset of the viewport within `total`.
    pub offset: u64,
    /// Viewport height in rows.
    pub len: u64,
}

impl Scrollbar {
    /// Whether the viewport is scrolled away from the live bottom.
    pub fn scrolled_back(&self) -> bool {
        self.offset + self.len < self.total
    }
}

/// Callback invoked with bytes the terminal wants written to the pty.
pub type PtyWriteFn = Box<dyn FnMut(&[u8]) + Send>;
/// Parameterless notification callback (title changed, bell).
pub type NotifyFn = Box<dyn FnMut() + Send>;

/// Host callbacks invoked synchronously during [`Terminal::vt_write`].
///
/// Callbacks must not touch the [`Terminal`] that invoked them (the C API
/// forbids reentrancy); queue work and act on it after `vt_write` returns.
#[derive(Default)]
pub struct Callbacks {
    /// The terminal needs to write bytes back to the pty (query responses,
    /// device status reports, ...).
    pub on_pty_write: Option<PtyWriteFn>,
    /// The terminal title changed (OSC 0/2). Read it with
    /// [`Terminal::title`] after `vt_write` returns.
    pub on_title_changed: Option<NotifyFn>,
    /// BEL received.
    pub on_bell: Option<NotifyFn>,
}

#[derive(Default)]
enum MouseModeScan {
    #[default]
    Ground,
    Escape,
    Csi {
        private: bool,
        at_start: bool,
        parameter: u16,
        has_parameter: bool,
        has_mouse_mode: bool,
        soft_reset: bool,
    },
}

impl MouseModeScan {
    fn feed(&mut self, data: &[u8]) -> bool {
        let mut changed = false;
        for &byte in data {
            let state = std::mem::take(self);
            *self = match state {
                Self::Ground => match byte {
                    0x1b => Self::Escape,
                    0x9b => Self::csi(),
                    _ => Self::Ground,
                },
                Self::Escape => match byte {
                    b'[' => Self::csi(),
                    0x1b => Self::Escape,
                    b'c' => {
                        changed = true;
                        Self::Ground
                    }
                    _ => Self::Ground,
                },
                Self::Csi {
                    mut private,
                    mut at_start,
                    mut parameter,
                    mut has_parameter,
                    mut has_mouse_mode,
                    mut soft_reset,
                } => match byte {
                    b'?' if at_start => {
                        private = true;
                        at_start = false;
                        Self::Csi {
                            private,
                            at_start,
                            parameter,
                            has_parameter,
                            has_mouse_mode,
                            soft_reset,
                        }
                    }
                    b'0'..=b'9' => {
                        at_start = false;
                        has_parameter = true;
                        parameter =
                            parameter.saturating_mul(10).saturating_add(u16::from(byte - b'0'));
                        Self::Csi {
                            private,
                            at_start,
                            parameter,
                            has_parameter,
                            has_mouse_mode,
                            soft_reset,
                        }
                    }
                    b';' => {
                        has_mouse_mode |=
                            private && has_parameter && Self::is_mouse_mode(parameter);
                        at_start = false;
                        parameter = 0;
                        has_parameter = false;
                        Self::Csi {
                            private,
                            at_start,
                            parameter,
                            has_parameter,
                            has_mouse_mode,
                            soft_reset,
                        }
                    }
                    b'!' => {
                        soft_reset = true;
                        Self::Csi {
                            private,
                            at_start,
                            parameter,
                            has_parameter,
                            has_mouse_mode,
                            soft_reset,
                        }
                    }
                    0x40..=0x7e => {
                        has_mouse_mode |=
                            private && has_parameter && Self::is_mouse_mode(parameter);
                        if (has_mouse_mode && matches!(byte, b'h' | b'l' | b'r'))
                            || (soft_reset && byte == b'p')
                        {
                            changed = true;
                        }
                        Self::Ground
                    }
                    0x1b => Self::Escape,
                    _ => Self::Ground,
                },
            };
        }
        changed
    }

    fn csi() -> Self {
        Self::Csi {
            private: false,
            at_start: true,
            parameter: 0,
            has_parameter: false,
            has_mouse_mode: false,
            soft_reset: false,
        }
    }

    fn is_mouse_mode(mode: u16) -> bool {
        matches!(mode, 9 | 1000 | 1002 | 1003 | 1005 | 1006 | 1015 | 1016)
    }
}

/// A terminal instance: VT parser plus full screen/scrollback state.
pub struct Terminal {
    raw: sys::GhosttyTerminal,
    instance_id: u64,
    mouse_mode_revision: u64,
    mouse_mode_scan: MouseModeScan,
    // Heap-pinned so the userdata pointer stays valid for the terminal's
    // lifetime.
    callbacks: Box<Callbacks>,
    cursor_override: CursorOverrideTracker,
}

#[derive(Default)]
struct CursorOverrideTracker {
    state: CursorTrackState,
    active: bool,
}

#[derive(Default)]
enum CursorTrackState {
    #[default]
    Ground,
    Escape,
    EscapeIntermediate,
    Csi(CursorCsi),
    String {
        bell_terminated: bool,
    },
    StringEscape {
        bell_terminated: bool,
    },
}

#[derive(Default)]
struct CursorCsi {
    value: u16,
    digits: bool,
    space: bool,
    invalid: bool,
}

impl CursorOverrideTracker {
    fn write(&mut self, data: &[u8]) {
        for &byte in data {
            let state = std::mem::take(&mut self.state);
            self.state = match state {
                CursorTrackState::Ground => self.ground(byte),
                CursorTrackState::Escape => self.escape(byte),
                CursorTrackState::EscapeIntermediate => match byte {
                    0x1b => CursorTrackState::Escape,
                    0x20..=0x2f => CursorTrackState::EscapeIntermediate,
                    _ => CursorTrackState::Ground,
                },
                CursorTrackState::Csi(mut csi) => self.csi(byte, &mut csi),
                CursorTrackState::String { bell_terminated } => match byte {
                    0x07 if bell_terminated => CursorTrackState::Ground,
                    0x9c => CursorTrackState::Ground,
                    0x1b => CursorTrackState::StringEscape { bell_terminated },
                    _ => CursorTrackState::String { bell_terminated },
                },
                CursorTrackState::StringEscape { bell_terminated } => match byte {
                    b'\\' | 0x9c => CursorTrackState::Ground,
                    0x1b => CursorTrackState::StringEscape { bell_terminated },
                    0x07 if bell_terminated => CursorTrackState::Ground,
                    _ => CursorTrackState::String { bell_terminated },
                },
            };
        }
    }

    fn ground(&mut self, byte: u8) -> CursorTrackState {
        // Ghostty's stream UTF-8-decodes in ground state, so 0x80..=0xff here
        // are text (UTF-8 lead/continuation bytes), never C1 controls — an
        // emoji like U+1F44D contains 0x9f and must not open a control
        // string. C1 openers are only honored inside escape-initiated states,
        // mirroring ghostty's ground handling.
        match byte {
            0x1b => CursorTrackState::Escape,
            _ => CursorTrackState::Ground,
        }
    }

    fn escape(&mut self, byte: u8) -> CursorTrackState {
        match byte {
            b'[' => CursorTrackState::Csi(CursorCsi::default()),
            b']' => CursorTrackState::String { bell_terminated: true },
            b'P' | b'X' | b'^' | b'_' => CursorTrackState::String { bell_terminated: false },
            b'c' => {
                self.active = false;
                CursorTrackState::Ground
            }
            0x1b => CursorTrackState::Escape,
            0x20..=0x2f => CursorTrackState::EscapeIntermediate,
            _ => CursorTrackState::Ground,
        }
    }

    fn csi(&mut self, byte: u8, csi: &mut CursorCsi) -> CursorTrackState {
        match byte {
            b'0'..=b'9' if !csi.space => {
                csi.digits = true;
                csi.value = csi.value.saturating_mul(10).saturating_add((byte - b'0') as u16);
                CursorTrackState::Csi(std::mem::take(csi))
            }
            0x30..=0x3f => {
                csi.invalid = true;
                CursorTrackState::Csi(std::mem::take(csi))
            }
            b' ' if !csi.space => {
                csi.space = true;
                CursorTrackState::Csi(std::mem::take(csi))
            }
            0x20..=0x2f => {
                csi.invalid = true;
                CursorTrackState::Csi(std::mem::take(csi))
            }
            b'q' => {
                if csi.space && !csi.invalid {
                    match (csi.digits, csi.value) {
                        (false, _) | (true, 0) => self.active = false,
                        (true, 1..=6) => self.active = true,
                        _ => {}
                    }
                }
                CursorTrackState::Ground
            }
            0x40..=0x7e => CursorTrackState::Ground,
            0x18 | 0x1a => CursorTrackState::Ground,
            0x1b => CursorTrackState::Escape,
            _ => CursorTrackState::Csi(std::mem::take(csi)),
        }
    }
}

// The handle is not thread-safe, but it is movable and we only expose
// mutation through &mut self, so guarding a Terminal with a Mutex is sound.
unsafe impl Send for Terminal {}

unsafe extern "C" fn write_pty_trampoline(
    _terminal: sys::GhosttyTerminal,
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) {
    let callbacks = unsafe { &mut *(userdata as *mut Callbacks) };
    if let Some(f) = callbacks.on_pty_write.as_mut() {
        let bytes = if len == 0 { &[] } else { unsafe { std::slice::from_raw_parts(data, len) } };
        f(bytes);
    }
}

unsafe extern "C" fn title_changed_trampoline(
    _terminal: sys::GhosttyTerminal,
    userdata: *mut c_void,
) {
    let callbacks = unsafe { &mut *(userdata as *mut Callbacks) };
    if let Some(f) = callbacks.on_title_changed.as_mut() {
        f();
    }
}

unsafe extern "C" fn bell_trampoline(_terminal: sys::GhosttyTerminal, userdata: *mut c_void) {
    let callbacks = unsafe { &mut *(userdata as *mut Callbacks) };
    if let Some(f) = callbacks.on_bell.as_mut() {
        f();
    }
}

impl Terminal {
    pub fn new(cols: u16, rows: u16, max_scrollback: usize, callbacks: Callbacks) -> Result<Self> {
        let mut raw: sys::GhosttyTerminal = ptr::null_mut();
        let opts =
            sys::GhosttyTerminalOptions { cols: cols.max(1), rows: rows.max(1), max_scrollback };
        check(unsafe { sys::ghostty_terminal_new(ptr::null(), &mut raw, opts) })?;

        let mut term = Terminal {
            raw,
            instance_id: NEXT_TERMINAL_ID.fetch_add(1, Ordering::Relaxed),
            mouse_mode_revision: 0,
            mouse_mode_scan: MouseModeScan::default(),
            callbacks: Box::new(callbacks),
            cursor_override: CursorOverrideTracker::default(),
        };
        let userdata = &mut *term.callbacks as *mut Callbacks as *mut c_void;
        unsafe {
            sys::ghostty_terminal_set(raw, sys::GHOSTTY_TERMINAL_OPT_USERDATA, userdata);
            sys::ghostty_terminal_set(
                raw,
                sys::GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                write_pty_trampoline as *const c_void,
            );
            sys::ghostty_terminal_set(
                raw,
                sys::GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
                title_changed_trampoline as *const c_void,
            );
            sys::ghostty_terminal_set(
                raw,
                sys::GHOSTTY_TERMINAL_OPT_BELL,
                bell_trampoline as *const c_void,
            );
        }
        Ok(term)
    }

    pub(crate) fn raw(&self) -> sys::GhosttyTerminal {
        self.raw
    }

    pub(crate) fn mouse_mode_revision(&self) -> u64 {
        self.mouse_mode_revision
    }

    pub(crate) fn instance_id(&self) -> u64 {
        self.instance_id
    }

    /// Feed VT-encoded bytes (pty output) into the terminal.
    pub fn vt_write(&mut self, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        if self.mouse_mode_scan.feed(data) {
            self.mouse_mode_revision = self.mouse_mode_revision.wrapping_add(1);
        }
        self.cursor_override.write(data);
        unsafe { sys::ghostty_terminal_vt_write(self.raw, data.as_ptr(), data.len()) }
    }

    /// Whether the current cursor style/blink came from an active DECSCUSR
    /// override rather than the embedder defaults.
    pub fn cursor_overridden(&self) -> bool {
        self.cursor_override.active
    }

    /// Set host-provided default foreground, background, and cursor colors.
    ///
    /// `None` leaves that channel unchanged.
    pub fn set_default_colors(&mut self, fg: Option<Rgb>, bg: Option<Rgb>, cursor: Option<Rgb>) {
        unsafe {
            if let Some(fg) = fg {
                let color = sys::GhosttyColorRgb { r: fg.r, g: fg.g, b: fg.b };
                sys::ghostty_terminal_set(
                    self.raw,
                    sys::GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND,
                    &color as *const sys::GhosttyColorRgb as *const c_void,
                );
            }
            if let Some(bg) = bg {
                let color = sys::GhosttyColorRgb { r: bg.r, g: bg.g, b: bg.b };
                sys::ghostty_terminal_set(
                    self.raw,
                    sys::GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND,
                    &color as *const sys::GhosttyColorRgb as *const c_void,
                );
            }
            if let Some(cursor) = cursor {
                let color = sys::GhosttyColorRgb { r: cursor.r, g: cursor.g, b: cursor.b };
                sys::ghostty_terminal_set(
                    self.raw,
                    sys::GHOSTTY_TERMINAL_OPT_COLOR_CURSOR,
                    &color as *const sys::GhosttyColorRgb as *const c_void,
                );
            }
        }
    }

    /// Set selected entries in the host-provided default palette.
    ///
    /// Unspecified entries use Ghostty's built-in palette. Active OSC 4
    /// overrides remain effective; this only replaces their defaults.
    pub fn set_default_palette(&mut self, overrides: &[Option<Rgb>; 256]) {
        let mut palette = [sys::GhosttyColorRgb::default(); 256];
        unsafe { sys::ghostty_color_palette_default(palette.as_mut_ptr()) };
        for (slot, color) in palette.iter_mut().zip(overrides) {
            if let Some(color) = color {
                *slot = sys::GhosttyColorRgb { r: color.r, g: color.g, b: color.b };
            }
        }
        unsafe {
            sys::ghostty_terminal_set(
                self.raw,
                sys::GHOSTTY_TERMINAL_OPT_COLOR_PALETTE,
                palette.as_ptr().cast(),
            );
        }
    }

    /// Set the cursor defaults used until an application overrides them with
    /// DECSCUSR. `None` leaves that default unchanged.
    pub fn set_default_cursor(&mut self, style: Option<CursorShape>, blink: Option<bool>) {
        unsafe {
            if let Some(style) = style {
                let style = match style {
                    CursorShape::Bar => sys::GHOSTTY_TERMINAL_CURSOR_STYLE_BAR,
                    CursorShape::Underline => sys::GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE,
                    CursorShape::Block | CursorShape::BlockHollow => {
                        sys::GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK
                    }
                };
                sys::ghostty_terminal_set(
                    self.raw,
                    sys::GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE,
                    &style as *const sys::GhosttyTerminalCursorStyle as *const c_void,
                );
            }
            if let Some(blink) = blink {
                sys::ghostty_terminal_set(
                    self.raw,
                    sys::GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK,
                    &blink as *const bool as *const c_void,
                );
            }
        }
    }

    /// Effective foreground, background, and cursor colors.
    ///
    /// Each value includes any active OSC 10/11/12 override and is `None`
    /// when neither the embedder nor the terminal application set it.
    pub fn effective_colors(&self) -> (Option<Rgb>, Option<Rgb>, Option<Rgb>) {
        let color = |data| self.get::<sys::GhosttyColorRgb>(data).ok().map(Rgb::from);
        (
            color(sys::GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND),
            color(sys::GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND),
            color(sys::GHOSTTY_TERMINAL_DATA_COLOR_CURSOR),
        )
    }

    /// Cursor position (col, row), 0-indexed within the active area.
    pub fn cursor_position(&self) -> Option<(u16, u16)> {
        let x = self.get::<u16>(sys::GHOSTTY_TERMINAL_DATA_CURSOR_X).ok()?;
        let y = self.get::<u16>(sys::GHOSTTY_TERMINAL_DATA_CURSOR_Y).ok()?;
        Some((x, y))
    }

    pub fn resize(
        &mut self,
        cols: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> Result<()> {
        check(unsafe {
            sys::ghostty_terminal_resize(
                self.raw,
                cols.max(1),
                rows.max(1),
                cell_width_px,
                cell_height_px,
            )
        })
    }

    fn get<T: Default>(&self, data: sys::GhosttyTerminalData) -> Result<T> {
        let mut out = T::default();
        check(unsafe {
            sys::ghostty_terminal_get(self.raw, data, &mut out as *mut T as *mut c_void)
        })?;
        Ok(out)
    }

    pub fn cols(&self) -> u16 {
        self.get::<u16>(sys::GHOSTTY_TERMINAL_DATA_COLS).unwrap_or(0)
    }

    pub fn rows(&self) -> u16 {
        self.get::<u16>(sys::GHOSTTY_TERMINAL_DATA_ROWS).unwrap_or(0)
    }

    pub fn active_screen(&self) -> Screen {
        match self.get::<sys::GhosttyTerminalScreen>(sys::GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN) {
            Ok(sys::GHOSTTY_TERMINAL_SCREEN_ALTERNATE) => Screen::Alternate,
            _ => Screen::Primary,
        }
    }

    /// Whether any mouse tracking mode is enabled by the application.
    pub fn mouse_tracking(&self) -> bool {
        self.get::<bool>(sys::GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING).unwrap_or(false)
    }

    /// Number of scrollback rows above the viewport.
    pub fn scrollback_rows(&self) -> usize {
        self.get::<usize>(sys::GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS).unwrap_or(0)
    }

    /// Number of retained history rows, saturated to the protocol's `u32`.
    pub fn history_rows(&self) -> u32 {
        u32::try_from(self.scrollback_rows()).unwrap_or(u32::MAX)
    }

    /// Read styled retained rows without moving the viewport or consuming
    /// terminal/render damage.
    ///
    /// `start` is zero-based from the oldest retained row. Reads clamp at the
    /// current history length, so an evicted or past-the-end start returns an
    /// empty page. This uses Ghostty's read-only history-coordinate grid refs;
    /// it never scrolls the shared viewport or updates a render state.
    pub fn styled_history_rows(&self, start: u32, count: u16) -> Result<Vec<Vec<Cell>>> {
        let total = self.history_rows();
        if count == 0 || start >= total {
            return Ok(Vec::new());
        }

        let palette = terminal_palette(self.raw, sys::GHOSTTY_TERMINAL_DATA_COLOR_PALETTE)?;
        let end = start.saturating_add(u32::from(count)).min(total);
        let cols = self.cols();
        let mut rows = Vec::with_capacity((end - start) as usize);
        let mut grapheme_buf = Vec::new();

        for y in start..end {
            let mut row = Vec::with_capacity(cols as usize);
            for x in 0..cols {
                let point = sys::GhosttyPoint {
                    tag: sys::GHOSTTY_POINT_TAG_HISTORY,
                    value: sys::GhosttyPointValue {
                        coordinate: sys::GhosttyPointCoordinate { x, y },
                    },
                };
                let mut grid_ref = sys::GhosttyGridRef {
                    size: size_of::<sys::GhosttyGridRef>(),
                    ..Default::default()
                };
                check(unsafe { sys::ghostty_terminal_grid_ref(self.raw, point, &mut grid_ref) })?;
                row.push(read_grid_ref_cell(&grid_ref, &palette, &mut grapheme_buf)?);
            }
            rows.push(row);
        }
        Ok(rows)
    }

    /// Terminal title as set by OSC 0/2, if any.
    pub fn title(&self) -> Option<String> {
        let s: sys::GhosttyString = self.get(sys::GHOSTTY_TERMINAL_DATA_TITLE).ok()?;
        if s.len == 0 || s.ptr.is_null() {
            return None;
        }
        let bytes = unsafe { std::slice::from_raw_parts(s.ptr, s.len) };
        Some(String::from_utf8_lossy(bytes).into_owned())
    }

    /// Working directory reported via OSC 7, if any.
    pub fn pwd(&self) -> Option<String> {
        let s: sys::GhosttyString = self.get(sys::GHOSTTY_TERMINAL_DATA_PWD).ok()?;
        if s.len == 0 || s.ptr.is_null() {
            return None;
        }
        let bytes = unsafe { std::slice::from_raw_parts(s.ptr, s.len) };
        Some(String::from_utf8_lossy(bytes).into_owned())
    }

    /// Query a terminal mode (DEC private when `ansi` is false).
    pub fn mode(&self, mode: u16, ansi: bool) -> bool {
        let mut out = false;
        let result = unsafe {
            sys::ghostty_terminal_mode_get(self.raw, sys::ghostty_mode_new(mode, ansi), &mut out)
        };
        result == sys::GHOSTTY_SUCCESS && out
    }

    pub fn scroll_delta(&mut self, delta: isize) {
        let behavior = sys::GhosttyTerminalScrollViewport {
            tag: sys::GHOSTTY_SCROLL_VIEWPORT_DELTA,
            value: sys::GhosttyTerminalScrollViewportValue { delta },
        };
        unsafe { sys::ghostty_terminal_scroll_viewport(self.raw, behavior) }
    }

    pub fn scroll_to_bottom(&mut self) {
        let behavior = sys::GhosttyTerminalScrollViewport {
            tag: sys::GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
            value: sys::GhosttyTerminalScrollViewportValue { delta: 0 },
        };
        unsafe { sys::ghostty_terminal_scroll_viewport(self.raw, behavior) }
    }

    /// Scrollbar geometry for the current viewport. The engine notes this
    /// can be expensive for arbitrary scroll positions; call it once per
    /// frame at most.
    pub fn scrollbar(&self) -> Option<Scrollbar> {
        let raw: sys::GhosttyTerminalScrollbar =
            self.get(sys::GHOSTTY_TERMINAL_DATA_SCROLLBAR).ok()?;
        if raw.total == 0 || raw.len == 0 {
            return None;
        }
        Some(Scrollbar { total: raw.total, offset: raw.offset, len: raw.len })
    }

    /// Plain text of a selection range given in viewport coordinates
    /// (inclusive). Returns `None` when either endpoint is out of bounds.
    pub fn selection_text(&mut self, start: (u16, u16), end: (u16, u16)) -> Option<String> {
        self.selection_text_with_tag(
            sys::GHOSTTY_POINT_TAG_VIEWPORT,
            (start.0, start.1 as u64),
            (end.0, end.1 as u64),
        )
    }

    /// Plain-text dump of the currently rendered viewport.
    ///
    /// This uses the terminal formatter's read-only selection path rather
    /// than `RenderState::update`, so callers can inspect the viewport
    /// without clearing dirty flags needed by a concurrent renderer.
    pub fn viewport_text(&mut self) -> Result<String> {
        let cols = self.cols();
        let rows = self.rows();
        if cols == 0 || rows == 0 {
            return Ok(String::new());
        }
        self.selection_text_with_tag_options(
            sys::GHOSTTY_POINT_TAG_VIEWPORT,
            (0, 0),
            (cols.saturating_sub(1), rows.saturating_sub(1) as u64),
            false,
            true,
        )
        .ok_or(crate::Error::InvalidValue)
    }

    /// Plain text of a selection range given in absolute screen
    /// coordinates (scrollbar offset + viewport row), inclusive.
    /// Clamps the end row when scrollback has trimmed rows after the
    /// selection was captured.
    pub fn selection_text_absolute(
        &mut self,
        start: (u16, u64),
        end: (u16, u64),
    ) -> Option<String> {
        let sb = self.scrollbar()?;
        let last_row = sb.total.checked_sub(1)?;
        if start.1 > last_row {
            return None;
        }
        let end = (end.0, end.1.min(last_row));
        if (end.1, end.0) < (start.1, start.0) {
            return None;
        }
        self.selection_text_with_tag(sys::GHOSTTY_POINT_TAG_SCREEN, start, end)
    }

    fn selection_text_with_tag(
        &mut self,
        tag: sys::GhosttyPointTag,
        start: (u16, u64),
        end: (u16, u64),
    ) -> Option<String> {
        self.selection_text_with_tag_options(tag, start, end, true, true)
    }

    fn selection_text_with_tag_options(
        &mut self,
        tag: sys::GhosttyPointTag,
        start: (u16, u64),
        end: (u16, u64),
        unwrap_lines: bool,
        trim: bool,
    ) -> Option<String> {
        let selection = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            start: self.grid_ref(tag, start.0, start.1)?,
            end: self.grid_ref(tag, end.0, end.1)?,
            rectangle: false,
        };
        let opts = sys::GhosttyFormatterTerminalOptions {
            size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: sys::GHOSTTY_FORMATTER_FORMAT_PLAIN,
            unwrap: unwrap_lines,
            trim,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
                ..Default::default()
            },
            selection: &selection,
        };
        let bytes = self.format(opts).ok()?;
        Some(String::from_utf8_lossy(&bytes).into_owned())
    }

    /// Plain-text dump of the active screen's full page list, INCLUDING
    /// scrollback. For the rendered viewport only, use [`Self::viewport_text`].
    pub fn plain_text(&mut self) -> Result<String> {
        let opts = sys::GhosttyFormatterTerminalOptions {
            size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: sys::GHOSTTY_FORMATTER_FORMAT_PLAIN,
            unwrap: false,
            trim: true,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
                ..Default::default()
            },
            selection: ptr::null(),
        };
        Ok(String::from_utf8_lossy(&self.format(opts)?).into_owned())
    }

    /// VT-sequence replay of the terminal's current state: feeding the
    /// returned bytes into a fresh terminal of the same size reproduces
    /// the screen contents, styles, cursor, modes, palette, keyboard
    /// state, charsets, and tabstops. This is the attach primitive: a new
    /// frontend replays this, then follows the live pty stream.
    pub fn vt_replay(&mut self) -> Result<Vec<u8>> {
        self.vt_replay_with_selection(None)
    }

    /// VT replay bounded to `max_bytes`, retaining the newest complete rows.
    ///
    /// Formatting begins with a recent row window derived from the budget. A
    /// fitting window grows geometrically up to the complete history, while an
    /// oversized window shrinks until the active screen fits. This preserves
    /// full history when it fits without first scanning unbounded scrollback.
    /// A pathological screen whose newest row alone exceeds the budget falls
    /// back to a terminal reset so callers can still attach and receive live
    /// output instead of entering a permanent overflow loop.
    pub fn vt_replay_bounded(&mut self, max_bytes: usize) -> Result<Vec<u8>> {
        let Some(scrollbar) = self.scrollbar() else {
            return Ok(minimal_vt_replay(max_bytes));
        };
        if scrollbar.total == 0 {
            return Ok(minimal_vt_replay(max_bytes));
        }

        let screen_rows = scrollbar.len.min(scrollbar.total).max(1);
        let mut tail_rows =
            vt_replay_row_window(scrollbar.total, screen_rows, self.cols(), max_bytes);
        let mut best = None;
        let mut upper_failed = false;

        loop {
            if let Some(replay) = self.vt_replay_screen_tail_bounded(tail_rows, max_bytes)? {
                if upper_failed || tail_rows == scrollbar.total {
                    return Ok(replay);
                }
                best = Some(replay);
                let next = tail_rows.saturating_mul(2).min(scrollbar.total);
                if next == tail_rows {
                    break;
                }
                tail_rows = next;
                continue;
            }
            upper_failed = true;
            if let Some(replay) = best {
                return Ok(replay);
            }
            if tail_rows <= 1 {
                break;
            }
            tail_rows = if tail_rows > screen_rows {
                screen_rows.max(tail_rows / 2)
            } else {
                tail_rows / 2
            };
        }

        Ok(minimal_vt_replay(max_bytes))
    }

    fn vt_replay_screen_tail_bounded(
        &mut self,
        rows: u64,
        max_bytes: usize,
    ) -> Result<Option<Vec<u8>>> {
        let scrollbar = self.scrollbar().ok_or(crate::Error::InvalidValue)?;
        let cols = self.cols();
        if cols == 0 || scrollbar.total == 0 || rows == 0 {
            return Err(crate::Error::InvalidValue);
        }
        let selection = sys::GhosttySelection {
            size: size_of::<sys::GhosttySelection>(),
            start: self
                .grid_ref(sys::GHOSTTY_POINT_TAG_SCREEN, 0, scrollbar.total.saturating_sub(rows))
                .ok_or(crate::Error::InvalidValue)?,
            end: self
                .grid_ref(
                    sys::GHOSTTY_POINT_TAG_SCREEN,
                    cols.saturating_sub(1),
                    scrollbar.total - 1,
                )
                .ok_or(crate::Error::InvalidValue)?,
            rectangle: false,
        };
        self.vt_replay_with_selection_bounded(Some(&selection), max_bytes)
    }

    fn vt_replay_with_selection(
        &mut self,
        selection: Option<&sys::GhosttySelection>,
    ) -> Result<Vec<u8>> {
        let mut bytes = self.format(Self::vt_replay_options(selection))?;
        self.append_cursor_position(&mut bytes);
        Ok(bytes)
    }

    fn vt_replay_with_selection_bounded(
        &mut self,
        selection: Option<&sys::GhosttySelection>,
        max_bytes: usize,
    ) -> Result<Option<Vec<u8>>> {
        let mut bytes = self.format_bounded(Self::vt_replay_options(selection), max_bytes)?;
        if let Some(bytes) = bytes.as_mut() {
            self.append_cursor_position(bytes);
        }
        Ok(bytes)
    }

    fn vt_replay_options(
        selection: Option<&sys::GhosttySelection>,
    ) -> sys::GhosttyFormatterTerminalOptions {
        sys::GhosttyFormatterTerminalOptions {
            size: size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: sys::GHOSTTY_FORMATTER_FORMAT_VT,
            unwrap: false,
            trim: false,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: size_of::<sys::GhosttyFormatterTerminalExtra>(),
                palette: true,
                modes: true,
                scrolling_region: true,
                tabstops: true,
                pwd: true,
                keyboard: true,
                screen: sys::GhosttyFormatterScreenExtra {
                    size: size_of::<sys::GhosttyFormatterScreenExtra>(),
                    cursor: true,
                    style: true,
                    hyperlink: true,
                    protection: true,
                    kitty_keyboard: true,
                    charsets: true,
                },
            },
            selection: selection.map_or(ptr::null(), |value| value),
        }
    }

    fn grid_ref(&self, tag: sys::GhosttyPointTag, x: u16, y: u64) -> Option<sys::GhosttyGridRef> {
        let y = u32::try_from(y).ok()?;
        let point = sys::GhosttyPoint {
            tag,
            value: sys::GhosttyPointValue { coordinate: sys::GhosttyPointCoordinate { x, y } },
        };
        let mut out =
            sys::GhosttyGridRef { size: size_of::<sys::GhosttyGridRef>(), ..Default::default() };
        let result = unsafe { sys::ghostty_terminal_grid_ref(self.raw, point, &mut out) };
        (result == sys::GHOSTTY_SUCCESS).then_some(out)
    }

    fn append_cursor_position(&self, bytes: &mut Vec<u8>) {
        // Ghostty's formatter emits tabstop programming (CHA+HTS pairs) and
        // the OSC 7 pwd report AFTER its cursor restore, so a fresh mirror
        // ends with its cursor parked on the last tabstop column. Re-assert
        // the true position as the final sequence. (A pending soft-wrap flag
        // is not restorable this way; the next print in that rare state
        // wraps one column early on the mirror only.) Remove once the
        // formatter orders the cursor restore last.
        if let Some((x, y)) = self.cursor_position() {
            bytes.extend_from_slice(
                format!("\x1b[{};{}H", u32::from(y) + 1, u32::from(x) + 1).as_bytes(),
            );
        }
    }

    fn format(&mut self, opts: sys::GhosttyFormatterTerminalOptions) -> Result<Vec<u8>> {
        let mut formatter: sys::GhosttyFormatter = ptr::null_mut();
        check(unsafe {
            sys::ghostty_formatter_terminal_new(ptr::null(), &mut formatter, self.raw, opts)
        })?;
        let result = (|| {
            let mut needed: usize = 0;
            let query = unsafe {
                sys::ghostty_formatter_format_buf(formatter, ptr::null_mut(), 0, &mut needed)
            };
            if query != sys::GHOSTTY_OUT_OF_SPACE && query != sys::GHOSTTY_SUCCESS {
                check(query)?;
            }
            let mut buf = vec![0u8; needed.max(1)];
            let mut written: usize = 0;
            check(unsafe {
                sys::ghostty_formatter_format_buf(
                    formatter,
                    buf.as_mut_ptr(),
                    buf.len(),
                    &mut written,
                )
            })?;
            buf.truncate(written);
            Ok(buf)
        })();
        unsafe { sys::ghostty_formatter_free(formatter) };
        result
    }

    fn format_bounded(
        &mut self,
        opts: sys::GhosttyFormatterTerminalOptions,
        max_bytes: usize,
    ) -> Result<Option<Vec<u8>>> {
        let mut formatter: sys::GhosttyFormatter = ptr::null_mut();
        check(unsafe {
            sys::ghostty_formatter_terminal_new(ptr::null(), &mut formatter, self.raw, opts)
        })?;
        let result = (|| {
            let mut needed: usize = 0;
            let query = unsafe {
                sys::ghostty_formatter_format_buf(formatter, ptr::null_mut(), 0, &mut needed)
            };
            if query != sys::GHOSTTY_OUT_OF_SPACE && query != sys::GHOSTTY_SUCCESS {
                check(query)?;
            }
            if needed > max_bytes {
                return Ok(None);
            }
            let mut buf = vec![0u8; needed.max(1)];
            let mut written: usize = 0;
            check(unsafe {
                sys::ghostty_formatter_format_buf(
                    formatter,
                    buf.as_mut_ptr(),
                    buf.len(),
                    &mut written,
                )
            })?;
            buf.truncate(written);
            Ok(Some(buf))
        })();
        unsafe { sys::ghostty_formatter_free(formatter) };
        result
    }
}

fn minimal_vt_replay(max_bytes: usize) -> Vec<u8> {
    const RESET: &[u8] = b"\x1bc";
    if max_bytes >= RESET.len() { RESET.to_vec() } else { Vec::new() }
}

fn vt_replay_row_window(total_rows: u64, screen_rows: u64, cols: u16, max_bytes: usize) -> u64 {
    let estimated_row_bytes = u64::from(cols.max(1)) * VT_REPLAY_ESTIMATED_BYTES_PER_CELL;
    let budget_rows = u64::try_from(max_bytes).unwrap_or(u64::MAX) / estimated_row_bytes;
    budget_rows.max(screen_rows).min(total_rows)
}

impl Drop for Terminal {
    fn drop(&mut self) {
        unsafe {
            // Clear callbacks first so a hypothetical late invocation can't
            // touch the freed Box.
            sys::ghostty_terminal_set(self.raw, sys::GHOSTTY_TERMINAL_OPT_WRITE_PTY, ptr::null());
            sys::ghostty_terminal_set(
                self.raw,
                sys::GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
                ptr::null(),
            );
            sys::ghostty_terminal_set(self.raw, sys::GHOSTTY_TERMINAL_OPT_BELL, ptr::null());
            sys::ghostty_terminal_free(self.raw);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Callbacks, MouseModeScan, Terminal, vt_replay_row_window};

    #[test]
    fn mouse_mode_scan_tracks_split_private_mode_sequences() {
        let mut scan = MouseModeScan::default();

        assert!(!scan.feed(b"\x1b[?10"));
        assert!(scan.feed(b"00;1006h"));
        assert!(!scan.feed(b"ordinary output\x1b[31m"));
        assert!(scan.feed(b"\x9b?1002l"));
        assert!(scan.feed(b"\x1b[?1000r"));
        assert!(scan.feed(b"\x1b[!p"));
        assert!(scan.feed(b"\x1bc"));
    }

    #[test]
    fn terminal_instances_have_lifetime_stable_ids() {
        let first = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        let second = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();

        assert_ne!(first.instance_id(), second.instance_id());
    }

    #[test]
    fn bounded_vt_replay_keeps_the_latest_screen_after_large_history() {
        let mut source = Terminal::new(80, 24, 2 * 1024 * 1024, Callbacks::default()).unwrap();
        let wide_line = "x".repeat(2048);
        for index in 0..500 {
            source.vt_write(format!("history-{index:04}-{wide_line}\r\n").as_bytes());
        }
        source.vt_write(b"LATEST-VISIBLE-CONTENT");

        let full = source.vt_replay().unwrap();
        assert!(full.len() > 32 * 1024);

        let bounded = source.vt_replay_bounded(32 * 1024).unwrap();
        assert!(bounded.len() <= 32 * 1024);

        let mut restored = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
        restored.vt_write(&bounded);
        assert!(restored.viewport_text().unwrap().contains("LATEST-VISIBLE-CONTENT"));
    }

    #[test]
    fn bounded_vt_replay_preserves_complete_history_when_it_fits() {
        let mut source = Terminal::new(80, 24, 4 * 1024 * 1024, Callbacks::default()).unwrap();
        for index in 0..10_000 {
            source.vt_write(format!("plain-history-{index:05}\r\n").as_bytes());
        }
        source.vt_write(b"LATEST-VISIBLE-CONTENT");

        let full = source.vt_replay().unwrap();
        assert!(full.len() < 8 * 1024 * 1024);
        assert_eq!(source.vt_replay_bounded(8 * 1024 * 1024).unwrap(), full);
    }

    #[test]
    fn bounded_vt_replay_limits_rows_before_formatting_large_history() {
        let rows = vt_replay_row_window(1_000_000, 24, 80, 8 * 1024 * 1024);

        assert_eq!(rows, 3_276);
    }
}
