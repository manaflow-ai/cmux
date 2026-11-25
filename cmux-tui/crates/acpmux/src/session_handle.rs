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

/// Whether `key` names the session `id` whose explicit handle is `value`: that handle, or the
/// `Food-<hex>` one derived from its id, which every session keeps as an alias after it picks a
/// name, so a send typed before the rename still reaches it.
pub(crate) fn matches(value: Option<&str>, id: &str, key: &str) -> bool {
    if value.filter(|h| valid(h)).is_some_and(|handle| handle.eq_ignore_ascii_case(key)) {
        return true;
    }
    let Some((word, tail)) = key.split_once('-') else { return false };
    if tail.len() != 12 || !FOODS.iter().any(|food| food.eq_ignore_ascii_case(word)) {
        return false;
    }
    let (food, suffix) = default_parts(id);
    FOODS[food].eq_ignore_ascii_case(word) && suffix.eq_ignore_ascii_case(tail)
}

/// Short, cute names a new chat is offered (`pick_free`), and takes when it picks none itself.
const NAMES: &[&str] = &[
    "Acorn",
    "Apple",
    "Bagel",
    "Basil",
    "Bean",
    "Berry",
    "Biscuit",
    "Boba",
    "Bonbon",
    "Brioche",
    "Bun",
    "Butter",
    "Button",
    "Cashew",
    "Cherry",
    "Chickpea",
    "Chili",
    "Churro",
    "Clover",
    "Cocoa",
    "Coconut",
    "Cookie",
    "Crumb",
    "Cupcake",
    "Custard",
    "Daisy",
    "Date",
    "Dumpling",
    "Fig",
    "Flan",
    "Fudge",
    "Ginger",
    "Gnocchi",
    "Gumdrop",
    "Hazel",
    "Honey",
    "Jelly",
    "Kiwi",
    "Kumquat",
    "Latte",
    "Lemon",
    "Lime",
    "Lychee",
    "Macaron",
    "Mango",
    "Maple",
    "Marzipan",
    "Melon",
    "Meringue",
    "Mint",
    "Miso",
    "Mochi",
    "Muffin",
    "Noodle",
    "Nori",
    "Nutmeg",
    "Olive",
    "Pancake",
    "Papaya",
    "Peach",
    "Peanut",
    "Pear",
    "Pebble",
    "Pepper",
    "Pickle",
    "Pistachio",
    "Plum",
    "Popcorn",
    "Pretzel",
    "Pudding",
    "Pumpkin",
    "Quince",
    "Radish",
    "Ramen",
    "Ravioli",
    "Sage",
    "Sesame",
    "Sorbet",
    "Sprout",
    "Sprinkle",
    "Sundae",
    "Sushi",
    "Taco",
    "Taffy",
    "Tapioca",
    "Toffee",
    "Tofu",
    "Truffle",
    "Turnip",
    "Udon",
    "Waffle",
    "Wasabi",
    "Yuzu",
];

/// Little words before a name once every bare name is taken: still short, never hex.
const LITTLE: &[&str] = &[
    "Tiny", "Wee", "Fuzzy", "Sunny", "Lucky", "Happy", "Bouncy", "Cozy", "Sleepy", "Zippy",
    "Jolly", "Breezy", "Snug", "Dandy", "Peppy", "Merry",
];

/// Up to `count` free names for the chat `id`, in an order its id spreads across the fleet, so
/// lanes started together are not all offered the same first name: bare names (`Pickle`) first,
/// then a little word and a name (`TinyPickle`), then a name and a number (`Pickle7`). `taken`
/// answers for any spelling case; the daemon passes its live check (`hub/spoken_handles.rs`).
pub(crate) fn pick_free(id: &str, count: usize, taken: impl Fn(&str) -> bool) -> Vec<String> {
    let start = Sha256::digest(id)[..4].iter().fold(0_usize, |n, b| (n << 8) | usize::from(*b));
    let names = (0..NAMES.len()).map(|i| NAMES[(start + i) % NAMES.len()]);
    let bare = names.clone().map(str::to_owned);
    let little = LITTLE.iter().cycle().skip(start % LITTLE.len()).take(LITTLE.len());
    let paired = little.flat_map(move |l| names.clone().map(move |n| format!("{l}{n}")));
    let numbered = (2..).flat_map(|k| NAMES.iter().map(move |n| format!("{n}{k}")));
    bare.chain(paired).chain(numbered).filter(|n| !taken(n)).take(count).collect()
}

/// The note a new lane's first turn carries (`hub/turns.rs`): it has the name the daemon gave
/// it, and picks its own on this turn. `offers` are free names it may take instead.
pub(crate) fn first_turn_note(current: &str, offers: &[String]) -> String {
    let offers = if offers.is_empty() {
        String::new()
    } else {
        format!(" Free now: {}.", offers.join(", "))
    };
    format!(
        "[acpmux] Your name is {current} for now. Pick your own short, cute name (2-24 letters, \
         digits or hyphens), unique across the fleet, on this turn: `acpmux session rename @ \
         --handle NAME`. A taken name is refused; pick another. Peers send to you as \
         `acpmux send NAME '...'`.{offers} If you pick none, you stay {current}."
    )
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
mod display_tests {
    use super::*;

    const ID: &str = "0f6a1c2e-1b2c-4d5e-8f70-764b5709a685";

    #[test]
    fn a_picked_name_keeps_the_derived_hex_handle_as_an_alias() {
        let old = default_handle(ID);
        assert!(matches(Some("Pickle"), ID, "pickle"));
        assert!(matches(Some("Pickle"), ID, &old));
        assert!(matches(None, ID, &old));
        assert!(!matches(Some("Pickle"), ID, "Waffle"));
        assert!(!matches(Some("Pickle"), "1f6a1c2e-1b2c-4d5e-8f70-000000000000", "Pickle-x"));
    }

    #[test]
    fn free_names_are_short_have_no_hex_and_skip_taken_ones() {
        let picks = pick_free(ID, 5, |n| n.eq_ignore_ascii_case("pickle"));
        assert_eq!(picks.len(), 5);
        for p in &picks {
            assert!(valid(p) && !p.contains('-') && p.len() <= 14, "{p}");
            assert!(!p.eq_ignore_ascii_case("Pickle"));
        }
        assert_eq!(picks, pick_free(ID, 5, |n| n.eq_ignore_ascii_case("pickle")));
        // Every bare name taken: a little word and a name, never a hex tail.
        let paired = pick_free(ID, 1, |n| NAMES.iter().any(|b| b.eq_ignore_ascii_case(n)));
        assert!(LITTLE.iter().any(|l| paired[0].starts_with(l)), "{paired:?}");
        // Every pairing taken too: a name and a small number.
        let numbered = pick_free(ID, 1, |n| !n.ends_with(|c: char| c.is_ascii_digit()));
        assert!(numbered[0].ends_with('2') && valid(&numbered[0]), "{numbered:?}");
        assert!(first_turn_note("Pickle", &picks).contains("acpmux session rename @ --handle"));
    }

    #[test]
    fn a_broker_alias_reads_with_spaces_and_a_shown_cell_matches_its_value() {
        assert_eq!(spoken_alias("Logan+dot+chats-going-blank"), "Logan dot chats-going-blank");
        assert_eq!(spoken_alias("Ruby dot startup-speedups"), "Ruby dot startup-speedups");
        assert!(shown_matches("app-version-rollback", "App-Version-Rollback"));
        assert!(shown_matches("chat-recovery-versi…", "chat-recovery-version-rollback"));
        assert!(!shown_matches(
            "chat-recovery-version-rollback…",
            "chat-recovery-version-rollback"
        ));
        assert!(!shown_matches("app-version", "app-version-rollback"));
        assert!(!shown_matches("…", "anything"));
    }
}
