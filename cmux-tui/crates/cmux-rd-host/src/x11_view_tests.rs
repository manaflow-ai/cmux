use super::*;

const HD: Rect = Rect { x: 0, y: 0, w: 1920, h: 1080 };

#[test]
fn no_max_width_streams_the_source_as_is() {
    let v = View::new(HD, None);
    assert_eq!(v.out, (1920, 1080));
    assert!(!v.scaled());
    assert_eq!(View::new(HD, Some(2560)).out, (1920, 1080), "never scales up");
}

#[test]
fn max_width_fits_keeping_the_aspect_even() {
    let v = View::new(HD, Some(1280));
    assert_eq!(v.out, (1280, 720));
    assert!(v.scaled());
    let odd = View::new(Rect { x: 0, y: 0, w: 1366, h: 768 }, Some(1001));
    assert_eq!(odd.out.0 % 2, 0);
    assert_eq!(odd.out.1 % 2, 0);
    assert_eq!(odd.out, (1000, 562));
}

#[test]
fn a_monitor_keeps_only_its_own_damage() {
    let right = View::new(Rect { x: 1920, y: 0, w: 1280, h: 1024 }, None);
    assert_eq!(right.clip(Rect { x: 10, y: 10, w: 100, h: 100 }), None, "left monitor");
    assert_eq!(
        right.clip(Rect { x: 1900, y: 5, w: 40, h: 10 }),
        Some(Rect { x: 0, y: 5, w: 20, h: 10 }),
        "straddling: only the right part, at the monitor's origin"
    );
}

#[test]
fn pointer_maps_back_through_the_monitor_and_the_scale() {
    let v = View::new(Rect { x: 1920, y: 0, w: 2560, h: 1440 }, Some(1280));
    assert_eq!(v.out, (1280, 720));
    assert_eq!(v.pointer(0, 0), (1920, 0));
    assert_eq!(v.pointer(640, 360), (1920 + 1280, 720));
    assert_eq!(v.pointer(5000, -3), (1920 + 2558, 0), "clamped into the picture");
}

#[test]
fn rects_round_trip_covering_whole_pixels() {
    let v = View::new(HD, Some(1280));
    let small = Rect { x: 101, y: 51, w: 3, h: 3 };
    let out = v.to_out(small);
    assert!(out.w >= 2 && out.h >= 2 && out.x.is_multiple_of(2) && out.y.is_multiple_of(2));
    let back = v.to_src(out);
    assert!(back.x <= small.x && back.y <= small.y);
    assert!(back.x + back.w >= small.x + small.w && back.y + back.h >= small.y + small.h);
    let full = v.to_src(Rect { x: 0, y: 0, w: 1280, h: 720 });
    assert_eq!(full, Rect { x: 0, y: 0, w: 1920, h: 1080 });
}

#[test]
fn the_whole_screen_comes_first_and_monitors_only_when_two() {
    let left = Rect { x: 0, y: 0, w: 1920, h: 1080 };
    let right = Rect { x: 1920, y: 0, w: 1280, h: 1024 };
    assert_eq!(listing((3200, 1080), &[left]).len(), 1, "one monitor is the screen");
    let listed = listing((3200, 1080), &[left, right]);
    assert_eq!(listed.len(), 3);
    assert_eq!(pick(None, &listed), Ok(listed[0]));
    assert_eq!(pick(Some("main"), &listed), Ok(listed[0]));
    assert_eq!(pick(Some(":99"), &listed), Ok(listed[0]), "an X display name");
    assert_eq!(pick(Some("2"), &listed), Ok(right));
    assert!(pick(Some("3"), &listed).unwrap_err().contains("3 listed"));
}

#[test]
fn a_monitor_that_is_the_whole_screen_or_a_mirror_is_listed_once() {
    let a = Rect { x: 0, y: 0, w: 960, h: 1080 };
    let b = Rect { x: 960, y: 0, w: 960, h: 1080 };
    let whole = Rect { x: 0, y: 0, w: 1920, h: 1080 };
    assert_eq!(distinct_monitors(vec![b, whole, a, b], (1920, 1080)), vec![a, b]);
    assert_eq!(listing((1920, 1080), &distinct_monitors(vec![whole], (1920, 1080))).len(), 1);
}

#[test]
fn scaling_averages_what_each_pixel_covers() {
    // 4x2 -> 2x1: each output pixel averages a 2x2 block.
    let src = [0u8, 10, 100, 200, 20, 30, 100, 0];
    let mut dst = [0u8; 2];
    scale_plane(&src, (4, 2), &mut dst, (2, 1), (0, 0, 2, 1));
    assert_eq!(dst, [15, 100]);
    // Only the asked rect is written.
    let mut dst = [7u8; 2];
    scale_plane(&src, (4, 2), &mut dst, (2, 1), (1, 0, 1, 1));
    assert_eq!(dst, [7, 100]);
}
