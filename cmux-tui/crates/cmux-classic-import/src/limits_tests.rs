use super::*;

#[test]
fn the_byte_scan_refuses_nul_unclosed_strings_and_deep_nesting() {
    assert_eq!(validate_encoded(b"{\"a\":1}", 100), Ok(()));
    assert_eq!(validate_encoded(b"{\"a\0\":1}", 100), Err(Error::NotASnapshot));
    assert_eq!(validate_encoded(b"{\"a", 100), Err(Error::NotASnapshot));
    assert_eq!(validate_encoded(b"{\"a\\", 100), Err(Error::NotASnapshot));
    assert_eq!(validate_encoded(&b"["[..].repeat(129), 1000), Err(Error::TooComplex));
    assert_eq!(validate_encoded(&b"["[..].repeat(128), 1000), Ok(()));
    assert_eq!(validate_encoded(b"{}", 1), Err(Error::TooLarge { actual: 2, maximum: 1 }));
}

#[test]
fn a_capped_read_stops_one_byte_past_its_limit() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("f.json");
    std::fs::write(&file, b"0123456789").unwrap();
    assert_eq!(read_capped(&file, 10).unwrap().unwrap().len(), 10);
    assert_eq!(read_capped(&file, 4), Err(Error::TooLarge { actual: 5, maximum: 4 }));
    assert_eq!(read_capped(&dir.path().join("none"), 4), Ok(None));
}
