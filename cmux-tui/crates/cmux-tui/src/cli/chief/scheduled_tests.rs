use super::parse_when;

const NOW: u64 = 1_761_500_000_000;

#[test]
fn when_reads_relative_rfc3339_and_unix_times() {
    assert_eq!(parse_when("+2m", NOW), Ok(NOW + 120_000));
    assert_eq!(parse_when("+1d", NOW), Ok(NOW + 86_400_000));
    assert_eq!(parse_when("2026-10-27T09:00:00Z", NOW), Ok(1_793_091_600_000));
    assert_eq!(parse_when("2026-10-27T09:00-07:00", NOW), Ok(1_793_116_800_000));
    assert_eq!(parse_when("2028-02-29T00:00:00Z", NOW), Ok(1_835_395_200_000));
    // Unix seconds are not read as milliseconds (a 1970 time).
    assert_eq!(parse_when("1761500000", NOW), Ok(1_761_500_000_000));
    assert_eq!(parse_when("1761500000123", NOW), Ok(1_761_500_000_123));
}

#[test]
fn when_refuses_impossible_dates_and_offsets() {
    for bad in [
        "2026-02-31T09:00:00Z",
        "2027-02-29T09:00:00Z",
        "2026-10-27-5T09:00:00Z",
        "2026-10-27T09:00:00+99:99",
        "2026-10-27T09:00:00+05:60",
        "+5x",
        "soon",
    ] {
        assert!(parse_when(bad, NOW).is_err(), "{bad} was accepted");
    }
}
