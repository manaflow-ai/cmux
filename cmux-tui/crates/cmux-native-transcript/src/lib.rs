//! The read-only native transcript scene (RFD 0121, cmuxterm-hq `docs/rfd/0121-blank-cheque/app-perf.md` section 6,
//! "First PR"): a disposable prototype that draws the 3,000-row bench fixture in one Metal layer, so the fling
//! frame interval of a native transcript can be measured beside the React one in one harness.
//!
//! Rust owns the scene and the per-frame work: rows laid out once per width, the visible rows found by binary
//! search, one instance quad per glyph, fill and rich row, glyph atlas slots, rich-row texture prefetch, the fling
//! and the frame record. The macOS app owns the CAMetalLayer, its render thread, CoreText rasterization and the
//! textures (`include/cmux_native_transcript.h`). Per frame the cost is O(visible glyphs), never O(rows).
//!
//! Read-only: no selection, no streaming tail, no editing. Behind the app's debug flag; the React transcript stays
//! the default.

pub mod atlas;
pub mod ffi;
pub mod fixture;
pub mod fling;
pub mod stats;

use atlas::{Atlas, GlyphKey};
use fixture::RowSource;
use fling::Fling;
use stats::Record;
use std::time::Instant;

pub const QUAD_GLYPH: u32 = 0;
pub const QUAD_FILL: u32 = 1;
pub const QUAD_TEXTURE: u32 = 2;

pub const PAD_X: f32 = 16.0;
pub const ROW_GAP: f32 = 12.0;
pub const CODE_PAD: f32 = 8.0;

pub const TEXT_COLOR: u32 = 0xE6E6_E6FF;
pub const CODE_COLOR: u32 = 0xC8D3_F5FF;
pub const CODE_GROUND: u32 = 0x1E1E_24FF;

/// The app's font metrics, in points (the C `CmuxNtMetrics`).
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Metrics {
    pub advances: [f32; 95],
    pub fallback_advance: f32,
    pub line_height: f32,
    pub ascent: f32,
    pub glyph_w: f32,
    pub glyph_h: f32,
    pub mono_advance: f32,
    pub mono_line_height: f32,
    pub scale: f32,
    pub atlas_px: u32,
}

impl Metrics {
    /// A uniform stand-in (tests, benches, Linux): 7 pt advances, 18 pt lines, 2x.
    pub fn uniform() -> Self {
        Metrics {
            advances: [7.0; 95],
            fallback_advance: 7.0,
            line_height: 18.0,
            ascent: 13.0,
            glyph_w: 10.0,
            glyph_h: 18.0,
            mono_advance: 7.2,
            mono_line_height: 17.0,
            scale: 2.0,
            atlas_px: 2048,
        }
    }

    fn advance(&self, c: char) -> f32 {
        let u = c as u32;
        if (32..127).contains(&u) {
            self.advances[(u - 32) as usize]
        } else {
            self.fallback_advance
        }
    }

    fn valid(&self) -> bool {
        let pos = |x: f32| x.is_finite() && x > 0.0;
        pos(self.line_height)
            && pos(self.glyph_w)
            && pos(self.glyph_h)
            && pos(self.mono_advance)
            && pos(self.mono_line_height)
            && pos(self.scale)
            && self.fallback_advance.is_finite()
            && self.advances.iter().all(|a| a.is_finite() && *a >= 0.0)
            && self.atlas_px > 0
    }
}

/// One quad (the C `CmuxNtQuad`): points from the viewport's top-left.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Quad {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    pub u0: f32,
    pub v0: f32,
    pub u1: f32,
    pub v1: f32,
    pub color: u32,
    pub kind: u32,
    pub texture_id: u32,
    pub _pad: u32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Placed {
    x: f32,
    /// From the row's top.
    y: f32,
    glyph: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Text,
    Code,
    Rich,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Row {
    kind: Kind,
    y: f32,
    h: f32,
    glyphs: (u32, u32),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TextureState {
    None,
    Requested,
    Ready,
}

/// What one frame did (the C `CmuxNtFrameInfo`, less the build time the FFI adds).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct FrameInfo {
    pub offset: f64,
    pub content_height: f64,
    pub quads: u32,
    pub quads_needed: u32,
    pub first_row: u32,
    pub last_row: u32,
    pub late_textures: u32,
    pub flinging: bool,
    pub build_us: f64,
}

pub struct Scene {
    sources: Vec<RowSource>,
    metrics: Metrics,
    width: f32,
    height: f32,
    rows: Vec<Row>,
    glyphs: Vec<Placed>,
    content_height: f64,
    offset: f64,
    fling: Option<Fling>,
    atlas: Atlas,
    textures: Vec<TextureState>,
    visible: (u32, u32),
    pub record: Record,
}

impl Scene {
    /// None on a bad metric or size.
    pub fn new(sources: Vec<RowSource>, width: f32, height: f32, metrics: Metrics) -> Option<Self> {
        if !(metrics.valid()
            && width.is_finite()
            && height.is_finite()
            && width > 0.0
            && height >= 0.0)
        {
            return None;
        }
        let cell = |pt: f32| (pt * metrics.scale).ceil() as u32;
        let atlas = Atlas::new(metrics.atlas_px, cell(metrics.glyph_w), cell(metrics.glyph_h));
        let textures = vec![TextureState::None; sources.len()];
        let mut scene = Scene {
            sources,
            metrics,
            width,
            height,
            rows: Vec::new(),
            glyphs: Vec::new(),
            content_height: 0.0,
            offset: 0.0,
            fling: None,
            atlas,
            textures,
            visible: (0, 0),
            record: Record::default(),
        };
        scene.layout();
        Some(scene)
    }

    pub fn fixture(rows: u32, width: f32, height: f32, metrics: Metrics) -> Option<Self> {
        Scene::new(fixture::fixture(rows), width, height, metrics)
    }

    /// Lay every row out for the current width: the only O(document) pass.
    fn layout(&mut self) {
        let m = self.metrics;
        let inner = (self.width - 2.0 * PAD_X).max(m.glyph_w);
        let mut rows = Vec::with_capacity(self.sources.len());
        let mut glyphs = Vec::new();
        let mut y = ROW_GAP;
        for src in &self.sources {
            let start = glyphs.len() as u32;
            let (kind, h) = match src {
                RowSource::Text(s) => {
                    let lines = wrap(
                        s,
                        inner,
                        &m,
                        |c| self.atlas.intern(GlyphKey { scalar: c as u32, font: 0 }),
                        &mut glyphs,
                    );
                    (Kind::Text, lines as f32 * m.line_height)
                }
                RowSource::Code(lines) => {
                    for (i, line) in lines.iter().enumerate() {
                        let mut x = 0.0;
                        for c in line.chars() {
                            if x + m.mono_advance > inner - 2.0 * CODE_PAD {
                                break;
                            }
                            if c != ' ' {
                                let glyph =
                                    self.atlas.intern(GlyphKey { scalar: c as u32, font: 1 });
                                glyphs.push(Placed {
                                    x: CODE_PAD + x,
                                    y: CODE_PAD + i as f32 * m.mono_line_height,
                                    glyph,
                                });
                            }
                            x += m.mono_advance;
                        }
                    }
                    (Kind::Code, lines.len() as f32 * m.mono_line_height + 2.0 * CODE_PAD)
                }
                RowSource::Rich { height } => (Kind::Rich, *height),
            };
            rows.push(Row { kind, y, h, glyphs: (start, glyphs.len() as u32) });
            y += h + ROW_GAP;
        }
        self.rows = rows;
        self.glyphs = glyphs;
        self.content_height = f64::from(y);
        self.offset = self.clamp(self.offset);
    }

    fn max_offset(&self) -> f64 {
        (self.content_height - f64::from(self.height)).max(0.0)
    }

    fn clamp(&self, offset: f64) -> f64 {
        if offset.is_finite() { offset.clamp(0.0, self.max_offset()) } else { 0.0 }
    }

    pub fn content_height(&self) -> f64 {
        self.content_height
    }

    pub fn offset(&self) -> f64 {
        self.offset
    }

    pub fn rows(&self) -> usize {
        self.rows.len()
    }

    pub fn glyph_count(&self) -> usize {
        self.glyphs.len()
    }

    pub fn atlas(&mut self) -> &mut Atlas {
        &mut self.atlas
    }

    pub fn set_viewport(&mut self, width: f32, height: f32) {
        if !(width.is_finite() && height.is_finite() && width > 0.0 && height >= 0.0) {
            return;
        }
        let relayout = width != self.width;
        self.width = width;
        self.height = height;
        if relayout {
            // Keep the row at the top of the viewport at the top.
            let top = self.row_at(self.offset);
            let into = self.offset - f64::from(self.rows.get(top).map_or(0.0, |r| r.y));
            self.layout();
            let y = self.rows.get(top).map_or(0.0, |r| f64::from(r.y));
            self.offset = self.clamp(y + into);
        } else {
            self.offset = self.clamp(self.offset);
        }
    }

    pub fn scroll_to(&mut self, offset: f64) {
        self.fling = None;
        self.offset = self.clamp(offset);
    }

    pub fn scroll_by(&mut self, delta: f64) {
        self.scroll_to(self.offset + if delta.is_finite() { delta } else { 0.0 });
    }

    pub fn fling(&mut self, velocity: f64, now: f64) {
        if velocity.is_finite() && now.is_finite() && velocity.abs() >= fling::STOP_SPEED {
            self.fling = Some(Fling { start: now, origin: self.offset, velocity });
        }
    }

    /// The first row whose bottom is below `offset`.
    fn row_at(&self, offset: f64) -> usize {
        self.rows.partition_point(|r| f64::from(r.y + r.h) <= offset)
    }

    /// Advance to `now` and write the visible quads into `out` (as many as fit).
    pub fn frame(&mut self, now: f64, out: &mut [Quad]) -> FrameInfo {
        let started = Instant::now();
        let mut flinging = false;
        if let Some(f) = self.fling {
            let (offset, moving) = f.at(now);
            let clamped = self.clamp(offset);
            flinging = true;
            self.offset = clamped;
            if !moving || clamped != offset {
                self.fling = None;
            }
        }
        let top = self.offset;
        let bottom = top + f64::from(self.height);
        let first = self.row_at(top);
        let m = self.metrics;
        let side = self.atlas.side() as f32;
        let inner = self.width - 2.0 * PAD_X;
        let mut n = 0usize;
        let mut needed = 0u32;
        let mut late = 0u32;
        let mut last = first;
        let mut push = |q: Quad, n: &mut usize| {
            needed += 1;
            if let Some(slot) = out.get_mut(*n) {
                *slot = q;
                *n += 1;
            }
        };
        for (i, row) in self.rows.iter().enumerate().skip(first) {
            let ry = f64::from(row.y);
            if ry >= bottom {
                break;
            }
            last = i;
            let vy = (ry - top) as f32;
            match row.kind {
                Kind::Rich => {
                    if self.textures[i] != TextureState::Ready {
                        late += 1;
                    }
                    // The visible part of the texture.
                    let y0 = vy.max(0.0);
                    let y1 = (vy + row.h).min(self.height);
                    if y1 > y0 {
                        push(
                            Quad {
                                x: PAD_X,
                                y: y0,
                                w: inner,
                                h: y1 - y0,
                                u0: 0.0,
                                v0: (y0 - vy) / row.h,
                                u1: 1.0,
                                v1: (y1 - vy) / row.h,
                                color: 0xFFFF_FFFF,
                                kind: QUAD_TEXTURE,
                                texture_id: i as u32 + 1,
                                _pad: 0,
                            },
                            &mut n,
                        );
                    }
                    continue;
                }
                Kind::Code => push(
                    Quad {
                        x: PAD_X,
                        y: vy,
                        w: inner,
                        h: row.h,
                        color: CODE_GROUND,
                        kind: QUAD_FILL,
                        ..Quad::default()
                    },
                    &mut n,
                ),
                Kind::Text => {}
            }
            let color = if row.kind == Kind::Code { CODE_COLOR } else { TEXT_COLOR };
            let line_h = if row.kind == Kind::Code { m.mono_line_height } else { m.line_height };
            for g in &self.glyphs[row.glyphs.0 as usize..row.glyphs.1 as usize] {
                let gy = vy + g.y;
                if gy + line_h <= 0.0 || gy >= self.height {
                    continue;
                }
                let Some(slot) = self.atlas.slot(g.glyph) else { continue };
                push(
                    Quad {
                        x: PAD_X + g.x,
                        y: gy + (line_h - m.glyph_h) * 0.5,
                        w: m.glyph_w,
                        h: m.glyph_h,
                        u0: slot.x as f32 / side,
                        v0: slot.y as f32 / side,
                        u1: (slot.x + slot.w) as f32 / side,
                        v1: (slot.y + slot.h) as f32 / side,
                        color,
                        kind: QUAD_GLYPH,
                        texture_id: 0,
                        _pad: 0,
                    },
                    &mut n,
                );
            }
        }
        self.visible = (first as u32, last as u32);
        let build_us = started.elapsed().as_secs_f64() * 1e6;
        self.record.frame(now, flinging, late, build_us);
        FrameInfo {
            offset: self.offset,
            content_height: self.content_height,
            quads: n as u32,
            quads_needed: needed,
            first_row: first as u32,
            last_row: last as u32,
            late_textures: late,
            flinging: self.fling.is_some(),
            build_us,
        }
    }

    /// Rich rows to make textures for, visible first, then `prefetch` rows ahead (the fling's way), then behind.
    pub fn take_texture_requests(
        &mut self,
        prefetch: u32,
        cap: usize,
    ) -> Vec<(u32, u32, f32, f32)> {
        let (first, last) = self.visible;
        let n = self.rows.len() as u32;
        if n == 0 {
            return Vec::new();
        }
        let down = self.fling.is_none_or(|f| f.velocity >= 0.0);
        let ahead = (last + 1)..(last.saturating_add(1).saturating_add(prefetch)).min(n);
        let behind = first.saturating_sub(prefetch)..first;
        let visible = first..(last + 1).min(n);
        let order: [std::ops::Range<u32>; 3] =
            if down { [visible, ahead, behind] } else { [visible, behind, ahead] };
        let mut out = Vec::new();
        let width = self.width - 2.0 * PAD_X;
        for range in order {
            let rows: Box<dyn Iterator<Item = u32>> =
                if !down && range.end <= first { Box::new(range.rev()) } else { Box::new(range) };
            for i in rows {
                if out.len() >= cap {
                    return out;
                }
                let row = self.rows[i as usize];
                if row.kind == Kind::Rich && self.textures[i as usize] == TextureState::None {
                    self.textures[i as usize] = TextureState::Requested;
                    out.push((i + 1, i, width, row.h));
                }
            }
        }
        out
    }

    pub fn texture_ready(&mut self, texture_id: u32, ready: bool) {
        let Some(i) = texture_id.checked_sub(1) else { return };
        if let Some(t) = self.textures.get_mut(i as usize) {
            *t = if ready { TextureState::Ready } else { TextureState::None };
        }
    }
}

/// Greedy word wrap of `s` into `inner` points; pushes the placed glyphs, returns the line count (at least 1).
fn wrap(
    s: &str,
    inner: f32,
    m: &Metrics,
    mut intern: impl FnMut(char) -> u32,
    out: &mut Vec<Placed>,
) -> usize {
    let space = m.advance(' ');
    let mut line = 0usize;
    let mut x = 0.0f32;
    for word in s.split(' ') {
        let w: f32 = word.chars().map(|c| m.advance(c)).sum();
        if x > 0.0 && x + w > inner {
            line += 1;
            x = 0.0;
        }
        for c in word.chars() {
            // A word longer than the line breaks anywhere.
            if x > 0.0 && x + m.advance(c) > inner {
                line += 1;
                x = 0.0;
            }
            out.push(Placed { x, y: line as f32 * m.line_height, glyph: intern(c) });
            x += m.advance(c);
        }
        x += space;
    }
    line + 1
}

#[cfg(test)]
mod tests;
