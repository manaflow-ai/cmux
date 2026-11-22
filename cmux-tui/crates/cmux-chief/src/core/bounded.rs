//! The core's bounded memories (TypeScript `rememberBounded` and the
//! children cap in `pruneChildren`).

use std::collections::{BTreeMap, VecDeque};

/// Most message authors the core remembers for the reply-to-Chief wake rule.
pub const MAX_AUTHORS: usize = 10_000;

/// An insertion-ordered map of at most `max` entries: a new key past the cap
/// drops the oldest; setting a known key keeps its place.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Bounded {
    map: BTreeMap<String, String>,
    order: VecDeque<String>,
}

impl Bounded {
    pub fn get(&self, key: &str) -> Option<&String> {
        self.map.get(key)
    }

    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }

    pub fn remember(&mut self, key: &str, value: &str, max: usize) {
        if self.map.insert(key.to_owned(), value.to_owned()).is_some() {
            return;
        }
        self.order.push_back(key.to_owned());
        while self.map.len() > max {
            let Some(oldest) = self.order.pop_front() else { break };
            self.map.remove(&oldest);
        }
    }

    /// The keys, oldest first.
    pub fn keys(&self) -> impl Iterator<Item = &String> {
        self.order.iter()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_the_newest_entries_up_to_the_cap_and_a_known_key_keeps_its_place() {
        let mut map = Bounded::default();
        map.remember("a", "1", 2);
        map.remember("b", "2", 2);
        map.remember("a", "3", 2);
        map.remember("c", "4", 2);
        let entries: Vec<(&str, &str)> =
            map.keys().map(|k| (k.as_str(), map.get(k).unwrap().as_str())).collect();
        assert_eq!(entries, vec![("b", "2"), ("c", "4")]);
        assert_eq!(MAX_AUTHORS, 10_000);
    }
}
