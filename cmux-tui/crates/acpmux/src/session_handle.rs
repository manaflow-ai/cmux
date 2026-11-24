//! Spoken handles address chats through their existing UUID routes.
use sha2::{Digest, Sha256};
use std::borrow::Cow;

const FOODS: &[&str] = &[
    "Apple", "Bagel", "Basil", "Bean", "Berry", "Biscuit", "Boba", "Bun", "Cherry", "Chili",
    "Cocoa", "Crumb", "Date", "Fig", "Ginger", "Honey", "Kiwi", "Lemon", "Lime", "Mango", "Mint",
    "Miso", "Mochi", "Nori", "Olive", "Peach", "Pear", "Pepper", "Plum", "Sage", "Tofu", "Yuzu",
];

pub(crate) fn valid(handle: &str) -> bool {
    (2..=24).contains(&handle.len())
        && handle.starts_with(|c: char| c.is_ascii_alphabetic())
        && handle.ends_with(|c: char| c.is_ascii_alphanumeric())
        && handle.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        && !handle.eq_ignore_ascii_case("current")
}

fn default_parts(id: &str) -> (usize, Cow<'_, str>) {
    // UUIDs use 53 bits from the random half of the id. Older records with a different
    // id format use the same stable projection of their id's hash.
    if id.len() == 36
        && let Some(last) = id.get(24..).filter(|s| s.bytes().all(|b| b.is_ascii_hexdigit()))
        && let Some(food) = id.get(21..23).and_then(|s| usize::from_str_radix(s, 16).ok())
    {
        return (food % FOODS.len(), Cow::Borrowed(last));
    }
    let digest = Sha256::digest(id);
    let tail = digest[1..7].iter().fold(0_u64, |number, byte| (number << 8) | u64::from(*byte));
    (usize::from(digest[0]) % FOODS.len(), Cow::Owned(format!("{tail:012x}")))
}

pub(crate) fn default_handle(id: &str) -> String {
    let (food, tail) = default_parts(id);
    format!("{}-{}", FOODS[food], tail.to_ascii_lowercase())
}

pub(crate) fn display<'a>(handle: Option<&'a str>, id: &str) -> Cow<'a, str> {
    handle.filter(|h| valid(h)).map_or_else(|| Cow::Owned(default_handle(id)), Cow::Borrowed)
}

pub(crate) fn matches(value: Option<&str>, id: &str, key: &str) -> bool {
    if let Some(handle) = value.filter(|h| valid(h)) {
        return handle.eq_ignore_ascii_case(key);
    }
    let Some((word, tail)) = key.split_once('-') else { return false };
    if tail.len() != 12 || !FOODS.iter().any(|food| food.eq_ignore_ascii_case(word)) {
        return false;
    }
    let (food, suffix) = default_parts(id);
    FOODS[food].eq_ignore_ascii_case(word) && suffix.eq_ignore_ascii_case(tail)
}

/// A `session.alias` tag as people say it: the lane-gh broker writes its spaces as `+`
/// ("Logan+dot+chats-going-blank"), and `acpmux ls` prints it with spaces again
/// (`cli/ls_table.rs` `alias`), so a key typed from that listing finds it (`hub/key_route.rs`).
pub(crate) fn spoken_alias(raw: &str) -> Cow<'_, str> {
    let raw = raw.trim();
    if raw.contains('+') && !raw.contains(char::is_whitespace) {
        Cow::Owned(raw.replace('+', " "))
    } else {
        Cow::Borrowed(raw)
    }
}

/// Whether `shown`, a cell `acpmux ls` printed (`cli/output.rs` `short`: runs of space as one,
/// cut short with `…`), shows `value`: the whole of it in any case, or its start when cut.
pub(crate) fn shown_matches(shown: &str, value: &str) -> bool {
    let lower = |s: &str| {
        s.split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .to_lowercase()
            .chars()
            .collect::<Vec<_>>()
    };
    let (head, cut) = match shown.trim().strip_suffix('…') {
        Some(head) => (lower(head), true),
        None => (lower(shown), false),
    };
    let value = lower(value);
    !head.is_empty()
        && if cut { value.len() > head.len() && value.starts_with(&head) } else { value == head }
}

#[cfg(test)]
#[path = "session_handle_display_tests.rs"]
mod display_tests;
