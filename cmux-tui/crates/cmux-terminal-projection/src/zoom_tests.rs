use super::*;

/// A 120x40 Mac pane at 12 pt (7.2 x 15.6 pt cells) on a 378 x 600 pt page.
fn mac() -> ZoomGeometry {
    ZoomGeometry {
        grid_width: 120.0 * 7.2,
        grid_height: 40.0 * 15.6,
        page_width: 378.0,
        page_height: 600.0,
    }
}

fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-9
}

#[test]
fn fit_width_shows_the_whole_width_and_never_enlarges_a_narrow_grid() {
    let g = mac();
    assert!(close(g.fit_width_scale(), 378.0 / 864.0));
    let fitted = g.initial();
    assert!(close(fitted.scale * g.grid_width, g.page_width));
    assert_eq!((fitted.pan_x, fitted.pan_y), (0.0, 0.0));
    let narrow = ZoomGeometry { grid_width: 40.0 * 7.2, ..g };
    assert!(close(narrow.fit_width_scale(), 1.0));
    assert_eq!(narrow.stop(narrow.initial().scale), ZoomStop::FitWidth);
}

#[test]
fn a_pinch_snaps_to_the_stops_and_stays_in_bounds() {
    let g = mac();
    let fit = g.fit_width_scale();
    assert!(close(g.snap(fit * 1.1), fit));
    assert!(close(g.snap(0.9), 1.0));
    assert!(close(g.snap(1.12), 1.0));
    assert!(close(g.snap(0.7), 0.7), "between the stops it stays");
    assert!(close(g.snap(0.01), fit), "never smaller than fit width");
    assert!(close(g.snap(9.0), MAX_SCALE));
    assert!(close(g.snap(f64::NAN), fit));
}

#[test]
fn a_double_tap_toggles_about_the_tapped_point() {
    let g = mac();
    let fitted = g.initial();
    // Tap column 60, row 1 at fit width (row 1 so the vertical pan is inside the 24 pt the
    // readable grid overhangs the page).
    let s = fitted.scale;
    let (fx, fy) = (60.0 * 7.2 * s, 1.0 * 15.6 * s);
    let readable = g.toggle(fitted, fx, fy);
    assert!(close(readable.scale, 1.0));
    // The tapped cell is still under the finger.
    assert!(close(readable.pan_x + fx, 60.0 * 7.2));
    assert!(close(readable.pan_y + fy, 1.0 * 15.6));
    let back = g.toggle(readable, fx, fy);
    assert!(close(back.scale, g.fit_width_scale()));
    assert_eq!((back.pan_x, back.pan_y), (0.0, 0.0), "fit width shows the whole grid from the top");
    // Zoomed past readable: a double tap goes to fit width.
    let past = g.zoom_about(readable, 1.8, 10.0, 10.0);
    assert!(close(g.toggle(past, 0.0, 0.0).scale, g.fit_width_scale()));
}

#[test]
fn the_pan_keeps_the_grid_on_the_page() {
    let g = mac();
    let wild = g.clamp(ZoomState { scale: 1.0, pan_x: 5000.0, pan_y: -40.0 });
    assert!(close(wild.pan_x, 864.0 - 378.0));
    assert!(close(wild.pan_y, 0.0));
    let low = g.clamp(ZoomState { scale: 1.0, pan_x: 10.0, pan_y: 9999.0 });
    assert!(close(low.pan_y, 624.0 - 600.0));
    // Smaller than the page vertically: pinned to the top.
    let small = g.clamp(ZoomState { scale: g.fit_width_scale(), pan_x: 30.0, pan_y: 30.0 });
    assert_eq!((small.pan_x, small.pan_y), (0.0, 0.0));
    let nan = g.clamp(ZoomState { scale: 1.0, pan_x: f64::NAN, pan_y: f64::INFINITY });
    assert_eq!((nan.pan_x, nan.pan_y), (0.0, 0.0));
}

#[test]
fn typing_reveals_the_cursor_moving_as_little_as_it_can() {
    let g = mac();
    let start = ZoomState { scale: 1.0, pan_x: 0.0, pan_y: 0.0 };
    // Cursor at column 100: pans right just enough, with a margin.
    let next = g.reveal(start, 100.0 * 7.2, 0.0, 7.2, 15.6, 28.8);
    assert!(close(next.pan_x, 101.0 * 7.2 + 28.8 - 378.0));
    // Already visible: no move.
    assert_eq!(g.reveal(next, 90.0 * 7.2, 0.0, 7.2, 15.6, 28.8), next);
    // Row 39 below the page: pans down to it.
    let low = g.reveal(start, 0.0, 39.0 * 15.6, 7.2, 15.6, 0.0);
    assert!(close(low.pan_y, 624.0 - 600.0));
}
