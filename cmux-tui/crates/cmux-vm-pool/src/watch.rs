//! When runners come online in GitHub. A runner counts only once GitHub has shown it offline at or after
//! `since` and then online: a paused machine's runner can stay listed as online for a while after the pause,
//! and that stale "online" must never count as a resume.

use std::collections::{BTreeMap, HashMap, HashSet};

use serde_json::{Value, json};

use crate::model::Runner;

#[derive(Clone, Debug, Default)]
struct Seen {
    offline: bool,
    first_online_ms: Option<u64>,
}

/// Tracks runners across roster reads.
#[derive(Clone, Debug)]
pub struct Tracker {
    since_ms: u64,
    /// The runners to count; `None` counts every runner in the roster.
    wanted: Option<HashSet<String>>,
    seen: HashMap<String, Seen>,
}

impl Tracker {
    pub fn new(since_ms: u64, wanted: Option<HashSet<String>>) -> Self {
        Self { since_ms, wanted, seen: HashMap::new() }
    }

    fn counts(&self, name: &str) -> bool {
        self.wanted.as_ref().is_none_or(|w| w.contains(name))
    }

    /// One roster read, taken at `at_ms`. A wanted runner missing from the roster is offline.
    ///
    /// A read before `since` is the baseline: it arms "offline" (a runner GitHub already shows offline before
    /// the resume counts as soon as it is online after it, however fast the resume was) and an online sighting
    /// there disarms it again. Nothing before `since` counts as coming online.
    pub fn observe(&mut self, at_ms: u64, roster: &[Runner]) {
        if at_ms < self.since_ms {
            self.baseline(roster);
            return;
        }
        let listed: HashSet<&str> = roster.iter().map(|r| r.name.as_str()).collect();
        if let Some(wanted) = &self.wanted {
            for name in wanted {
                if !listed.contains(name.as_str()) {
                    self.seen.entry(name.clone()).or_default().offline = true;
                }
            }
        }
        for runner in roster {
            if !self.counts(&runner.name) {
                continue;
            }
            let seen = self.seen.entry(runner.name.clone()).or_default();
            if !runner.online {
                seen.offline = true;
            } else if seen.offline && seen.first_online_ms.is_none() {
                seen.first_online_ms = Some(at_ms);
            }
        }
    }

    /// A roster read taken before the resume: arms each runner's offline mark from what GitHub shows then.
    pub fn baseline(&mut self, roster: &[Runner]) {
        let listed: HashMap<&str, bool> =
            roster.iter().map(|r| (r.name.as_str(), r.online)).collect();
        if let Some(wanted) = &self.wanted {
            for name in wanted {
                if !listed.contains_key(name.as_str()) {
                    self.seen.entry(name.clone()).or_default().offline = true;
                }
            }
        }
        for (name, online) in listed {
            if self.counts(name) && self.seen.get(name).is_none_or(|s| s.first_online_ms.is_none())
            {
                self.seen.entry(name.to_owned()).or_default().offline = !online;
            }
        }
    }

    /// Runners that came back, earliest first, as (name, ms after `since`).
    pub fn online(&self) -> Vec<(String, u64)> {
        let mut out: Vec<(String, u64)> = self
            .seen
            .iter()
            .filter_map(|(name, s)| {
                s.first_online_ms.map(|at| (name.clone(), at.saturating_sub(self.since_ms)))
            })
            .collect();
        out.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
        out
    }

    pub fn online_count(&self) -> usize {
        self.seen.values().filter(|s| s.first_online_ms.is_some()).count()
    }

    /// Runners GitHub showed offline at least once (the ones that can count).
    pub fn offline_count(&self) -> usize {
        self.seen.values().filter(|s| s.offline).count()
    }

    /// Milliseconds after `since` at which the k-th runner came online, for each k in `marks` reached.
    pub fn nth(&self, marks: &[usize]) -> BTreeMap<usize, u64> {
        let online = self.online();
        marks.iter().filter_map(|&k| online.get(k.checked_sub(1)?).map(|o| (k, o.1))).collect()
    }

    pub fn to_json(&self, marks: &[usize]) -> Value {
        let online: Vec<Value> = self
            .online()
            .into_iter()
            .map(|(name, ms)| json!({"name": name, "online_after_ms": ms}))
            .collect();
        let nth: serde_json::Map<String, Value> =
            self.nth(marks).into_iter().map(|(k, ms)| (k.to_string(), json!(ms))).collect();
        json!({
            "since_ms": self.since_ms,
            "seen_offline": self.offline_count(),
            "online": online,
            "nth_ms": nth,
        })
    }
}
