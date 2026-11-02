use super::*;

fn bootstrap() -> NativeBootstrap {
    let (binding, keys, _) = super::super::receiver_read_tests::public_fixture();
    NativeBootstrap::new(binding, keys, Zeroizing::new([9; 32]), "a".repeat(64)).unwrap()
}

#[test]
fn native_receiver_private_frame_preserves_original_self_key_and_keyset() {
    let source = bootstrap();
    let bytes = source.encode().unwrap();
    let copy = NativeBootstrap::decode(&bytes).unwrap();
    assert_eq!(source.binding(), copy.binding());
    assert_eq!(source.keys(), copy.keys());
    assert_eq!(source.generation(), copy.generation());
    assert_eq!(*copy.into_parts().2, [9; 32]);
    let header = &bytes[4..bytes.len() - 32];
    let public: Value = serde_json::from_slice(header).unwrap();
    assert!(public.get("private_key").is_none());
    assert!(public.get("grant").is_none());
    assert!(!String::from_utf8_lossy(header).contains("private-test-bearer"));
}

#[test]
fn native_receiver_private_frame_refuses_mismatch_truncation_extra_bytes_and_large_prefix() {
    let source = bootstrap();
    let bytes = source.encode().unwrap();
    for end in [0, 3, 4, bytes.len() - 1] {
        assert!(NativeBootstrap::decode(&bytes[..end]).is_err());
    }
    assert!(NativeBootstrap::frame_length(u32::MAX.to_be_bytes()).is_err());
    assert!(NativeBootstrap::frame_length(0_u32.to_be_bytes()).is_err());
    let mut extra = bytes.clone();
    extra.push(0);
    assert!(NativeBootstrap::decode(&extra).is_err());
    let mut wrong = bytes;
    *wrong.last_mut().unwrap() ^= 1;
    assert!(NativeBootstrap::decode(&wrong).is_err());
}

#[test]
fn native_receiver_private_frame_refuses_duplicate_members_unknown_fields_and_version() {
    let source = bootstrap();
    let bytes = source.encode().unwrap();
    let original = std::str::from_utf8(&bytes[4..bytes.len() - 32]).unwrap();
    for header in [
        original.replacen("\"version\":2", "\"version\":1", 1),
        original.replacen("\"version\":2", "\"version\":2,\"version\":2", 1),
        original.replacen("\"version\":2", "\"extra\":true,\"version\":2", 1),
        original.replacen(&"a".repeat(64), &"A".repeat(64), 1),
    ] {
        let mut frame = Zeroizing::new((header.len() as u32).to_be_bytes().to_vec());
        frame.extend_from_slice(header.as_bytes());
        frame.extend_from_slice(&bytes[bytes.len() - 32..]);
        assert!(NativeBootstrap::decode(&frame).is_err());
    }
}
