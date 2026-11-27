//! The 120 fps gradient's frames, byte for byte as tuikit.py's `Gradient.frame` draws them for the
//! same style (tuikit.py `gradient_style(seed)`, passed on the command line) and the same shown time.
//! The layout (which element sits where) is tuikit.py's `gradient_layout`; `tuikit.py describe`
//! prints it.

use std::fmt::Write as _;

pub const BSU: &str = "\x1b[?2026h";
pub const ESU: &str = "\x1b[?2026l";
pub const RESET: &str = "\x1b[0m";
pub const ALT_ON: &str = "\x1b[?1049h";
pub const ALT_OFF: &str = "\x1b[?1049l";
pub const HIDE: &str = "\x1b[?25l";
pub const SHOW: &str = "\x1b[?25h";
pub const WRAP_OFF: &str = "\x1b[?7l";
pub const WRAP_ON: &str = "\x1b[?7h";

const PERIOD: usize = 240;
const BARCODE_BITS: u32 = 20;
const BOX_W: usize = 28;
const BOX_ROW: usize = 3;
const BOX_COL: usize = 2;
const WIDE_ROW: usize = 11;
const EMOJI_ROW: usize = 12;
const RULER_ROW: usize = 13;
const RULER: &str = "012345678901234567890123";
const INK: &str = "\x1b[0;97;40m";
const SPIN: [char; 4] = ['◐', '◓', '◑', '◒'];
const BIG: [[&str; 5]; 10] = [
    ["███", "█ █", "█ █", "█ █", "███"],
    [" █ ", "██ ", " █ ", " █ ", "███"],
    ["███", "  █", "███", "█  ", "███"],
    ["███", "  █", "███", "  █", "███"],
    ["█ █", "█ █", "███", "  █", "  █"],
    ["███", "█  ", "███", "  █", "███"],
    ["███", "█  ", "███", "█ █", "███"],
    ["███", "  █", "  █", "  █", "  █"],
    ["███", "█ █", "███", "█ █", "███"],
    ["███", "█ █", "███", "  █", "███"],
];

/// tuikit.py `gradient_style(seed)`: the seeded colors, speeds and characters.
#[derive(Clone, Debug)]
pub struct Style {
    pub seed: i64,
    pub hue: f64,
    pub sat: f64,
    pub val: f64,
    pub speed: u64,
    pub diag: u64,
    pub word: String,
    pub cjk: Vec<char>,
    pub emoji: Vec<char>,
}

/// tuikit.py `hsv(h, s, v)`: colorsys.hsv_to_rgb(h % 1.0, s, v), each channel int(x * 255 + 0.5).
pub fn hsv(h: f64, s: f64, v: f64) -> (u8, u8, u8) {
    let h = h.rem_euclid(1.0);
    let (r, g, b) = if s == 0.0 {
        (v, v, v)
    } else {
        let i = (h * 6.0).trunc();
        let f = h * 6.0 - i;
        let p = v * (1.0 - s);
        let q = v * (1.0 - s * f);
        let t = v * (1.0 - s * (1.0 - f));
        match (i as i64).rem_euclid(6) {
            0 => (v, t, p),
            1 => (q, v, p),
            2 => (p, v, t),
            3 => (p, q, v),
            4 => (t, p, v),
            _ => (v, p, q),
        }
    };
    (channel(r), channel(g), channel(b))
}

#[allow(
    clippy::cast_possible_truncation,
    reason = "clamped to 0..=255 first; Python's int() truncates the same way"
)]
fn channel(x: f64) -> u8 {
    (x * 255.0 + 0.5).trunc().clamp(0.0, 255.0) as u8
}

fn bg(rgb: (u8, u8, u8)) -> String {
    format!("\x1b[48;2;{};{};{}m", rgb.0, rgb.1, rgb.2)
}

/// tuikit.py `clip_cells`: the cells (text, width) that fit whole between `col` and the right edge.
fn clip_cells(out: &mut String, cells: &[(String, usize)], col: usize, cols: usize) {
    let mut x = col;
    for (text, width) in cells {
        if x + width > cols {
            break;
        }
        out.push_str(text);
        x += width;
    }
}

fn narrow(text: &str) -> Vec<(String, usize)> {
    text.chars().map(|c| (c.to_string(), 1)).collect()
}

pub struct Gradient {
    style: Style,
    cell: usize,
    sync: bool,
    strip: Vec<String>,
    tail_strip: Vec<String>,
    cols: usize,
    rows: usize,
    items: usize,
    tail: usize,
    wide: Vec<(String, usize)>,
    emoji: Vec<(String, usize)>,
    white: String,
    black: String,
}

impl Gradient {
    pub fn new(style: Style, cell: usize, sync: bool) -> Gradient {
        let cell = cell.clamp(1, 2);
        let mut strip = Vec::with_capacity(PERIOD);
        let mut tail_strip = Vec::with_capacity(PERIOD);
        for i in 0..PERIOD {
            let color = bg(hsv(
                style.hue + i as f64 / PERIOD as f64,
                style.sat,
                style.val,
            ));
            strip.push(format!("{color}{}", " ".repeat(cell)));
            tail_strip.push(format!("{color} "));
        }
        let mut wide = Vec::new();
        let mut emoji = Vec::new();
        for i in 0..8_u8 {
            wide.push((char::from(b'A' + i).to_string(), 1));
            wide.push((
                style
                    .cjk
                    .get(usize::from(i))
                    .map_or(String::new(), |c| c.to_string()),
                2,
            ));
            emoji.push((i.to_string(), 1));
            emoji.push((
                style
                    .emoji
                    .get(usize::from(i))
                    .map_or(String::new(), |c| c.to_string()),
                2,
            ));
        }
        Gradient {
            style,
            cell,
            sync,
            strip,
            tail_strip,
            cols: 0,
            rows: 0,
            items: 0,
            tail: 0,
            wide,
            emoji,
            white: format!("{} ", bg((255, 255, 255))),
            black: format!("{} ", bg((0, 0, 0))),
        }
    }

    pub fn size(&self) -> (usize, usize) {
        (self.cols, self.rows)
    }

    pub fn resize(&mut self, cols: usize, rows: usize) {
        self.cols = cols.max(1);
        self.rows = rows.max(1);
        self.items = self.cols.div_ceil(self.cell);
        self.tail = self.cols - (self.items - 1) * self.cell;
    }

    /// Frame k at shown time t (seconds), as tuikit.py `Gradient.frame(k, t)`.
    pub fn frame(&self, k: u64, t: f64) -> String {
        let (cols, rows) = (self.cols, self.rows);
        let st = &self.style;
        let mut out = String::with_capacity(rows * self.items * 24 + 2048);
        if self.sync {
            out.push_str(BSU);
        }
        let shift = k.wrapping_mul(st.speed);
        for y in 0..rows {
            let off =
                ((y as u64).wrapping_mul(st.diag).wrapping_add(shift) % PERIOD as u64) as usize;
            let _ = write!(out, "\x1b[{};1H", y + 1);
            for j in 0..self.items {
                let idx = (off + j) % PERIOD;
                let cells = if j + 1 == self.items && self.tail != self.cell {
                    &self.tail_strip
                } else {
                    &self.strip
                };
                if let Some(text) = cells.get(idx) {
                    out.push_str(text);
                }
            }
        }
        out.push_str(INK);
        let hud = format!(" F{k:07} t={t:9.3}s seed={} {cols}x{rows} ", st.seed);
        out.push_str("\x1b[1;1H");
        out.extend(hud.chars().take(cols));
        if cols >= BARCODE_BITS as usize + 2 && rows >= 2 {
            let code = k % (1_u64 << BARCODE_BITS);
            out.push_str("\x1b[2;1H");
            out.push_str(&bg((255, 0, 255)));
            out.push(' ');
            for i in (0..BARCODE_BITS).rev() {
                out.push_str(if (code >> i) & 1 == 1 {
                    &self.white
                } else {
                    &self.black
                });
            }
            out.push_str(&bg((0, 255, 255)));
            out.push(' ');
            out.push_str(INK);
        }
        self.draw_box(&mut out, k);
        for (row, cells) in [(WIDE_ROW, &self.wide), (EMOJI_ROW, &self.emoji)] {
            if row < rows {
                let _ = write!(out, "\x1b[{};3H", row + 1);
                clip_cells(&mut out, cells, 2, cols);
            }
        }
        if RULER_ROW < rows {
            let _ = write!(out, "\x1b[{};{}H", RULER_ROW + 1, BOX_COL + 1);
            clip_cells(&mut out, &narrow(RULER), BOX_COL, cols);
        }
        if cols >= 50 && rows >= 18 {
            let digits = format!("{:06}", k % 1_000_000);
            let (row, col) = (rows - 6, cols - 24);
            for r in 0..5 {
                let _ = write!(out, "\x1b[{};{}H", row + r + 1, col + 1);
                let parts: Vec<&str> = digits
                    .bytes()
                    .map(|d| {
                        BIG.get(usize::from(d.wrapping_sub(b'0')))
                            .and_then(|glyph| glyph.get(r))
                            .copied()
                            .unwrap_or("   ")
                    })
                    .collect();
                out.push_str(&parts.join(" "));
            }
        }
        out.push_str(RESET);
        if self.sync {
            out.push_str(ESU);
        }
        out
    }

    fn draw_box(&self, out: &mut String, k: u64) {
        let inner = BOX_W - 2;
        let spin = SPIN.get((k % 4) as usize).copied().unwrap_or('◐');
        let title: String = format!("{:<inner$}", format!(" tui-gradient {}", self.style.word))
            .chars()
            .take(inner)
            .collect();
        let lines = [
            format!("╔{}╗", "═".repeat(inner)),
            format!("║{title}║"),
            format!("║ ┌────────┐ ┌────────┐ {spin}  ║"),
            format!(
                "║ │F{:07}│ │s{:7}│    ║",
                k % 10_000_000,
                self.style.seed.rem_euclid(10_000_000)
            ),
            "║ └────────┘ └────────┘    ║".to_string(),
            "║ ░▒▓█ ▏▎▍▌▋▊▉█ ━┃┏┓┗┛╋    ║".to_string(),
            format!("╚{}╝", "═".repeat(inner)),
        ];
        for (i, line) in lines.iter().enumerate() {
            let y = BOX_ROW + i;
            if y < self.rows {
                let _ = write!(out, "\x1b[{};{}H", y + 1, BOX_COL + 1);
                clip_cells(out, &narrow(line), BOX_COL, self.cols);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn style() -> Style {
        Style {
            seed: 3,
            hue: 0.25,
            sat: 0.8,
            val: 0.9,
            speed: 2,
            diag: 1,
            word: "pixel".into(),
            cjk: "漢字かなカナ한글".chars().collect(),
            emoji: "🚀🌈🔥🎉🐙💡🧪🍀".chars().collect(),
        }
    }

    #[test]
    #[ignore = "run by scripts/measure/tui-kit-selftest.sh"]
    fn hsv_matches_colorsys() {
        assert_eq!(hsv(0.0, 1.0, 1.0), (255, 0, 0));
        assert_eq!(hsv(1.0 / 3.0, 1.0, 1.0), (0, 255, 0));
        assert_eq!(hsv(1.25, 0.0, 0.5), (128, 128, 128));
    }

    #[test]
    #[ignore = "run by scripts/measure/tui-kit-selftest.sh"]
    fn barcode_and_counter() {
        let mut g = Gradient::new(style(), 1, true);
        g.resize(90, 30);
        let text = g.frame(37, 37.0 / 120.0);
        assert!(text.starts_with(BSU) && text.ends_with(ESU));
        assert!(text.contains(" F0000037 t=    0.308s seed=3 90x30 "));
        let bits = text.rsplit("\x1b[2;1H").next().unwrap_or_default();
        let white = format!("{} ", bg((255, 255, 255)));
        let black = format!("{} ", bg((0, 0, 0)));
        let mut body = bits
            .strip_prefix(&format!("{} ", bg((255, 0, 255))))
            .unwrap_or_default();
        let mut code = 0_u64;
        for _ in 0..BARCODE_BITS {
            if let Some(rest) = body.strip_prefix(&white) {
                code = code * 2 + 1;
                body = rest;
            } else if let Some(rest) = body.strip_prefix(&black) {
                code *= 2;
                body = rest;
            }
        }
        assert_eq!(code, 37);
    }
}
