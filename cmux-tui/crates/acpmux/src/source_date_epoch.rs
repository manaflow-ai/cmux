//! SOURCE_DATE_EPOCH handling for the build id date. `build.rs` includes this
//! file with `#[path]`, and the library compiles it only under `cfg(test)` so
//! its unit tests run with `cargo test -p acpmux`. Keep it std-only: a build
//! script cannot use the crate's dependencies.

/// Parses a SOURCE_DATE_EPOCH value: a non-negative integer of Unix seconds,
/// ASCII digits only (no sign, no whitespace, no fraction).
pub fn parse(raw: &str) -> Result<u64, String> {
    let _ = raw;
    todo!()
}

/// Formats Unix seconds as the UTC calendar date `YYYY-MM-DD`.
pub fn utc_date(secs: u64) -> String {
    let _ = secs;
    todo!()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utc_date_at_day_boundaries() {
        assert_eq!(utc_date(0), "1970-01-01");
        assert_eq!(utc_date(86_399), "1970-01-01");
        assert_eq!(utc_date(86_400), "1970-01-02");
    }

    #[test]
    fn utc_date_on_leap_days_and_century_rules() {
        assert_eq!(utc_date(951_782_400), "2000-02-29");
        assert_eq!(utc_date(951_868_800), "2000-03-01");
        assert_eq!(utc_date(4_107_456_000), "2100-02-28");
        assert_eq!(utc_date(4_107_542_400), "2100-03-01");
    }

    #[test]
    fn utc_date_for_a_recent_value() {
        assert_eq!(utc_date(1_759_622_399), "2025-10-04");
        assert_eq!(utc_date(1_759_622_400), "2025-10-05");
    }

    #[test]
    fn parse_accepts_only_non_negative_integers() {
        assert_eq!(parse("0"), Ok(0));
        assert_eq!(parse("1759622400"), Ok(1_759_622_400));
        for bad in ["", "-1", "+1", " 1", "1 ", "1.5", "abc", "99999999999999999999999"] {
            assert!(parse(bad).is_err(), "{bad:?} must be rejected");
        }
    }
}
