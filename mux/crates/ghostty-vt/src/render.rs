use std::ffi::c_void;
use std::ptr;

use ghostty_vt_sys as sys;

use crate::terminal::{Rgb, Terminal};
use crate::{check, Result};

/// Global dirty state after a [`RenderState::update`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dirty {
    Clean,
    Partial,
    Full,
}

/// Cursor visual shape.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CursorShape {
    Bar,
    Block,
    Underline,
    BlockHollow,
}

/// Cursor state within the viewport.
#[derive(Debug, Clone, Copy)]
pub struct CursorInfo {
    pub x: u16,
    pub y: u16,
    pub shape: CursorShape,
    pub blinking: bool,
}

/// One rendered cell.
///
/// `text` is empty for blank cells (draw a space with `bg`). Wide
/// graphemes occupy the head cell; the following spacer cell also has
/// empty text.
#[derive(Debug, Clone, Default)]
pub struct Cell {
    pub text: String,
    pub fg: Option<Rgb>,
    pub bg: Option<Rgb>,
    pub bold: bool,
    pub faint: bool,
    pub italic: bool,
    pub underline: bool,
    pub strikethrough: bool,
    pub inverse: bool,
    pub blink: bool,
    pub invisible: bool,
}

/// Snapshot of everything needed to draw one frame of a terminal.
///
/// Update it while holding exclusive access to the [`Terminal`]; reading
/// afterwards no longer touches the terminal, so pty IO can continue
/// concurrently.
pub struct RenderState {
    raw: sys::GhosttyRenderState,
    rows: sys::GhosttyRenderStateRowIterator,
    cells: sys::GhosttyRenderStateRowCells,
    row_buf: Vec<Cell>,
    grapheme_buf: Vec<u32>,
}

unsafe impl Send for RenderState {}

impl RenderState {
    pub fn new() -> Result<Self> {
        let mut raw: sys::GhosttyRenderState = ptr::null_mut();
        check(unsafe { sys::ghostty_render_state_new(ptr::null(), &mut raw) })?;
        let mut rows: sys::GhosttyRenderStateRowIterator = ptr::null_mut();
        if let Err(e) = check(unsafe { sys::ghostty_render_state_row_iterator_new(ptr::null(), &mut rows) }) {
            unsafe { sys::ghostty_render_state_free(raw) };
            return Err(e);
        }
        let mut cells: sys::GhosttyRenderStateRowCells = ptr::null_mut();
        if let Err(e) = check(unsafe { sys::ghostty_render_state_row_cells_new(ptr::null(), &mut cells) }) {
            unsafe {
                sys::ghostty_render_state_row_iterator_free(rows);
                sys::ghostty_render_state_free(raw);
            }
            return Err(e);
        }
        Ok(RenderState {
            raw,
            rows,
            cells,
            row_buf: Vec::new(),
            grapheme_buf: Vec::new(),
        })
    }

    /// Snapshot the terminal's viewport into this render state.
    pub fn update(&mut self, terminal: &mut Terminal) -> Result<()> {
        check(unsafe { sys::ghostty_render_state_update(self.raw, terminal.raw()) })
    }

    fn get<T: Default>(&self, data: sys::GhosttyRenderStateData) -> Result<T> {
        let mut out = T::default();
        check(unsafe {
            sys::ghostty_render_state_get(self.raw, data, &mut out as *mut T as *mut c_void)
        })?;
        Ok(out)
    }

    pub fn dirty(&self) -> Dirty {
        match self.get::<sys::GhosttyRenderStateDirty>(sys::GHOSTTY_RENDER_STATE_DATA_DIRTY) {
            Ok(sys::GHOSTTY_RENDER_STATE_DIRTY_PARTIAL) => Dirty::Partial,
            Ok(sys::GHOSTTY_RENDER_STATE_DIRTY_FULL) => Dirty::Full,
            _ => Dirty::Clean,
        }
    }

    /// Reset the global dirty flag after drawing a frame.
    pub fn set_clean(&mut self) {
        let value = sys::GHOSTTY_RENDER_STATE_DIRTY_FALSE;
        unsafe {
            sys::ghostty_render_state_set(
                self.raw,
                sys::GHOSTTY_RENDER_STATE_OPTION_DIRTY,
                &value as *const _ as *const c_void,
            );
        }
    }

    /// Viewport size as (cols, rows).
    pub fn size(&self) -> (u16, u16) {
        let cols = self.get::<u16>(sys::GHOSTTY_RENDER_STATE_DATA_COLS).unwrap_or(0);
        let rows = self.get::<u16>(sys::GHOSTTY_RENDER_STATE_DATA_ROWS).unwrap_or(0);
        (cols, rows)
    }

    /// Default background and foreground for this frame.
    pub fn default_colors(&self) -> (Rgb, Rgb) {
        let bg = self
            .get::<sys::GhosttyColorRgb>(sys::GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND)
            .map(Rgb::from)
            .unwrap_or_default();
        let fg = self
            .get::<sys::GhosttyColorRgb>(sys::GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND)
            .map(Rgb::from)
            .unwrap_or(Rgb { r: 255, g: 255, b: 255 });
        (bg, fg)
    }

    /// Cursor state, or `None` when the cursor is invisible or outside the
    /// viewport (e.g. scrolled back).
    pub fn cursor(&self) -> Option<CursorInfo> {
        let visible: bool = self.get(sys::GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE).ok()?;
        let in_viewport: bool = self
            .get(sys::GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE)
            .ok()?;
        if !visible || !in_viewport {
            return None;
        }
        let x: u16 = self.get(sys::GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X).ok()?;
        let y: u16 = self.get(sys::GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y).ok()?;
        let shape = match self
            .get::<sys::GhosttyRenderStateCursorVisualStyle>(
                sys::GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE,
            )
            .unwrap_or(sys::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK)
        {
            sys::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR => CursorShape::Bar,
            sys::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE => CursorShape::Underline,
            sys::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW => CursorShape::BlockHollow,
            _ => CursorShape::Block,
        };
        let blinking: bool = self
            .get(sys::GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING)
            .unwrap_or(false);
        Some(CursorInfo { x, y, shape, blinking })
    }

    /// Walk every row of the snapshot top to bottom. The callback receives
    /// the row index, the row's dirty flag, and its cells. Row dirty flags
    /// are cleared as part of the walk.
    pub fn walk_rows(&mut self, mut f: impl FnMut(usize, bool, &[Cell])) -> Result<()> {
        check(unsafe {
            sys::ghostty_render_state_get(
                self.raw,
                sys::GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                &mut self.rows as *mut _ as *mut c_void,
            )
        })?;

        let mut row_index = 0usize;
        while unsafe { sys::ghostty_render_state_row_iterator_next(self.rows) } {
            let mut dirty = false;
            unsafe {
                sys::ghostty_render_state_row_get(
                    self.rows,
                    sys::GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
                    &mut dirty as *mut _ as *mut c_void,
                );
            }

            check(unsafe {
                sys::ghostty_render_state_row_get(
                    self.rows,
                    sys::GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                    &mut self.cells as *mut _ as *mut c_void,
                )
            })?;

            // Reuse the row buffer (and each Cell's String capacity).
            let mut col = 0usize;
            while unsafe { sys::ghostty_render_state_row_cells_next(self.cells) } {
                if self.row_buf.len() <= col {
                    self.row_buf.push(Cell::default());
                }
                let cell = &mut self.row_buf[col];
                fill_cell(self.cells, cell, &mut self.grapheme_buf);
                col += 1;
            }
            self.row_buf.truncate(col);

            if dirty {
                let clean = false;
                unsafe {
                    sys::ghostty_render_state_row_set(
                        self.rows,
                        sys::GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY,
                        &clean as *const _ as *const c_void,
                    );
                }
            }

            f(row_index, dirty, &self.row_buf);
            row_index += 1;
        }
        Ok(())
    }

    /// Convenience: the viewport rendered as plain text lines (used by
    /// tests and debugging, not by the TUI hot path).
    pub fn text_lines(&mut self) -> Result<Vec<String>> {
        let mut lines = Vec::new();
        self.walk_rows(|_, _, cells| {
            let mut line = String::new();
            for cell in cells {
                if cell.text.is_empty() {
                    line.push(' ');
                } else {
                    line.push_str(&cell.text);
                }
            }
            lines.push(line.trim_end().to_string());
        })?;
        Ok(lines)
    }
}

fn fill_cell(
    cells: sys::GhosttyRenderStateRowCells,
    cell: &mut Cell,
    grapheme_buf: &mut Vec<u32>,
) {
    cell.text.clear();

    let mut grapheme_len: u32 = 0;
    unsafe {
        sys::ghostty_render_state_row_cells_get(
            cells,
            sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
            &mut grapheme_len as *mut _ as *mut c_void,
        );
    }
    if grapheme_len > 0 {
        grapheme_buf.clear();
        grapheme_buf.resize(grapheme_len as usize, 0);
        let result = unsafe {
            sys::ghostty_render_state_row_cells_get(
                cells,
                sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                grapheme_buf.as_mut_ptr() as *mut c_void,
            )
        };
        if result == sys::GHOSTTY_SUCCESS {
            for &cp in grapheme_buf.iter() {
                cell.text.push(char::from_u32(cp).unwrap_or('\u{FFFD}'));
            }
        }
    }

    let mut style = sys::GhosttyStyle {
        size: std::mem::size_of::<sys::GhosttyStyle>(),
        ..Default::default()
    };
    let style_ok = unsafe {
        sys::ghostty_render_state_row_cells_get(
            cells,
            sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
            &mut style as *mut _ as *mut c_void,
        )
    } == sys::GHOSTTY_SUCCESS;
    if style_ok {
        cell.bold = style.bold;
        cell.faint = style.faint;
        cell.italic = style.italic;
        cell.underline = style.underline != sys::GHOSTTY_SGR_UNDERLINE_NONE as i32;
        cell.strikethrough = style.strikethrough;
        cell.inverse = style.inverse;
        cell.blink = style.blink;
        cell.invisible = style.invisible;
    } else {
        cell.bold = false;
        cell.faint = false;
        cell.italic = false;
        cell.underline = false;
        cell.strikethrough = false;
        cell.inverse = false;
        cell.blink = false;
        cell.invisible = false;
    }

    let mut fg = sys::GhosttyColorRgb::default();
    cell.fg = (unsafe {
        sys::ghostty_render_state_row_cells_get(
            cells,
            sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
            &mut fg as *mut _ as *mut c_void,
        )
    } == sys::GHOSTTY_SUCCESS)
        .then(|| Rgb::from(fg));

    let mut bg = sys::GhosttyColorRgb::default();
    cell.bg = (unsafe {
        sys::ghostty_render_state_row_cells_get(
            cells,
            sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
            &mut bg as *mut _ as *mut c_void,
        )
    } == sys::GHOSTTY_SUCCESS)
        .then(|| Rgb::from(bg));
}

impl Drop for RenderState {
    fn drop(&mut self) {
        unsafe {
            sys::ghostty_render_state_row_cells_free(self.cells);
            sys::ghostty_render_state_row_iterator_free(self.rows);
            sys::ghostty_render_state_free(self.raw);
        }
    }
}
