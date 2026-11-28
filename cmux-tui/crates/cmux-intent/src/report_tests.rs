use super::*;

#[test]
fn the_date_is_utc_iso() {
    assert_eq!(iso_utc(0), "1970-01-01T00:00:00Z");
    assert_eq!(iso_utc(1_795_420_224), "2026-11-23T07:50:24Z");
}
