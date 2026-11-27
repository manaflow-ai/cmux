use super::*;

#[test]
fn a_frame_parses_back_to_its_header_and_bytes() {
    let f = frame(7, "chat", "up", 9, b"hello");
    let (id, params, start) = parse(&f).unwrap();
    assert_eq!(id, json!(7));
    assert_eq!(params["offset"], 9);
    assert_eq!(&f[start..], b"hello");
    for bad in [&b"AMU"[..], b"XXXX\0\0\0\x01{", b"AMUP\0\0\0\x09{}", b"AMUP\0\x01\0\0{}"] {
        assert!(parse(bad).is_err(), "{bad:?}");
    }
    // A long id is not echoed: every answer stays small whatever a client sends.
    let long = "x".repeat(MAX_ID + 1);
    let header = json!({"id": long, "method": method::MUX_FILE_PUT_DATA}).to_string();
    let mut long_id = b"AMUP".to_vec();
    long_id.extend_from_slice(&u32::try_from(header.len()).unwrap().to_be_bytes());
    long_id.extend_from_slice(header.as_bytes());
    assert_eq!(parse(&long_id).unwrap().0, Value::Null);
    let mut other = f.clone();
    let at = other.windows(9).position(|w| w == b"file_put_").unwrap();
    other[at] = b'F';
    let (id, e) = parse(&other).unwrap_err();
    assert_eq!((id, e.code), (json!(7), RpcError::method_not_found("x").code));
}
