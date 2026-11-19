use super::*;

fn frame<'a>(
    width: f64,
    height: f64,
    scale: f64,
    tiled: &'a [RectPt],
    floating: &'a [RectPt],
) -> Frame<'a> {
    Frame { width, height, scale, tiled, floating }
}

#[test]
fn an_exact_cover_passes_and_each_fault_is_named() {
    let mut checker = Checker::new();
    let tiled = [
        RectPt::new(0.0, 0.0, 40.0, 60.0),
        RectPt::new(40.0, 0.0, 60.0, 30.0),
        RectPt::new(40.0, 30.0, 60.0, 30.0),
    ];
    assert_eq!(checker.check(&frame(100.0, 60.0, 2.0, &tiled, &[])), Ok(()));
    // A seam of one point between two columns.
    let seam = [RectPt::new(0.0, 0.0, 40.0, 60.0), RectPt::new(41.0, 0.0, 59.0, 60.0)];
    assert_eq!(checker.check(&frame(100.0, 60.0, 1.0, &seam, &[])), Err(Fault::Gap { pixels: 60 }));
    // An overlap whose area makes up for a gap elsewhere: the areas alone would pass.
    let swap = [
        RectPt::new(0.0, 0.0, 50.0, 60.0),
        RectPt::new(40.0, 0.0, 50.0, 60.0),
        RectPt::new(90.0, 0.0, 10.0, 50.0),
        RectPt::new(0.0, 0.0, 0.0, 0.0),
    ];
    assert_eq!(
        checker.check(&frame(100.0, 60.0, 1.0, &swap, &[])),
        Err(Fault::Overlap { a: 0, b: 1 })
    );
    // Half a pixel at scale 1.5 (0.5 pt is 0.75 px).
    let half = [RectPt::new(0.0, 0.0, 50.5, 60.0), RectPt::new(50.5, 0.0, 49.5, 60.0)];
    assert!(matches!(
        checker.check(&frame(100.0, 60.0, 1.5, &half, &[])),
        Err(Fault::OffPixel { index: 0, .. })
    ));
    // At scale 2 the same rects are on the grid.
    assert_eq!(checker.check(&frame(100.0, 60.0, 2.0, &half, &[])), Ok(()));
    let outside = [RectPt::new(0.0, 0.0, 101.0, 60.0)];
    assert_eq!(
        checker.check(&frame(100.0, 60.0, 1.0, &outside, &[])),
        Err(Fault::Outside { set: Set::Tiled, index: 0 })
    );
    let full = [RectPt::new(0.0, 0.0, 100.0, 60.0)];
    let float_out = [RectPt::new(80.0, 10.0, 30.0, 20.0)];
    assert_eq!(
        checker.check(&frame(100.0, 60.0, 1.0, &full, &float_out)),
        Err(Fault::Outside { set: Set::Floating, index: 0 })
    );
    // A floating rect is no part of the tiling: over the tiled set and between pixels is fine.
    let float_in = [RectPt::new(10.25, 10.0, 30.0, 20.0)];
    assert_eq!(checker.check(&frame(100.0, 60.0, 1.0, &full, &float_in)), Ok(()));
    assert!(matches!(
        checker.check(&frame(100.0, 60.0, 1.0, &[RectPt::new(0.0, 0.0, f64::NAN, 1.0)], &[])),
        Err(Fault::Malformed { .. })
    ));
}

/// The corner rule against a pixel raster, on random rect sets (many exact covers among them: a
/// random guillotine cut of the viewport, then sometimes one rect nudged).
#[test]
fn the_corner_rule_agrees_with_a_raster_of_every_pixel() {
    let mut seed = 0x9E37_79B9_7F4A_7C15u64;
    let mut next = |n: u64| {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        seed % n
    };
    let mut checker = Checker::new();
    let (mut exact, mut not) = (0, 0);
    for _ in 0..4000 {
        let (w, h) = (1 + next(24) as i64, 1 + next(16) as i64);
        let mut rects = vec![(0i64, 0i64, w, h)];
        for _ in 0..next(8) {
            let i = next(rects.len() as u64) as usize;
            let (x0, y0, x1, y1) = rects[i];
            if next(2) == 0 && x1 - x0 > 1 {
                let cut = x0 + 1 + next((x1 - x0 - 1) as u64) as i64;
                rects[i] = (x0, y0, cut, y1);
                rects.push((cut, y0, x1, y1));
            } else if y1 - y0 > 1 {
                let cut = y0 + 1 + next((y1 - y0 - 1) as u64) as i64;
                rects[i] = (x0, y0, x1, cut);
                rects.push((x0, cut, x1, y1));
            }
        }
        match next(4) {
            0 => {
                let i = next(rects.len() as u64) as usize;
                let d = next(3) as i64 - 1;
                rects[i].0 += d;
                rects[i].2 += d;
            }
            1 => rects.push((
                next(w as u64) as i64,
                next(h as u64) as i64,
                next(w as u64 + 1) as i64,
                next(h as u64 + 1) as i64,
            )),
            2 => {
                let i = next(rects.len() as u64) as usize;
                rects.remove(i);
            }
            _ => {}
        }
        let tiled: Vec<RectPt> = rects
            .iter()
            .map(|&(x0, y0, x1, y1)| {
                RectPt::new(x0 as f64, y0 as f64, (x1 - x0).max(0) as f64, (y1 - y0).max(0) as f64)
            })
            .collect();
        let mut raster_exact = true;
        for y in 0..h {
            for x in 0..w {
                let n = tiled
                    .iter()
                    .filter(|r| {
                        r.w > 0.0
                            && r.h > 0.0
                            && (r.x as i64) <= x
                            && x < (r.x + r.w) as i64
                            && (r.y as i64) <= y
                            && y < (r.y + r.h) as i64
                    })
                    .count();
                raster_exact &= n == 1;
            }
        }
        raster_exact &= tiled.iter().all(|r| {
            r.w == 0.0
                || r.h == 0.0
                || (r.x >= 0.0 && r.y >= 0.0 && r.x + r.w <= w as f64 && r.y + r.h <= h as f64)
        });
        let got = checker.check(&frame(w as f64, h as f64, 1.0, &tiled, &[]));
        assert_eq!(got.is_ok(), raster_exact, "{w}x{h} {rects:?}: {got:?}");
        if raster_exact { exact += 1 } else { not += 1 }
    }
    assert!(exact > 1000 && not > 1000, "{exact} exact, {not} not");
}

#[test]
fn pixel_edges_round_each_edge_and_ties_go_up() {
    let r = RectPt::new(10.25, 0.75, 5.5, 2.0).pixel_edges(2.0);
    assert_eq!(r, RectPt::new(10.5, 1.0, 5.5, 2.0));
    assert_eq!(RectPt::new(-0.25, 0.0, 1.0, 1.0).pixel_edges(2.0), RectPt::new(0.0, 0.0, 1.0, 1.0));
}

#[test]
fn a_fault_at_a_commit_is_counted_and_fails_a_debug_build() {
    let mut checker = Checker::new();
    let full = [RectPt::new(0.0, 0.0, 10.0, 10.0)];
    let before = stats();
    assert_eq!(commit(&mut checker, &frame(10.0, 10.0, 1.0, &full, &[])), Ok(()));
    let gap = std::panic::catch_unwind(|| {
        let mut checker = Checker::new();
        commit(&mut checker, &frame(10.0, 11.0, 1.0, &[RectPt::new(0.0, 0.0, 10.0, 10.0)], &[]))
    });
    // A debug build fails loudly at the fault; a release build counts it and goes on.
    let debug = cfg!(debug_assertions);
    match gap {
        Ok(result) => {
            assert!(!debug, "a fault fails a debug build");
            assert_eq!(result, Err(Fault::Gap { pixels: 10 }));
        }
        Err(_) => assert!(debug, "a release build never panics at a fault"),
    }
    let after = stats();
    // Other tests commit at the same time: the counts only grow.
    assert!(
        after.commits >= before.commits + 2
            && after.faults > before.faults
            && after.gap > before.gap
    );
}
