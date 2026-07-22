use std::ffi::c_void;
use std::ptr;

use ghostty_vt_sys as sys;

use crate::terminal::{Rgb, Terminal};
use crate::{Result, check};

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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CursorInfo {
    pub x: u16,
    pub y: u16,
    pub shape: CursorShape,
    pub blinking: bool,
}

/// A terminal color as authored by the application, before palette resolution.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ColorSpec {
    #[default]
    Default,
    Palette(u8),
    Rgb(Rgb),
}

/// The width role of a cell in Ghostty's grid.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CellWidth {
    /// A normal one-column cell.
    #[default]
    Narrow,
    /// The lead cell of a two-column grapheme.
    Wide,
    /// The trailing spacer cell of a two-column grapheme.
    SpacerTail,
    /// An end-of-row spacer inserted before a wide grapheme soft-wraps.
    SpacerHead,
}

/// The exact SGR underline variant for a cell or rendered run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnderlineStyle {
    Single,
    Double,
    Curly,
    Dotted,
    Dashed,
}

/// Protocol-v7 attribute bits produced by [`Cell::attrs`].
pub const ATTR_BOLD: u16 = 0x0001;
pub const ATTR_ITALIC: u16 = 0x0002;
pub const ATTR_STRIKETHROUGH: u16 = 0x0004;
pub const ATTR_INVERSE: u16 = 0x0008;
pub const ATTR_FAINT: u16 = 0x0010;
pub const ATTR_INVISIBLE: u16 = 0x0020;
pub const ATTR_BLINK: u16 = 0x0040;

/// One rendered cell.
///
/// `text` is empty for blank cells (draw a space with `bg`). [`Cell::width`]
/// distinguishes those blanks from the empty trailing cell of a wide
/// grapheme. `fg` and `bg` preserve the authored color form for the local
/// TUI, while `resolved_fg` and `resolved_bg` contain protocol-ready RGB.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Cell {
    pub text: String,
    pub width: CellWidth,
    pub fg: ColorSpec,
    pub bg: ColorSpec,
    pub resolved_fg: Option<Rgb>,
    pub resolved_bg: Option<Rgb>,
    pub bold: bool,
    pub faint: bool,
    pub italic: bool,
    pub underline: bool,
    pub underline_style: Option<UnderlineStyle>,
    pub strikethrough: bool,
    pub inverse: bool,
    pub blink: bool,
    pub invisible: bool,
}

impl Cell {
    /// Boolean attributes encoded with the protocol-v7 bit assignments.
    pub fn attrs(&self) -> u16 {
        (if self.bold { ATTR_BOLD } else { 0 })
            | (if self.italic { ATTR_ITALIC } else { 0 })
            | (if self.strikethrough { ATTR_STRIKETHROUGH } else { 0 })
            | (if self.inverse { ATTR_INVERSE } else { 0 })
            | (if self.faint { ATTR_FAINT } else { 0 })
            | (if self.invisible { ATTR_INVISIBLE } else { 0 })
            | (if self.blink { ATTR_BLINK } else { 0 })
    }
}

/// A maximal adjacent same-style span ready for protocol-v7 serialization.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StyledRun {
    pub text: String,
    pub fg: Option<Rgb>,
    pub bg: Option<Rgb>,
    pub attrs: u16,
    pub underline: Option<UnderlineStyle>,
    /// Grid columns covered when Unicode width alone is ambiguous.
    pub width_hint: Option<u16>,
}

/// Convert styled cell rows into maximal protocol-v7 runs.
///
/// Blank narrow cells become spaces. A wide lead contributes its grapheme
/// once and its immediately following spacer contributes only a grid column,
/// so no empty-text spacer run is emitted. An orphan spacer is represented as
/// a space to keep every returned run drawable and width-accounted.
pub fn rows_to_runs(rows: &[Vec<Cell>]) -> Vec<Vec<StyledRun>> {
    rows.iter().map(|row| row_to_runs(row)).collect()
}

/// An immutable terminal frame whose damage can be read by any number of
/// consumers.
#[derive(Debug, Clone)]
pub struct RenderFrame {
    pub seq: u64,
    pub dirty: Dirty,
    pub size: (u16, u16),
    pub cursor: Option<CursorInfo>,
    pub cursor_visual: (CursorShape, bool),
    pub cursor_color: Option<Rgb>,
    pub default_colors: (Rgb, Rgb),
    pub dirty_rows: Vec<u16>,
    rows: Vec<Vec<Cell>>,
}

impl RenderFrame {
    /// All viewport rows in this immutable snapshot.
    pub fn styled_rows(&self) -> &[Vec<Cell>] {
        &self.rows
    }

    /// One viewport row from this immutable snapshot.
    pub fn styled_row(&self, row: u16) -> Option<&[Cell]> {
        self.rows.get(row as usize).map(Vec::as_slice)
    }

    /// Assemble all snapshot rows into protocol-v7 runs.
    pub fn runs(&self) -> Vec<Vec<StyledRun>> {
        rows_to_runs(&self.rows)
    }

    /// Assemble one snapshot row into protocol-v7 runs.
    pub fn row_runs(&self, row: u16) -> Option<Vec<StyledRun>> {
        self.styled_row(row).map(row_to_runs)
    }
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
    palette: [Rgb; 256],
    default_palette: [Rgb; 256],
    next_frame_seq: u64,
}

unsafe impl Send for RenderState {}

impl RenderState {
    pub fn new() -> Result<Self> {
        let mut raw: sys::GhosttyRenderState = ptr::null_mut();
        check(unsafe { sys::ghostty_render_state_new(ptr::null(), &mut raw) })?;
        let mut rows: sys::GhosttyRenderStateRowIterator = ptr::null_mut();
        if let Err(e) =
            check(unsafe { sys::ghostty_render_state_row_iterator_new(ptr::null(), &mut rows) })
        {
            unsafe { sys::ghostty_render_state_free(raw) };
            return Err(e);
        }
        let mut cells: sys::GhosttyRenderStateRowCells = ptr::null_mut();
        if let Err(e) =
            check(unsafe { sys::ghostty_render_state_row_cells_new(ptr::null(), &mut cells) })
        {
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
            palette: [Rgb::default(); 256],
            default_palette: [Rgb::default(); 256],
            next_frame_seq: 0,
        })
    }

    /// Snapshot the terminal's viewport into this render state.
    pub fn update(&mut self, terminal: &mut Terminal) -> Result<()> {
        check(unsafe { sys::ghostty_render_state_update(self.raw, terminal.raw()) })?;
        self.palette = terminal_palette(terminal.raw(), sys::GHOSTTY_TERMINAL_DATA_COLOR_PALETTE)?;
        self.default_palette =
            terminal_palette(terminal.raw(), sys::GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT)?;
        Ok(())
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

    /// Current palette entry for this frame, including OSC 4 overrides.
    pub fn palette_color(&self, idx: u8) -> Rgb {
        self.palette[idx as usize]
    }

    /// Whether this frame's palette entry differs from the terminal default.
    pub fn palette_overridden(&self, idx: u8) -> bool {
        let idx = idx as usize;
        self.palette[idx] != self.default_palette[idx]
    }

    /// Cursor state, or `None` when the cursor is invisible or outside the
    /// viewport (e.g. scrolled back).
    pub fn cursor(&self) -> Option<CursorInfo> {
        let visible: bool = self.get(sys::GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE).ok()?;
        let in_viewport: bool =
            self.get(sys::GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE).ok()?;
        if !visible || !in_viewport {
            return None;
        }
        let x: u16 = self.get(sys::GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X).ok()?;
        let y: u16 = self.get(sys::GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y).ok()?;
        let (shape, blinking) = self.cursor_visual().ok()?;
        Some(CursorInfo { x, y, shape, blinking })
    }

    /// Current cursor shape and blink mode, even when the cursor is hidden
    /// or outside the viewport.
    pub fn cursor_visual(&self) -> Result<(CursorShape, bool)> {
        let shape = match self.get::<sys::GhosttyRenderStateCursorVisualStyle>(
            sys::GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE,
        )? {
            sys::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR => CursorShape::Bar,
            sys::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE => CursorShape::Underline,
            sys::GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW => CursorShape::BlockHollow,
            _ => CursorShape::Block,
        };
        let blinking: bool = self.get(sys::GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING)?;
        Ok((shape, blinking))
    }

    /// Effective explicit OSC 12 cursor color, if one is set.
    pub fn cursor_color(&self) -> Option<Rgb> {
        let has_value: bool =
            self.get(sys::GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR_HAS_VALUE).ok()?;
        if !has_value {
            return None;
        }
        self.get::<sys::GhosttyColorRgb>(sys::GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR)
            .ok()
            .map(Rgb::from)
    }

    /// Consume the current damage once and return a shareable immutable frame.
    ///
    /// Both the global dirty state and every per-row dirty flag are cleared
    /// only after the frame has captured them. Any number of local or remote
    /// renderers can then read the returned frame without touching this state.
    pub fn build_frame(&mut self) -> Result<RenderFrame> {
        let dirty = self.dirty();
        let size = self.size();
        let cursor_visual = self.cursor_visual()?;
        let cursor = self.cursor();
        let cursor_color = self.cursor_color();
        let default_colors = self.default_colors();
        let mut rows = Vec::with_capacity(size.1 as usize);
        let mut dirty_rows = Vec::new();

        self.walk_rows(|row, row_dirty, cells| {
            rows.push(cells.to_vec());
            if row_dirty {
                dirty_rows.push(row as u16);
            }
        })?;

        if dirty == Dirty::Full {
            dirty_rows.clear();
            dirty_rows.extend(0..rows.len() as u16);
        }
        self.set_clean();

        self.next_frame_seq = self.next_frame_seq.wrapping_add(1);
        Ok(RenderFrame {
            seq: self.next_frame_seq,
            dirty,
            size,
            cursor,
            cursor_visual,
            cursor_color,
            default_colors,
            dirty_rows,
            rows,
        })
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

fn fill_cell(cells: sys::GhosttyRenderStateRowCells, cell: &mut Cell, grapheme_buf: &mut Vec<u32>) {
    cell.text.clear();

    let mut raw = sys::GhosttyCell::default();
    let raw_ok = unsafe {
        sys::ghostty_render_state_row_cells_get(
            cells,
            sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
            &mut raw as *mut _ as *mut c_void,
        )
    } == sys::GHOSTTY_SUCCESS;
    cell.width = if raw_ok { cell_width(raw) } else { CellWidth::Narrow };

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

    let mut style =
        sys::GhosttyStyle { size: size_of::<sys::GhosttyStyle>(), ..Default::default() };
    let style_ok = unsafe {
        sys::ghostty_render_state_row_cells_get(
            cells,
            sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
            &mut style as *mut _ as *mut c_void,
        )
    } == sys::GHOSTTY_SUCCESS;
    if style_ok {
        apply_style(cell, raw, &style);
    } else {
        apply_default_style(cell);
    }

    cell.resolved_fg = render_cell_color(cells, sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR);
    cell.resolved_bg = render_cell_color(cells, sys::GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR);
}

pub(crate) fn terminal_palette(
    terminal: sys::GhosttyTerminal,
    data: sys::GhosttyTerminalData,
) -> Result<[Rgb; 256]> {
    let mut palette = [sys::GhosttyColorRgb::default(); 256];
    check(unsafe {
        sys::ghostty_terminal_get(terminal, data, palette.as_mut_ptr() as *mut c_void)
    })?;
    Ok(palette.map(Rgb::from))
}

pub(crate) fn read_grid_ref_cell(
    grid_ref: &sys::GhosttyGridRef,
    palette: &[Rgb; 256],
    grapheme_buf: &mut Vec<u32>,
) -> Result<Cell> {
    let mut raw = sys::GhosttyCell::default();
    check(unsafe { sys::ghostty_grid_ref_cell(grid_ref, &mut raw) })?;

    let mut style =
        sys::GhosttyStyle { size: size_of::<sys::GhosttyStyle>(), ..Default::default() };
    check(unsafe { sys::ghostty_grid_ref_style(grid_ref, &mut style) })?;

    let mut grapheme_len = 0usize;
    let query =
        unsafe { sys::ghostty_grid_ref_graphemes(grid_ref, ptr::null_mut(), 0, &mut grapheme_len) };
    if query != sys::GHOSTTY_SUCCESS && query != sys::GHOSTTY_OUT_OF_SPACE {
        check(query)?;
    }

    let mut cell = Cell { width: cell_width(raw), ..Cell::default() };
    if grapheme_len > 0 {
        grapheme_buf.clear();
        grapheme_buf.resize(grapheme_len, 0);
        check(unsafe {
            sys::ghostty_grid_ref_graphemes(
                grid_ref,
                grapheme_buf.as_mut_ptr(),
                grapheme_buf.len(),
                &mut grapheme_len,
            )
        })?;
        for &cp in grapheme_buf.iter().take(grapheme_len) {
            cell.text.push(char::from_u32(cp).unwrap_or('\u{FFFD}'));
        }
    }

    apply_style(&mut cell, raw, &style);
    cell.resolved_fg = resolve_color_spec(cell.fg, palette);
    cell.resolved_bg = resolve_color_spec(cell.bg, palette);
    Ok(cell)
}

fn style_color_spec(color: sys::GhosttyStyleColor) -> ColorSpec {
    match color.tag {
        sys::GHOSTTY_STYLE_COLOR_PALETTE => ColorSpec::Palette(unsafe { color.value.palette }),
        sys::GHOSTTY_STYLE_COLOR_RGB => ColorSpec::Rgb(Rgb::from(unsafe { color.value.rgb })),
        _ => ColorSpec::Default,
    }
}

fn raw_cell_bg_spec(raw: sys::GhosttyCell) -> Option<ColorSpec> {
    let mut tag = sys::GHOSTTY_CELL_CONTENT_CODEPOINT;
    let tag_ok = unsafe {
        sys::ghostty_cell_get(
            raw,
            sys::GHOSTTY_CELL_DATA_CONTENT_TAG,
            &mut tag as *mut _ as *mut c_void,
        )
    } == sys::GHOSTTY_SUCCESS;
    if !tag_ok {
        return None;
    }

    match tag {
        sys::GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE => {
            let mut idx = 0;
            let color_ok = unsafe {
                sys::ghostty_cell_get(
                    raw,
                    sys::GHOSTTY_CELL_DATA_COLOR_PALETTE,
                    &mut idx as *mut _ as *mut c_void,
                )
            } == sys::GHOSTTY_SUCCESS;
            color_ok.then_some(ColorSpec::Palette(idx))
        }
        sys::GHOSTTY_CELL_CONTENT_BG_COLOR_RGB => {
            let mut rgb = sys::GhosttyColorRgb::default();
            let color_ok = unsafe {
                sys::ghostty_cell_get(
                    raw,
                    sys::GHOSTTY_CELL_DATA_COLOR_RGB,
                    &mut rgb as *mut _ as *mut c_void,
                )
            } == sys::GHOSTTY_SUCCESS;
            color_ok.then_some(ColorSpec::Rgb(Rgb::from(rgb)))
        }
        _ => None,
    }
}

fn cell_width(raw: sys::GhosttyCell) -> CellWidth {
    let mut wide = sys::GHOSTTY_CELL_WIDE_NARROW;
    let result = unsafe {
        sys::ghostty_cell_get(raw, sys::GHOSTTY_CELL_DATA_WIDE, &mut wide as *mut _ as *mut c_void)
    };
    if result != sys::GHOSTTY_SUCCESS {
        return CellWidth::Narrow;
    }
    match wide {
        sys::GHOSTTY_CELL_WIDE_WIDE => CellWidth::Wide,
        sys::GHOSTTY_CELL_WIDE_SPACER_TAIL => CellWidth::SpacerTail,
        sys::GHOSTTY_CELL_WIDE_SPACER_HEAD => CellWidth::SpacerHead,
        _ => CellWidth::Narrow,
    }
}

fn underline_style(value: i32) -> Option<UnderlineStyle> {
    match value {
        value if value == sys::GHOSTTY_SGR_UNDERLINE_SINGLE as i32 => Some(UnderlineStyle::Single),
        value if value == sys::GHOSTTY_SGR_UNDERLINE_DOUBLE as i32 => Some(UnderlineStyle::Double),
        value if value == sys::GHOSTTY_SGR_UNDERLINE_CURLY as i32 => Some(UnderlineStyle::Curly),
        value if value == sys::GHOSTTY_SGR_UNDERLINE_DOTTED as i32 => Some(UnderlineStyle::Dotted),
        value if value == sys::GHOSTTY_SGR_UNDERLINE_DASHED as i32 => Some(UnderlineStyle::Dashed),
        _ => None,
    }
}

fn apply_style(cell: &mut Cell, raw: sys::GhosttyCell, style: &sys::GhosttyStyle) {
    cell.bold = style.bold;
    cell.faint = style.faint;
    cell.italic = style.italic;
    cell.underline_style = underline_style(style.underline);
    cell.underline = cell.underline_style.is_some();
    cell.strikethrough = style.strikethrough;
    cell.inverse = style.inverse;
    cell.blink = style.blink;
    cell.invisible = style.invisible;
    cell.fg = style_color_spec(style.fg_color);
    cell.bg = raw_cell_bg_spec(raw).unwrap_or_else(|| style_color_spec(style.bg_color));
}

fn apply_default_style(cell: &mut Cell) {
    cell.bold = false;
    cell.faint = false;
    cell.italic = false;
    cell.underline = false;
    cell.underline_style = None;
    cell.strikethrough = false;
    cell.inverse = false;
    cell.blink = false;
    cell.invisible = false;
    cell.fg = ColorSpec::Default;
    cell.bg = ColorSpec::Default;
}

fn render_cell_color(
    cells: sys::GhosttyRenderStateRowCells,
    data: sys::GhosttyRenderStateRowCellsData,
) -> Option<Rgb> {
    let mut rgb = sys::GhosttyColorRgb::default();
    let result = unsafe {
        sys::ghostty_render_state_row_cells_get(cells, data, &mut rgb as *mut _ as *mut c_void)
    };
    (result == sys::GHOSTTY_SUCCESS).then(|| Rgb::from(rgb))
}

fn resolve_color_spec(spec: ColorSpec, palette: &[Rgb; 256]) -> Option<Rgb> {
    match spec {
        ColorSpec::Default => None,
        ColorSpec::Palette(index) => Some(palette[index as usize]),
        ColorSpec::Rgb(rgb) => Some(rgb),
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
struct RunKey {
    fg: Option<Rgb>,
    bg: Option<Rgb>,
    attrs: u16,
    underline: Option<UnderlineStyle>,
}

struct RunAccumulator {
    key: RunKey,
    text: String,
    columns: u16,
    ambiguous_width: bool,
}

impl RunAccumulator {
    fn finish(self) -> StyledRun {
        StyledRun {
            text: self.text,
            fg: self.key.fg,
            bg: self.key.bg,
            attrs: self.key.attrs,
            underline: self.key.underline,
            width_hint: self.ambiguous_width.then_some(self.columns),
        }
    }
}

fn row_to_runs(row: &[Cell]) -> Vec<StyledRun> {
    let mut runs: Vec<RunAccumulator> = Vec::new();
    let mut previous_was_wide = false;

    for cell in row {
        if cell.width == CellWidth::SpacerTail && previous_was_wide {
            if let Some(run) = runs.last_mut() {
                run.columns = run.columns.saturating_add(1);
                run.ambiguous_width = true;
            }
            previous_was_wide = false;
            continue;
        }

        let key = RunKey {
            fg: cell.resolved_fg,
            bg: cell.resolved_bg,
            attrs: cell.attrs(),
            underline: cell.underline_style,
        };
        let text = if cell.text.is_empty() { " " } else { &cell.text };
        let ambiguous_width = cell.width != CellWidth::Narrow;

        if let Some(run) = runs.last_mut().filter(|run| run.key == key) {
            run.text.push_str(text);
            run.columns = run.columns.saturating_add(1);
            run.ambiguous_width |= ambiguous_width;
        } else {
            runs.push(RunAccumulator { key, text: text.to_string(), columns: 1, ambiguous_width });
        }
        previous_was_wide = cell.width == CellWidth::Wide;
    }

    runs.into_iter().map(RunAccumulator::finish).collect()
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
