//! Synthetic screens, drawn straight into I420, deterministic per seed:
//! - `scroll`: a terminal printing a long file, one new line every frame;
//! - `typing`: a mostly static terminal where one character appears per frame;
//! - `drag`: a text window dragged across a desktop of other windows;
//! - `video`: a 30 fps camera-like clip playing in a 640x360 region of a terminal;
//! - `noise`: every pixel random every frame (the worst case, not a real screen).
//!
//! Text is a procedural monospace font (9x18 cells, 1-pixel strokes with an
//! anti-aliased edge), light on dark like a terminal theme: the high-contrast,
//! high-frequency content screen sharing has to keep legible.

use cmux_encode::I420;

pub const CELL_W: usize = 9;
pub const CELL_H: usize = 18;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SceneKind {
    Scroll,
    Typing,
    Drag,
    Video,
    Noise,
}

impl SceneKind {
    pub const ALL: [SceneKind; 5] =
        [SceneKind::Scroll, SceneKind::Drag, SceneKind::Video, SceneKind::Typing, SceneKind::Noise];

    pub fn name(self) -> &'static str {
        match self {
            SceneKind::Scroll => "scroll",
            SceneKind::Typing => "typing",
            SceneKind::Drag => "drag",
            SceneKind::Video => "video",
            SceneKind::Noise => "noise",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.name() == s)
    }

    /// Scenes whose luma PSNR says how legible text stays.
    pub fn is_text(self) -> bool {
        matches!(self, SceneKind::Scroll | SceneKind::Typing | SceneKind::Drag)
    }
}

/// xorshift64*: fast, deterministic, good enough for pictures and loss.
#[derive(Debug, Clone)]
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self(seed.max(1))
    }
    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    pub fn below(&mut self, n: u64) -> u64 {
        self.next_u64() % n.max(1)
    }
    /// Uniform in [0, 1).
    pub fn unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
}

/// 95 printable glyphs, each a 7x12 bitmap inside its 9x18 cell.
struct Font {
    glyphs: Vec<[u16; 12]>,
}

impl Font {
    fn new() -> Self {
        let mut rng = Rng::new(0xf0_17);
        let glyphs = (0..95)
            .map(|i| {
                let mut g = [0u16; 12];
                if i == 0 {
                    return g; // space
                }
                // Strokes: a vertical, a horizontal and a diagonal or two, like letterforms.
                let v = rng.below(7) as u16;
                let h = 2 + rng.below(9) as usize;
                for (r, row) in g.iter_mut().enumerate().skip(2) {
                    if rng.below(4) != 0 {
                        *row |= 1 << v;
                    }
                    if r == h {
                        *row |= 0x7f;
                    }
                }
                let d = rng.below(3);
                for r in 2..12 {
                    let c = match d {
                        0 => (r * 7 / 12) as u16,
                        1 => 6 - (r * 7 / 12) as u16,
                        _ => continue,
                    };
                    g[r] |= 1 << c.min(6);
                }
                if rng.below(2) == 0 {
                    g[2] |= 0x7f & (rng.next_u64() as u16 | 0x41);
                    g[11] |= 0x7f & (rng.next_u64() as u16 | 0x41);
                }
                g
            })
            .collect();
        Self { glyphs }
    }

    /// Draws glyph `ch` (32..127) with its cell's top-left at (`x`, `y`).
    fn draw(&self, pic: &mut I420, x: usize, y: usize, ch: u8, fg: u8, bg: u8) {
        let g = &self.glyphs[usize::from(ch.clamp(32, 126) - 32)];
        let w = pic.width;
        let h = pic.y.len() / w;
        let mid = ((u16::from(fg) + u16::from(bg)) / 2) as u8;
        for (r, bits) in g.iter().enumerate() {
            let py = y + 3 + r;
            if py >= h {
                break;
            }
            let row = &mut pic.y[py * w..(py + 1) * w];
            for c in 0..7 {
                let px = x + 1 + c;
                if px >= w || bits & (1 << c) == 0 {
                    continue;
                }
                row[px] = fg;
                // An anti-aliased right edge, as subpixel-free grayscale AA draws it.
                if px + 1 < w && bits & (1 << (c + 1)) == 0 && row[px + 1] == bg {
                    row[px + 1] = mid;
                }
            }
        }
    }
}

const TERM_BG: u8 = 28;
const TERM_FG: u8 = 214;

fn fill(pic: &mut I420, x: usize, y: usize, w: usize, h: usize, luma: u8, u: u8, v: u8) {
    let pw = pic.width;
    let ph = pic.y.len() / pw;
    let (x1, y1) = ((x + w).min(pw), (y + h).min(ph));
    for row in y..y1 {
        pic.y[row * pw + x..row * pw + x1].fill(luma);
    }
    let cw = pw / 2;
    for row in y / 2..y1 / 2 {
        pic.u[row * cw + x / 2..row * cw + x1 / 2].fill(u);
        pic.v[row * cw + x / 2..row * cw + x1 / 2].fill(v);
    }
}

/// Words of a plausible source file or log line.
fn text_line(rng: &mut Rng, cols: usize) -> Vec<u8> {
    let mut line = Vec::with_capacity(cols);
    let indent = (rng.below(5) * 4) as usize;
    line.resize(indent.min(cols), b' ');
    let len = indent + rng.below((cols - indent.min(cols)).max(1) as u64 * 3 / 4) as usize;
    while line.len() < len.min(cols) {
        let word = 1 + rng.below(9) as usize;
        for _ in 0..word {
            if line.len() >= cols {
                break;
            }
            line.push(33 + rng.below(94) as u8);
        }
        if line.len() < cols {
            line.push(b' ');
        }
    }
    line
}

pub struct Scene {
    kind: SceneKind,
    width: usize,
    height: usize,
    rng: Rng,
    font: Font,
    /// Terminal grid (rows of characters) for the text scenes.
    grid: Vec<Vec<u8>>,
    cursor: (usize, usize),
    frame: u64,
    /// The desktop under the dragged window, drawn once.
    backdrop: I420,
    pic: I420,
}

impl Scene {
    pub fn new(kind: SceneKind, width: usize, height: usize, seed: u64) -> Self {
        let mut rng = Rng::new(seed);
        let cols = width / CELL_W;
        let rows = height / CELL_H;
        let grid = (0..rows).map(|_| text_line(&mut rng, cols)).collect();
        let mut s = Self {
            kind,
            width,
            height,
            rng,
            font: Font::new(),
            grid,
            cursor: (0, rows.saturating_sub(1)),
            frame: 0,
            backdrop: I420::new(0, 0),
            pic: I420::new(width, height),
        };
        if kind == SceneKind::Typing {
            let last = s.grid.len() - 1;
            s.grid[last].clear();
        }
        if kind == SceneKind::Drag {
            s.backdrop = s.draw_desktop();
        }
        s.render();
        s
    }

    pub fn picture(&self) -> &I420 {
        &self.pic
    }

    /// Advances one frame (a 30 fps tick) and redraws.
    pub fn advance(&mut self) {
        self.frame += 1;
        let cols = self.width / CELL_W;
        match self.kind {
            SceneKind::Scroll => {
                self.grid.remove(0);
                let line = text_line(&mut self.rng, cols);
                self.grid.push(line);
            }
            SceneKind::Typing => {
                let row = self.grid.len() - 1;
                if self.grid[row].len() >= cols.min(72) || self.rng.below(40) == 0 {
                    self.grid.remove(0);
                    self.grid.push(Vec::new());
                } else {
                    let ch =
                        if self.rng.below(6) == 0 { b' ' } else { 33 + self.rng.below(94) as u8 };
                    self.grid[row].push(ch);
                }
                self.cursor = (self.grid[row].len(), row);
            }
            _ => {}
        }
        self.render();
    }

    fn draw_terminal(&self, pic: &mut I420) {
        fill(pic, 0, 0, self.width, self.height, TERM_BG, 128, 128);
        for (r, line) in self.grid.iter().enumerate() {
            for (c, &ch) in line.iter().enumerate() {
                if ch != b' ' {
                    self.font.draw(pic, c * CELL_W, r * CELL_H, ch, TERM_FG, TERM_BG);
                }
            }
        }
    }

    fn draw_desktop(&mut self) -> I420 {
        let mut pic = I420::new(self.width, self.height);
        // A soft vertical gradient wallpaper.
        let (w, h) = (self.width, self.height);
        for y in 0..h {
            let l = (60 + y * 60 / h) as u8;
            pic.y[y * w..(y + 1) * w].fill(l);
        }
        pic.u.fill(140);
        pic.v.fill(118);
        // Three background windows of text, light theme.
        for (i, (x, y)) in [(60, 80), (w / 2, 140), (200, h / 2)].into_iter().enumerate() {
            let (ww, wh) = (w * 2 / 5, h * 2 / 5);
            fill(&mut pic, x, y, ww, 28, 200, 120 + i as u8 * 6, 128);
            fill(&mut pic, x, y + 28, ww, wh, 245, 128, 128);
            for r in 0..(wh / CELL_H).saturating_sub(1) {
                let line = text_line(&mut self.rng, ww / CELL_W - 1);
                for (c, &ch) in line.iter().enumerate() {
                    if ch != b' ' {
                        self.font.draw(
                            &mut pic,
                            x + 4 + c * CELL_W,
                            y + 32 + r * CELL_H,
                            ch,
                            30,
                            245,
                        );
                    }
                }
            }
        }
        pic
    }

    fn render(&mut self) {
        let mut pic = std::mem::replace(&mut self.pic, I420::new(0, 0));
        match self.kind {
            SceneKind::Scroll | SceneKind::Typing => {
                self.draw_terminal(&mut pic);
                if self.kind == SceneKind::Typing {
                    let (cx, cy) = self.cursor;
                    fill(
                        &mut pic,
                        cx * CELL_W,
                        cy * CELL_H + 2,
                        CELL_W,
                        CELL_H - 4,
                        TERM_FG,
                        128,
                        128,
                    );
                }
            }
            SceneKind::Drag => {
                pic.clone_from(&self.backdrop);
                // The dragged window bounces across the screen at about 360 px/s.
                let (ww, wh) = (self.width * 2 / 5 & !1, self.height / 2 & !1);
                let span_x = (self.width - ww) as u64;
                let span_y = (self.height - wh) as u64;
                let t = self.frame * 12;
                let bounce = |t: u64, span: u64| {
                    let p = t % (2 * span.max(1));
                    (if p > span { 2 * span - p } else { p }) as usize & !1
                };
                let (x, y) = (bounce(t, span_x), bounce(t / 2, span_y));
                fill(&mut pic, x, y, ww, 30, 90, 150, 110);
                fill(&mut pic, x, y + 30, ww, wh - 30, TERM_BG, 128, 128);
                for r in 0..(wh - 30) / CELL_H {
                    if let Some(line) = self.grid.get(r) {
                        for (c, &ch) in line.iter().take((ww - 8) / CELL_W).enumerate() {
                            if ch != b' ' {
                                self.font.draw(
                                    &mut pic,
                                    x + 4 + c * CELL_W,
                                    y + 30 + r * CELL_H,
                                    ch,
                                    TERM_FG,
                                    TERM_BG,
                                );
                            }
                        }
                    }
                }
            }
            SceneKind::Video => {
                self.draw_terminal(&mut pic);
                let (vw, vh) = (640.min(self.width), 360.min(self.height));
                let (x0, y0) = ((self.width - vw) / 2 & !1, (self.height - vh) / 3 & !1);
                let f = self.frame as f64;
                let w = pic.width;
                for y in 0..vh {
                    for x in 0..vw {
                        // A slowly panning scene with two moving blobs and sensor noise.
                        let fx = x as f64 + f * 3.0;
                        let fy = y as f64 + f * 1.0;
                        let base = 110.0 + 50.0 * ((fx / 70.0).sin() * (fy / 50.0).cos());
                        let b1 = {
                            let dx = x as f64 - (320.0 + 200.0 * (f / 25.0).sin());
                            let dy = y as f64 - (180.0 + 100.0 * (f / 19.0).cos());
                            70.0 * (-(dx * dx + dy * dy) / 3000.0).exp()
                        };
                        let b2 = {
                            let dx = x as f64 - (320.0 + 240.0 * (f / 31.0).cos());
                            let dy = y as f64 - (180.0 + 120.0 * (f / 23.0).sin());
                            -60.0 * (-(dx * dx + dy * dy) / 5000.0).exp()
                        };
                        let n = self.rng.below(9) as f64 - 4.0;
                        pic.y[(y0 + y) * w + x0 + x] =
                            (base + b1 + b2 + n).clamp(16.0, 235.0) as u8;
                    }
                }
                let cw = w / 2;
                for y in 0..vh / 2 {
                    for x in 0..vw / 2 {
                        let i = (y0 / 2 + y) * cw + x0 / 2 + x;
                        let fx = (x as f64 * 2.0 + f * 3.0) / 90.0;
                        pic.u[i] = (128.0 + 20.0 * fx.sin()) as u8;
                        pic.v[i] = (128.0 + 25.0 * (fx * 0.7 + f / 40.0).cos()) as u8;
                    }
                }
            }
            SceneKind::Noise => {
                for b in pic.y.iter_mut().chain(pic.u.iter_mut()).chain(pic.v.iter_mut()) {
                    *b = self.rng.next_u64() as u8;
                }
            }
        }
        self.pic = pic;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scenes_change_and_repeat() {
        for kind in SceneKind::ALL {
            let mut a = Scene::new(kind, 640, 360, 7);
            let mut b = Scene::new(kind, 640, 360, 7);
            let first = a.picture().clone();
            a.advance();
            b.advance();
            assert_eq!(a.picture(), b.picture(), "{} is deterministic", kind.name());
            assert_ne!(&first, a.picture(), "{} changes every frame", kind.name());
        }
    }
}
