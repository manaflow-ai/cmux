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
    for o in
        [rest_outline(&b), blob(&b, 5.), neck(&b, &RoundedRect::new(104., 2., 80., 28., 8.), 14.)]
    {
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
