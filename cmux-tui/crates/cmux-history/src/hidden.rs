//! Hides of history the daemon cannot delete (agent sessions and commands in
//! the append-only session journal): port of Swift `HiddenHistory`. Stored
//! as the home session's personal projection `history.hidden`.
//!
//! The JSON shape is the Swift document at schema version 1, so the daemon
//! module reads what the app wrote: `{"ranges":[{"from":<seconds since
//! 2001-01-01 UTC>,"until":...,"kind":"agent"?}],"entries":["<id>",...]}`
//! (Swift `Date` encodes as seconds since its reference date).

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

/// Unix seconds of the Swift reference date, 2001-01-01T00:00:00Z.
const SWIFT_REFERENCE_UNIX_S: f64 = 978_307_200.0;

/// One cleared time range, inclusive at both ends.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(into = "RangeWire", from = "RangeWire")]
pub struct HiddenRange {
    pub from_ms: i64,
    pub until_ms: i64,
    /// The entry kind it clears (`agent`, `command`); `None`: every kind.
    pub kind: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct RangeWire {
    from: f64,
    until: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    kind: Option<String>,
}

impl From<HiddenRange> for RangeWire {
    fn from(range: HiddenRange) -> Self {
        Self {
            from: swift_seconds(range.from_ms),
            until: swift_seconds(range.until_ms),
            kind: range.kind,
        }
    }
}

impl From<RangeWire> for HiddenRange {
    fn from(wire: RangeWire) -> Self {
        Self { from_ms: unix_ms(wire.from), until_ms: unix_ms(wire.until), kind: wire.kind }
    }
}

fn swift_seconds(unix_ms: i64) -> f64 {
    unix_ms as f64 / 1000.0 - SWIFT_REFERENCE_UNIX_S
}

/// Float to integer casts saturate in Rust, so no input panics.
fn unix_ms(swift_seconds: f64) -> i64 {
    ((swift_seconds + SWIFT_REFERENCE_UNIX_S) * 1000.0).round() as i64
}

/// Cleared ranges and single hidden entry ids.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq, Eq)]
pub struct HiddenHistory {
    /// Oldest first.
    #[serde(default)]
    ranges: Vec<HiddenRange>,
    /// Hidden entry ids (`AgentSession::qualified_id`,
    /// `TerminalCommand::qualified_id`), oldest first.
    #[serde(default)]
    entries: Vec<String>,
}

impl HiddenHistory {
    pub const SCHEMA_VERSION: u32 = 1;
    pub const RANGE_LIMIT: usize = 64;
    pub const ENTRY_LIMIT: usize = 2_000;
    /// Swift `Date.distantPast` (year 1) in Unix milliseconds: the start of an
    /// all-time clear.
    pub const DISTANT_PAST_MS: i64 = -62_135_769_600_000;

    pub fn new() -> Self {
        Self::default()
    }

    pub fn ranges(&self) -> &[HiddenRange] {
        &self.ranges
    }

    pub fn entries(&self) -> &[String] {
        &self.entries
    }

    /// Hides everything active from `since_ms` (`None`: all time) until
    /// `now_ms`. Later activity shows again. Keeps the newest 64 ranges.
    pub fn hide_range(&mut self, since_ms: Option<i64>, now_ms: i64, kind: Option<&str>) {
        self.ranges.push(HiddenRange {
            from_ms: since_ms.unwrap_or(Self::DISTANT_PAST_MS),
            until_ms: now_ms,
            kind: kind.map(str::to_owned),
        });
        drop_oldest(&mut self.ranges, Self::RANGE_LIMIT);
    }

    /// Hides one entry id; keeps the newest 2,000 ids.
    pub fn hide_entry(&mut self, id: &str) {
        if self.entries.iter().any(|entry| entry == id) {
            return;
        }
        self.entries.push(id.to_owned());
        drop_oldest(&mut self.entries, Self::ENTRY_LIMIT);
    }

    /// True when `id` is hidden, or a range of `kind` (or of every kind)
    /// covers `active_at_ms`.
    pub fn hides(&self, id: &str, active_at_ms: i64, kind: Option<&str>) -> bool {
        self.entries.iter().any(|entry| entry == id)
            || self.ranges.iter().any(|range| {
                (range.kind.is_none() || range.kind.as_deref() == kind)
                    && range.from_ms <= active_at_ms
                    && active_at_ms <= range.until_ms
            })
    }

    /// Both documents' hides; a revision conflict merges with this, so no
    /// clear is lost. Ranges: the union without duplicates, ordered by
    /// `(until, from, kind)`, the newest 64 kept. Entries: this document's
    /// ids, then the other's new ids, without duplicates, the newest 2,000
    /// kept.
    pub fn merged(&self, other: &Self) -> Self {
        let mut ranges: Vec<HiddenRange> =
            self.ranges.iter().chain(&other.ranges).cloned().collect();
        ranges.sort_by(|a, b| {
            (a.until_ms, a.from_ms, &a.kind).cmp(&(b.until_ms, b.from_ms, &b.kind))
        });
        ranges.dedup();
        drop_oldest(&mut ranges, Self::RANGE_LIMIT);
        let mut seen: HashSet<&str> = HashSet::new();
        let mut entries: Vec<String> = Vec::with_capacity(self.entries.len() + other.entries.len());
        for id in self.entries.iter().chain(&other.entries) {
            if seen.insert(id.as_str()) {
                entries.push(id.clone());
            }
        }
        drop_oldest(&mut entries, Self::ENTRY_LIMIT);
        Self { ranges, entries }
    }
}

fn drop_oldest<T>(items: &mut Vec<T>, limit: usize) {
    if items.len() > limit {
        items.drain(..items.len() - limit);
    }
}

/// The hide id of a history entry id: `agent:<qualified>` and
/// `command:<qualified>` hide `<qualified>`. Other kinds are not hidden this
/// way (their owners delete them).
pub fn hidden_id(entry_id: &str) -> Option<&str> {
    entry_id.strip_prefix("agent:").or_else(|| entry_id.strip_prefix("command:"))
}

#[cfg(test)]
#[path = "hidden_tests.rs"]
mod tests;
