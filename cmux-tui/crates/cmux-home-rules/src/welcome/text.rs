//! Text helpers the welcome ops share: Foundation's `%@` / `%N$@` format, a grapheme count close to
//! Swift's `String.count`, and the UTC dates the Swift side wrote with `ISO8601DateFormatter`.

/// Fills a Foundation format string's `%@`, `%N$@` and `%%` with `args` (the only specifiers the
/// welcome's localized strings use). A missing argument becomes the empty string.
pub fn format(template: &str, args: &[&str]) -> String {
    let mut out = String::with_capacity(template.len());
    let mut next = 0usize;
    let mut chars = template.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '%' {
            out.push(ch);
            continue;
        }
        match chars.peek().copied() {
            Some('%') => {
                chars.next();
                out.push('%');
            }
            Some('@') => {
                chars.next();
                out.push_str(args.get(next).copied().unwrap_or(""));
                next += 1;
            }
            Some(d) if d.is_ascii_digit() => {
                let mut lookahead = chars.clone();
                let mut number = 0usize;
                while let Some(c) = lookahead.peek().copied() {
                    if let Some(v) = c.to_digit(10) {
                        number = number * 10 + v as usize;
                        lookahead.next();
                    } else {
                        break;
                    }
                }
                if lookahead.next() == Some('$') && lookahead.next() == Some('@') && number > 0 {
                    chars = lookahead;
                    out.push_str(args.get(number - 1).copied().unwrap_or(""));
                } else {
                    out.push('%');
                }
            }
            _ => out.push('%'),
        }
    }
    out
}

fn extends(c: char) -> bool {
    let u = c as u32;
    matches!(u,
        0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F
        | 0xFE00..=0xFE0F | 0xE0100..=0xE01EF
        | 0x1F3FB..=0x1F3FF
        | 0xE0020..=0xE007F
        | 0x200C | 0x200D
        | 0x0483..=0x0489 | 0x0591..=0x05BD | 0x0610..=0x061A | 0x064B..=0x065F
        | 0x0900..=0x0903 | 0x093A..=0x094F | 0x0E31 | 0x0E34..=0x0E3A | 0x0E47..=0x0E4E
        | 0x3099 | 0x309A)
}

fn regional(c: char) -> bool {
    (0x1F1E6..=0x1F1FF).contains(&(c as u32))
}

/// About Swift's `String.count`: combining marks, variation selectors, skin tones, emoji tags, ZWJ
/// sequences, flag pairs and CRLF each stay inside one character.
pub fn grapheme_count(text: &str) -> usize {
    let mut count = 0usize;
    let mut previous: Option<char> = None;
    let mut joined = false;
    let mut flag_open = false;
    for c in text.chars() {
        let starts = match previous {
            None => true,
            Some(p) => {
                !((p == '\r' && c == '\n')
                    || joined
                    || extends(c)
                    || (regional(c) && regional(p) && flag_open))
            }
        };
        if starts {
            count += 1;
            flag_open = regional(c);
        } else if regional(c) {
            flag_open = false;
        }
        joined = c == '\u{200D}';
        previous = Some(c);
    }
    count
}

/// Days since 1970-01-01 to a civil (year, month, day), Howard Hinnant's algorithm.
fn civil(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// `yyyy-MM-dd` in UTC for seconds since 1970.
pub fn utc_day(seconds: f64) -> String {
    let secs = seconds.floor() as i64;
    let (y, m, d) = civil(secs.div_euclid(86_400));
    format!("{y:04}-{m:02}-{d:02}")
}

/// `yyyy-MM-ddTHH:mm:ss.SSSZ` in UTC for seconds since 1970 (`ISO8601DateFormatter` with
/// `.withFractionalSeconds`).
pub fn iso8601_millis(seconds: f64) -> String {
    let millis = (seconds * 1000.0).floor() as i64;
    let secs = millis.div_euclid(1000);
    let ms = millis.rem_euclid(1000);
    let (y, m, d) = civil(secs.div_euclid(86_400));
    let in_day = secs.rem_euclid(86_400);
    let (hh, mm, ss) = (in_day / 3600, (in_day / 60) % 60, in_day % 60);
    format!("{y:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}.{ms:03}Z")
}

/// Swift's `trimmingCharacters(in: .whitespacesAndNewlines)`.
pub fn trim(text: &str) -> &str {
    text.trim_matches(|c: char| c.is_whitespace())
}
