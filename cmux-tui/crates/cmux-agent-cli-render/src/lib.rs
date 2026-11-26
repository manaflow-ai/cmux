//! Draw an agent CLI's terminal look on the phone from its session's acpmux records, instead of
//! streaming the Mac's PTY (Leo, 2026-11-14: "but i mean the terminal like claude code cli codex
//! cli opencode etc can we still keep the current behaviour/appearance and not stream").
//!
//! Pure: records, a terminal size and chrome facts in; a [`Grid`] of styled cells out, which
//! [`Grid::runs`] turns into the render-mode row shape (`cmux-tui/spec/render.md`: maximal runs
//! with server-resolved colors and the protocol-v7 attribute bits).
//!
//! This is the feasibility stage. `tests/parity.rs` replays a real Claude Code session's PTY
//! bytes through ghostty-vt and compares each scripted screen, cell by cell, with what
//! [`claude::render`] draws from the acpmux records of the same moment. The measured gap (see
//! that test) is why nothing on the phone uses this yet: a lookalike that differs is worse than
//! the stream. [`hybrid`] adds what the records lack: the Mac sends only the cells that differ
//! from the drawn screen, and `tests/parity.rs` measures its parity and bytes against the PTY.

pub mod adapter;
pub mod claude;
pub mod hybrid;
pub mod lean;
pub mod stream;
pub mod vt;

/// A cell color as the CLI authored it, before a theme resolves it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub enum Color {
    /// The terminal's default foreground or background.
    #[default]
    Default,
    /// A 256-color palette index.
    Palette(u8),
    /// A 24-bit color.
    Rgb(u8, u8, u8),
}

/// Protocol-v7 attribute bits (`spec/render.md`).
pub const BOLD: u16 = 0x0001;
pub const ITALIC: u16 = 0x0002;
pub const STRIKETHROUGH: u16 = 0x0004;
pub const INVERSE: u16 = 0x0008;
pub const FAINT: u16 = 0x0010;
pub const INVISIBLE: u16 = 0x0020;
pub const BLINK: u16 = 0x0040;
/// Not a protocol-v7 bit (render mode sends underline as its own field): the hybrid stream's
/// own bit for an underlined cell, from the reserved range.
pub const UNDERLINE: u16 = 0x0100;
/// With [`UNDERLINE`]: which underline, also from the reserved range (0 is a single line, so a
/// viewer that reads only [`UNDERLINE`] draws what it drew before): [`UNDERLINE_DOUBLE`],
/// [`UNDERLINE_CURLY`], [`UNDERLINE_DOTTED`] or [`UNDERLINE_DASHED`] (SGR `4:2` to `4:5`).
pub const UNDERLINE_STYLE: u16 = 0x0e00;
pub const UNDERLINE_DOUBLE: u16 = 0x0200;
pub const UNDERLINE_CURLY: u16 = 0x0400;
pub const UNDERLINE_DOTTED: u16 = 0x0600;
pub const UNDERLINE_DASHED: u16 = 0x0800;

/// One cell's style.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct Style {
    pub fg: Color,
    pub bg: Color,
    pub attrs: u16,
}

impl Style {
    pub const PLAIN: Style = Style { fg: Color::Default, bg: Color::Default, attrs: 0 };

    pub const fn fg(index: u8) -> Style {
        Style { fg: Color::Palette(index), bg: Color::Default, attrs: 0 }
    }

    pub const fn on(self, index: u8) -> Style {
        Style { bg: Color::Palette(index), ..self }
    }

    pub const fn with(self, attrs: u16) -> Style {
        Style { attrs: self.attrs | attrs, ..self }
    }
}

/// One grid cell. `text` is empty for a blank cell and for the trailing half of a wide grapheme.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Cell {
    pub text: String,
    pub style: Style,
}

impl Cell {
    /// Whether the cell draws no glyph: blank, a space or a no-break space. Its foreground then
    /// shows nowhere, so [`Cell::looks_same`] ignores it.
    pub fn is_blank(&self) -> bool {
        matches!(self.text.as_str(), "" | " " | "\u{a0}")
    }

    /// Whether two cells draw the same pixels: the same glyph, background and attributes, and
    /// the same foreground unless neither draws a glyph (inverse draws the foreground as the
    /// background, so it always counts).
    pub fn looks_same(&self, other: &Cell) -> bool {
        let blank = self.is_blank() && other.is_blank();
        let text = blank || self.text == other.text;
        let fg_shows = !blank || (self.style.attrs | other.style.attrs) & INVERSE != 0;
        text && self.style.bg == other.style.bg
            && self.style.attrs == other.style.attrs
            && (!fg_shows || self.style.fg == other.style.fg)
    }
}

/// A screen of cells, `rows` rows of `cols` cells each.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Grid {
    pub cols: u16,
    pub rows: u16,
    pub cells: Vec<Vec<Cell>>,
}

/// A render-mode run (`spec/render.md` `Run`): `fg`/`bg` resolved, `None` for the default.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Run {
    pub text: String,
    pub fg: Option<(u8, u8, u8)>,
    pub bg: Option<(u8, u8, u8)>,
    pub attrs: u16,
}

impl Grid {
    pub fn blank(cols: u16, rows: u16) -> Grid {
        Grid {
            cols,
            rows,
            cells: vec![vec![Cell::default(); usize::from(cols)]; usize::from(rows)],
        }
    }

    /// The share of cells that look the same in both grids, as (same, total). Grids of
    /// different sizes compare over this grid's cells, a missing cell counting as different.
    pub fn parity(&self, other: &Grid) -> (usize, usize) {
        let mut same = 0;
        let mut total = 0;
        for (y, row) in self.cells.iter().enumerate() {
            for (x, cell) in row.iter().enumerate() {
                total += 1;
                if other.cells.get(y).and_then(|r| r.get(x)).is_some_and(|o| cell.looks_same(o)) {
                    same += 1;
                }
            }
        }
        (same, total)
    }

    /// The row as plain text, blanks as spaces, trailing blanks trimmed.
    pub fn row_text(&self, y: usize) -> String {
        let text: String = self
            .cells
            .get(y)
            .into_iter()
            .flatten()
            .map(|c| if c.text.is_empty() { " " } else { c.text.as_str() })
            .collect();
        text.trim_end().to_owned()
    }

    /// Each row as maximal runs of one style, colors resolved through `palette` (the
    /// 256-color table of the theme the phone draws with).
    pub fn runs(&self, palette: &[(u8, u8, u8); 256]) -> Vec<Vec<Run>> {
        let resolve = |c: Color| match c {
            Color::Default => None,
            Color::Palette(i) => palette.get(usize::from(i)).copied(),
            Color::Rgb(r, g, b) => Some((r, g, b)),
        };
        self.cells
            .iter()
            .map(|row| {
                let mut runs: Vec<Run> = Vec::new();
                let mut after_wide = false;
                for cell in row {
                    let (fg, bg) = (resolve(cell.style.fg), resolve(cell.style.bg));
                    // The trailing half of a wide grapheme adds a column, not a glyph.
                    let spacer = after_wide && cell.text.is_empty();
                    after_wide = !spacer && str_width(&cell.text) == 2;
                    let text = match (spacer, cell.text.is_empty()) {
                        (true, _) => "",
                        (false, true) => " ",
                        (false, false) => cell.text.as_str(),
                    };
                    match runs.last_mut() {
                        Some(run)
                            if run.fg == fg && run.bg == bg && run.attrs == cell.style.attrs =>
                        {
                            run.text.push_str(text);
                        }
                        _ => runs.push(Run {
                            text: text.to_owned(),
                            fg,
                            bg,
                            attrs: cell.style.attrs,
                        }),
                    }
                }
                runs
            })
            .collect()
    }
}

/// The xterm 256-color table: 16 ANSI colors, the 6x6x6 cube and the gray ramp.
pub fn xterm_palette() -> [(u8, u8, u8); 256] {
    const ANSI: [(u8, u8, u8); 16] = [
        (0, 0, 0),
        (205, 0, 0),
        (0, 205, 0),
        (205, 205, 0),
        (0, 0, 238),
        (205, 0, 205),
        (0, 205, 205),
        (229, 229, 229),
        (127, 127, 127),
        (255, 0, 0),
        (0, 255, 0),
        (255, 255, 0),
        (92, 92, 255),
        (255, 0, 255),
        (0, 255, 255),
        (255, 255, 255),
    ];
    let mut table = [(0, 0, 0); 256];
    for (i, slot) in table.iter_mut().enumerate() {
        *slot = match i {
            0..=15 => ANSI.get(i).copied().unwrap_or_default(),
            16..=231 => {
                let n = i - 16;
                let level = |v: usize| if v == 0 { 0 } else { (55 + v * 40) as u8 };
                (level(n / 36), level((n / 6) % 6), level(n % 6))
            }
            _ => {
                let v = (8 + (i - 232) * 10) as u8;
                (v, v, v)
            }
        };
    }
    table
}

/// Terminal columns `c` takes: 2 for East Asian wide and emoji ranges, 0 for combining marks,
/// else 1. Enough for agent transcripts; a grapheme the table gets wrong shows as a parity gap.
pub fn char_width(c: char) -> usize {
    let u = u32::from(c);
    match u {
        0x0300..=0x036F | 0x200B..=0x200F | 0xFE00..=0xFE0F => 0,
        0x1100..=0x115F
        | 0x2E80..=0x303E
        | 0x3041..=0x33FF
        | 0x3400..=0x4DBF
        | 0x4E00..=0x9FFF
        | 0xA000..=0xA4CF
        | 0xAC00..=0xD7A3
        | 0xF900..=0xFAFF
        | 0xFE30..=0xFE4F
        | 0xFF00..=0xFF60
        | 0xFFE0..=0xFFE6
        | 0x1F300..=0x1F64F
        | 0x1F900..=0x1F9FF
        | 0x20000..=0x3FFFD => 2,
        _ => 1,
    }
}

/// Columns `s` takes.
pub fn str_width(s: &str) -> usize {
    s.chars().map(char_width).sum()
}

/// One line being laid out: styled cells, at most `cols` wide.
#[derive(Debug, Clone, Default)]
pub struct Line {
    pub cells: Vec<Cell>,
}

impl Line {
    pub fn new() -> Line {
        Line::default()
    }

    pub fn width(&self) -> usize {
        self.cells.len()
    }

    /// Appends `text` in `style`, a cell per column.
    pub fn push(&mut self, text: &str, style: Style) -> &mut Line {
        for c in text.chars() {
            match char_width(c) {
                0 => {
                    if let Some(last) =
                        self.cells.iter_mut().rev().find(|cell| !cell.text.is_empty())
                    {
                        last.text.push(c);
                    }
                }
                w => {
                    self.cells.push(Cell { text: c.to_string(), style });
                    for _ in 1..w {
                        self.cells.push(Cell { text: String::new(), style });
                    }
                }
            }
        }
        self
    }

    /// Pads with `style` spaces to `width` columns.
    pub fn pad_to(&mut self, width: usize, style: Style) -> &mut Line {
        while self.cells.len() < width {
            self.cells.push(Cell { text: " ".to_owned(), style });
        }
        self
    }

    /// The line as one grid row of `cols` cells: cut, or filled with default blanks.
    pub fn into_row(mut self, cols: usize) -> Vec<Cell> {
        self.cells.truncate(cols);
        self.cells.resize(cols, Cell::default());
        self.cells
    }
}

/// Word-wraps `text` to `width` columns the way Ink's `wrap-ansi` does with `trim: false`: a
/// line breaks before the word that would pass `width`, the space before that word stays on
/// the line, and a word longer than `width` is cut. A newline always breaks.
pub fn wrap(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut out = Vec::new();
    for para in text.split('\n') {
        let mut line = String::new();
        let mut line_w = 0;
        // Words with the spaces that follow them.
        let mut rest = para;
        if rest.is_empty() {
            out.push(String::new());
            continue;
        }
        while !rest.is_empty() {
            let word_end = rest.find(' ').unwrap_or(rest.len());
            let space_end = rest
                .get(word_end..)
                .map(|tail| word_end + tail.len() - tail.trim_start_matches(' ').len())
                .unwrap_or(word_end);
            let word = rest.get(..word_end).unwrap_or_default();
            let spaces = rest.get(word_end..space_end).unwrap_or_default();
            rest = rest.get(space_end..).unwrap_or_default();
            let ww = str_width(word);
            if line_w > 0 && line_w + ww > width {
                out.push(std::mem::take(&mut line));
                line_w = 0;
            }
            // A word longer than a line is cut at the width.
            let mut word = word.to_owned();
            while str_width(&word) > width {
                let mut head = String::new();
                let mut head_w = 0;
                let mut cut = 0;
                for (i, c) in word.char_indices() {
                    if line_w + head_w + char_width(c) > width {
                        cut = i;
                        break;
                    }
                    head.push(c);
                    head_w += char_width(c);
                }
                line.push_str(&head);
                out.push(std::mem::take(&mut line));
                line_w = 0;
                word = word.get(cut..).unwrap_or_default().to_owned();
            }
            line.push_str(&word);
            line_w += str_width(&word);
            // The spaces after a word stay with it while they fit.
            for c in spaces.chars() {
                if line_w < width {
                    line.push(c);
                    line_w += 1;
                }
            }
        }
        out.push(line);
    }
    out
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
