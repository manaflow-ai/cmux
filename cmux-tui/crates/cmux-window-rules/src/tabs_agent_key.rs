//! An agent tab's key across relaunch (the Mac app's `AgentTabKey`): forked
//! and SSH machines may reuse a durable tab id, so the launch-wake file names
//! the machine of an id two machines list. Pure.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// A tab id and the daemon (machine) that lists it; "" is the local daemon.
#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AgentTabKey {
    pub machine: String,
    pub key: String,
}

const SEPARATOR: char = '\0';

impl AgentTabKey {
    /// The key the launch-wake file stores: the bare id unless another
    /// machine lists it too (so old bare keys stay readable).
    pub fn relaunch_storage_key(&self, duplicate_ids: &BTreeSet<String>) -> String {
        if self.machine.is_empty() || !duplicate_ids.contains(&self.key) {
            return self.key.clone();
        }
        format!("{}{SEPARATOR}{}", self.machine, self.key)
    }

    /// The stored keys that may name this tab, the machine's first.
    pub fn relaunch_key_candidates(&self) -> Vec<String> {
        if self.machine.is_empty() {
            vec![self.key.clone()]
        } else {
            vec![format!("{}{SEPARATOR}{}", self.machine, self.key), self.key.clone()]
        }
    }

    /// Reads a stored key: a separator past the first character splits machine and id.
    pub fn from_relaunch_storage_key(stored: &str) -> Self {
        match stored.find(SEPARATOR) {
            Some(at) if at > 0 => {
                AgentTabKey { machine: stored[..at].to_string(), key: stored[at + 1..].to_string() }
            }
            _ => AgentTabKey { machine: String::new(), key: stored.to_string() },
        }
    }
}

/// The tab ids more than one machine lists (one tab listed twice is no duplicate).
pub fn duplicate_ids(keys: &[AgentTabKey]) -> BTreeSet<String> {
    let mut machines: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
    for key in keys {
        machines.entry(&key.key).or_default().insert(&key.machine);
    }
    machines.into_iter().filter(|(_, held)| held.len() > 1).map(|(id, _)| id.to_string()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(machine: &str, id: &str) -> AgentTabKey {
        AgentTabKey { machine: machine.into(), key: id.into() }
    }

    #[test]
    fn only_a_colliding_id_of_a_named_machine_is_qualified() {
        let keys = [key("", "a"), key("m1", "a"), key("m1", "b"), key("m1", "b")];
        let duplicates = duplicate_ids(&keys);
        assert_eq!(duplicates, BTreeSet::from(["a".to_string()]));
        assert_eq!(key("m1", "a").relaunch_storage_key(&duplicates), "m1\0a");
        assert_eq!(key("", "a").relaunch_storage_key(&duplicates), "a");
        assert_eq!(key("m1", "b").relaunch_storage_key(&duplicates), "b");
    }

    #[test]
    fn a_stored_key_reads_back_and_an_old_bare_key_is_local() {
        assert_eq!(AgentTabKey::from_relaunch_storage_key("m1\0a"), key("m1", "a"));
        assert_eq!(AgentTabKey::from_relaunch_storage_key("a"), key("", "a"));
        assert_eq!(AgentTabKey::from_relaunch_storage_key("\0a"), key("", "\0a"));
        assert_eq!(AgentTabKey::from_relaunch_storage_key("m\0a\0b"), key("m", "a\0b"));
        assert_eq!(key("m1", "a").relaunch_key_candidates(), ["m1\0a", "a"]);
        assert_eq!(key("", "a").relaunch_key_candidates(), ["a"]);
    }
}
