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

fn digit_byte(value: usize) -> Option<u8> {
    DIGITS.get(value).copied()
}

fn integer_length(head: u8) -> Option<usize> {
    match head {
        b'a'..=b'z' => Some(usize::from(head - b'a') + 2),
        b'A'..=b'Z' => Some(usize::from(b'Z' - head) + 2),
        _ => None,
    }
}

/// Splits a key into its integer part and its fraction.
fn split_key(key: &[u8]) -> Option<(&[u8], &[u8])> {
    key.split_at_checked(integer_length(*key.first()?)?)
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
    match split_key(bytes) {
        Some((_, fraction)) => !fraction.ends_with(b"0"),
        None => false,
    }
}

fn increment_integer(x: &[u8]) -> Option<Vec<u8>> {
    let (&head, rest) = x.split_first()?;
    let mut digs = rest.to_vec();
    let mut carry = true;
    for d in digs.iter_mut().rev() {
        if !carry {
            break;
        }
        match digit_byte(digit(*d)? + 1) {
            Some(next) => {
                *d = next;
                carry = false;
            }
            None => *d = ZERO,
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
    let (&head, rest) = x.split_first()?;
    let mut digs = rest.to_vec();
    let mut borrow = true;
    for d in digs.iter_mut().rev() {
        if !borrow {
            break;
        }
        match digit(*d)?.checked_sub(1) {
            None => *d = LAST,
            Some(previous) => {
                *d = digit_byte(previous)?;
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

/// A fraction strictly between `a` and `b` (`None` = open end). A digit
/// past the end of `a` reads as `0`, the fraction's implicit trailing zeros.
fn midpoint(a: &[u8], b: Option<&[u8]>, out: &mut Vec<u8>) -> Option<()> {
    if let Some(b) = b {
        let common = b
            .iter()
            .enumerate()
            .take_while(|(i, d)| a.get(*i).copied().unwrap_or(ZERO) == **d)
            .count();
        if let Some((prefix, b_rest)) = b.split_at_checked(common)
            && !prefix.is_empty()
        {
            out.extend_from_slice(prefix);
            return midpoint(a.get(common..).unwrap_or_default(), Some(b_rest), out);
        }
    }
    let digit_a = a.first().and_then(|d| digit(*d)).unwrap_or(0);
    let digit_b = b.and_then(|b| b.first()).and_then(|d| digit(*d)).unwrap_or(DIGITS.len());
    if digit_b - digit_a > 1 {
        out.push(digit_byte((digit_a + digit_b).div_ceil(2))?);
        return Some(());
    }
    if let Some((&first, _)) = b.filter(|b| b.len() > 1).and_then(<[u8]>::split_first) {
        out.push(first);
        return Some(());
    }
    out.push(digit_byte(digit_a)?);
    midpoint(a.split_first().map_or(&[][..], |(_, rest)| rest), None, out)
}

fn with_fraction(int: &[u8], a: &[u8], b: Option<&[u8]>) -> Option<Vec<u8>> {
    let mut out = int.to_vec();
    midpoint(a, b, &mut out)?;
    Some(out)
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
            let (ib, fb) = split_key(b)?;
            if ib == SMALLEST_INTEGER.as_bytes() {
                with_fraction(ib, b"", Some(fb))?
            } else if !fb.is_empty() {
                ib.to_vec()
            } else {
                decrement_integer(ib)?
            }
        }
        (Some(a), None) => {
            let (ia, fa) = split_key(a)?;
            match increment_integer(ia) {
                Some(i) => i,
                None => with_fraction(ia, fa, None)?,
            }
        }
        (Some(a), Some(b)) => {
            let (ia, fa) = split_key(a)?;
            let (ib, fb) = split_key(b)?;
            if ia == ib {
                with_fraction(ia, fa, Some(fb))?
            } else {
                let i = increment_integer(ia)?;
                if i.as_slice() < b { i } else { with_fraction(ia, fa, None)? }
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
        // Appends never exhaust the integer space at rebalance sizes; should
        // they, the sequence is shorter and the caller keeps the old keys.
        let Some(next) = between(out.last().map(String::as_str), None) else { break };
        out.push(next);
    }
    out
}
