//! Pure formatting helpers for owner-assigned ids and timestamps. The host
//! supplies the clock reading and the random bytes.

const CROCKFORD: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// `<prefix><26 Crockford base32 chars>`: a 48-bit millisecond time followed
/// by 80 random bits (the ULID layout), so ids sort by creation time.
pub fn encode_id(prefix: &str, unix_ms: u64, random: [u8; 10]) -> String {
    let mut value = u128::from(unix_ms & 0xFFFF_FFFF_FFFF) << 80;
    for (index, byte) in random.iter().enumerate() {
        value |= u128::from(*byte) << (8 * (9 - index));
    }
    let mut id = String::with_capacity(prefix.len() + 26);
    id.push_str(prefix);
    for index in 0..26 {
        let shift = 5 * (25 - index);
        let digit = ((value >> shift) & 31) as usize;
        id.push(char::from(CROCKFORD[digit]));
    }
    id
}

/// RFC 3339 UTC with milliseconds, for example `2026-10-01T12:34:56.789Z`.
/// The fixed width makes lexicographic order equal time order.
pub fn format_rfc3339_millis(unix_ms: u64) -> String {
    let millis = unix_ms % 1000;
    let seconds = unix_ms / 1000;
    let days = seconds / 86_400;
    let second_of_day = seconds % 86_400;
    let (year, month, day) = civil_from_days(days);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{millis:03}Z",
        second_of_day / 3600,
        (second_of_day % 3600) / 60,
        second_of_day % 60,
    )
}

/// Days since 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's
/// `civil_from_days`, restricted to non-negative day counts).
fn civil_from_days(days: u64) -> (u64, u64, u64) {
    let z = days + 719_468;
    let era = z / 146_097;
    let day_of_era = z % 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 { month_index + 3 } else { month_index - 9 };
    let year = year_of_era + era * 400 + u64::from(month <= 2);
    (year, month, day)
}
