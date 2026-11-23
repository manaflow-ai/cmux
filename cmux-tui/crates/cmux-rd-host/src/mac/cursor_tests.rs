use super::*;

#[test]
fn points_map_to_the_injectors_pixels() {
    let bounds = Bounds { x: 100.0, y: 0.0, width: 1512.0, height: 982.0 };
    let reader = CursorReader::new(bounds, (3024, 1964));
    assert_eq!(reader.scale, (2.0, 2.0));
    assert_eq!(to_pixels(CGPoint::new(100.0, 0.0), bounds, reader.scale), (0, 0));
    assert_eq!(to_pixels(CGPoint::new(110.25, 5.5), bounds, reader.scale), (20, 11));
    // On another display: outside the frame, never clamped into it.
    assert_eq!(to_pixels(CGPoint::new(50.0, -10.0), bounds, reader.scale), (-100, -20));
}

#[test]
fn shapes_scale_to_the_stream_and_stay_bounded() {
    let arrow = CGSize { width: 17.0, height: 23.0 };
    assert_eq!(fit_shape(arrow, 2.0), (34, 46, 2.0));
    // A downscaled stream (max width): the cursor shrinks with the picture.
    let (w, h, _) = fit_shape(arrow, 0.5);
    assert_eq!((w, h), (9, 12));
    // An accessibility-size cursor at 2x is capped, aspect kept.
    let (w, h, k) = fit_shape(CGSize { width: 256.0, height: 128.0 }, 2.0);
    assert_eq!((w, h), (MAX_CURSOR_SIDE, MAX_CURSOR_SIDE / 2));
    assert!((k - 1.0).abs() < 1e-9);
}
