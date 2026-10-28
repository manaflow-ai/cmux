//! Fractional order keys: base-62 digit strings (`0-9A-Za-z`, so byte order
//! is digit order) compared as strings. A key is never empty and never ends
//! in `0`, so a key always exists between two keys. Appending and prepending
//! grow a key by one digit every 61 steps; repeated inserts at one place grow
//! it faster, so a caller renumbers the siblings ([`spread`]) once a key
//! exceeds [`super::MAX_ORDER_KEY_CHARS`].

const DIGITS: &[u8; BASE] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const BASE: usize = 62;
/// The first key of an empty list: the middle digit, so both ends have room.
const FIRST: u8 = b'V';

fn digit(byte: u8) -> usize {
    DIGITS.iter().position(|&candidate| candidate == byte).unwrap_or(0)
}

/// The digit byte of `value % BASE`.
#[allow(clippy::indexing_slicing, reason = "INVARIANT: value % BASE < BASE, the length of DIGITS")]
fn digit_byte(value: usize) -> u8 {
    DIGITS[value % BASE]
}

/// Keys are built from `DIGITS` bytes, which are ASCII.
fn key_text(key: Vec<u8>) -> String {
    key.into_iter().map(char::from).collect()
}

/// Whether `key` is a well-formed order key.
pub fn is_valid(key: &str) -> bool {
    !key.is_empty() && !key.ends_with('0') && key.bytes().all(|byte| DIGITS.contains(&byte))
}

/// A key after `a`.
fn after(a: &[u8]) -> Vec<u8> {
    let Some((&first, rest)) = a.split_first() else { return vec![FIRST] };
    let value = digit(first);
    if value + 1 < BASE {
        return vec![digit_byte(value + 1)];
    }
    let mut key = vec![digit_byte(value)];
    key.extend(after(rest));
    key
}

/// A key before `b` (no trailing zero). With no digits left there is no
/// bound, so any key is before it.
fn before(b: &[u8]) -> Vec<u8> {
    let Some((&first, rest)) = b.split_first() else { return vec![FIRST] };
    let value = digit(first);
    if value >= 2 {
        return vec![digit_byte(value - 1)];
    }
    if value == 1 {
        return if rest.is_empty() { b"0z".to_vec() } else { b"1".to_vec() };
    }
    let mut key = vec![b'0'];
    key.extend(before(rest));
    key
}

/// A key strictly between `a` and `b` (`a < b`; `a` may be empty). Bounds
/// out of order get a key after `a`, as in [`between`].
fn midpoint(a: &[u8], b: &[u8]) -> Vec<u8> {
    // `a` reads as padded with `0` digits past its end.
    let padded_a = a.iter().copied().chain(std::iter::repeat(b'0'));
    let shared = b.iter().zip(padded_a).take_while(|(high, low)| **high == *low).count();
    let Some((prefix, b_rest)) = b.split_at_checked(shared) else { return after(a) };
    let Some((&high_byte, b_tail)) = b_rest.split_first() else { return after(a) };
    let a_rest = a.get(shared..).unwrap_or(&[]);
    let (low, a_tail) = match a_rest.split_first() {
        Some((&byte, tail)) => (digit(byte), tail),
        None => (0, &[][..]),
    };
    let high = digit(high_byte);
    let mut key = prefix.to_vec();
    if high > low + 1 {
        key.push(digit_byte((low + high).div_ceil(2)));
    } else if !b_tail.is_empty() {
        key.push(high_byte);
    } else {
        key.push(digit_byte(low));
        key.extend(after(a_tail));
    }
    key
}

/// A key strictly between `low` and `high` (either may be absent). A bound
/// that is not a valid key counts as absent; keys that are equal or out of
/// order fall back to a key after `low` (the caller renumbers then, see
/// [`needs_spread`]).
pub fn between(low: Option<&str>, high: Option<&str>) -> String {
    let low = low.filter(|key| is_valid(key));
    let high = high.filter(|key| is_valid(key));
    key_text(match (low, high) {
        (None, None) => vec![FIRST],
        (Some(low), None) => after(low.as_bytes()),
        (None, Some(high)) => before(high.as_bytes()),
        (Some(low), Some(high)) if low < high => midpoint(low.as_bytes(), high.as_bytes()),
        (Some(low), Some(_)) => after(low.as_bytes()),
    })
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
            let mut digits: Vec<u8> = (0..width)
                .map(|_| {
                    let byte = digit_byte((value % BASE as u128) as usize);
                    value /= BASE as u128;
                    byte
                })
                .collect();
            digits.reverse();
            key_text(digits).trim_end_matches('0').to_string()
        })
        .collect()
}

#[cfg(test)]
#[path = "order_key_tests.rs"]
mod tests;
