/// The bench asks for Constrained Baseline exactly when it decodes with OpenH264.
#[test]
fn offers_the_cap_when_openh264_decodes() {
    assert_eq!(super::bench_decodes_with_openh264(None), !cfg!(target_os = "macos"));
    assert!(super::bench_decodes_with_openh264(Some("openh264")));
    assert!(!super::bench_decodes_with_openh264(Some("videotoolbox")));
    assert!(!super::bench_decodes_with_openh264(Some("vp9")));
}
