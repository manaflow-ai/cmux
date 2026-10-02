//! Fractional sort keys with a variable-length integer head (the scheme of
//! rocicorp's fractional-indexing, base 62). A key is an integer part whose
//! first character encodes its length (`a`..`z` positive, `A`..`Z` negative)
//! plus an optional fraction that never ends with `0`. Appends and prepends
//! increment or decrement the integer part, so their keys grow
//! logarithmically (2,000 appends stay at 3 to 4 characters). Inserting into
//! one gap again and again still lengthens keys; the owner rebalances when a
//! key would pass `MAX_LEN` (reduce/tasks.rs).

const DIGITS: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const ZERO: u8 = b'0';
const LAST: u8 = b'z';
const INTEGER_ZERO: &str = "a0";
const SMALLEST_INTEGER: &str = "A00000000000000000000000000";
/// Longest key the owner commits.
pub const MAX_LEN: usize = 128;

fn digit(byte: u8) -> Option<usize> {
    DIGITS.iter().position(|d| *d == byte)
}

fn integer_length(head: u8) -> Option<usize> {
    match head {
        b'a'..=b'z' => Some(usize::from(head - b'a') + 2),
        b'A'..=b'Z' => Some(usize::from(b'Z' - head) + 2),
        _ => None,
    }
}

fn integer_part(key: &[u8]) -> Option<&[u8]> {
    let n = integer_length(*key.first()?)?;
    (n <= key.len()).then(|| &key[..n])
}

/// Whether `key` is a valid sort key.
pub fn is_valid(key: &str) -> bool {
    let bytes = key.as_bytes();
    if key.is_empty()
        || key.len() > MAX_LEN
        || key == SMALLEST_INTEGER
        || !bytes.iter().all(|b| digit(*b).is_some())
    {
        return false;
    }
    match integer_part(bytes) {
        Some(int) => !bytes[int.len()..].ends_with(b"0"),
        None => false,
    }
}

fn increment_integer(x: &[u8]) -> Option<Vec<u8>> {
    let head = x[0];
    let mut digs = x[1..].to_vec();
    let mut carry = true;
    for d in digs.iter_mut().rev() {
        if !carry {
            break;
        }
        let next = digit(*d)? + 1;
        if next == DIGITS.len() {
            *d = ZERO;
        } else {
            *d = DIGITS[next];
            carry = false;
        }
    }
    if !carry {
        let mut out = vec![head];
        out.extend(digs);
        return Some(out);
    }
    match head {
        b'Z' => Some(INTEGER_ZERO.as_bytes().to_vec()),
        b'z' => None,
        _ => {
            let h = head + 1;
            if h > b'a' {
                digs.push(ZERO);
            } else {
                digs.pop();
            }
            let mut out = vec![h];
            out.extend(digs);
            Some(out)
        }
    }
}

fn decrement_integer(x: &[u8]) -> Option<Vec<u8>> {
    let head = x[0];
    let mut digs = x[1..].to_vec();
    let mut borrow = true;
    for d in digs.iter_mut().rev() {
        if !borrow {
            break;
        }
        match digit(*d)? {
            0 => *d = LAST,
            n => {
                *d = DIGITS[n - 1];
                borrow = false;
            }
        }
    }
    if !borrow {
        let mut out = vec![head];
        out.extend(digs);
        return Some(out);
    }
    match head {
        b'a' => Some(vec![b'Z', LAST]),
        b'A' => None,
        _ => {
            let h = head - 1;
            if h < b'Z' {
                digs.push(LAST);
            } else {
                digs.pop();
            }
            let mut out = vec![h];
            out.extend(digs);
            Some(out)
        }
    }
}

/// A fraction strictly between `a` and `b` (`None` = open end).
fn midpoint(a: &[u8], b: Option<&[u8]>, out: &mut Vec<u8>) {
    if let Some(b) = b {
        let mut n = 0;
        while n < b.len() && a.get(n).copied().unwrap_or(ZERO) == b[n] {
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

fn with_fraction(int: &[u8], a: &[u8], b: Option<&[u8]>) -> Vec<u8> {
    let mut out = int.to_vec();
    midpoint(a, b, &mut out);
    out
}

/// A key strictly between `a` and `b` (`None` = open end). Returns `None`
/// for invalid or unordered inputs and when the result would be longer than
/// `MAX_LEN` (the owner then rebalances).
pub fn between(a: Option<&str>, b: Option<&str>) -> Option<String> {
    if a.is_some_and(|a| !is_valid(a)) || b.is_some_and(|b| !is_valid(b)) {
        return None;
    }
    if let (Some(a), Some(b)) = (a, b)
        && a >= b
    {
        return None;
    }
    let key = match (a.map(str::as_bytes), b.map(str::as_bytes)) {
        (None, None) => INTEGER_ZERO.as_bytes().to_vec(),
        (None, Some(b)) => {
            let ib = integer_part(b)?;
            if ib == SMALLEST_INTEGER.as_bytes() {
                with_fraction(ib, b"", Some(&b[ib.len()..]))
            } else if ib.len() < b.len() {
                ib.to_vec()
            } else {
                decrement_integer(ib)?
            }
        }
        (Some(a), None) => {
            let ia = integer_part(a)?;
            match increment_integer(ia) {
                Some(i) => i,
                None => with_fraction(ia, &a[ia.len()..], None),
            }
        }
        (Some(a), Some(b)) => {
            let ia = integer_part(a)?;
            let ib = integer_part(b)?;
            if ia == ib {
                with_fraction(ia, &a[ia.len()..], Some(&b[ib.len()..]))
            } else {
                let i = increment_integer(ia)?;
                if i.as_slice() < b { i } else { with_fraction(ia, &a[ia.len()..], None) }
            }
        }
    };
    let key = String::from_utf8(key).ok()?;
    is_valid(&key).then_some(key)
}

/// `n` evenly growing keys in order (`a0`, `a1`, …): the owner's rebalance.
pub fn sequence(n: usize) -> Vec<String> {
    let mut out: Vec<String> = Vec::with_capacity(n);
    for _ in 0..n {
        let next = between(out.last().map(String::as_str), None).expect("appends never exhaust");
        out.push(next);
    }
    out
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
    fn appends_and_prepends_grow_logarithmically() {
        let keys = sequence(5_000);
        assert!(keys.windows(2).all(|w| w[0] < w[1]));
        assert!(keys.iter().all(|k| k.len() <= 4), "{}", keys.last().unwrap());
        let mut low = "a0".to_owned();
        for _ in 0..5_000 {
            let next = between(None, Some(&low)).unwrap();
            assert!(next < low);
            low = next;
        }
        assert!(low.len() <= 4, "{low}");
    }

    #[test]
    fn between_adjacent_integers_uses_a_fraction() {
        let k = between(Some("a0"), Some("a1")).unwrap();
        assert!("a0" < k.as_str() && k.as_str() < "a1", "{k}");
    }

    #[test]
    fn rejects_unordered_and_overlong() {
        assert_eq!(between(Some("a1"), Some("a0")), None);
        assert_eq!(between(Some("a1"), Some("a1")), None);
        let mut b = "a1".to_owned();
        let mut steps = 0;
        while let Some(k) = between(Some("a0"), Some(&b)) {
            b = k;
            steps += 1;
        }
        assert!(steps > 100 && b.len() <= MAX_LEN, "steps {steps}");
    }
}
