//! Idempotency: the newest committed outcomes by idempotency key. The same
//! key with the same op and canonical params replays the outcome; the same
//! key with anything else is a conflict.

use std::collections::{HashMap, VecDeque};

use serde_json::json;

use super::{Op, Outcome};
use crate::render::compact;

/// Replay records kept (oldest dropped first).
pub const REPLAY_CAPACITY: usize = 4096;

#[derive(Debug, Clone)]
struct Record {
    fingerprint: String,
    outcome: Outcome,
}

#[derive(Debug, Clone, Default)]
pub(crate) struct ReplayLog {
    order: VecDeque<String>,
    records: HashMap<String, Record>,
}

pub(super) enum Lookup {
    Miss,
    Replay(Outcome),
    /// The key committed another op; its wire name.
    Conflict(String),
}

impl ReplayLog {
    pub(super) fn lookup(&self, key: &str, fingerprint: &str) -> Lookup {
        match self.records.get(key) {
            None => Lookup::Miss,
            Some(record) if record.fingerprint == fingerprint => {
                Lookup::Replay(Outcome { replayed: true, ..record.outcome.clone() })
            }
            Some(record) => Lookup::Conflict(committed_operation(&record.fingerprint)),
        }
    }

    pub(super) fn insert(&mut self, key: String, fingerprint: String, outcome: Outcome) {
        if self.records.insert(key.clone(), Record { fingerprint, outcome }).is_none() {
            self.order.push_back(key);
        }
        while self.order.len() > REPLAY_CAPACITY {
            if let Some(oldest) = self.order.pop_front() {
                self.records.remove(&oldest);
            }
        }
    }

    pub(crate) fn len(&self) -> usize {
        self.records.len()
    }
}

/// The wire name of the op a fingerprint records (`settings.set`, ...).
fn committed_operation(fingerprint: &str) -> String {
    let name = serde_json::from_str::<serde_json::Value>(fingerprint)
        .ok()
        .and_then(|value| value["op"].as_str().map(str::to_string))
        .unwrap_or_default();
    format!("settings.{name}")
}

/// The op's kind and canonical params (target as a key path, value with
/// sorted keys and canonical numbers), without the idempotency key.
pub(super) fn fingerprint(op: &Op) -> String {
    let (name, meta, path, value) = match op {
        Op::Set { target, value, meta } => {
            ("set", meta, Some(target.path()), Some(crate::value::canonical(value.clone())))
        }
        Op::Reset { target, meta } => ("reset", meta, Some(target.path()), None),
        Op::ResetAll { meta } => ("reset_all", meta, None, None),
        Op::DomainsPublish { .. } | Op::TeamPolicySet { .. } => return String::new(),
    };
    compact(&json!({
        "op": name,
        "path": path,
        "value": value,
        "origin": meta.origin.as_str(),
        "if_revision": meta.if_revision,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn outcome(revision: u64) -> Outcome {
        Outcome { revision, keys: Vec::new(), replayed: false }
    }

    #[test]
    fn keeps_the_newest_records_only() {
        let mut log = ReplayLog::default();
        for index in 0..(REPLAY_CAPACITY + 10) {
            log.insert(format!("k{index}"), "p".to_string(), outcome(index as u64));
        }
        assert_eq!(log.len(), REPLAY_CAPACITY);
        assert!(matches!(log.lookup("k0", "p"), Lookup::Miss));
        assert!(matches!(log.lookup("k9", "p"), Lookup::Miss));
        let newest = format!("k{}", REPLAY_CAPACITY + 9);
        assert!(
            matches!(log.lookup(&newest, "p"), Lookup::Replay(o) if o.replayed && o.revision == (REPLAY_CAPACITY + 9) as u64)
        );
        assert!(matches!(log.lookup(&newest, "q"), Lookup::Conflict(_)));
    }
}
