use super::*;

const WIDE: Size = Size { width: 2000.0, height: 1000.0 };
const SQUARE: Size = Size { width: 400.0, height: 400.0 };

fn place(text: &str) -> Placement {
    Placement::parse(text).unwrap_or_else(|| panic!("{text} parses"))
}

fn close(a: Rect, b: Rect) {
    let eq = |x: f64, y: f64| (x - y).abs() < 1e-6;
    assert!(
        eq(a.x, b.x) && eq(a.y, b.y) && eq(a.width, b.width) && eq(a.height, b.height),
        "{a:?} != {b:?}"
    );
}

#[test]
fn unset_is_the_centered_fill_of_today() {
    let rect = placement_rect(WIDE, SQUARE, &Placement::default()).unwrap();
    // resizeAspectFill: scale 0.4, 800x400 centered on the 400x400 view.
    close(rect, Rect { x: -200.0, y: 0.0, width: 800.0, height: 400.0 });
    // A tall view crops the sides of a wide picture, centered.
    close(
        placement_rect(WIDE, Size { width: 300.0, height: 600.0 }, &Placement::default()).unwrap(),
        Rect { x: -450.0, y: 0.0, width: 1200.0, height: 600.0 },
    );
}

#[test]
fn fit_shows_the_whole_picture() {
    let rect = placement_rect(WIDE, SQUARE, &place("fit")).unwrap();
    close(rect, Rect { x: 0.0, y: 100.0, width: 400.0, height: 200.0 });
    // Anchored to the top.
    close(
        placement_rect(WIDE, SQUARE, &place("fit 0.5 0")).unwrap(),
        Rect { x: 0.0, y: 0.0, width: 400.0, height: 200.0 },
    );
}

#[test]
fn center_and_stretch() {
    let small = Size { width: 100.0, height: 50.0 };
    close(
        placement_rect(small, SQUARE, &place("center")).unwrap(),
        Rect { x: 150.0, y: 175.0, width: 100.0, height: 50.0 },
    );
    close(
        placement_rect(WIDE, SQUARE, &place("stretch")).unwrap(),
        Rect { x: 0.0, y: 0.0, width: 400.0, height: 400.0 },
    );
}

#[test]
fn a_filled_picture_never_shows_an_empty_edge() {
    for x in [0.0, 0.1, 0.5, 0.9, 1.0] {
        for y in [0.0, 0.5, 1.0] {
            for zoom in [1.0, 1.7, 4.0] {
                let p = Placement::clamped(PlacementMode::Fill, x, y, zoom);
                let r = placement_rect(WIDE, SQUARE, &p).unwrap();
                assert!(r.x <= 1e-9 && r.y <= 1e-9, "{p:?} {r:?}");
                assert!(
                    r.x + r.width >= SQUARE.width - 1e-9 && r.y + r.height >= SQUARE.height - 1e-9,
                    "{p:?} {r:?}"
                );
            }
        }
    }
    // Anchors past the range clamp, so the picture still covers.
    let p = Placement::clamped(PlacementMode::Fill, -3.0, 9.0, 1.0);
    assert_eq!((p.x, p.y), (0.0, 1.0));
}

#[test]
fn the_anchor_picks_the_part_that_shows() {
    close(
        placement_rect(WIDE, SQUARE, &place("fill 0 0.5")).unwrap(),
        Rect { x: 0.0, y: 0.0, width: 800.0, height: 400.0 },
    );
    close(
        placement_rect(WIDE, SQUARE, &place("fill 1 0.5")).unwrap(),
        Rect { x: -400.0, y: 0.0, width: 800.0, height: 400.0 },
    );
}

#[test]
fn zoom_scales_around_the_anchor() {
    // 2x: 1600x800, centered.
    close(
        placement_rect(WIDE, SQUARE, &place("fill 0.5 0.5 2")).unwrap(),
        Rect { x: -600.0, y: -200.0, width: 1600.0, height: 800.0 },
    );
    // The zoom is clamped to 1...4.
    let p = Placement::clamped(PlacementMode::Fill, 0.5, 0.5, 10.0);
    assert_eq!(p.zoom, 4.0);
    // A zoomed fit can run past the view.
    let r = placement_rect(WIDE, SQUARE, &place("fit 0.5 0.5 3")).unwrap();
    close(r, Rect { x: -400.0, y: -100.0, width: 1200.0, height: 600.0 });
}

#[test]
fn visible_is_the_cropped_part() {
    let v = visible(WIDE, SQUARE, &Placement::default()).unwrap();
    close(v.frame, Rect { x: 0.0, y: 0.0, width: 400.0, height: 400.0 });
    close(v.contents, Rect { x: 0.25, y: 0.0, width: 0.5, height: 1.0 });
    let fit = visible(WIDE, SQUARE, &place("fit")).unwrap();
    close(fit.frame, Rect { x: 0.0, y: 100.0, width: 400.0, height: 200.0 });
    close(fit.contents, Rect { x: 0.0, y: 0.0, width: 1.0, height: 1.0 });
}

#[test]
fn dragging_moves_the_picture_with_the_pointer_until_an_edge() {
    // Fill: 800 wide in 400, room -400. Dragging right 100 shows more of the left.
    let p = dragged(WIDE, SQUARE, &Placement::default(), 100.0, 50.0);
    assert!((p.x - 0.25).abs() < 1e-9, "{p:?}");
    // No vertical room: y stays.
    assert_eq!(p.y, 0.5);
    let r = placement_rect(WIDE, SQUARE, &p).unwrap();
    assert!((r.x - -100.0).abs() < 1e-9, "the picture moved 100 points right: {r:?}");
    // Far past the edge, it stops there.
    let p = dragged(WIDE, SQUARE, &Placement::default(), 10_000.0, 0.0);
    assert_eq!(p.x, 0.0);
}

#[test]
fn no_area_has_no_rect() {
    assert!(
        placement_rect(Size { width: 0.0, height: 1.0 }, SQUARE, &Placement::default()).is_none()
    );
    assert!(
        placement_rect(WIDE, Size { width: 10.0, height: 0.0 }, &Placement::default()).is_none()
    );
    assert!(
        placement_rect(WIDE, Size { width: f64::NAN, height: 1.0 }, &Placement::default())
            .is_none()
    );
}

#[test]
fn text_round_trips() {
    for text in [
        "fill",
        "fit",
        "center",
        "stretch",
        "fill 0.3 0.7",
        "fill 0.3 0.7 2",
        "fit 0 1",
        "fill 0.5 0.5 1.25",
    ] {
        assert_eq!(place(text).to_text(), text);
    }
    assert_eq!(place("fill 0.5 0.5 1").to_text(), "fill");
    assert_eq!(
        Placement::clamped(PlacementMode::Fill, 1.0 / 3.0, 0.5, 1.0).to_text(),
        "fill 0.333 0.5"
    );
    assert_eq!(place("  fit   0.25  0.75 ").to_text(), "fit 0.25 0.75");
}

#[test]
fn bad_text_is_refused() {
    for text in [
        "",
        "cover",
        "Fill",
        "fill 0.5",
        "fill 2 0.5",
        "fill 0.5 -0.1",
        "fill 0.5 0.5 0.5",
        "fill 0.5 0.5 5",
        "fill 0.5 0.5 1 1",
        "fill a b",
        "fill NaN 0.5",
        "fill inf 0.5",
    ] {
        assert!(Placement::parse(text).is_none(), "{text:?} is refused");
    }
}

#[test]
fn the_map_holds_one_placement_per_picture() {
    use serde_json::json;
    assert!(is_placement_map(&json!({})));
    assert!(is_placement_map(
        &json!({ "munch-scream": "fit", "file:/Users/me/a.png": "fill 0.2 0.8 1.5" })
    ));
    for bad in [
        json!("fit"),
        json!([]),
        json!({ "a": "cover" }),
        json!({ "a": 1 }),
        json!({ "": "fit" }),
        json!({ " ": "fit" }),
    ] {
        assert!(!is_placement_map(&bad), "{bad} is refused");
    }
}
