use super::*;

#[test]
fn a_position_round_trips_through_its_datagram() {
    let pos = CursorPos { shape: 0xdead_beef, x: -3, y: 1080, visible: true };
    let datagram = pos.datagram(41);
    assert_eq!(datagram.len(), crate::HEADER_LEN + CURSOR_POS_LEN);
    assert_eq!(datagram[1], DatagramKind::CursorPos as u8);
    assert_eq!(CursorPos::from_datagram(&datagram), Ok((41, pos)));
    let hidden = CursorPos { visible: false, ..pos };
    assert_eq!(CursorPos::decode(&hidden.encode()), Ok(hidden));
}

#[test]
fn a_bad_position_is_refused() {
    let mut bytes = CursorPos { shape: 1, x: 0, y: 0, visible: true }.encode().to_vec();
    bytes[12] = 0b10;
    assert!(CursorPos::decode(&bytes).is_err(), "unknown flag");
    assert!(CursorPos::decode(&bytes[..12]).is_err(), "truncated");
    bytes[12] = 1;
    bytes.push(0);
    assert!(CursorPos::decode(&bytes).is_err(), "trailing byte");
}

#[test]
fn newer_wraps_and_ignores_repeats() {
    assert!(cursor_seq_newer(2, 1));
    assert!(!cursor_seq_newer(1, 2));
    assert!(!cursor_seq_newer(5, 5));
    assert!(cursor_seq_newer(0, u32::MAX));
    assert!(!cursor_seq_newer(u32::MAX, 0));
}

#[test]
fn shape_ids_follow_pixels_and_hotspot_and_are_never_zero() {
    let pixels = [0u8, 0, 0, 255, 255, 255, 255, 255];
    let a = shape_id(2, 1, 0, 0, &pixels);
    assert_eq!(a, shape_id(2, 1, 0, 0, &pixels));
    assert_ne!(a, shape_id(2, 1, 1, 0, &pixels));
    assert_ne!(a, shape_id(1, 2, 0, 0, &pixels));
    assert_ne!(a, shape_id(2, 1, 0, 0, &[0u8, 0, 0, 255, 255, 255, 255, 254]));
    assert_ne!(a, 0);
}

#[test]
fn base64_matches_the_standard_alphabet() {
    for (plain, coded) in [
        (&b""[..], ""),
        (b"f", "Zg=="),
        (b"fo", "Zm8="),
        (b"foo", "Zm9v"),
        (b"foob", "Zm9vYg=="),
        (b"\xff\xfe\x00", "//4A"),
    ] {
        assert_eq!(base64_encode(plain), coded);
        assert_eq!(base64_decode(coded).as_deref(), Some(plain));
    }
    assert_eq!(base64_decode("Zg="), None);
    assert_eq!(base64_decode("Zg==Zg=="), None);
    assert_eq!(base64_decode("Z!=="), None);
}
