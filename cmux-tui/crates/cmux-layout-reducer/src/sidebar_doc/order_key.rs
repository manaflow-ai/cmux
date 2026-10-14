//! Fractional order keys: base-62 digit strings (`0-9A-Za-z`, so byte order
//! is digit order) compared as strings. A key is never empty and never ends
//! in `0`, so a key always exists between two keys. Appending and prepending
//! grow a key by one digit every 61 steps; repeated inserts at one place grow
//! it faster, so a caller renumbers the siblings ([`spread`]) once a key
//! exceeds [`super::MAX_ORDER_KEY_CHARS`].

const DIGITS: &[u8; 62] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const BASE: usize = 62;
/// The first key of an empty list: the middle digit, so both ends have room.
const FIRST: &str = "V";

fn digit(byte: u8) -> usize {
    DIGITS.iter().position(|&candidate| candidate == byte).unwrap_or(0)
}

fn char_of(value: usize) -> char {
    DIGITS[value] as char
}

/// Whether `key` is a well-formed order key.
pub fn is_valid(key: &str) -> bool {
    !key.is_empty() && !key.ends_with('0') && key.bytes().all(|byte| DIGITS.contains(&byte))
}

/// A key after `a`.
fn after(a: &str) -> String {
    if a.is_empty() {
        return FIRST.into();
    }
    let first = digit(a.as_bytes()[0]);
    if first + 1 < BASE {
        return char_of(first + 1).to_string();
    }
    format!("{}{}", char_of(first), after(&a[1..]))
}

/// A key before `b` (non-empty, no trailing zero).
fn before(b: &str) -> String {
    let first = digit(b.as_bytes()[0]);
    if first >= 2 {
        return char_of(first - 1).to_string();
    }
    if first == 1 {
        return if b.len() > 1 { "1".into() } else { "0z".into() };
    }
    format!("0{}", before(&b[1..]))
}

/// A key strictly between `a` and `b` (`a < b`; `a` may be empty).
fn midpoint(a: &str, b: &str) -> String {
    let (a_bytes, b_bytes) = (a.as_bytes(), b.as_bytes());
    let mut shared = 0;
    while shared < b_bytes.len() && a_bytes.get(shared).copied().unwrap_or(b'0') == b_bytes[shared]
    {
        shared += 1;
    }
    if shared > 0 {
        let rest_a = if shared <= a.len() { &a[shared..] } else { "" };
        return format!("{}{}", &b[..shared], midpoint(rest_a, &b[shared..]));
    }
    let low = a_bytes.first().map_or(0, |&byte| digit(byte));
    let high = digit(b_bytes[0]);
    if high - low > 1 {
        return char_of((low + high).div_ceil(2)).to_string();
    }
    if b.len() > 1 {
        return b[..1].to_string();
    }
    let rest_a = if a.is_empty() { "" } else { &a[1..] };
    format!("{}{}", char_of(low), after(rest_a))
}

/// A key strictly between `low` and `high` (either may be absent). A bound
/// that is not a valid key counts as absent; keys that are equal or out of
/// order fall back to a key after `low` (the caller renumbers then, see
/// [`needs_spread`]).
pub fn between(low: Option<&str>, high: Option<&str>) -> String {
    let low = low.filter(|key| is_valid(key));
    let high = high.filter(|key| is_valid(key));
    match (low, high) {
        (None, None) => FIRST.into(),
        (Some(low), None) => after(low),
        (None, Some(high)) => before(high),
        (Some(low), Some(high)) if low < high => midpoint(low, high),
        (Some(low), Some(_)) => after(low),
    }
}

/// Whether keys between `low` and `high` cannot keep the order (a bound is
/// invalid, or the bounds are equal or reversed): the siblings need
/// [`spread`].
pub fn needs_spread(low: Option<&str>, high: Option<&str>) -> bool {
    low.is_some_and(|key| !is_valid(key))
        || high.is_some_and(|key| !is_valid(key))
        || matches!((low, high), (Some(low), Some(high)) if low >= high)
}

/// `count` keys strictly between `low` and `high`, in order.
pub fn sequence(low: Option<&str>, high: Option<&str>, count: usize) -> Vec<String> {
    let mut keys = Vec::with_capacity(count);
    let mut previous = low.map(str::to_string);
    for _ in 0..count {
        let key = between(previous.as_deref(), high);
        previous = Some(key.clone());
        keys.push(key);
    }
    keys
}

/// `count` evenly spaced short keys (the renumbering of a sibling list).
pub fn spread(count: usize) -> Vec<String> {
    if count == 0 {
        return Vec::new();
    }
    let mut width = 1;
    let mut space = BASE as u128;
    while space <= (count as u128) * 2 {
        width += 1;
        space *= BASE as u128;
    }
    let step = space / (count as u128 + 1);
    (1..=count as u128)
        .map(|index| {
            let mut value = index * step;
            let mut digits = vec![b'0'; width];
            for slot in (0..width).rev() {
                digits[slot] = DIGITS[(value % BASE as u128) as usize];
                value /= BASE as u128;
            }
            let text = String::from_utf8(digits).unwrap_or_default();
            text.trim_end_matches('0').to_string()
        })
        .collect()
}
