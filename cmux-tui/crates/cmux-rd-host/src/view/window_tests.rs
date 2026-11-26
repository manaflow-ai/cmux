use super::*;

#[test]
fn x_keycodes_map_back_to_hid_usages() {
    let keys = KeyTable::new();
    // X keycode 38 is evdev 30, KEY_A, HID usage 0x04.
    assert_eq!(keys.usage(38), Some(0x0007_0004));
    // Every usage the host injects maps back to itself.
    for id in 0..=0xffu32 {
        let usage = 0x0007_0000 | id;
        if let Some(code) = crate::keymap::hid_to_x(usage) {
            assert_eq!(keys.usage(code), Some(usage), "usage {usage:#x}");
        }
    }
    assert_eq!(keys.usage(0), None);
}

#[test]
fn wheel_buttons_scroll_and_others_click() {
    let mut t = InputTracker::default();
    let mut out = Vec::new();
    t.button(4, true, &mut out);
    t.button(4, false, &mut out);
    t.button(7, true, &mut out);
    t.button(3, true, &mut out);
    t.button(3, false, &mut out);
    assert_eq!(
        out,
        [
            InputEvent::Scroll { dx: 0, dy: -100, precise: false },
            InputEvent::Scroll { dx: 100, dy: 0, precise: false },
            InputEvent::Button { button: 3, down: true },
            InputEvent::Button { button: 3, down: false },
        ]
    );
}

#[test]
fn motion_coalesces_to_the_newest_position() {
    let mut t = InputTracker::default();
    let mut out = Vec::new();
    t.pointer(1, 1, &mut out);
    t.pointer(2, 2, &mut out);
    t.pointer(2, 2, &mut out);
    assert_eq!(out, [InputEvent::Pointer { x: 2, y: 2 }]);
    t.button(1, true, &mut out);
    t.pointer(3, 3, &mut out);
    assert_eq!(out.len(), 3, "motion after a press is its own event");
}

#[test]
fn losing_focus_releases_what_is_held_once() {
    let mut t = InputTracker::default();
    let mut out = Vec::new();
    t.key(0x0007_00e0, true, &mut out);
    t.button(1, true, &mut out);
    out.clear();
    t.release_all(&mut out);
    assert_eq!(
        out,
        [
            InputEvent::Key { usage: 0x0007_00e0, down: false },
            InputEvent::Button { button: 1, down: false },
        ]
    );
    out.clear();
    t.key(0x0007_00e0, false, &mut out);
    t.button(1, false, &mut out);
    assert!(out.is_empty(), "a release with nothing held sends nothing");
}

#[test]
fn white_and_black_convert_from_video_range() {
    let mut picture = cmux_encode::I420::new(2, 2);
    picture.y.copy_from_slice(&[235, 16, 235, 16]);
    let mut out = vec![0u8; 16];
    i420_to_bgrx(&picture, Yuv::SCREEN, 2, &mut out);
    assert_eq!(&out[..4], &[255, 255, 255, 0]);
    assert_eq!(&out[4..8], &[0, 0, 0, 0]);
}

/// The Mac host's red (ScreenCaptureKit converts with BT.709 and the stream says so) is
/// red here, not the orange-shifted red a BT.601 conversion of the same bytes shows.
#[test]
fn a_bt709_tagged_red_shows_red() {
    let mut picture = cmux_encode::I420::new(2, 2);
    // sRGB (255, 0, 0) in BT.709 video range.
    picture.y.fill(63);
    picture.u.fill(102);
    picture.v.fill(240);
    let mut out = vec![0u8; 16];
    i420_to_bgrx(&picture, Yuv::SCREEN, 2, &mut out);
    let [b, g, r, _] = [out[0], out[1], out[2], out[3]];
    assert!(r >= 253 && g <= 2 && b <= 2, "BT.709: {:?}", (r, g, b));
    let bt601 = Yuv { matrix: cmux_encode::color::Matrix::Bt601, full_range: false };
    i420_to_bgrx(&picture, bt601, 2, &mut out);
    assert!(out[2] < 240, "the untagged reading shifts it (BGR): {:?}", &out[..3]);
}
