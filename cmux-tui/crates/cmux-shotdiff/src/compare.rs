//! The comparison: per-pixel tolerance, SSIM on luma, ignore masks and per-region thresholds.
//!
//! Deterministic: every sum runs in a fixed row-major order in f64 (Rust never fuses multiply-add on its
//! own), and every float in the verdict is rounded to 6 decimals, so the same two images and spec give the
//! same verdict bytes and the same diff image bytes on every machine.

use crate::image::Rgba;
use serde::{Deserialize, Serialize};

pub const VERDICT_SCHEMA: &str = "cmux-shotdiff.verdict/v1";

/// The defaults match scripts/ci/ios_gate_screen_diff.py (CHANNEL_TOLERANCE 16, CHANGED_RATIO 0.01), so a
/// gate that moves from it to this keeps its outcomes; SSIM then catches structural change the pixel ratio
/// lets through (a moved control, a missing glyph run) and tolerates what it should not count (antialiasing).
pub const DEFAULT_CHANNEL_TOLERANCE: u8 = 16;
pub const DEFAULT_MAX_CHANGED_RATIO: f64 = 0.01;
pub const DEFAULT_MIN_SSIM: f64 = 0.98;

const WINDOW: u32 = 8;
const STRIDE: u32 = 4;
const TILE: u32 = 16;
/// Worst-tile SSIM tile size.
const SSIM_TILE: u32 = 32;
const MAX_BOXES: usize = 64;

/// A rectangle in spec units (pixels times `scale`, see `Spec::scale`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

/// A region nothing is compared in: a caret, a clock, an animation, a live avatar.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
// skew: strict local spec file: a typo in a region or mask key must fail, not silently widen the tolerance
#[serde(deny_unknown_fields)]
pub struct Mask {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    /// Why it is ignored; required so a mask never hides a real change without a reason on record.
    pub why: String,
}

/// A named region with its own thresholds (unset fields take the spec's).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
// skew: strict local spec file: a typo in a region or mask key must fail, not silently widen the tolerance
#[serde(deny_unknown_fields)]
pub struct Region {
    pub name: String,
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channel_tolerance: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_changed_ratio: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_ssim: Option<f64>,
}

/// How two screenshots are judged. A pass needs both the changed-pixel ratio at or under
/// `max_changed_ratio` and SSIM at or over `min_ssim`, globally and in every region. Set
/// `max_changed_ratio` to 1 for SSIM alone (cross-renderer: lavapipe against Metal), or `min_ssim` to 0 for
/// the pixel ratio alone.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
// skew: strict local spec file: a typo in a region or mask key must fail, not silently widen the tolerance
#[serde(deny_unknown_fields, default)]
pub struct Spec {
    /// A pixel changes when any channel moves by more than this (0..255).
    pub channel_tolerance: u8,
    /// Changed pixels over compared (unmasked) pixels, 0..1.
    pub max_changed_ratio: f64,
    /// Mean SSIM of luma over 8x8 windows (stride 4) that touch no mask, 0..1.
    pub min_ssim: f64,
    /// Worst 32x32 tile's mean SSIM, 0..1 (0 = report only). Catches a short label or a nudged button that
    /// moves well under 1% of pixels and barely moves the mean.
    pub min_tile_ssim: f64,
    /// Pixels per spec unit: 2 for rects written in points against a Retina capture.
    pub scale: u32,
    pub ignore: Vec<Mask>,
    pub regions: Vec<Region>,
}

impl Default for Spec {
    fn default() -> Self {
        Spec {
            channel_tolerance: DEFAULT_CHANNEL_TOLERANCE,
            max_changed_ratio: DEFAULT_MAX_CHANGED_RATIO,
            min_ssim: DEFAULT_MIN_SSIM,
            min_tile_ssim: 0.0,
            scale: 1,
            ignore: Vec::new(),
            regions: Vec::new(),
        }
    }
}

impl Spec {
    pub fn validate(&self) -> Result<(), String> {
        if self.scale == 0 {
            return Err("spec: scale must be at least 1".into());
        }
        let ratio_ok = |r: f64| (0.0..=1.0).contains(&r);
        if !ratio_ok(self.max_changed_ratio)
            || !ratio_ok(self.min_ssim)
            || !ratio_ok(self.min_tile_ssim)
        {
            return Err("spec: max_changed_ratio, min_ssim and min_tile_ssim are 0..1".into());
        }
        for m in &self.ignore {
            if m.why.trim().is_empty() {
                return Err(format!("spec: ignore mask at {},{} has no why", m.x, m.y));
            }
        }
        for r in &self.regions {
            if r.max_changed_ratio.is_some_and(|v| !ratio_ok(v))
                || r.min_ssim.is_some_and(|v| !ratio_ok(v))
            {
                return Err(format!("spec: region {} thresholds are 0..1", r.name));
            }
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ImageInfo {
    pub hash: String,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegionVerdict {
    pub name: String,
    pub pass: bool,
    pub changed_pixels: u64,
    pub compared_pixels: u64,
    pub changed_ratio: f64,
    pub ssim: f64,
    pub reasons: Vec<String>,
}

/// The JSON verdict every caller reads.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Verdict {
    pub schema: String,
    pub pass: bool,
    /// Same pixels exactly (same content hash).
    pub identical: bool,
    pub reasons: Vec<String>,
    pub base: ImageInfo,
    pub head: ImageInfo,
    pub changed_pixels: u64,
    pub compared_pixels: u64,
    pub ignored_pixels: u64,
    pub changed_ratio: f64,
    pub ssim: f64,
    /// The 32x32 tile with the lowest mean SSIM (its windows' centers inside it); None when no tile has a window.
    pub worst_tile: Option<Tile>,
    /// Changed areas, merged on a 16-pixel grid, top to bottom (at most 64).
    pub boxes: Vec<Rect>,
    pub regions: Vec<RegionVerdict>,
    pub spec: Spec,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Tile {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    pub ssim: f64,
}

pub struct Comparison {
    pub verdict: Verdict,
    /// Head dimmed to gray, changed pixels red, ignored areas blue, changed boxes outlined. None when
    /// the sizes differ.
    pub diff_image: Option<Rgba>,
}

fn round6(v: f64) -> f64 {
    (v * 1e6).round() / 1e6
}

fn clip(r: (u32, u32, u32, u32), scale: u32, w: u32, h: u32) -> (u32, u32, u32, u32) {
    let x0 = r.0.saturating_mul(scale).min(w);
    let y0 = r.1.saturating_mul(scale).min(h);
    let x1 = r.0.saturating_add(r.2).saturating_mul(scale).min(w);
    let y1 = r.1.saturating_add(r.3).saturating_mul(scale).min(h);
    (x0, y0, x1, y1)
}

#[inline]
fn luma(p: [u8; 4]) -> f64 {
    // Rec. 601 in integers, then to f64: identical on every machine.
    ((299 * p[0] as u32 + 587 * p[1] as u32 + 114 * p[2] as u32) as f64) / 1000.0
}

fn ssim_window(a: &[f64], b: &[f64]) -> f64 {
    const C1: f64 = (0.01 * 255.0) * (0.01 * 255.0);
    const C2: f64 = (0.03 * 255.0) * (0.03 * 255.0);
    let n = a.len() as f64;
    let (mut sa, mut sb) = (0.0, 0.0);
    for (&x, &y) in a.iter().zip(b) {
        sa += x;
        sb += y;
    }
    let (ma, mb) = (sa / n, sb / n);
    let (mut va, mut vb, mut cov) = (0.0, 0.0, 0.0);
    for (&x, &y) in a.iter().zip(b) {
        let (da, db) = (x - ma, y - mb);
        va += da * da;
        vb += db * db;
        cov += da * db;
    }
    let denom = if n > 1.0 { n - 1.0 } else { 1.0 };
    let (va, vb, cov) = (va / denom, vb / denom, cov / denom);
    ((2.0 * ma * mb + C1) * (2.0 * cov + C2)) / ((ma * ma + mb * mb + C1) * (va + vb + C2))
}

/// Sets `value` on every cell of a clipped rect in a row-major grid `w` cells wide.
fn fill_rect<T: Copy>(grid: &mut [T], w: u32, rect: (u32, u32, u32, u32), value: T) {
    let (x0, y0, x1, y1) = (rect.0 as usize, rect.1 as usize, rect.2 as usize, rect.3 as usize);
    for row in grid.chunks_exact_mut(w as usize).skip(y0).take(y1.saturating_sub(y0)) {
        if let Some(cells) = row.get_mut(x0..x1) {
            cells.fill(value);
        }
    }
}

/// Per-region running totals for the pixel and SSIM passes.
#[derive(Clone, Copy, Default)]
struct RegionAcc {
    changed: u64,
    compared: u64,
    ssim_sum: f64,
    ssim_n: u64,
}

fn inside(r: &(u32, u32, u32, u32), x: u32, y: u32) -> bool {
    x >= r.0 && x < r.2 && y >= r.1 && y < r.3
}

/// Window origins along one axis: every STRIDE, plus the last full window so the far edge is covered.
fn origins(len: u32, win: u32) -> Vec<u32> {
    if len <= win {
        return vec![0];
    }
    let mut v: Vec<u32> = (0..=len - win).step_by(STRIDE as usize).collect();
    if *v.last().unwrap_or(&0) != len - win {
        v.push(len - win);
    }
    v
}

pub fn compare(base: &Rgba, head: &Rgba, spec: &Spec) -> Comparison {
    let base_info = ImageInfo { hash: base.content_hash(), width: base.width, height: base.height };
    let head_info = ImageInfo { hash: head.content_hash(), width: head.width, height: head.height };
    let identical = base_info.hash == head_info.hash;

    if base.width != head.width || base.height != head.height {
        let verdict = Verdict {
            schema: VERDICT_SCHEMA.into(),
            pass: false,
            identical: false,
            reasons: vec![format!(
                "size: base {}x{}, head {}x{}",
                base.width, base.height, head.width, head.height
            )],
            base: base_info,
            head: head_info,
            changed_pixels: 0,
            compared_pixels: 0,
            ignored_pixels: 0,
            changed_ratio: 1.0,
            ssim: 0.0,
            worst_tile: None,
            boxes: Vec::new(),
            regions: Vec::new(),
            spec: spec.clone(),
        };
        return Comparison { verdict, diff_image: None };
    }

    let (w, h) = (base.width, base.height);
    let n = w as usize * h as usize;

    // Ignore mask and per-pixel tolerance (the last region covering a pixel sets its tolerance).
    let mut ignored = vec![false; n];
    for m in &spec.ignore {
        fill_rect(&mut ignored, w, clip((m.x, m.y, m.w, m.h), spec.scale, w, h), true);
    }
    let regions: Vec<(u32, u32, u32, u32)> =
        spec.regions.iter().map(|r| clip((r.x, r.y, r.w, r.h), spec.scale, w, h)).collect();
    let mut tolerance = vec![spec.channel_tolerance; n];
    for (r, rect) in spec.regions.iter().zip(&regions) {
        if let Some(t) = r.channel_tolerance {
            fill_rect(&mut tolerance, w, *rect, t);
        }
    }

    // Pixel pass.
    let (base_px, head_px) = (base.data.as_chunks::<4>().0, head.data.as_chunks::<4>().0);
    let mut changed = vec![false; n];
    let (mut changed_count, mut compared, mut ignored_count) = (0u64, 0u64, 0u64);
    let mut acc = vec![RegionAcc::default(); regions.len()];
    let cells = base_px.iter().zip(head_px).zip(&ignored).zip(&tolerance).zip(changed.iter_mut());
    for (i, ((((a, b), &ign), &tol), out)) in cells.enumerate() {
        if ign {
            ignored_count += 1;
            continue;
        }
        compared += 1;
        let delta = a.iter().zip(b).map(|(p, q)| p.abs_diff(*q)).max().unwrap_or(0);
        let is_changed = delta > tol;
        if is_changed {
            *out = true;
            changed_count += 1;
        }
        let (x, y) = ((i % w as usize) as u32, (i / w as usize) as u32);
        for (r, a) in regions.iter().zip(acc.iter_mut()) {
            if inside(r, x, y) {
                a.compared += 1;
                if is_changed {
                    a.changed += 1;
                }
            }
        }
    }

    // SSIM pass over luma windows that touch no mask.
    let la: Vec<f64> = base_px.iter().map(|p| luma(*p)).collect();
    let lb: Vec<f64> = head_px.iter().map(|p| luma(*p)).collect();
    let (ww, wh) = (WINDOW.min(w), WINDOW.min(h));
    let (mut ssim_sum, mut ssim_n) = (0.0f64, 0u64);
    let mut wa = Vec::with_capacity((ww * wh) as usize);
    let mut wb = Vec::with_capacity((ww * wh) as usize);
    let tiles_x = w.div_ceil(SSIM_TILE) as usize;
    let mut tiles = vec![(0.0f64, 0u64); tiles_x * h.div_ceil(SSIM_TILE) as usize];
    let xs = origins(w, ww);
    for oy in origins(h, wh) {
        'win: for &ox in &xs {
            wa.clear();
            wb.clear();
            for y in oy..oy + wh {
                let s = y as usize * w as usize + ox as usize;
                let e = s + ww as usize;
                let (Some(ign), Some(ra), Some(rb)) =
                    (ignored.get(s..e), la.get(s..e), lb.get(s..e))
                else {
                    continue 'win;
                };
                if ign.iter().any(|&b| b) {
                    continue 'win;
                }
                wa.extend_from_slice(ra);
                wb.extend_from_slice(rb);
            }
            let s = ssim_window(&wa, &wb);
            ssim_sum += s;
            ssim_n += 1;
            // A window counts for a tile or region when its center lies inside it, so small regions
            // still get windows.
            let (cx, cy) = (ox + ww / 2, oy + wh / 2);
            let t = (cy / SSIM_TILE) as usize * tiles_x + (cx / SSIM_TILE) as usize;
            if let Some(tile) = tiles.get_mut(t) {
                tile.0 += s;
                tile.1 += 1;
            }
            for (r, a) in regions.iter().zip(acc.iter_mut()) {
                if inside(r, cx, cy) {
                    a.ssim_sum += s;
                    a.ssim_n += 1;
                }
            }
        }
    }
    let mean = |sum: f64, k: u64| if k == 0 { 1.0 } else { sum / k as f64 };
    let ratio = |c: u64, t: u64| if t == 0 { 0.0 } else { c as f64 / t as f64 };

    let ssim = round6(mean(ssim_sum, ssim_n));
    let changed_ratio = round6(ratio(changed_count, compared));
    let mut worst_tile: Option<Tile> = None;
    for (t, &(sum, k)) in tiles.iter().enumerate() {
        if k == 0 {
            continue;
        }
        let ts = round6(sum / k as f64);
        if worst_tile.as_ref().is_none_or(|b| ts < b.ssim) {
            let (x, y) = ((t % tiles_x) as u32 * SSIM_TILE, (t / tiles_x) as u32 * SSIM_TILE);
            worst_tile =
                Some(Tile { x, y, w: SSIM_TILE.min(w - x), h: SSIM_TILE.min(h - y), ssim: ts });
        }
    }
    let mut reasons = Vec::new();
    if changed_ratio > spec.max_changed_ratio {
        reasons.push(format!("changed_ratio {changed_ratio} > {}", spec.max_changed_ratio));
    }
    if ssim < spec.min_ssim {
        reasons.push(format!("ssim {ssim} < {}", spec.min_ssim));
    }
    if let Some(t) = worst_tile.as_ref().filter(|t| t.ssim < spec.min_tile_ssim) {
        reasons.push(format!("tile {},{} ssim {} < {}", t.x, t.y, t.ssim, spec.min_tile_ssim));
    }

    let mut region_verdicts = Vec::new();
    for (r, a) in spec.regions.iter().zip(&acc) {
        let max_ratio = r.max_changed_ratio.unwrap_or(spec.max_changed_ratio);
        let min_ssim = r.min_ssim.unwrap_or(spec.min_ssim);
        let cr = round6(ratio(a.changed, a.compared));
        let rs = round6(mean(a.ssim_sum, a.ssim_n));
        let mut rr = Vec::new();
        if cr > max_ratio {
            rr.push(format!("changed_ratio {cr} > {max_ratio}"));
        }
        if rs < min_ssim {
            rr.push(format!("ssim {rs} < {min_ssim}"));
        }
        for reason in &rr {
            reasons.push(format!("region {}: {reason}", r.name));
        }
        region_verdicts.push(RegionVerdict {
            name: r.name.clone(),
            pass: rr.is_empty(),
            changed_pixels: a.changed,
            compared_pixels: a.compared,
            changed_ratio: cr,
            ssim: rs,
            reasons: rr,
        });
    }

    let boxes = changed_boxes(&changed, w, h);
    let diff_image = Some(render_diff(head, &changed, &ignored, &boxes));
    let verdict = Verdict {
        schema: VERDICT_SCHEMA.into(),
        pass: reasons.is_empty(),
        identical,
        reasons,
        base: base_info,
        head: head_info,
        changed_pixels: changed_count,
        compared_pixels: compared,
        ignored_pixels: ignored_count,
        changed_ratio,
        ssim,
        worst_tile,
        boxes,
        regions: region_verdicts,
        spec: spec.clone(),
    };
    Comparison { verdict, diff_image }
}

/// Connected groups of 16-pixel tiles that hold a changed pixel, as pixel boxes, top to bottom.
fn changed_boxes(changed: &[bool], w: u32, h: u32) -> Vec<Rect> {
    let (tw, th) = (w.div_ceil(TILE), h.div_ceil(TILE));
    let mut tiles = vec![false; (tw * th) as usize];
    for (y, row) in changed.chunks_exact(w as usize).enumerate() {
        for (x, _) in row.iter().enumerate().filter(|(_, c)| **c) {
            let t = (y as u32 / TILE) * tw + x as u32 / TILE;
            if let Some(tile) = tiles.get_mut(t as usize) {
                *tile = true;
            }
        }
    }
    // seen[j]: tile j is changed and already in a box; starts true for unchanged tiles.
    let mut seen: Vec<bool> = tiles.iter().map(|t| !t).collect();
    let mut boxes = Vec::new();
    for start in 0..seen.len() {
        match seen.get_mut(start) {
            Some(s) if !*s => *s = true,
            _ => continue,
        }
        let (mut x0, mut y0, mut x1, mut y1) = (u32::MAX, u32::MAX, 0u32, 0u32);
        let mut stack = vec![start];
        while let Some(t) = stack.pop() {
            let (tx, ty) = (t as u32 % tw, t as u32 / tw);
            x0 = x0.min(tx);
            y0 = y0.min(ty);
            x1 = x1.max(tx);
            y1 = y1.max(ty);
            let mut push = |nx: u32, ny: u32| {
                let j = (ny * tw + nx) as usize;
                if let Some(s) = seen.get_mut(j).filter(|s| !**s) {
                    *s = true;
                    stack.push(j);
                }
            };
            if tx > 0 {
                push(tx - 1, ty);
            }
            if tx + 1 < tw {
                push(tx + 1, ty);
            }
            if ty > 0 {
                push(tx, ty - 1);
            }
            if ty + 1 < th {
                push(tx, ty + 1);
            }
        }
        let px0 = x0 * TILE;
        let py0 = y0 * TILE;
        let px1 = ((x1 + 1) * TILE).min(w);
        let py1 = ((y1 + 1) * TILE).min(h);
        boxes.push(Rect { x: px0, y: py0, w: px1 - px0, h: py1 - py0 });
        if boxes.len() == MAX_BOXES {
            break;
        }
    }
    boxes
}

fn render_diff(head: &Rgba, changed: &[bool], ignored: &[bool], boxes: &[Rect]) -> Rgba {
    let (w, h) = (head.width, head.height);
    let mut out = Rgba::new(w, h, [0, 0, 0, 255]);
    let cells = out
        .data
        .as_chunks_mut::<4>()
        .0
        .iter_mut()
        .zip(head.data.as_chunks::<4>().0)
        .zip(changed)
        .zip(ignored);
    for (((o, p), &c), &ign) in cells {
        let gray = (170 + luma(*p) as u32 / 3) as u8;
        *o = if c {
            [255, 0, 64, 255]
        } else if ign {
            [gray / 2, gray / 2 + 40, 255, 255]
        } else {
            [gray, gray, gray, 255]
        };
    }
    let outline = [255, 160, 0, 255];
    for b in boxes {
        let (x1, y1) = (b.x + b.w - 1, b.y + b.h - 1);
        for x in b.x..=x1 {
            out.set(x, b.y, outline);
            out.set(x, y1, outline);
        }
        for y in b.y..=y1 {
            out.set(b.x, y, outline);
            out.set(x1, y, outline);
        }
    }
    out
}
