/// Milliseconds between the Unix epoch and Apple's reference date (2001-01-01T00:00:00Z).
const APPLE_EPOCH_UNIX_MS: i64 = 978_307_200_000;

/// Converts a Messages `date` column to Unix milliseconds.
///
/// Since macOS 10.13 the column holds nanoseconds since 2001-01-01; older databases hold seconds.
/// Values above 10^11 cannot be seconds (that is past the year 5000), so they are nanoseconds.
/// Zero means "no date" and stays `None`.
pub fn apple_to_unix_ms(value: i64) -> Option<i64> {
    if value == 0 {
        return None;
    }
    let since_apple_ms =
        if value.abs() > 100_000_000_000 { value / 1_000_000 } else { value.saturating_mul(1_000) };
    Some(since_apple_ms.saturating_add(APPLE_EPOCH_UNIX_MS))
}
