use super::*;

#[test]
fn the_epoch_and_a_leap_day() {
    assert_eq!(iso8601(0.0), "1970-01-01T00:00:00Z");
    assert_eq!(iso8601(1_709_208_000.9), "2024-02-29T12:00:00Z");
    assert_eq!(described(1_700_000_000), "2023-11-14 22:13:20 +0000");
    assert_eq!(iso8601(-1.0), "1969-12-31T23:59:59Z");
}
