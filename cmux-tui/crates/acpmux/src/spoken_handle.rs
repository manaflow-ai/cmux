//! Stable, human-sized names for agent sessions.
//!
//! The mux session UUID remains the authority.  A spoken handle is display and routing
//! metadata: an explicit value is kept in the session's durable tag map, while older
//! sessions (and sessions created by older daemons) get a deterministic fallback from
//! their UUID.  That makes a handle survive compaction and a move without changing the
//! journal or identity model.

use crate::store::{SessionMeta, Tag};
use serde_json::Value;

/// The durable tag key.  The namespace keeps this out of ordinary orchestration tags.
pub const TAG: &str = "acpmux.spokenHandle";

const WORDS: &[&str] = &[
    "Mango",
    "Biscuit",
    "Tofu",
    "Noodle",
    "Peach",
    "Waffle",
    "Pickle",
    "Cocoa",
    "Mochi",
    "Pesto",
    "Olive",
    "Berry",
    "Taco",
    "Kiwi",
    "Churro",
    "Pancake",
    "Dumpling",
    "Cookie",
    "Lemon",
    "Truffle",
    "Pudding",
    "Pretzel",
    "Sushi",
    "Bagel",
    "Coconut",
    "Ginger",
    "Hazelnut",
    "Latte",
    "Melon",
    "Pistachio",
    "Raisin",
    "Sesame",
];

/// A stable fallback for sessions made before spoken handles shipped.
pub fn fallback(id: &str) -> String {
    let digest = crate::sha256::sha256_hex(id.as_bytes());
    match WORDS.get(usize::from(digest.as_bytes()[0]) % WORDS.len()) {
        Some(word) => (*word).to_owned(),
        None => "Mango".to_owned(),
    }
}

/// Allocate a spoken handle that is free among the live handles already assigned on this host.
/// The first choice is always a food word; a numeric suffix is used only when that word is taken.
pub fn allocate(id: &str, existing: impl IntoIterator<Item = impl AsRef<str>>) -> String {
    let digest = crate::sha256::sha256_hex(id.as_bytes());
    let start = usize::from(digest.as_bytes()[0]) % WORDS.len();
    let used: std::collections::HashSet<String> =
        existing.into_iter().map(|value| value.as_ref().to_ascii_lowercase()).collect();
    for offset in 0..WORDS.len() {
        let word = WORDS[(start + offset) % WORDS.len()];
        if !used.contains(&word.to_ascii_lowercase()) {
            return word.to_owned();
        }
    }
    let word = WORDS[start];
    let mut suffix = 2;
    loop {
        let candidate = format!("{word}-{suffix}");
        if !used.contains(&candidate.to_ascii_lowercase()) {
            return candidate;
        }
        suffix += 1;
    }
}

/// The effective handle for a session metadata record.
pub fn of_meta(meta: &SessionMeta) -> String {
    meta.tags
        .get(TAG)
        .map(|tag| tag.value.clone())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| fallback(&meta.id))
}

/// Read a handle from a projected summary, with a UUID fallback for old peers.
pub fn of_summary(summary: &Value) -> Option<String> {
    summary
        .get("spokenHandle")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .or_else(|| summary.get("sessionId").and_then(Value::as_str).map(fallback))
}

/// Handles are short spoken labels, not arbitrary session names.
pub fn validate(value: &str) -> bool {
    (2..=32).contains(&value.len())
        && value.chars().next().is_some_and(char::is_ascii_alphabetic)
        && value.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
}

/// Build the tag update used by the CLI and protocol callers.
pub fn tag(value: &str) -> (String, Tag) {
    (TAG.to_owned(), Tag { value: value.to_owned(), expires_at: None })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fallback_is_stable_and_spoken() {
        assert_eq!(fallback("session-1"), fallback("session-1"));
        assert!(validate(&fallback("session-1")));
    }

    #[test]
    fn explicit_tag_wins_and_validation_is_bounded() {
        let mut meta: SessionMeta = serde_json::from_value(serde_json::json!({
            "schema": "acpmux.session.v1", "id": "s", "name": "task", "harness": "codex",
            "cwd": "/tmp", "status": "idle", "createdAt": 0, "updatedAt": 0,
            "tags": {"acpmux.spokenHandle": "Mochi"}
        }))
        .unwrap();
        assert_eq!(of_meta(&meta), "Mochi");
        assert!(validate("Mochi-7"));
        assert!(!validate("M"));
        assert!(!validate("two words"));
        meta.tags.remove(TAG);
        assert!(validate(&of_meta(&meta)));
    }

    #[test]
    fn two_hundred_allocations_are_distinct_and_spoken() {
        let mut assigned = Vec::new();
        for i in 0..200 {
            let handle = allocate(&format!("session-{i}"), &assigned);
            assert!(validate(&handle));
            assert!(assigned.iter().all(|old| old != &handle));
            assigned.push(handle);
        }
        assert_eq!(assigned.len(), 200);
    }
}
