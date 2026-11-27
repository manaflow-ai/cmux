#[test]
fn eight_cores_encode_on_four_threads_and_fewer_on_two() {
    let threads: Vec<u16> = [1, 2, 4, 6, 8, 16].map(super::threads_for_cores).to_vec();
    assert_eq!(threads, [2, 2, 2, 2, 4, 4]);
}

/// The Linux host codes OpenH264 in camera usage unless the viewer asked for sharp text
/// (Settings > Customize), which gets cmux-encode's default switching screen usage; other
/// hosts code the default either way.
#[cfg(any(feature = "openh264", feature = "bench"))]
#[test]
fn a_sharp_text_viewer_gets_the_switching_screen_usage_on_linux() {
    use cmux_encode::openh264::{OpenH264Options, Usage};
    assert_eq!(super::shipped_openh264_base(true, false), OpenH264Options::linux_host());
    assert_eq!(super::shipped_openh264_base(true, false).usage, Usage::Camera);
    assert_eq!(super::shipped_openh264_base(true, true), OpenH264Options::default());
    assert_eq!(super::shipped_openh264_base(true, true).usage, Usage::Switch);
    assert_eq!(super::shipped_openh264_base(false, false), OpenH264Options::default());
    assert_eq!(super::shipped_openh264_base(false, true), OpenH264Options::default());
}
