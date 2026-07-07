use std::ffi::c_void;
use std::ptr;

use ghostty_vt_sys as sys;

use crate::{check, Result};

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

/// A terminal instance: VT parser plus full screen/scrollback state.
pub struct Terminal {
    raw: sys::GhosttyTerminal,
    // Heap-pinned so the userdata pointer stays valid for the terminal's
    // lifetime.
    callbacks: Box<Callbacks>,
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

        let mut term = Terminal { raw, callbacks: Box::new(callbacks) };
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

    /// Feed VT-encoded bytes (pty output) into the terminal.
    pub fn vt_write(&mut self, data: &[u8]) {
        if data.is_empty() {
            return;
        }
        unsafe { sys::ghostty_terminal_vt_write(self.raw, data.as_ptr(), data.len()) }
    }

    /// Set host-provided default foreground/background colors.
    ///
    /// `None` leaves that channel unchanged.
    pub fn set_default_colors(&mut self, fg: Option<Rgb>, bg: Option<Rgb>) {
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
        }
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
        let grid_ref = |x: u16, y: u64| -> Option<sys::GhosttyGridRef> {
            let y = u32::try_from(y).ok()?;
            let point = sys::GhosttyPoint {
                tag,
                value: sys::GhosttyPointValue { coordinate: sys::GhosttyPointCoordinate { x, y } },
            };
            let mut out = sys::GhosttyGridRef {
                size: std::mem::size_of::<sys::GhosttyGridRef>(),
                ..Default::default()
            };
            let result = unsafe { sys::ghostty_terminal_grid_ref(self.raw, point, &mut out) };
            (result == sys::GHOSTTY_SUCCESS).then_some(out)
        };
        let selection = sys::GhosttySelection {
            size: std::mem::size_of::<sys::GhosttySelection>(),
            start: grid_ref(start.0, start.1)?,
            end: grid_ref(end.0, end.1)?,
            rectangle: false,
        };
        let opts = sys::GhosttyFormatterTerminalOptions {
            size: std::mem::size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: sys::GHOSTTY_FORMATTER_FORMAT_PLAIN,
            unwrap: unwrap_lines,
            trim,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: std::mem::size_of::<sys::GhosttyFormatterTerminalExtra>(),
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
            size: std::mem::size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: sys::GHOSTTY_FORMATTER_FORMAT_PLAIN,
            unwrap: false,
            trim: true,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: std::mem::size_of::<sys::GhosttyFormatterTerminalExtra>(),
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
        let opts = sys::GhosttyFormatterTerminalOptions {
            size: std::mem::size_of::<sys::GhosttyFormatterTerminalOptions>(),
            emit: sys::GHOSTTY_FORMATTER_FORMAT_VT,
            unwrap: false,
            trim: false,
            extra: sys::GhosttyFormatterTerminalExtra {
                size: std::mem::size_of::<sys::GhosttyFormatterTerminalExtra>(),
                palette: true,
                modes: true,
                scrolling_region: true,
                tabstops: true,
                pwd: true,
                keyboard: true,
                screen: sys::GhosttyFormatterScreenExtra {
                    size: std::mem::size_of::<sys::GhosttyFormatterScreenExtra>(),
                    cursor: true,
                    style: true,
                    hyperlink: true,
                    protection: true,
                    kitty_keyboard: true,
                    charsets: true,
                },
            },
            selection: ptr::null(),
        };
        self.format(opts)
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
