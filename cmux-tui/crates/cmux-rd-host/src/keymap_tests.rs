use super::*;

#[test]
fn x_to_hid_inverts_hid_to_x() {
    for id in 0x04..=0xe7u32 {
        let usage = 0x0007_0000 | id;
        if let Some(code) = hid_to_x(usage) {
            assert_eq!(x_to_hid(code), Some(usage), "usage {usage:#x}, X keycode {code}");
        }
    }
    // Xvfb's `a` is keycode 38 (evdev KEY_A 30 + 8).
    assert_eq!(x_to_hid(38), Some(0x0007_0004));
    assert_eq!(x_to_hid(0), None);
}
