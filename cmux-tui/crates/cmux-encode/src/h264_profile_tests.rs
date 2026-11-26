use super::*;

/// An SPS NAL (start code, header 0x67, profile, constraint flags, level 3.1, one byte of
/// the rest), as an encoder writes it.
fn sps(profile: u8, flags: u8) -> Vec<u8> {
    vec![0, 0, 0, 1, 0x67, profile, flags, 0x1f, 0xac]
}

fn with_idr(mut au: Vec<u8>) -> Vec<u8> {
    au.extend([0, 0, 0, 1, 0x68, 0xee, 0x3c, 0x80, 0, 0, 0, 1, 0x65, 0x88, 0x84]);
    au
}

const P_FRAME: [u8; 7] = [0, 0, 0, 1, 0x41, 0x9a, 0x02];

#[test]
fn constrained_baseline_and_main_decode() {
    // VideoToolbox ConstrainedBaseline (66, set0+set1) and OpenH264's own SPS.
    assert_eq!(sps_verdict(&with_idr(sps(66, 0xc0))), Some(Ok(())));
    assert_eq!(sps_verdict(&with_idr(sps(66, 0x00))), Some(Ok(())));
    assert_eq!(sps_verdict(&with_idr(sps(77, 0x40))), Some(Ok(())));
    assert_eq!(sps_verdict(&P_FRAME), None);
}

#[test]
fn high_profile_is_refused_unless_main_compatible() {
    // VideoToolbox's default High (100, no constraint flags): the stream of cmux#50591.
    assert_eq!(sps_verdict(&with_idr(sps(100, 0x00))), Some(Err(100)));
    assert_eq!(sps_verdict(&with_idr(sps(100, 0x40))), Some(Ok(())));
}

/// The bug: every P-frame after a High SPS decoded to a wrong picture with no error.
/// The gate refuses the IDR and every frame after it, until a decodable SPS arrives.
#[test]
fn gate_refuses_every_frame_under_a_high_sps() {
    let mut gate = ProfileGate::default();
    let err = gate.check(&with_idr(sps(100, 0x00))).expect_err("high IDR refused");
    assert!(err.contains("high profile") && err.contains("h264.baseline"), "{err}");
    for _ in 0..3 {
        assert!(gate.check(&P_FRAME).is_err(), "P-frames under a high SPS are refused");
    }
    assert_eq!(gate.refused(), Some(100));
    // The host restarts on constrained baseline (the viewer's cap): frames decode again.
    assert!(gate.check(&with_idr(sps(66, 0xc0))).is_ok());
    assert!(gate.check(&P_FRAME).is_ok());
    assert_eq!(gate.refused(), None);
}

#[test]
fn a_stream_with_no_sps_yet_is_let_through() {
    assert!(ProfileGate::default().check(&P_FRAME).is_ok());
}
