//! A cell-grid rasterizer: draws rows of styled runs into a BGRX framebuffer.
//!
//! The host draws what the video path captures, and a cell viewer draws what it
//! received with the same code, so "exact text" is a pixel compare. Alongside the
//! pixels it keeps a mask: 1 where a glyph covers the pixel fully (the text colour
//! itself, where colour error is measured), 2 where it is anti-aliased, 0 for bare
//! background.

use std::collections::HashMap;

use fontdue::{Font, FontSettings, Metrics};
use unicode_width::UnicodeWidthChar;

use ghostty_vt::Rgb;

pub const ATTR_BOLD: u16 = 0x0001;
pub const ATTR_INVERSE: u16 = 0x0008;
pub const ATTR_INVISIBLE: u16 = 0x0020;

/// One run as either side holds it: the host from `StyledRun`, a viewer from JSON.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Run {
    pub text: String,
    pub fg: Option<Rgb>,
    pub bg: Option<Rgb>,
    pub attrs: u16,
    pub underline: bool,
}

impl From<&ghostty_vt::StyledRun> for Run {
    fn from(r: &ghostty_vt::StyledRun) -> Self {
        Run {
            text: r.text.clone(),
            fg: r.fg,
            bg: r.bg,
            attrs: r.attrs,
            underline: r.underline.is_some(),
        }
    }
}

pub struct Raster {
    regular: Font,
    bold: Font,
    px: f32,
    baseline: i32,
    pub cw: usize,
    pub ch: usize,
    pub cols: usize,
    pub rows: usize,
    pub w: usize,
    pub h: usize,
    cache: HashMap<(char, bool), (Metrics, Vec<u8>)>,
}

pub struct Surface {
    pub bgrx: Vec<u8>,
    pub mask: Vec<u8>,
}

impl Raster {
    pub fn new(
        regular: &[u8],
        bold: &[u8],
        px: f32,
        cols: usize,
        rows: usize,
    ) -> Result<Self, String> {
        let regular = Font::from_bytes(regular, FontSettings::default()).map_err(str::to_string)?;
        let bold = Font::from_bytes(bold, FontSettings::default()).map_err(str::to_string)?;
        let lm = regular.horizontal_line_metrics(px).ok_or("font has no line metrics")?;
        let cw = regular.metrics('M', px).advance_width.ceil() as usize;
        let ch = (lm.ascent - lm.descent + lm.line_gap).ceil() as usize;
        // The encoder takes even dimensions.
        let (w, h) = ((cols * cw + 1) & !1, (rows * ch + 1) & !1);
        Ok(Raster {
            regular,
            bold,
            px,
            baseline: lm.ascent.ceil() as i32,
            cw,
            ch,
            cols,
            rows,
            w,
            h,
            cache: HashMap::new(),
        })
    }

    pub fn surface(&self) -> Surface {
        Surface { bgrx: vec![0; self.w * self.h * 4], mask: vec![0; self.w * self.h] }
    }

    /// Draws one row. `cursor` is the cursor's column when it sits on this row
    /// (drawn as a block: the cell's colours swapped).
    pub fn draw_row(
        &mut self,
        s: &mut Surface,
        row: usize,
        runs: &[Run],
        defaults: (Rgb, Rgb),
        cursor: Option<usize>,
    ) {
        if row >= self.rows {
            return;
        }
        let (dfg, dbg) = defaults;
        let y0 = row * self.ch;
        let band = y0..(y0 + self.ch).min(self.h);
        for y in band.clone() {
            for x in 0..self.w {
                put(s, self.w, x, y, dbg, 0);
            }
        }
        let mut col = 0usize;
        for run in runs {
            let (mut fg, mut bg) = (run.fg.unwrap_or(dfg), run.bg.unwrap_or(dbg));
            if run.attrs & ATTR_INVERSE != 0 {
                std::mem::swap(&mut fg, &mut bg);
            }
            for c in run.text.chars() {
                let width = c.width().unwrap_or(0);
                if width == 0 {
                    continue;
                }
                let (mut cfg, mut cbg) = (fg, bg);
                if cursor == Some(col) {
                    std::mem::swap(&mut cfg, &mut cbg);
                }
                let x0 = col * self.cw;
                for y in band.clone() {
                    for x in x0..(x0 + width * self.cw).min(self.w) {
                        put(s, self.w, x, y, cbg, 0);
                    }
                }
                if c != ' ' && run.attrs & ATTR_INVISIBLE == 0 {
                    self.glyph(s, c, run.attrs & ATTR_BOLD != 0, x0, y0, width, cfg, cbg);
                }
                if run.underline {
                    let uy = y0 + self.baseline as usize + 2;
                    for y in uy..(uy + 2).min(y0 + self.ch).min(self.h) {
                        for x in x0..(x0 + width * self.cw).min(self.w) {
                            put(s, self.w, x, y, cfg, 1);
                        }
                    }
                }
                col += width;
            }
        }
        if let Some(c) = cursor.filter(|&c| c >= col && c < self.cols) {
            // The cursor past the row's last run: a block in the default foreground.
            let x0 = c * self.cw;
            for y in band {
                for x in x0..(x0 + self.cw).min(self.w) {
                    put(s, self.w, x, y, dfg, 1);
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn glyph(
        &mut self,
        s: &mut Surface,
        c: char,
        bold: bool,
        x0: usize,
        y0: usize,
        width: usize,
        fg: Rgb,
        bg: Rgb,
    ) {
        let (font, px) = (if bold { &self.bold } else { &self.regular }, self.px);
        let (m, cov) = self.cache.entry((c, bold)).or_insert_with(|| font.rasterize(c, px));
        let top = y0 as i32 + self.baseline - (m.height as i32 + m.ymin);
        let left = x0 as i32 + m.xmin;
        // Clip to the cell band so a row redraws on its own.
        let (xmax, ymax) =
            (((x0 + width * self.cw).min(self.w)) as i32, ((y0 + self.ch).min(self.h)) as i32);
        for gy in 0..m.height {
            let y = top + gy as i32;
            if y < y0 as i32 || y >= ymax {
                continue;
            }
            for gx in 0..m.width {
                let x = left + gx as i32;
                if x < x0 as i32 || x >= xmax {
                    continue;
                }
                let a = cov[gy * m.width + gx];
                if a == 0 {
                    continue;
                }
                let blend = |f: u8, b: u8| {
                    ((u32::from(f) * u32::from(a) + u32::from(b) * (255 - u32::from(a)) + 127)
                        / 255) as u8
                };
                let px = Rgb { r: blend(fg.r, bg.r), g: blend(fg.g, bg.g), b: blend(fg.b, bg.b) };
                put(s, self.w, x as usize, y as usize, px, if a == 255 { 1 } else { 2 });
            }
        }
    }
}

#[inline(always)]
fn put(s: &mut Surface, w: usize, x: usize, y: usize, c: Rgb, mask: u8) {
    let i = y * w + x;
    s.bgrx[i * 4] = c.b;
    s.bgrx[i * 4 + 1] = c.g;
    s.bgrx[i * 4 + 2] = c.r;
    s.mask[i] = mask;
}
