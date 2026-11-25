use super::*;

fn frame(w: u32, h: u32, scale: f64) -> RawFrame {
    RawFrame {
        width: w,
        height: h,
        rgba: vec![255; (w * h * 4) as usize],
        scale,
        origin: Point { x: 100.0, y: 50.0 },
    }
}

#[test]
fn downscales_and_maps_back_to_points() {
    let f = frame(2912, 1820, 2.0); // a 1456x910 pt display at 2x
    let e = process(f, &[], DEFAULT_MAX_EDGE, None, false).unwrap();
    assert_eq!((e.geometry.width, e.geometry.height), (1456, 910));
    assert!((e.geometry.points_per_pixel - 1.0).abs() < 1e-9);
    assert_eq!(e.geometry.to_global(10.0, 20.0), Point { x: 110.0, y: 70.0 });
    assert!(e.png_base64.is_some());
}

#[test]
fn unchanged_frames_send_no_image() {
    let a = process(frame(40, 30, 1.0), &[], 100, None, false).unwrap();
    let b = process(frame(40, 30, 1.0), &[], 100, Some(a.digest), false).unwrap();
    assert!(b.unchanged && b.png_base64.is_none());
    let c = process(frame(40, 30, 1.0), &[], 100, Some(a.digest), true).unwrap();
    assert!(c.png_base64.is_some());
}

#[test]
fn redaction_paints_the_denied_window_out() {
    let mut f = frame(20, 20, 2.0); // 10x10 pt at (100, 50)
    let n = redact(&mut f, &[Rect { x: 100.0, y: 50.0, width: 5.0, height: 5.0 }]);
    assert_eq!(n, 1);
    assert_eq!(f.rgba[0], 24); // top-left pixel redacted
    let last = f.rgba.len() - 4;
    assert_eq!(f.rgba[last], 255); // bottom-right untouched
    // Outside the frame: nothing.
    assert_eq!(redact(&mut f, &[Rect { x: 0.0, y: 0.0, width: 10.0, height: 10.0 }]), 0);
}

#[test]
fn rejects_short_buffers() {
    let mut f = frame(4, 4, 1.0);
    f.rgba.truncate(10);
    assert!(process(f, &[], 100, None, false).is_err());
}
