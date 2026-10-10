//! SOURCE_DATE_EPOCH handling for the build id date. `build.rs` includes this
//! file with `#[path]`. Keep it std-only: a build script cannot use the
//! crate's dependencies.

/// Parses a SOURCE_DATE_EPOCH value: a non-negative integer of Unix seconds,
/// ASCII digits only (no sign, no whitespace, no fraction).
pub fn parse(raw: &str) -> Result<u64, String> {
    if raw.is_empty() || !raw.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!(
            "SOURCE_DATE_EPOCH={raw:?} is not a non-negative integer of Unix seconds"
        ));
    }
    raw.parse::<u64>().map_err(|e| format!("SOURCE_DATE_EPOCH={raw:?} is out of range: {e}"))
}

/// Formats Unix seconds as the UTC calendar date `YYYY-MM-DD`.
pub fn utc_date(secs: u64) -> String {
    // Howard Hinnant's civil_from_days, restricted to days >= 0 (1970-01-01),
    // with the year starting on March 1 so the leap day is the year's last.
    let z = secs / 86_400 + 719_468;
    let era = z / 146_097;
    let doe = z % 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + u64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}")
}
