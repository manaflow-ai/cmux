//! Fractional sort keys over base-62 digits (`0-9A-Za-z`, byte order equals
//! digit order). A key never ends with the zero digit, so a key strictly
//! between any two distinct keys always exists.

const DIGITS: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

fn digit(byte: u8) -> Option<usize> {
    DIGITS.iter().position(|d| *d == byte)
}

/// Whether `key` is a valid sort key: non-empty, ≤ 128 digits, base 62, no trailing zero.
pub fn is_valid(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 128
        && key.bytes().all(|b| digit(b).is_some())
        && !key.ends_with('0')
}

/// A key strictly between `a` and `b` (`None` = open end). Requires valid
/// keys with `a < b`; returns `None` otherwise.
pub fn between(a: Option<&str>, b: Option<&str>) -> Option<String> {
    let a = a.unwrap_or("");
    if !a.is_empty() && !is_valid(a) {
        return None;
    }
    if let Some(b) = b
        && (!is_valid(b) || a >= b)
    {
        return None;
    }
    let mut out = Vec::new();
    midpoint(a.as_bytes(), b.map(str::as_bytes), &mut out);
    String::from_utf8(out).ok()
}

fn midpoint(a: &[u8], b: Option<&[u8]>, out: &mut Vec<u8>) {
    if let Some(b) = b {
        let mut n = 0;
        while n < b.len() && a.get(n).copied().unwrap_or(DIGITS[0]) == b[n] {
            n += 1;
        }
        if n > 0 {
            out.extend_from_slice(&b[..n]);
            let rest_a = if n <= a.len() { &a[n..] } else { &[] };
            midpoint(rest_a, Some(&b[n..]), out);
            return;
        }
    }
    let digit_a = a.first().and_then(|d| digit(*d)).unwrap_or(0);
    let digit_b = b.and_then(|b| b.first()).and_then(|d| digit(*d)).unwrap_or(DIGITS.len());
    if digit_b - digit_a > 1 {
        out.push(DIGITS[(digit_a + digit_b).div_ceil(2)]);
    } else if let Some(b) = b.filter(|b| b.len() > 1) {
        out.push(b[0]);
    } else {
        out.push(DIGITS[digit_a]);
        let rest = if a.is_empty() { &[][..] } else { &a[1..] };
        midpoint(rest, None, out);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn between_open_ends() {
        let first = between(None, None).unwrap();
        let after = between(Some(&first), None).unwrap();
        let before = between(None, Some(&first)).unwrap();
        assert!(before < first && first < after);
    }

    #[test]
    fn between_adjacent_digits_extends() {
        let k = between(Some("V"), Some("W")).unwrap();
        assert!("V" < k.as_str() && k.as_str() < "W", "{k}");
        assert!(is_valid(&k));
    }

    #[test]
    fn rejects_unordered() {
        assert_eq!(between(Some("W"), Some("V")), None);
        assert_eq!(between(Some("V"), Some("V")), None);
    }
}
