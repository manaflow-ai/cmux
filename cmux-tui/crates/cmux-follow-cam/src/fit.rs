//! `fit`: the largest crop of an aspect inside a source that keeps the most
//! salient weight in frame.
//!
//! The crop's size is fixed by the aspect (and an optional zoom); only its
//! position is chosen. Each position scores
//!
//! ```text
//!   Σ weight·coverage                        keep the subject in frame
//! - COMPOSE · Σ weight·coverage·offset       subject near the crop's middle
//! - center_bias · Σ weight · drift           mild pull to the source centre
//! ```
//!
//! where `coverage` is the fraction of a region inside the crop (its top
//! [`TOP_SHARE`] counts extra: a crop that must cut a tall figure keeps the
//! head, a face, the sky line, and drops the feet), `offset` is
//! the region centre's distance from the crop centre in crop half-sizes, and
//! `drift` is the crop's distance from the centred crop in units of its free
//! travel. Coverage is piecewise linear in the position, so its maximum is at a
//! crop edge meeting a region edge; the candidates are those breakpoints, each
//! region centred, the weighted centroid centred and an even sweep. Candidates
//! are tried in a fixed order starting at the centred crop and a later one
//! wins only with a strictly higher score, so equal scores keep the centred
//! crop and the result is deterministic.

// Pure and panic-free on any input (the camera calls it every retarget).
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::indexing_slicing,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented
    )
)]

use crate::Rect;

/// A source picture's size in pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Size {
    pub w: f64,
    pub h: f64,
}

impl Size {
    pub const fn new(w: f64, h: f64) -> Self {
        Self { w, h }
    }
}

/// A salient part of the source, in source pixels, with a positive weight.
/// A region of zero width or height is a point (a face centre, a caret).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Salient {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub weight: f64,
}

impl Salient {
    pub const fn new(x: f64, y: f64, w: f64, h: f64, weight: f64) -> Self {
        Self { x, y, w, h, weight }
    }

    pub fn center(&self) -> (f64, f64) {
        (self.x + self.w / 2.0, self.y + self.h / 2.0)
    }
}

/// Low-detail margins of a picture (a blurred fill, a plain border painted
/// so a crop has somewhere to go), as fractions of the source's width
/// (`left`, `right`) and height (`top`, `bottom`). A crop never shows them:
/// it is the largest of its aspect inside what they leave, so they set a
/// floor on how far the picture is enlarged.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Bleed {
    pub left: f64,
    pub top: f64,
    pub right: f64,
    pub bottom: f64,
}

/// The most a pair of opposite margins may take: a tenth of each axis is
/// always left to show.
const MAX_BLEED: f64 = 0.9;

impl Bleed {
    /// The part of `source` inside the margins. A margin that is not finite
    /// or is negative counts as 0; opposite margins that add up to more than
    /// [`MAX_BLEED`] shrink in proportion.
    pub fn safe(&self, source: Size) -> Rect {
        let m = |v: f64| if v.is_finite() { v.clamp(0.0, 1.0) } else { 0.0 };
        let axis = |lead: f64, trail: f64| {
            let (lead, trail) = (m(lead), m(trail));
            let sum = lead + trail;
            if sum > MAX_BLEED {
                (lead * MAX_BLEED / sum, trail * MAX_BLEED / sum)
            } else {
                (lead, trail)
            }
        };
        let (l, r) = axis(self.left, self.right);
        let (t, b) = axis(self.top, self.bottom);
        Rect::new(source.w * l, source.h * t, source.w * (1.0 - l - r), source.h * (1.0 - t - b))
    }
}

/// A picture's framing set by hand (a sidecar next to the picture): the
/// point to keep in view and the margins to keep off screen.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Framing {
    /// The point to keep in view, 0..=1 from the top left (clamped). When
    /// set, the crop is centred on it as far as the margins allow and the
    /// salient regions are not used; when `None`, they place the crop inside
    /// the margins.
    pub focus: Option<(f64, f64)>,
    pub bleed: Bleed,
}

/// How [`fit_with`] trades the subject against the centre.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FitOptions {
    /// Score lost (as a fraction of the total weight) by a crop pushed all
    /// the way to one side of the source. Small, so it only breaks ties.
    pub center_bias: f64,
    /// Crop scale: 1 is the largest crop of the aspect, 2 is half as wide and
    /// half as tall. Values under 1 or not finite count as 1.
    pub zoom: f64,
    /// A hand-set framing; overrides the regions with its focus point and
    /// keeps its bleed off screen.
    pub framing: Option<Framing>,
}

impl Default for FitOptions {
    fn default() -> Self {
        Self { center_bias: 0.03, zoom: 1.0, framing: None }
    }
}

/// What a crop costs the picture: how much of it stays and how much it is
/// enlarged.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CropReport {
    pub crop: Rect,
    /// The crop's share of the source's area, 0..=1.
    pub kept: f64,
    /// How much larger the picture shows than with the largest crop of the
    /// same aspect (1: no more than a plain cover fill; 1.5: bleed or zoom
    /// enlarge it half again). 0 for a degenerate crop.
    pub enlargement: f64,
}

impl CropReport {
    /// Display pixels per source pixel when the crop fills `display_w`
    /// pixels across: over 1 the picture is upsampled. 0 when degenerate.
    pub fn display_scale(&self, display_w: f64) -> f64 {
        let s = display_w / self.crop.w;
        if s.is_finite() && s > 0.0 { s } else { 0.0 }
    }
}

/// The [`CropReport`] of `crop`, a crop of `aspect` in `source`.
pub fn report(source: Size, aspect: f64, crop: Rect) -> CropReport {
    if !(valid(source) && crop.w.is_finite() && crop.h.is_finite() && crop.w > 0.0 && crop.h > 0.0)
    {
        return CropReport { crop, kept: 0.0, enlargement: 0.0 };
    }
    let (cover_w, _) = crop_size(source, aspect, 1.0);
    let kept = (crop.w * crop.h / (source.w * source.h)).clamp(0.0, 1.0);
    let enlargement = cover_w / crop.w;
    CropReport { crop, kept, enlargement: if enlargement.is_finite() { enlargement } else { 0.0 } }
}

/// [`fit_with`] and its [`report`] in one call.
pub fn fit_report(
    source: Size,
    aspect: f64,
    regions: &[Salient],
    options: FitOptions,
) -> CropReport {
    report(source, aspect, fit_with(source, aspect, regions, options))
}

fn valid(source: Size) -> bool {
    source.w.is_finite() && source.h.is_finite() && source.w > 0.0 && source.h > 0.0
}

/// Weight of the composition term: how much a subject at the crop's edge
/// loses against one in the middle (as a fraction of its own weight).
const COMPOSE: f64 = 0.2;
/// The top share of a region that counts extra in its vertical coverage...
pub const TOP_SHARE: f64 = 0.4;
/// ...and how much extra: vertical coverage is (1 - TOP_WEIGHT) of the whole
/// region's plus TOP_WEIGHT of its top's.
const TOP_WEIGHT: f64 = 0.5;
/// Even sweep steps per free axis, on top of the breakpoints.
const SWEEP: usize = 48;
/// At most this many regions are scored (the heaviest); the rest are noise.
const MAX_REGIONS: usize = 32;

/// The largest crop of `aspect` (width / height) inside `source` that keeps
/// the most salient weight, centre-biased and deterministic.
///
/// Degenerate input never panics: a source that is not a positive finite
/// size gives a zero rect at the origin; an aspect that is not positive and
/// finite uses the source's own aspect; regions that are not finite, have no
/// positive weight or lie outside the source are ignored (no regions: the
/// centred crop).
pub fn fit(source: Size, aspect: f64, regions: &[Salient]) -> Rect {
    fit_with(source, aspect, regions, FitOptions::default())
}

/// [`fit`] with explicit options: zoom, centre bias and a hand-set
/// [`Framing`]. With a framing the crop is the largest of `aspect` inside the
/// bleed's safe area (divided by zoom), centred on the focus point when there
/// is one and placed by the regions otherwise, never over the bleed.
pub fn fit_with(source: Size, aspect: f64, regions: &[Salient], options: FitOptions) -> Rect {
    if !valid(source) {
        return Rect::new(0.0, 0.0, 0.0, 0.0);
    }
    let full = Rect::new(0.0, 0.0, source.w, source.h);
    let bounds = options.framing.map_or(full, |f| f.bleed.safe(source));
    // The aspect a degenerate request falls back to is the source's, not the
    // safe area's.
    let aspect = if aspect.is_finite() && aspect > 0.0 { aspect } else { source.w / source.h };
    let size = crop_size(Size::new(bounds.w, bounds.h), aspect, options.zoom);
    let focus =
        options.framing.and_then(|f| f.focus).filter(|(x, y)| x.is_finite() && y.is_finite());
    if let Some((fx, fy)) = focus {
        let (px, py) = (source.w * fx.clamp(0.0, 1.0), source.h * fy.clamp(0.0, 1.0));
        let x = (px - size.0 / 2.0).clamp(bounds.x, bounds.x + (bounds.w - size.0).max(0.0));
        let y = (py - size.1 / 2.0).clamp(bounds.y, bounds.y + (bounds.h - size.1).max(0.0));
        return Rect::new(x, y, size.0, size.1);
    }
    place_in(bounds, size, regions, options.center_bias)
}

/// Where a crop of `size` (clamped to the source) goes in `source` to keep
/// the most salient weight: [`fit_with`] once the size is known. The follow
/// camera calls this for its `Salient` goal with its own crop size (a manual
/// pinch keeps the person's size), so goal choice and `fit` are one function.
pub fn place(source: Size, size: (f64, f64), regions: &[Salient], center_bias: f64) -> Rect {
    if !valid(source) {
        return Rect::new(0.0, 0.0, 0.0, 0.0);
    }
    place_in(Rect::new(0.0, 0.0, source.w, source.h), size, regions, center_bias)
}

/// [`place`] inside `bounds` (a part of the source, in source pixels): the
/// search runs in the bounds' own coordinates and the regions are clipped to
/// them.
fn place_in(bounds: Rect, size: (f64, f64), regions: &[Salient], center_bias: f64) -> Rect {
    let source = Size::new(bounds.w, bounds.h);
    if !(valid(source) && bounds.x.is_finite() && bounds.y.is_finite()) {
        return Rect::new(0.0, 0.0, 0.0, 0.0);
    }
    let local: Vec<Salient> = regions
        .iter()
        .map(|r| Salient::new(r.x - bounds.x, r.y - bounds.y, r.w, r.h, r.weight))
        .collect();
    let r = place_local(source, size, &local, center_bias);
    Rect::new(r.x + bounds.x, r.y + bounds.y, r.w, r.h)
}

fn place_local(source: Size, size: (f64, f64), regions: &[Salient], center_bias: f64) -> Rect {
    let finite_or = |v: f64, d: f64| if v.is_finite() { v.clamp(0.0, d) } else { d };
    let (cw, ch) = (finite_or(size.0, source.w), finite_or(size.1, source.h));
    let travel_x = (source.w - cw).max(0.0);
    let travel_y = (source.h - ch).max(0.0);
    let centred = Rect::new(travel_x / 2.0, travel_y / 2.0, cw, ch);

    let mut live = sanitize(source, regions);
    if live.is_empty() {
        return centred;
    }
    // Heaviest first; ties keep input order (stable sort), so the cut below is
    // deterministic.
    live.sort_by(|a, b| b.weight.total_cmp(&a.weight));
    live.truncate(MAX_REGIONS);

    let bias = if center_bias.is_finite() { center_bias.max(0.0) } else { 0.0 };
    let xs = candidates(travel_x, cw, &live, |r| (r.x, r.w));
    let ys = candidates(travel_y, ch, &live, |r| (r.y, r.h));

    let mut best = centred;
    let mut best_score = score(centred, travel_x, travel_y, &live, bias);
    for &y in &ys {
        for &x in &xs {
            let rect = Rect::new(x, y, cw, ch);
            let s = score(rect, travel_x, travel_y, &live, bias);
            if s > best_score {
                best_score = s;
                best = rect;
            }
        }
    }
    best
}

/// The crop's size: the largest of `aspect` inside `source`, divided by zoom.
fn crop_size(source: Size, aspect: f64, zoom: f64) -> (f64, f64) {
    let source_aspect = source.w / source.h;
    let aspect = if aspect.is_finite() && aspect > 0.0 { aspect } else { source_aspect };
    let zoom = if zoom.is_finite() && zoom >= 1.0 { zoom } else { 1.0 };
    let (w, h) = if aspect >= source_aspect {
        (source.w, source.w / aspect)
    } else {
        (source.h * aspect, source.h)
    };
    ((w / zoom).clamp(0.0, source.w), (h / zoom).clamp(0.0, source.h))
}

/// Regions clipped to the source; drops the ones that cannot count.
fn sanitize(source: Size, regions: &[Salient]) -> Vec<Salient> {
    regions
        .iter()
        .filter(|r| {
            r.x.is_finite()
                && r.y.is_finite()
                && r.w.is_finite()
                && r.h.is_finite()
                && r.weight.is_finite()
                && r.weight > 0.0
                && r.w >= 0.0
                && r.h >= 0.0
        })
        .filter_map(|r| {
            let x0 = r.x.max(0.0);
            let y0 = r.y.max(0.0);
            let x1 = (r.x + r.w).min(source.w);
            let y1 = (r.y + r.h).min(source.h);
            (x1 >= x0 && y1 >= y0).then_some(Salient::new(x0, y0, x1 - x0, y1 - y0, r.weight))
        })
        .collect()
}

/// Positions to try along one axis, in a fixed order, all inside [0, travel].
fn candidates(
    travel: f64,
    len: f64,
    regions: &[Salient],
    axis: impl Fn(&Salient) -> (f64, f64),
) -> Vec<f64> {
    let mut out = vec![travel / 2.0];
    if travel <= 0.0 {
        return out;
    }
    out.push(0.0);
    out.push(travel);
    let mut total = 0.0;
    let mut moment = 0.0;
    for r in regions {
        let (start, extent) = axis(r);
        let end = start + extent;
        let mid = start + extent / 2.0;
        // A crop edge on a region edge: where coverage changes slope.
        let top_end = start + extent * TOP_SHARE;
        out.extend([start, end - len, end, start - len, mid - len / 2.0, top_end - len, top_end]);
        total += r.weight;
        moment += r.weight * mid;
    }
    if total > 0.0 {
        out.push(moment / total - len / 2.0);
    }
    for i in 0..=SWEEP {
        out.push(travel * i as f64 / SWEEP as f64);
    }
    for p in &mut out {
        *p = p.clamp(0.0, travel);
    }
    out
}

fn score(rect: Rect, travel_x: f64, travel_y: f64, regions: &[Salient], bias: f64) -> f64 {
    let (cx, cy) = rect.center();
    let mut total = 0.0;
    let mut kept = 0.0;
    for r in regions {
        let top = overlap(r.y, r.h * TOP_SHARE, rect.y, rect.h);
        let vertical = (1.0 - TOP_WEIGHT) * overlap(r.y, r.h, rect.y, rect.h) + TOP_WEIGHT * top;
        let coverage = overlap(r.x, r.w, rect.x, rect.w) * vertical;
        let (rx, ry) = r.center();
        let off_x = if rect.w > 0.0 { (rx - cx).abs() / (rect.w / 2.0) } else { 0.0 };
        let off_y = if rect.h > 0.0 { (ry - cy).abs() / (rect.h / 2.0) } else { 0.0 };
        let offset = off_x.max(off_y).min(1.0);
        kept += r.weight * coverage * (1.0 - COMPOSE * offset);
        total += r.weight;
    }
    let drift_x =
        if travel_x > 0.0 { (rect.x - travel_x / 2.0).abs() / (travel_x / 2.0) } else { 0.0 };
    let drift_y =
        if travel_y > 0.0 { (rect.y - travel_y / 2.0).abs() / (travel_y / 2.0) } else { 0.0 };
    kept - bias * total * drift_x.max(drift_y)
}

/// Fraction of the span [start, start + extent] inside [c0, c0 + clen]. A
/// span of zero extent is a point: 1 inside, 0 outside.
fn overlap(start: f64, extent: f64, c0: f64, clen: f64) -> f64 {
    let c1 = c0 + clen;
    if extent <= 0.0 {
        return if start >= c0 && start <= c1 { 1.0 } else { 0.0 };
    }
    let lo = start.max(c0);
    let hi = (start + extent).min(c1);
    ((hi - lo) / extent).clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ASPECTS: [(&str, f64); 6] = [
        ("21:9", 21.0 / 9.0),
        ("16:10", 16.0 / 10.0),
        ("16:9", 16.0 / 9.0),
        ("9:19.5", 9.0 / 19.5),
        ("1:1", 1.0),
        ("3:4", 3.0 / 4.0),
    ];

    fn contains(outer: Rect, r: Salient) -> bool {
        let e = 1e-6;
        r.x >= outer.x - e
            && r.y >= outer.y - e
            && r.x + r.w <= outer.x + outer.w + e
            && r.y + r.h <= outer.y + outer.h + e
    }

    fn inside_source(rect: Rect, s: Size) -> bool {
        let e = 1e-6;
        rect.x >= -e && rect.y >= -e && rect.x + rect.w <= s.w + e && rect.y + rect.h <= s.h + e
    }

    fn approx(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-6
    }

    #[test]
    fn largest_crop_of_each_aspect() {
        let src = Size::new(1600.0, 1000.0);
        for (name, a) in ASPECTS {
            let r = fit(src, a, &[]);
            assert!(approx(r.w / r.h, a), "{name}: {r:?}");
            assert!(approx(r.w, src.w) || approx(r.h, src.h), "{name} not largest: {r:?}");
            assert!(inside_source(r, src), "{name}: {r:?}");
        }
    }

    #[test]
    fn no_regions_is_centred() {
        let src = Size::new(1600.0, 1000.0);
        let r = fit(src, 1.0, &[]);
        assert_eq!(r, Rect::new(300.0, 0.0, 1000.0, 1000.0));
    }

    #[test]
    fn keeps_off_centre_subject_in_frame_at_every_aspect() {
        // A figure in the right third of a landscape (the backdrop shape:
        // painting on the right) and one near the top of a portrait.
        let cases = [
            (Size::new(1600.0, 1000.0), Salient::new(1180.0, 200.0, 220.0, 520.0, 1.0)),
            (Size::new(1600.0, 1000.0), Salient::new(60.0, 640.0, 180.0, 180.0, 1.0)),
            (Size::new(800.0, 1200.0), Salient::new(300.0, 40.0, 160.0, 200.0, 1.0)),
            (Size::new(3440.0, 1440.0), Salient::new(3000.0, 100.0, 300.0, 300.0, 1.0)),
        ];
        for (src, subject) in cases {
            for (name, a) in ASPECTS {
                let crop = fit(src, a, &[subject]);
                assert!(inside_source(crop, src), "{name} {src:?}: {crop:?}");
                assert!(approx(crop.w / crop.h, a), "{name}: aspect {crop:?}");
                // Keep it whenever the crop is big enough to hold it.
                if subject.w <= crop.w && subject.h <= crop.h {
                    assert!(contains(crop, subject), "{name} {src:?}: {crop:?} cuts {subject:?}");
                }
            }
        }
    }

    #[test]
    fn centre_crop_would_have_cut_it() {
        // The art-aware crop differs from the centre crop where it must.
        let src = Size::new(1600.0, 1000.0);
        let subject = Salient::new(1180.0, 200.0, 220.0, 520.0, 1.0);
        let centre = fit(src, 9.0 / 19.5, &[]);
        assert!(!contains(centre, subject));
        assert!(contains(fit(src, 9.0 / 19.5, &[subject]), subject));
    }

    #[test]
    fn subject_sits_near_the_crop_middle_when_it_can() {
        let src = Size::new(1600.0, 1000.0);
        let subject = Salient::new(1150.0, 300.0, 100.0, 400.0, 1.0);
        let crop = fit(src, 1.0, &[subject]);
        let (cx, _) = crop.center();
        let (sx, _) = subject.center();
        // The crop could hold it anywhere from x=250 to x=600; composition
        // pulls the subject towards the middle, not just inside the edge.
        assert!((cx - sx).abs() < crop.w * 0.25, "{crop:?}");
    }

    #[test]
    fn heavier_region_wins_when_both_do_not_fit() {
        let src = Size::new(2000.0, 1000.0);
        let light = Salient::new(50.0, 400.0, 100.0, 100.0, 1.0);
        let heavy = Salient::new(1800.0, 400.0, 100.0, 100.0, 3.0);
        let crop = fit(src, 1.0, &[light, heavy]);
        assert!(contains(crop, heavy), "{crop:?}");
        assert!(!contains(crop, light), "{crop:?}");
    }

    #[test]
    fn zoom_shrinks_and_still_keeps_subject() {
        let src = Size::new(1600.0, 1000.0);
        let subject = Salient::new(1300.0, 100.0, 100.0, 100.0, 1.0);
        let options = FitOptions { zoom: 2.0, ..FitOptions::default() };
        let crop = fit_with(src, 16.0 / 10.0, &[subject], options);
        assert!(approx(crop.w, 800.0) && approx(crop.h, 500.0), "{crop:?}");
        assert!(contains(crop, subject), "{crop:?}");
        assert!(inside_source(crop, src));
    }

    #[test]
    fn point_region_is_kept() {
        let src = Size::new(1600.0, 1000.0);
        let face = Salient::new(1500.0, 500.0, 0.0, 0.0, 1.0);
        let crop = fit(src, 9.0 / 19.5, &[face]);
        assert!(crop.x <= 1500.0 && crop.x + crop.w >= 1500.0, "{crop:?}");
    }

    #[test]
    fn deterministic() {
        let src = Size::new(1600.0, 1000.0);
        let regions = [
            Salient::new(100.0, 100.0, 300.0, 300.0, 0.4),
            Salient::new(1100.0, 300.0, 300.0, 500.0, 0.6),
        ];
        let a = fit(src, 1.0, &regions);
        for _ in 0..10 {
            assert_eq!(fit(src, 1.0, &regions), a);
        }
    }

    #[test]
    fn symmetric_regions_keep_centre() {
        let src = Size::new(1600.0, 1000.0);
        let regions = [
            Salient::new(400.0, 400.0, 100.0, 100.0, 1.0),
            Salient::new(1100.0, 400.0, 100.0, 100.0, 1.0),
        ];
        // Both fit; the centred crop holds them equally well and wins the tie.
        assert_eq!(fit(src, 1.0, &regions), fit(src, 1.0, &[]));
    }

    #[test]
    fn degenerate_inputs_never_panic() {
        let nan = f64::NAN;
        let inf = f64::INFINITY;
        let sizes = [
            Size::new(0.0, 0.0),
            Size::new(0.0, 100.0),
            Size::new(-5.0, 100.0),
            Size::new(nan, 100.0),
            Size::new(inf, inf),
            Size::new(1600.0, 1000.0),
            Size::new(1.0, 1e9),
        ];
        let aspects = [0.0, -1.0, nan, inf, 1e-12, 1e12, 1.0];
        let regions = [
            Salient::new(nan, 0.0, 10.0, 10.0, 1.0),
            Salient::new(0.0, 0.0, 10.0, 10.0, nan),
            Salient::new(0.0, 0.0, -10.0, 10.0, 1.0),
            Salient::new(5000.0, 5000.0, 10.0, 10.0, 1.0),
            Salient::new(-500.0, -500.0, 10.0, 10.0, 1.0),
            Salient::new(0.0, 0.0, inf, inf, 1.0),
            Salient::new(10.0, 10.0, 10.0, 10.0, 0.0),
            Salient::new(10.0, 10.0, 10.0, 10.0, -1.0),
            Salient::new(10.0, 10.0, 10.0, 10.0, inf),
        ];
        for s in sizes {
            for a in aspects {
                for zoom in [nan, 0.0, 0.5, 1.0, 3.0, inf] {
                    let opts = FitOptions { zoom, center_bias: nan, framing: None };
                    let r = fit_with(s, a, &regions, opts);
                    assert!(r.x.is_finite() && r.y.is_finite(), "{s:?} {a} {r:?}");
                    assert!(r.w.is_finite() && r.h.is_finite(), "{s:?} {a} {r:?}");
                    if s.w > 0.0 && s.h > 0.0 && s.w.is_finite() && s.h.is_finite() {
                        assert!(inside_source(r, s), "{s:?} {a} {r:?}");
                    } else {
                        assert_eq!(r, Rect::new(0.0, 0.0, 0.0, 0.0));
                    }
                }
            }
        }
    }

    fn framed(focus: Option<(f64, f64)>, bleed: Bleed) -> FitOptions {
        FitOptions { framing: Some(Framing { focus, bleed }), ..FitOptions::default() }
    }

    #[test]
    fn manual_focus_overrides_saliency() {
        let src = Size::new(1600.0, 1000.0);
        let left = Salient::new(50.0, 300.0, 200.0, 200.0, 1.0);
        let opts = framed(Some((0.8, 0.3)), Bleed::default());
        for (name, a) in ASPECTS {
            let crop = fit_with(src, a, &[left], opts);
            assert!(inside_source(crop, src), "{name}: {crop:?}");
            let (fx, fy) = (1280.0, 300.0);
            assert!(crop.x <= fx && crop.x + crop.w >= fx, "{name}: {crop:?}");
            assert!(crop.y <= fy && crop.y + crop.h >= fy, "{name}: {crop:?}");
        }
        // Centred on the focus when the source allows.
        let crop = fit_with(src, 1.0, &[left], framed(Some((0.5, 0.5)), Bleed::default()));
        assert_eq!(crop, Rect::new(300.0, 0.0, 1000.0, 1000.0));
        let crop = fit_with(src, 9.0 / 19.5, &[], framed(Some((0.6, 0.5)), Bleed::default()));
        assert!(approx(crop.center().0, 960.0), "{crop:?}");
        // A focus outside 0..=1 clamps; a NaN focus falls back to the regions.
        let crop = fit_with(src, 1.0, &[], framed(Some((7.0, -3.0)), Bleed::default()));
        assert_eq!(crop, Rect::new(600.0, 0.0, 1000.0, 1000.0));
        let nan = fit_with(src, 1.0, &[left], framed(Some((f64::NAN, 0.5)), Bleed::default()));
        assert_eq!(nan, fit(src, 1.0, &[left]));
    }

    #[test]
    fn bleed_stays_off_screen_and_floors_the_scale() {
        let src = Size::new(1600.0, 1000.0);
        // The left half is a blurred fill.
        let bleed = Bleed { left: 0.5, ..Bleed::default() };
        for focus in [None, Some((0.1, 0.5)), Some((0.9, 0.9))] {
            for (name, a) in ASPECTS {
                let crop = fit_with(
                    src,
                    a,
                    &[Salient::new(0.0, 0.0, 400.0, 400.0, 1.0)],
                    framed(focus, bleed),
                );
                assert!(crop.x >= 800.0 - 1e-6, "{name} {focus:?}: shows bleed {crop:?}");
                assert!(inside_source(crop, src), "{name}: {crop:?}");
                assert!(approx(crop.w / crop.h, a), "{name}: {crop:?}");
            }
        }
        // 16:10 into an 800-wide safe area: twice the plain cover scale.
        let r = fit_report(src, 1.6, &[], framed(None, bleed));
        assert!(approx(r.crop.w, 800.0) && approx(r.crop.h, 500.0), "{r:?}");
        assert!(approx(r.enlargement, 2.0), "{r:?}");
        // Where the cover crop already leaves the bleed out it is inert: a
        // 9:19.5 crop is 461 wide either way.
        let plain = fit_report(src, 9.0 / 19.5, &[], FitOptions::default());
        let bled =
            fit_report(src, 9.0 / 19.5, &[], framed(None, Bleed { left: 0.2, ..Bleed::default() }));
        assert!(approx(plain.crop.w, bled.crop.w) && approx(bled.enlargement, 1.0), "{bled:?}");
        assert!(bled.crop.x >= 320.0 - 1e-6);
    }

    #[test]
    fn bad_bleed_never_panics_and_leaves_a_tenth() {
        let src = Size::new(1600.0, 1000.0);
        let nan = f64::NAN;
        for bleed in [
            Bleed { left: nan, top: -1.0, right: f64::INFINITY, bottom: 2.0 },
            Bleed { left: 0.9, top: 0.9, right: 0.9, bottom: 0.9 },
            Bleed { left: 1.0, top: 0.0, right: 0.0, bottom: 1.0 },
        ] {
            let safe = bleed.safe(src);
            assert!(safe.w >= 160.0 - 1e-6 && safe.h >= 100.0 - 1e-6, "{bleed:?}: {safe:?}");
            for (name, a) in ASPECTS {
                for focus in [None, Some((nan, nan)), Some((0.5, 0.5))] {
                    let crop = fit_with(src, a, &[], framed(focus, bleed));
                    assert!(crop.w > 0.0 && crop.h > 0.0, "{name}: {crop:?}");
                    assert!(inside_source(crop, src), "{name}: {crop:?}");
                    let e = 1e-6;
                    assert!(
                        crop.x >= safe.x - e && crop.x + crop.w <= safe.x + safe.w + e,
                        "{name}"
                    );
                    assert!(
                        crop.y >= safe.y - e && crop.y + crop.h <= safe.y + safe.h + e,
                        "{name}"
                    );
                }
            }
        }
    }

    #[test]
    fn report_kept_and_enlargement() {
        let src = Size::new(1600.0, 1000.0);
        let r = fit_report(src, 1.0, &[], FitOptions::default());
        assert!(approx(r.kept, 0.625) && approx(r.enlargement, 1.0), "{r:?}");
        let r = fit_report(src, 1.6, &[], FitOptions::default());
        assert!(approx(r.kept, 1.0) && approx(r.enlargement, 1.0), "{r:?}");
        let zoomed = FitOptions { zoom: 2.0, ..FitOptions::default() };
        let r = fit_report(src, 1.0, &[], zoomed);
        assert!(approx(r.kept, 0.15625) && approx(r.enlargement, 2.0), "{r:?}");
        assert!(approx(r.display_scale(1000.0), 2.0), "{r:?}");
        let r = fit_report(src, 21.0 / 9.0, &[], FitOptions::default());
        assert!(approx(r.kept, 1600.0 * (1600.0 * 9.0 / 21.0) / 1.6e6), "{r:?}");
        // Degenerate: zeros, no panic.
        let none = report(Size::new(0.0, 0.0), 1.0, Rect::new(0.0, 0.0, 0.0, 0.0));
        assert_eq!((none.kept, none.enlargement, none.display_scale(100.0)), (0.0, 0.0, 0.0));
        let nan = report(src, f64::NAN, Rect::new(0.0, 0.0, f64::NAN, 10.0));
        assert_eq!((nan.kept, nan.enlargement), (0.0, 0.0));
    }

    #[test]
    fn too_tall_figure_keeps_its_head() {
        // A standing figure taller than a 21:9 crop of a 16:10 source.
        let src = Size::new(1600.0, 1000.0);
        let figure = Salient::new(1000.0, 60.0, 300.0, 900.0, 1.0);
        let crop = fit(src, 21.0 / 9.0, &[figure]);
        assert!(crop.y <= figure.y + 1e-6, "head cut: {crop:?}");
    }

    #[test]
    fn region_outside_source_is_ignored() {
        let src = Size::new(1600.0, 1000.0);
        let outside = Salient::new(5000.0, 0.0, 100.0, 100.0, 1.0);
        assert_eq!(fit(src, 1.0, &[outside]), fit(src, 1.0, &[]));
    }
}
