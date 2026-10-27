use super::*;

/// `u8::from_str_radix` takes a leading `+`, so "+f" read as 0x0f and an
/// identity that is not hex decoded as one (cmux-tui/fuzz `host_identity_hex`).
#[test]
fn hex_identity_refuses_a_sign() {
    let mut text = "00".repeat(16);
    text.replace_range(0..2, "+f");
    assert!(decode_hex_array::<16>(&text).is_err());
    assert!(decode_lower_hex_array::<16>(&text, "identity").is_err());
}

#[test]
fn hex_identity_round_trips_and_only_the_record_decoder_refuses_upper_case() {
    let bytes: [u8; 16] = std::array::from_fn(|index| (index as u8).wrapping_mul(37));
    let text = encode_hex(&bytes);
    assert_eq!(decode_hex_array::<16>(&text).ok(), Some(bytes));
    assert_eq!(decode_lower_hex_array::<16>(&text, "identity").ok(), Some(bytes));
    assert_eq!(decode_hex_array::<16>(&text.to_ascii_uppercase()).ok(), Some(bytes));
    assert!(decode_lower_hex_array::<16>(&text.to_ascii_uppercase(), "identity").is_err());
}
