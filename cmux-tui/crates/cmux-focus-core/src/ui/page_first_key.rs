//! The key-downs browser pages get first, each with what cmux runs if its
//! page reports it unhandled (Swift `PageFirstKeyOffer`).
//!
//! A bounded queue in offer order: a second key offered before the page
//! reported the first no longer replaces it. Chromium reports keys in the
//! order it got them, so a report releases its key and every older one. A
//! report from another tab than the one the key was offered to runs nothing.
//! A key matches by identity (the app's id for the `NSEvent`), else by
//! timestamp, key code and modifiers, because Chromium may hand back a copy.
//! The held action stays in the app, by the id it gives here.

use serde::{Deserialize, Serialize};

/// Keys held at most: older ones are dropped first.
pub const LIMIT: usize = 16;
/// `NSEvent.ModifierFlags.deviceIndependentFlagsMask`.
pub const DEVICE_INDEPENDENT: u64 = 0xFFFF_0000;

/// What a copy of an event keeps.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Signature {
    /// `NSEvent.timestamp` (seconds).
    pub timestamp: f64,
    pub key_code: u16,
    /// `modifierFlags.rawValue`; only its device-independent bits count.
    pub modifiers: u64,
}

impl Signature {
    fn masked(self) -> Self {
        Self { modifiers: self.modifiers & DEVICE_INDEPENDENT, ..self }
    }
}

/// A key-down as the app names it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct OfferedKey {
    /// The app's id for the `NSEvent` object.
    pub event: u64,
    pub signature: Signature,
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    event: u64,
    signature: Signature,
    held: u64,
    tab: u64,
}

impl Entry {
    fn matches(&self, other: &OfferedKey) -> bool {
        self.event == other.event
            || (other.signature.timestamp != 0.0 && self.signature == other.signature.masked())
    }
}

/// The queue. A value the app keeps and sends back.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PageFirstKeyOffer {
    entries: Vec<Entry>,
}

impl PageFirstKeyOffer {
    /// Keys held now.
    pub fn count(&self) -> usize {
        self.entries.len()
    }

    /// The held action ids still in the queue, oldest first (the app frees
    /// the rest).
    pub fn held(&self) -> Vec<u64> {
        self.entries.iter().map(|entry| entry.held).collect()
    }

    /// Holds `held` for `key`, offered to `tab`, after the keys held already.
    pub fn offer(&mut self, key: OfferedKey, held: u64, tab: u64) {
        self.entries.push(Entry { event: key.event, signature: key.signature.masked(), held, tab });
        if self.entries.len() > LIMIT {
            let extra = self.entries.len() - LIMIT;
            self.entries.drain(..extra);
        }
    }

    /// The held action when `key` is a held key reported by `tab`, the tab it
    /// was offered to. The key and every older one are released.
    pub fn take(&mut self, key: OfferedKey, tab: u64) -> Option<u64> {
        let index = self.entries.iter().position(|entry| entry.matches(&key))?;
        let entry = self.entries[index];
        self.entries.drain(..=index);
        (entry.tab == tab).then_some(entry.held)
    }

    /// The held action when `event` is the very key-down that was offered,
    /// sent back by its page (WebKit's report). Releases it and every older key.
    pub fn take_resent(&mut self, event: u64) -> Option<u64> {
        let index = self.entries.iter().position(|entry| entry.event == event)?;
        let held = self.entries[index].held;
        self.entries.drain(..=index);
        Some(held)
    }

    pub fn clear(&mut self) {
        self.entries.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CMD: u64 = 1 << 20;

    fn key(event: u64, key_code: u16, timestamp: f64) -> OfferedKey {
        OfferedKey { event, signature: Signature { timestamp, key_code, modifiers: CMD } }
    }

    #[test]
    fn a_second_offer_keeps_the_first_key() {
        let mut offers = PageFirstKeyOffer::default();
        let (find, next) = (key(1, 3, 10.0), key(2, 5, 11.0));
        offers.offer(find, 100, 9);
        offers.offer(next, 200, 9);
        assert_eq!(offers.take(find, 9), Some(100), "the first key was replaced by the second");
        assert_eq!(offers.take(next, 9), Some(200));
        assert_eq!(offers.count(), 0);
    }

    #[test]
    fn a_report_releases_its_key_and_the_older_ones() {
        let mut offers = PageFirstKeyOffer::default();
        let (handled, unhandled) = (key(1, 3, 20.0), key(2, 5, 21.0));
        offers.offer(handled, 100, 9);
        offers.offer(unhandled, 200, 9);
        assert_eq!(offers.take(unhandled, 9), Some(200));
        assert_eq!(offers.take(handled, 9), None, "a key older than a reported one is still held");
    }

    #[test]
    fn a_report_from_another_tab_runs_nothing() {
        let mut offers = PageFirstKeyOffer::default();
        let find = key(1, 3, 30.0);
        offers.offer(find, 100, 9);
        assert_eq!(offers.take(find, 8), None, "another tab's report ran the offered tab's action");
        assert_eq!(offers.count(), 0);
    }

    #[test]
    fn a_copy_matches_by_its_signature_but_not_at_timestamp_zero() {
        let mut offers = PageFirstKeyOffer::default();
        offers.offer(key(1, 3, 40.0), 100, 9);
        let copy = OfferedKey {
            event: 77,
            signature: Signature { modifiers: CMD | 0x8, ..key(1, 3, 40.0).signature },
        };
        assert_eq!(offers.take(copy, 9), Some(100), "device bits kept a copy from matching");
        offers.offer(key(2, 3, 0.0), 200, 9);
        assert_eq!(offers.take(key(78, 3, 0.0), 9), None);
        assert_eq!(offers.take_resent(2), Some(200));
    }

    #[test]
    fn the_queue_keeps_the_newest_keys() {
        let mut offers = PageFirstKeyOffer::default();
        for n in 0..20 {
            offers.offer(key(n, 3, n as f64 + 1.0), n, 9);
        }
        assert_eq!(offers.count(), LIMIT);
        assert_eq!(offers.held().first(), Some(&4));
        assert_eq!(offers.take(key(0, 3, 1.0), 9), None);
    }
}
