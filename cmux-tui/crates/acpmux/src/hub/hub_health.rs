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
    /// none whose ask is out, and no more than [`IN_FLIGHT`] out in all.
    pub(crate) fn due(&mut self, hosts: &[String], now: u64) -> Vec<String> {
        let mut due = Vec::new();
        for host in hosts {
            if self.out.len() >= IN_FLIGHT {
                break;
            }
            let recent = self.asked.get(host).is_some_and(|at| now.saturating_sub(*at) < EVERY_MS);
            if recent || self.out.contains(host) {
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
#[path = "hub_health_tests.rs"]
mod tests;
