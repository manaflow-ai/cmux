use super::*;

#[test]
fn round_trips_and_reads_url_safe() {
    for case in [&b""[..], b"f", b"fo", b"foo", b"foob", b"fooba", b"foobar"] {
        assert_eq!(decode(&encode(case)).as_deref(), Some(case));
    }
    assert_eq!(encode(b"foobar"), "Zm9vYmFy");
    assert_eq!(encode(b"fo"), "Zm8=");
    assert_eq!(decode("-_8").unwrap(), decode("+/8=").unwrap());
    assert!(decode("a b").is_none());
}
