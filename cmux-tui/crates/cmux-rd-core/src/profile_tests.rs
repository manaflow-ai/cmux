use super::*;

#[test]
fn standard_is_the_default_and_names_parse() {
    assert_eq!(EncodeProfile::default(), EncodeProfile::Standard);
    assert_eq!(EncodeProfile::parse("ultra"), Some(EncodeProfile::Ultra));
    assert_eq!(EncodeProfile::parse(" Ultra "), Some(EncodeProfile::Ultra));
    assert_eq!(EncodeProfile::parse("balanced"), Some(EncodeProfile::Standard));
    assert_eq!(EncodeProfile::parse("standard"), Some(EncodeProfile::Standard));
    assert_eq!(EncodeProfile::parse("fast"), None);
    for p in [EncodeProfile::Standard, EncodeProfile::Ultra] {
        assert_eq!(EncodeProfile::parse(p.as_str()), Some(p));
    }
}

#[test]
fn ultra_streams_at_the_session_rate_up_to_120() {
    assert_eq!(EncodeProfile::Standard.stream_fps(240), 240);
    assert_eq!(EncodeProfile::Ultra.stream_fps(120), 120);
    assert_eq!(EncodeProfile::Ultra.stream_fps(240), 120, "capped at 120");
    assert_eq!(EncodeProfile::Ultra.stream_fps(60), 60);
    assert_eq!(EncodeProfile::Standard.stream_fps(0), 1);
}

#[test]
fn ultra_raises_the_default_ceiling_and_an_explicit_one_wins() {
    assert_eq!(max_kbps(EncodeProfile::Standard, None, 50_000), 50_000);
    assert_eq!(max_kbps(EncodeProfile::Ultra, None, 50_000), ULTRA_MAX_KBPS);
    assert_eq!(max_kbps(EncodeProfile::Ultra, Some(20_000), 50_000), 20_000);
    assert_eq!(max_kbps(EncodeProfile::Standard, Some(80_000), 50_000), 80_000);
}

#[test]
fn a_refinement_waits_one_frame_interval() {
    assert_eq!(refine_after_us(120), 8_333);
    assert_eq!(refine_after_us(60), 16_666);
    assert_eq!(refine_after_us(0), 1_000_000);
}
