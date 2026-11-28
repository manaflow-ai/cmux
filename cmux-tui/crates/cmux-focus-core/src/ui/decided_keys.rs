//! The key-downs the dispatcher decided (Swift `DecidedKeyEvents`), so the
//! window hook, Chromium's pre-key hook and the menu gate run nothing for
//! them. The app matches an event by identity (weak) itself; this keeps the
//! signatures (timestamp, key code, modifiers, characters), so a copy of the
//! same key that Chromium hands back is recognized too. An event with a zero
//! timestamp (AppKit's synthesized key bindings) matches by identity only.

use serde::{Deserialize, Serialize};

use super::page_first_key::DEVICE_INDEPENDENT;

/// Signatures kept at most: older ones are dropped first.
pub const LIMIT: usize = 16;

/// What a copy of an event keeps.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct KeySignature {
    /// `NSEvent.timestamp` (seconds).
    pub timestamp: f64,
    pub key_code: u16,
    /// `modifierFlags.rawValue`; only its device-independent bits count.
    pub modifiers: u64,
    /// `charactersIgnoringModifiers`.
    pub characters: Option<String>,
}

impl KeySignature {
    fn masked(&self) -> Self {
        Self { modifiers: self.modifiers & DEVICE_INDEPENDENT, ..self.clone() }
    }
}

/// The recent signatures. A value the app keeps and sends back.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DecidedKeys {
    recent: Vec<KeySignature>,
}

impl DecidedKeys {
    /// Records a decided key (nothing for a zero timestamp).
    pub fn add(&mut self, key: &KeySignature) {
        if key.timestamp == 0.0 {
            return;
        }
        self.recent.push(key.masked());
        if self.recent.len() > LIMIT {
            self.recent.drain(..self.recent.len() - LIMIT);
        }
    }

    /// Whether a key with this signature was decided (never for a zero
    /// timestamp: the app's identity match answers those).
    pub fn contains(&self, key: &KeySignature) -> bool {
        key.timestamp != 0.0 && self.recent.contains(&key.masked())
    }

    pub fn len(&self) -> usize {
        self.recent.len()
    }

    pub fn is_empty(&self) -> bool {
        self.recent.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(timestamp: f64, key_code: u16, modifiers: u64, characters: &str) -> KeySignature {
        KeySignature { timestamp, key_code, modifiers, characters: Some(characters.into()) }
    }

    #[test]
    fn a_copy_of_a_decided_key_is_recognized_by_its_signature() {
        let mut decided = DecidedKeys::default();
        decided.add(&key(1.5, 0, 0x10_0000 | 0x8, "a"));
        assert!(decided.contains(&key(1.5, 0, 0x10_0000, "a")), "device bits do not count");
        assert!(!decided.contains(&key(1.5, 0, 0x10_0000, "b")));
        assert!(!decided.contains(&key(1.6, 0, 0x10_0000, "a")));
    }

    #[test]
    fn a_synthesized_key_matches_by_identity_only() {
        let mut decided = DecidedKeys::default();
        decided.add(&key(0.0, 0, 0, "a"));
        assert!(decided.is_empty());
        assert!(!decided.contains(&key(0.0, 0, 0, "a")));
    }

    #[test]
    fn only_the_last_sixteen_are_kept() {
        let mut decided = DecidedKeys::default();
        for n in 1..=20 {
            decided.add(&key(f64::from(n), 0, 0, "a"));
        }
        assert_eq!(decided.len(), LIMIT);
        assert!(!decided.contains(&key(4.0, 0, 0, "a")));
        assert!(decided.contains(&key(5.0, 0, 0, "a")));
    }
}
