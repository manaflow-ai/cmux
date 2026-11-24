//! The selection blob (gooey-tabs.md "The blob"): the selected tab's body,
//! rounded on top and running down into the card, with a concave fillet of
//! `feet_radius` at each bottom corner, tangent to the body's side and to the
//! card's top (none on the leading side when `skips_leading`). At rest it is
//! `TabCell.folderPath` exactly (lines and quarter arcs; a quarter arc's
//! cubic is off by under 0.03% of its radius).
//!
//! Smooth unions (`neck`) are real SDF math: the polynomial smooth-min of the
//! blob's and a rounded rect's signed distance fields, its zero contour
//! marched along each of the rest outline's anchor normals (the fixed
//! parameterization), and the displacements Catmull-Rom fitted onto the rest
//! cubics, so the count never changes and a far neighbour leaves the rest
//! outline untouched.

use std::f64::consts::FRAC_PI_2;

use super::{GOO_OUTLINE_POINTS, Outline, Point, finite_or, length_or_zero};

/// `GOO_OUTLINE_POINTS - 1`: the previous anchor, cyclically.
const PREV: usize = 23;
/// The next anchor but one.
const NEXT2: usize = 2;

/// The blob's geometry in the strip's layer coordinates (flipped: `baseline`
/// is the card's top, `top` < `baseline`).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Blob {
    pub left: f64,
    pub right: f64,
    pub top: f64,
    pub baseline: f64,
    pub corner_radius: f64,
    pub feet_radius: f64,
    /// No leading fillet: the tab sits on the card's own leading edge.
    pub skips_leading: bool,
}

/// A rounded rect (a neighbour, or a dragged tab) in the same coordinates.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RoundedRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub radius: f64,
}

/// A blob's resolved shape: finite, ordered, radii clamped the way
/// `folderPath` clamps them, and a fillet radius per side.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(crate) struct Shape {
    pub left: f64,
    pub right: f64,
    pub top: f64,
    pub baseline: f64,
    pub corner: f64,
    pub feet_leading: f64,
    pub feet_trailing: f64,
}

impl Blob {
    pub(crate) fn shape(&self) -> Shape {
        Shape::new(
            self.left,
            self.right,
            self.top,
            self.baseline,
            self.corner_radius,
            if self.skips_leading { 0. } else { self.feet_radius },
            self.feet_radius,
        )
    }

    pub fn width(&self) -> f64 {
        let s = self.shape();
        s.right - s.left
    }
}

impl Shape {
    pub(crate) fn new(
        left: f64,
        right: f64,
        top: f64,
        baseline: f64,
        corner: f64,
        feet_leading: f64,
        feet_trailing: f64,
    ) -> Self {
        let mut l = finite_or(left, 0.);
        let mut r = finite_or(right, l);
        if r < l {
            let mid = (l + r) * 0.5;
            (l, r) = (mid, mid);
        }
        let baseline = finite_or(baseline, 0.);
        let top = finite_or(top, baseline).min(baseline);
        let (w, h) = (r - l, baseline - top);
        // `folderPath`: min(cornerRadius, width / 2, height / 2).
        let corner = length_or_zero(corner).min(w * 0.5).min(h * 0.5);
        let room = (h - corner).max(0.);
        Self {
            left: l,
            right: r,
            top,
            baseline,
            corner,
            feet_leading: length_or_zero(feet_leading).min(room),
            feet_trailing: length_or_zero(feet_trailing).min(room),
        }
    }

    /// The outline, its top sheared by `lean` points toward +x (0 at the
    /// baseline, `lean` at the top).
    pub(crate) fn outline(&self, lean: f64) -> Outline {
        let Shape {
            left: l,
            right: r,
            top: t,
            baseline: b,
            corner: c,
            feet_leading: fl,
            feet_trailing: ft,
        } = *self;
        let mut pen = Pen::new(Point::new(l - fl, b));
        // Leading fillet: center (l - fl, b - fl), from straight down to straight right.
        pen.arc(Point::new(l - fl, b - fl), fl, FRAC_PI_2, 0., 2);
        pen.line(Point::new(l, t + c), 3);
        pen.arc(Point::new(l + c, t + c), c, 2. * FRAC_PI_2, 3. * FRAC_PI_2, 2);
        pen.line(Point::new(r - c, t), 6);
        pen.arc(Point::new(r - c, t + c), c, 3. * FRAC_PI_2, 4. * FRAC_PI_2, 2);
        pen.line(Point::new(r, b - ft), 3);
        // Trailing fillet: center (r + ft, b - ft), from straight left to straight down.
        pen.arc(Point::new(r + ft, b - ft), ft, 2. * FRAC_PI_2, FRAC_PI_2, 2);
        pen.line(Point::new(l - fl, b), 4);
        let mut out = pen.out;
        let h = b - t;
        if lean != 0. && lean.is_finite() && h > 0. {
            for p in &mut out.p {
                p.x += lean * (b - p.y) / h;
            }
        }
        out
    }

    /// Signed distance (negative inside) to the rest shape: the body's
    /// rounded-top box, unioned with each fillet (its corner square less the
    /// disc that rounds it). 1-Lipschitz, exact on the boundary.
    pub(crate) fn sd(&self, p: Point) -> f64 {
        let Shape {
            left: l,
            right: r,
            top: t,
            baseline: b,
            corner: c,
            feet_leading: fl,
            feet_trailing: ft,
        } = *self;
        let mut d = sd_box(p, l, t, r, b, c, 0.);
        if fl > 0. {
            let square = sd_box(p, l - fl, b - fl, l, b, 0., 0.);
            d = d.min(square.max(fl - p.sub(Point::new(l - fl, b - fl)).len()));
        }
        if ft > 0. {
            let square = sd_box(p, r, b - ft, r + ft, b, 0., 0.);
            d = d.min(square.max(ft - p.sub(Point::new(r + ft, b - ft)).len()));
        }
        d
    }
}

impl RoundedRect {
    pub const fn new(x: f64, y: f64, w: f64, h: f64, radius: f64) -> Self {
        Self { x, y, w, h, radius }
    }

    /// Finite, non-negative size, radius at most half the short side.
    pub(crate) fn sanitized(&self) -> Self {
        let x = finite_or(self.x, 0.);
        let y = finite_or(self.y, 0.);
        let w = length_or_zero(self.w);
        let h = length_or_zero(self.h);
        Self { x, y, w, h, radius: length_or_zero(self.radius).min(w * 0.5).min(h * 0.5) }
    }

    pub(crate) fn sd(&self, p: Point) -> f64 {
        sd_box(p, self.x, self.y, self.x + self.w, self.y + self.h, self.radius, self.radius)
    }

    /// Edge-to-edge distance to the box `l..r` x `t..b` (0 when they touch).
    pub(crate) fn gap_to(&self, l: f64, t: f64, r: f64, b: f64) -> f64 {
        let dx = (self.x - r).max(l - (self.x + self.w)).max(0.);
        let dy = (self.y - b).max(t - (self.y + self.h)).max(0.);
        dx.hypot(dy)
    }
}

/// Signed distance to the box `x0..x1` x `y0..y1` whose top corners (smaller
/// y) round by `top_r` and bottom corners by `bottom_r`.
fn sd_box(p: Point, x0: f64, y0: f64, x1: f64, y1: f64, top_r: f64, bottom_r: f64) -> f64 {
    let (cx, cy) = ((x0 + x1) * 0.5, (y0 + y1) * 0.5);
    let (hw, hh) = ((x1 - x0) * 0.5, (y1 - y0) * 0.5);
    let rr = if p.y < cy { top_r } else { bottom_r };
    let qx = (p.x - cx).abs() - hw + rr;
    let qy = (p.y - cy).abs() - hh + rr;
    qx.max(0.).hypot(qy.max(0.)) + qx.max(qy).min(0.) - rr
}

/// The polynomial smooth minimum: `min(a, b)`, rounded by up to `k / 4`
/// where the two are within `k` of each other (a plain min for `k` <= 0).
pub fn smooth_min(a: f64, b: f64, k: f64) -> f64 {
    if k.is_nan() || k <= 0. {
        return a.min(b);
    }
    let h = (k - (a - b).abs()).max(0.) / k;
    a.min(b) - h * h * k * 0.25
}

/// Writes an outline cubic by cubic; never past its end.
struct Pen {
    out: Outline,
    at: usize,
    last: Point,
}

impl Pen {
    fn new(start: Point) -> Self {
        let mut pen = Self { out: Outline::default(), at: 0, last: start };
        pen.push(start);
        pen
    }

    fn push(&mut self, p: Point) {
        if let Some(slot) = self.out.p.get_mut(self.at) {
            *slot = p;
        }
        self.at = self.at.saturating_add(1);
        self.last = p;
    }

    fn cubic(&mut self, c1: Point, c2: Point, p: Point) {
        self.push(c1);
        self.push(c2);
        self.push(p);
    }

    /// `n` straight cubics to `to`.
    fn line(&mut self, to: Point, n: u32) {
        let from = self.last;
        let nf = f64::from(n.max(1));
        for i in 0..n.max(1) {
            let a = from.lerp(to, f64::from(i) / nf);
            // The last piece ends exactly on `to` (the path closes on its start).
            let b = if i.saturating_add(1) >= n.max(1) {
                to
            } else {
                from.lerp(to, (f64::from(i) + 1.) / nf)
            };
            self.cubic(a.lerp(b, 1. / 3.), a.lerp(b, 2. / 3.), b);
        }
    }

    /// `n` cubics along the circle `center`, `radius` from angle `a0` to
    /// `a1` (y down: angle 0 is +x, pi/2 is +y).
    fn arc(&mut self, center: Point, radius: f64, a0: f64, a1: f64, n: u32) {
        let nf = f64::from(n.max(1));
        let step = (a1 - a0) / nf;
        let k = 4. / 3. * (step / 4.).tan() * radius;
        for i in 0..n.max(1) {
            let t0 = a0 + step * f64::from(i);
            let t1 = t0 + step;
            let p0 = Point::new(center.x + radius * t0.cos(), center.y + radius * t0.sin());
            let p1 = Point::new(center.x + radius * t1.cos(), center.y + radius * t1.sin());
            let c1 = p0.add(Point::new(-t0.sin(), t0.cos()).scale(k));
            let c2 = p1.sub(Point::new(-t1.sin(), t1.cos()).scale(k));
            self.cubic(c1, c2, p1);
        }
    }
}

/// The blob's outline with its top corners leaning `lean` points toward +x
/// (0: the rest outline, `TabCell.folderPath` to the pixel).
pub fn blob(b: &Blob, lean: f64) -> Outline {
    b.shape().outline(lean)
}

/// The rest outline.
pub fn rest_outline(b: &Blob) -> Outline {
    blob(b, 0.)
}

/// The smooth union of `b` with `other` at goo threshold `k`: `b`'s rest
/// outline when `other` is more than `k` away, else the zero contour of
/// `smooth_min(sd_blob, sd_other, k)` on the rest outline's parameterization.
pub fn neck(b: &Blob, other: &RoundedRect, k: f64) -> Outline {
    let shape = b.shape();
    let other = other.sanitized();
    let k = if k.is_finite() { k.clamp(0., 2000.) } else { 0. };
    let rest = shape.outline(0.);
    if other.w <= 0. || other.h <= 0. {
        return rest;
    }
    let gap = other.gap_to(shape.left, shape.top, shape.right, shape.baseline);
    if gap > k {
        return rest;
    }
    merge(&rest, &shape, &other, k)
}

/// Marches every anchor of `rest` out along its normal to the union's zero
/// contour (stopping half a point inside `other`, which draws itself), then
/// adds the displacements, Catmull-Rom fitted, to the rest cubics.
pub(crate) fn merge(rest: &Outline, shape: &Shape, other: &RoundedRect, k: f64) -> Outline {
    let field = |p: Point| smooth_min(shape.sd(p), other.sd(p), k);
    let far = Point::new(other.x + other.w * 0.5, other.y + other.h * 0.5);
    let reach = other.w.hypot(other.h) + k;
    let mut anchors = [Point::default(); GOO_OUTLINE_POINTS];
    let mut c1s = [Point::default(); GOO_OUTLINE_POINTS];
    let mut c2s = [Point::default(); GOO_OUTLINE_POINTS];
    for (slot, p) in anchors.iter_mut().zip(rest.p.iter().step_by(3)) {
        *slot = *p;
    }
    for (slot, p) in c1s.iter_mut().zip(rest.p.iter().skip(1).step_by(3)) {
        *slot = *p;
    }
    for (slot, p) in c2s.iter_mut().zip(rest.p.iter().skip(2).step_by(3)) {
        *slot = *p;
    }
    let mut d = [Point::default(); GOO_OUTLINE_POINTS];
    let mut pinned = [true; GOO_OUTLINE_POINTS];
    for (i, (slot, pin)) in d.iter_mut().zip(pinned.iter_mut()).enumerate() {
        let a = at(&anchors, i, 0);
        let c_in = at(&c2s, i, PREV);
        let Some(n) = normal(c_in, a, at(&c1s, i, 0), at(&anchors, i, PREV), at(&anchors, i, 1))
        else {
            continue;
        };
        // The card's top stays put.
        if n.y > 0.7 && (a.y - shape.baseline).abs() < 0.5 {
            continue;
        }
        *pin = false;
        let max_len = (a.sub(far).len() + reach).min(4000.);
        let t = march(a, n, &field, |p| other.sd(p), max_len);
        if t > 0.01 {
            *slot = n.scale(t);
        }
    }
    let mut out = *rest;
    let mut w = 0usize;
    let mut put = |p: Point| {
        if let Some(slot) = out.p.get_mut(w) {
            *slot = p;
        }
        w = w.saturating_add(1);
    };
    put(at(&anchors, 0, 0).add(at(&d, 0, 0)));
    for i in 0..GOO_OUTLINE_POINTS {
        let (dm, d0, d1, d2) = (at(&d, i, PREV), at(&d, i, 0), at(&d, i, 1), at(&d, i, NEXT2));
        // Catmull-Rom tangents of the displacement, none at a pinned anchor.
        let free =
            |j: usize| pinned.get(j.checked_rem(GOO_OUTLINE_POINTS).unwrap_or(0)) == Some(&false);
        let t0 = if free(i) { d1.sub(dm).scale(1. / 6.) } else { Point::default() };
        let t1 = if free(i.wrapping_add(1)) { d2.sub(d0).scale(1. / 6.) } else { Point::default() };
        put(at(&c1s, i, 0).add(d0).add(t0));
        put(at(&c2s, i, 0).add(d1).sub(t1));
        put(at(&anchors, i, 1).add(d1));
    }
    out
}

/// `arr[(i + off) % N]`.
fn at(arr: &[Point; GOO_OUTLINE_POINTS], i: usize, off: usize) -> Point {
    let j = i.wrapping_add(off).checked_rem(GOO_OUTLINE_POINTS).unwrap_or(0);
    arr.get(j).copied().unwrap_or_default()
}

/// The outward unit normal at anchor `a` (incoming control `c_in`, outgoing
/// `c_out`, neighbouring anchors `prev`, `next`); None where it is undefined.
fn normal(c_in: Point, a: Point, c_out: Point, prev: Point, next: Point) -> Option<Point> {
    let unit = |v: Point| {
        let l = v.len();
        if l > 1e-9 { v.scale(1. / l) } else { Point::default() }
    };
    let mut t = unit(a.sub(c_in)).add(unit(c_out.sub(a)));
    if t.len() < 1e-6 {
        t = next.sub(prev);
    }
    let l = t.len();
    if l.is_nan() || l <= 1e-6 {
        return None;
    }
    // The path runs clockwise on screen (y down): outward is (ty, -tx).
    Some(Point::new(t.y / l, -t.x / l))
}

/// Distance along `n` from `o` to the first exit of `field`'s zero contour,
/// or to half a point inside `stop`'s shape, whichever comes first.
fn march(
    o: Point,
    n: Point,
    field: &impl Fn(Point) -> f64,
    stop: impl Fn(Point) -> f64,
    max_len: f64,
) -> f64 {
    let at_t = |t: f64| o.add(n.scale(t));
    let mut prev = 0.;
    let mut t = 0.;
    for _ in 0..256 {
        let p = at_t(t);
        if stop(p) <= -0.5 {
            return t;
        }
        let f = field(p);
        if !f.is_finite() {
            return prev;
        }
        if f > 0. {
            let (mut lo, mut hi) = (prev, t);
            for _ in 0..24 {
                let mid = (lo + hi) * 0.5;
                if field(at_t(mid)) > 0. { hi = mid } else { lo = mid }
            }
            return lo;
        }
        prev = t;
        // 1-Lipschitz field: a step of |f| never skips an exit.
        t += (-f).clamp(0.25, 16.);
        if t > max_len {
            return prev;
        }
    }
    prev
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `TabCell.folderPath`'s region, as the Swift builds it: the body's
    /// rounded rect (r = min(cornerRadius, w/2, h/2)) unioned with the rect
    /// from minY + r down (square bottom corners), and `feetPath`: at each
    /// bottom corner an r-square outside the body less the circle that
    /// rounds it (no leading one when skipsLeading).
    fn swift_folder_contains(b: &Blob, x: f64, y: f64) -> bool {
        let (minx, maxx, miny, maxy) = (b.left, b.right, b.top, b.baseline);
        let (w, h) = (maxx - minx, maxy - miny);
        let r = b.corner_radius.min(w / 2.).min(h / 2.);
        let in_rect =
            |x0: f64, y0: f64, x1: f64, y1: f64| (x0..=x1).contains(&x) && (y0..=y1).contains(&y);
        let in_circle = |cx: f64, cy: f64, rad: f64| (x - cx).hypot(y - cy) < rad;
        let rounded = in_rect(minx, miny, maxx, maxy)
            && !((x < minx + r && y < miny + r && !in_circle(minx + r, miny + r, r))
                || (x > maxx - r && y < miny + r && !in_circle(maxx - r, miny + r, r))
                || (x < minx + r && y > maxy - r && !in_circle(minx + r, maxy - r, r))
                || (x > maxx - r && y > maxy - r && !in_circle(maxx - r, maxy - r, r)));
        let body = rounded || in_rect(minx, miny + r, maxx, maxy);
        let f = b.feet_radius;
        let lead = !b.skips_leading
            && f > 0.
            && in_rect(minx - f, maxy - f, minx, maxy)
            && !in_circle(minx - f, maxy - f, f);
        let trail =
            f > 0. && in_rect(maxx, maxy - f, maxx + f, maxy) && !in_circle(maxx + f, maxy - f, f);
        body || lead || trail
    }

    fn polyline(o: &Outline) -> Vec<Point> {
        let mut v = Vec::new();
        o.for_each_sample(16, |p| v.push(p));
        v
    }

    fn dist_to_polyline(poly: &[Point], p: Point) -> f64 {
        let mut best = f64::INFINITY;
        for (i, a) in poly.iter().enumerate() {
            let b = poly[(i + 1) % poly.len()];
            let ab = b.sub(*a);
            let l2 = ab.x * ab.x + ab.y * ab.y;
            let t = if l2 > 0. { ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / l2 } else { 0. };
            best = best.min(p.sub(a.lerp(b, t.clamp(0., 1.))).len());
        }
        best
    }

    fn inside_polyline(poly: &[Point], p: Point) -> bool {
        let mut inside = false;
        for (i, a) in poly.iter().enumerate() {
            let b = poly[(i + 1) % poly.len()];
            if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside = !inside;
            }
        }
        inside
    }

    /// The rest outline is the Swift static path to under 0.5 px: every
    /// point of a fine grid around it is in the outline exactly when it is in
    /// the Swift region, except within 0.5 px of the outline.
    #[test]
    fn goo_rest_matches_folder_path() {
        let cases = [
            Blob {
                left: 40.,
                right: 220.,
                top: 6.,
                baseline: 36.,
                corner_radius: 8.,
                feet_radius: 8.,
                skips_leading: false,
            },
            Blob {
                left: 0.,
                right: 180.,
                top: 6.,
                baseline: 36.,
                corner_radius: 8.,
                feet_radius: 8.,
                skips_leading: true,
            },
            Blob {
                left: 10.,
                right: 46.,
                top: 4.,
                baseline: 34.,
                corner_radius: 10.,
                feet_radius: 11.2,
                skips_leading: false,
            },
            Blob {
                left: 10.,
                right: 22.,
                top: 4.,
                baseline: 34.,
                corner_radius: 10.,
                feet_radius: 6.,
                skips_leading: false,
            },
            Blob {
                left: 5.,
                right: 300.,
                top: 0.,
                baseline: 28.,
                corner_radius: 6.,
                feet_radius: 0.,
                skips_leading: false,
            },
        ];
        for b in cases {
            let o = rest_outline(&b);
            assert!(o.is_finite());
            assert_eq!(o.p.first(), o.p.last(), "closed");
            let poly = polyline(&o);
            let (x0, x1) = (b.left - b.feet_radius - 4., b.right + b.feet_radius + 4.);
            let (y0, y1) = (b.top - 4., b.baseline - 0.01);
            let mut y = y0;
            while y < y1 {
                let mut x = x0;
                while x < x1 {
                    let p = Point::new(x, y);
                    if swift_folder_contains(&b, x, y) != inside_polyline(&poly, p) {
                        let d = dist_to_polyline(&poly, p);
                        assert!(d < 0.5, "{b:?}: ({x}, {y}) differs {d} px from the outline");
                    }
                    x += 0.5;
                }
                y += 0.43;
            }
            // And every outline sample lies on the Swift boundary (within 0.5 px).
            for p in &poly {
                if p.y >= b.baseline - 1e-9 {
                    continue;
                }
                let near_in = (0..16).any(|i| {
                    let a = i as f64 * std::f64::consts::PI / 8.;
                    swift_folder_contains(&b, p.x + 0.5 * a.cos(), p.y + 0.5 * a.sin())
                });
                let near_out = (0..16).any(|i| {
                    let a = i as f64 * std::f64::consts::PI / 8.;
                    !swift_folder_contains(&b, p.x + 0.5 * a.cos(), p.y + 0.5 * a.sin())
                });
                assert!(near_in && near_out, "{b:?}: {p:?} is off the Swift boundary");
            }
        }
    }

    #[test]
    fn goo_outline_count_is_constant() {
        let b = Blob {
            left: 0.,
            right: 100.,
            top: 0.,
            baseline: 30.,
            corner_radius: 8.,
            feet_radius: 8.,
            skips_leading: true,
        };
        for o in [
            rest_outline(&b),
            blob(&b, 5.),
            neck(&b, &RoundedRect::new(104., 2., 80., 28., 8.), 14.),
        ] {
            assert_eq!(o.p.len(), 1 + 3 * GOO_OUTLINE_POINTS);
            assert_eq!(o.anchors().count(), GOO_OUTLINE_POINTS);
            assert!(o.is_finite());
            assert!((o.p[0].x - o.p[crate::goo::GOO_OUTLINE_LEN - 1].x).abs() < 1e-9);
        }
    }

    #[test]
    fn goo_neck_far_is_rest_and_near_bridges() {
        let b = Blob {
            left: 0.,
            right: 100.,
            top: 0.,
            baseline: 30.,
            corner_radius: 8.,
            feet_radius: 8.,
            skips_leading: false,
        };
        let rest = rest_outline(&b);
        assert_eq!(neck(&b, &RoundedRect::new(140., 0., 80., 30., 8.), 14.), rest);
        assert_eq!(neck(&b, &RoundedRect::new(110., 0., 80., 30., 8.), 0.), rest);
        let near = neck(&b, &RoundedRect::new(106., 0., 80., 30., 8.), 14.);
        // The trailing side (x = 100 between the corner and the fillet) bulges
        // toward the neighbour 6 points away.
        let side = |o: &Outline| {
            o.p.iter().filter(|p| (10.0..20.).contains(&p.y)).map(|p| p.x).fold(f64::MIN, f64::max)
        };
        let reach = side(&near);
        assert!(reach > side(&rest) + 2., "the neck reaches out: {reach}");
        // The bottom edge stays on the card's top.
        assert!(near.p.iter().all(|p| p.y <= b.baseline + 1.), "{near:?}");
    }

    #[test]
    fn goo_blob_is_garbage_safe() {
        let bad = [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -50., 0., 1e300];
        for &a in &bad {
            for &c in &bad {
                let b = Blob {
                    left: a,
                    right: c,
                    top: c,
                    baseline: a,
                    corner_radius: a,
                    feet_radius: c,
                    skips_leading: a > 0.,
                };
                assert!(blob(&b, a).is_finite());
                assert!(neck(&b, &RoundedRect::new(a, c, a, c, a), c).is_finite());
            }
        }
    }
}
