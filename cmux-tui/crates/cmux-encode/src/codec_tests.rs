use super::*;

#[test]
fn h264_idr_and_p() {
    let idr = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 0x88];
    let p = [0, 0, 0, 1, 0x41, 0x9a, 0x22];
    assert!(Codec::H264.is_keyframe(&idr));
    assert!(!Codec::H264.is_keyframe(&p));
    let nals: Vec<&[u8]> = annexb_nals(&idr).collect();
    assert_eq!(nals, vec![&[0x67, 1, 2][..], &[0x68, 3][..], &[0x65, 0x88][..]]);
}

#[test]
fn vp9_frame_type() {
    // frame_marker 10, profile 0, show_existing 0, frame_type 0 (key), show_frame 1.
    assert!(Codec::Vp9.is_keyframe(&[0b1000_0010]));
    // frame_type 1 (inter).
    assert!(!Codec::Vp9.is_keyframe(&[0b1000_0110]));
    // Not a VP9 frame marker.
    assert!(!Codec::Vp9.is_keyframe(&[0b0100_0010]));
}

#[test]
fn av1_key_and_inter() {
    // Temporal delimiter, sequence header (2 bytes), frame OBU whose header byte has
    // show_existing_frame 0 and frame_type 0.
    let key = [0x12, 0x00, 0x0a, 0x02, 0xaa, 0xbb, 0x32, 0x02, 0x10, 0x00];
    // Temporal delimiter, frame OBU with frame_type 1 (inter).
    let inter = [0x12, 0x00, 0x32, 0x02, 0x30, 0x00];
    assert!(Codec::Av1.is_keyframe(&key));
    assert!(!Codec::Av1.is_keyframe(&inter));
    assert_eq!(av1_obus(&key).map(|(t, _)| t).collect::<Vec<_>>(), vec![2, 1, 6]);
}

#[test]
fn names_round_trip() {
    for c in Codec::ALL {
        assert_eq!(Codec::parse(c.wire_name()), Some(c));
    }
}
