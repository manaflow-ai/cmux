//! Part of `Hub`; see `hub/mod.rs`. The health of the machines only the mesh hub reaches
//! (`mesh_book.rs`), so placement weighs them as it weighs a direct peer (`placement.rs`).
//!
//! A direct peer's link asks its health every minute (`peer_health.rs`); a machine only the hub
//! lists has no link, so placement on one read "resources unknown" (a lane VM,
//! 2026-11-24: every fleet host was hub-only, and `machine pick` refused each). Here the asker
//! reads each one through the hub with an `_acpmux/host_health` read (`server/mesh_read.rs`),
//! and keeps the newest answer by machine. Asked only while something places: a placement asks
//! (`server/place.rs`), and for [`INTEREST`] after it a refresh asks again once readings are
//! [`EVERY`] old, so an idle daemon sends the hub nothing. At most one ask per machine is out at
//! a time, [`IN_FLIGHT`] at once, and none more often than [`EVERY`]: with N machines that is N
//! small reads a minute while placing, each answer at most `HEALTH_BYTES`.
//!
//! A machine that publishes its cell record on its heartbeat (`server/cell_record.rs`, RFD 0181
//! B1) is asked nothing: each book read keeps the record the hub returns as that machine's
//! reading ([`HubHealth::published`]), and a machine with a reading under [`EVERY_MS`] old is
//! not due. A placement then reads this replica and waits on no machine; only a build that
//! publishes none is still asked.

use super::*;
use std::collections::{BTreeMap, BTreeSet};

/// How often one machine is asked, as a direct peer's link asks (`peer_health.rs`).
pub(crate) const EVERY_MS: u64 = 60_000;

/// How long after a placement the readings are kept fresh.
pub(crate) const INTEREST_MS: u64 = 15 * 60_000;

/// The most health reads out at once.
pub(crate) const IN_FLIGHT: usize = 8;

/// The most machines kept: as many as the book lists rows (`mesh_book.rs`).
const MAX_HOSTS: usize = 2048;

#[derive(Default)]
pub(crate) struct HubHealth {
    /// Each machine's newest reading and when it came (ms).
    readings: BTreeMap<String, (u64, Value)>,
    /// When each machine was last asked (ms), answered or not.
    asked: BTreeMap<String, u64>,
    /// The machines whose ask is still out.
    out: BTreeSet<String>,
    /// Until when a placement wants fresh readings (ms).
    interest_until: u64,
}

impl HubHealth {
    /// The newest reading of `host` and when it came.
    pub(crate) fn reading(&self, host: &str) -> Option<(u64, Value)> {
        self.readings.get(host).cloned()
    }

    /// Of `hosts`, the ones to ask now at `now`, marked asked: none asked within [`EVERY_MS`],
    /// none with a reading under [`EVERY_MS`] old (a published record, `published`), none whose
    /// ask is out, and no more than [`IN_FLIGHT`] out in all.
    pub(crate) fn due(&mut self, hosts: &[String], now: u64) -> Vec<String> {
        let mut due = Vec::new();
        for host in hosts {
            if self.out.len() >= IN_FLIGHT {
                break;
            }
            let recent = self.asked.get(host).is_some_and(|at| now.saturating_sub(*at) < EVERY_MS);
            let fresh =
                self.readings.get(host).is_some_and(|(at, _)| now.saturating_sub(*at) < EVERY_MS);
            if recent || fresh || self.out.contains(host) {
                continue;
            }
            self.asked.insert(host.clone(), now);
            self.out.insert(host.clone());
            due.push(host.clone());
        }
        due
    }

    /// `host`'s ask ended at `now`: with its reading, or with none (kept as it was).
    pub(crate) fn answered(&mut self, host: &str, reading: Option<Value>, now: u64) {
        self.out.remove(host);
        if let Some(v) = reading
            && (self.readings.contains_key(host) || self.readings.len() < MAX_HOSTS)
        {
            self.readings.insert(host.to_owned(), (now, v));
        }
    }

    /// `host` published `record` on its heartbeat, which the hub took at `at` (its clock; one
    /// ahead of `now` counts as `now`). Kept as its reading unless the one held is newer: over
    /// an asked reading, the record's keys replace that reading's and the rest stay (an asked
    /// reading names more than placement weighs: `os`, `autoCloud`).
    pub(crate) fn published(&mut self, host: &str, record: Value, at: u64, now: u64) {
        let at = at.min(now);
        let Value::Object(record) = record else { return };
        let room = self.readings.len() < MAX_HOSTS;
        match self.readings.get_mut(host) {
            Some((held, _)) if *held >= at => {}
            Some((held, reading)) => {
                *held = at;
                if let Value::Object(fields) = reading {
                    fields.remove("unsupported");
                    fields.extend(record);
                } else {
                    *reading = Value::Object(record);
                }
            }
            None if room => {
                self.readings.insert(host.to_owned(), (at, Value::Object(record)));
            }
            None => {}
        }
    }

    /// Only the machines `listed` names are kept.
    pub(crate) fn retain(&mut self, listed: &BTreeSet<String>) {
        self.readings.retain(|h, _| listed.contains(h));
        self.asked.retain(|h, _| listed.contains(h) || self.out.contains(h));
    }

    /// A placement at `now`: readings are kept fresh until [`INTEREST_MS`] after it. Whether a
    /// refresh loop was already running (it was wanted until after `now`).
    pub(crate) fn interested(&mut self, now: u64) -> bool {
        let running = self.interest_until > now;
        self.interest_until = now + INTEREST_MS;
        running
    }

    /// Whether a refresh at `now` is still wanted.
    pub(crate) fn wanted(&self, now: u64) -> bool {
        self.interest_until > now
    }
}

impl Hub {
    /// The machines only the hub lists (`mesh_book_hosts`), by name.
    pub(crate) fn hub_only_hosts(&self) -> Vec<String> {
        self.mesh_book_hosts()
            .iter()
            .filter_map(|row| row.get("name").and_then(Value::as_str).map(str::to_owned))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hosts(names: &[&str]) -> Vec<String> {
        names.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn a_machine_is_asked_at_most_once_a_minute_and_never_twice_at_once() {
        let mut h = HubHealth::default();
        assert_eq!(h.due(&hosts(&["a", "b"]), 1_000), hosts(&["a", "b"]));
        // Out: not asked again, even past a minute.
        assert!(h.due(&hosts(&["a"]), 1_000 + EVERY_MS).is_empty());
        h.answered("a", Some(json!({"cpus": 4})), 2_000);
        assert!(h.due(&hosts(&["a"]), 2_000).is_empty(), "asked within the minute");
        // A reading under a minute old is not asked again either: due a minute after it came.
        assert!(h.due(&hosts(&["a"]), 1_000 + EVERY_MS).is_empty(), "its reading is fresh");
        assert_eq!(h.due(&hosts(&["a"]), 2_000 + EVERY_MS), hosts(&["a"]));
        assert_eq!(h.reading("a"), Some((2_000, json!({"cpus": 4}))));
        // No answer keeps the last reading.
        h.answered("a", None, 3_000);
        assert_eq!(h.reading("a"), Some((2_000, json!({"cpus": 4}))));
    }

    #[test]
    fn no_more_than_in_flight_asks_are_out() {
        let mut h = HubHealth::default();
        let many: Vec<String> = (0..20).map(|i| format!("h{i}")).collect();
        assert_eq!(h.due(&many, 0).len(), IN_FLIGHT);
        assert!(h.due(&many, 0).is_empty());
        h.answered("h0", None, 1);
        assert_eq!(h.due(&many, 1), hosts(&["h8"]));
    }

    #[test]
    fn interest_lasts_fifteen_minutes_after_the_last_placement() {
        let mut h = HubHealth::default();
        assert!(!h.wanted(0));
        assert!(!h.interested(0), "no loop ran before");
        assert!(h.wanted(INTEREST_MS - 1));
        assert!(h.interested(10), "the loop still runs");
        assert!(!h.wanted(10 + INTEREST_MS));
    }

    #[test]
    fn a_machine_that_publishes_its_record_is_never_asked() {
        let mut h = HubHealth::default();
        h.published("a", json!({"cpus": 8, "liveSessions": 1}), 1_000, 1_000);
        assert_eq!(h.due(&hosts(&["a", "b"]), 1_500), hosts(&["b"]), "only b publishes none");
        assert_eq!(h.reading("a"), Some((1_000, json!({"cpus": 8, "liveSessions": 1}))));
        // Its next record keeps it fresh; a reading a minute old is asked for again.
        h.published("a", json!({"cpus": 8, "liveSessions": 2}), 31_000, 31_000);
        assert!(h.due(&hosts(&["a"]), 61_000).is_empty());
        assert_eq!(h.due(&hosts(&["a"]), 31_000 + EVERY_MS), hosts(&["a"]));
    }

    #[test]
    fn a_record_updates_an_asked_reading_and_never_goes_back_in_time() {
        let mut h = HubHealth::default();
        h.due(&hosts(&["a"]), 0);
        h.answered("a", Some(json!({"os": "linux", "cpus": 4, "liveSessions": 1})), 10);
        h.published("a", json!({"cpus": 4, "liveSessions": 3}), 20, 20);
        assert_eq!(
            h.reading("a"),
            Some((20, json!({"os": "linux", "cpus": 4, "liveSessions": 3})))
        );
        // An older record (the hub's book read before the ask came back) is not taken.
        h.published("a", json!({"liveSessions": 9}), 15, 30);
        assert_eq!(h.reading("a").unwrap().1["liveSessions"], 3);
        // A hub clock ahead of this one counts as now.
        h.published("a", json!({"liveSessions": 4}), 999_999, 40);
        assert_eq!(h.reading("a").map(|r| r.0), Some(40));
        // A build that answered `unsupported` and now publishes is weighed.
        h.answered("b", Some(json!({"unsupported": true})), 50);
        h.published("b", json!({"cpus": 2}), 60, 60);
        assert_eq!(h.reading("b"), Some((60, json!({"cpus": 2}))));
    }

    #[test]
    fn a_machine_the_book_no_longer_lists_is_dropped() {
        let mut h = HubHealth::default();
        h.due(&hosts(&["a", "b"]), 0);
        h.answered("a", Some(json!({})), 1);
        h.answered("b", Some(json!({})), 1);
        h.retain(&["a".to_owned()].into_iter().collect());
        assert!(h.reading("b").is_none());
        assert!(h.reading("a").is_some());
    }
}
