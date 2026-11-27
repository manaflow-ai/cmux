//! The Cloud wire's `cloud.machine.autosize` frames fed into each chat's AutoSize rows (RFD 0080
//! piece 4's last step). The app's Cloud wire socket hands every such frame here as it came
//! ([`wire_event`] reads it), and the chat header asks for its machine's rows ([`Feed::rows`]).
//!
//! The rows are kept per machine record, not per machine id: after a shrink the frame names the
//! new machine (cmux-platform `AutoSizeEvent.ts`), so a chat still bound to the machine it started
//! on and one that already reads the new id both see the one record's rows.
//!
//! Rules:
//! - Only an ephemeral `cloud.machine.autosize` frame of the socket's own team is read; any other
//!   frame, team, or a `data` this build cannot read is left out.
//! - A row is added by [`super::row`] and [`super::push`] (wire version, resend, folded holds).
//! - At most [`MAX_RECORDS`] records are kept, the most recently changed; each names at most
//!   [`MAX_MACHINES`] machine ids, the newest.

use serde_json::Value;

use super::{EVENT, Event, Row, push, row};

/// Machine records whose rows are kept.
pub const MAX_RECORDS: usize = 64;
/// Machine ids kept per record (one per grow or shrink that replaced the machine).
pub const MAX_MACHINES: usize = 8;

/// The `data` of `frame` when it is an ephemeral `cloud.machine.autosize` frame for `team` (the
/// team the socket was opened in; `None` reads any team). A frame names its team in `stream`
/// (`cloud:<team>`) and in `data.team`; when either is there it must be `team`.
pub fn wire_event(frame: &Value, team: Option<&str>) -> Option<Event> {
    if frame.get("t")?.as_str()? != "ephemeral" || frame.get("event")?.as_str()? != EVENT {
        return None;
    }
    let data = frame.get("data")?;
    if let Some(team) = team.filter(|team| !team.is_empty()) {
        let stream_ok = match frame.get("stream").and_then(Value::as_str) {
            Some(stream) => stream.strip_prefix("cloud:") == Some(team),
            None => true,
        };
        let data_ok = match data.get("team").and_then(Value::as_str) {
            Some(named) => named == team,
            None => true,
        };
        if !(stream_ok && data_ok) {
            return None;
        }
    }
    serde_json::from_value(data.clone()).ok()
}

/// One machine record's rows and the machine ids it went by.
#[derive(Clone, Debug, Default, PartialEq)]
struct Record {
    record: String,
    machines: Vec<String>,
    rows: Vec<Row>,
    /// Bumped from [`Feed::clock`] on each change, to drop the stalest record first.
    changed: u64,
}

/// Every chat's AutoSize rows, by machine record.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Feed {
    records: Vec<Record>,
    clock: u64,
}

impl Feed {
    /// Adds `event` seen by `viewer` (see [`super::row`]); whether the rows changed (false for a
    /// resend or a wire version this build does not draw).
    pub fn add(&mut self, event: &Event, viewer: Option<&str>) -> bool {
        let Some(next) = row(event, viewer) else { return false };
        let at = match self.records.iter().position(|r| r.record == event.record) {
            Some(at) => at,
            None => {
                self.records.push(Record { record: event.record.clone(), ..Record::default() });
                self.records.len() - 1
            }
        };
        let record = &mut self.records[at];
        let mut changed = false;
        if !event.machine.is_empty() && record.machines.last() != Some(&event.machine) {
            record.machines.retain(|machine| machine != &event.machine);
            record.machines.push(event.machine.clone());
            let extra = record.machines.len().saturating_sub(MAX_MACHINES);
            record.machines.drain(..extra);
            changed = true;
        }
        let before = std::mem::take(&mut record.rows);
        let rows = push(before.clone(), next);
        changed |= rows != before;
        record.rows = rows;
        if changed {
            self.clock += 1;
            record.changed = self.clock;
        }
        self.evict();
        changed
    }

    /// Reads one wire frame for the socket of `team` and adds its row: the machine it names when
    /// the rows changed.
    pub fn add_frame(
        &mut self,
        frame: &Value,
        team: Option<&str>,
        viewer: Option<&str>,
    ) -> Option<String> {
        let event = wire_event(frame, team)?;
        self.add(&event, viewer).then_some(event.machine)
    }

    /// The rows of the record `machine` belongs to, oldest first; empty for a machine with none.
    pub fn rows(&self, machine: &str) -> &[Row] {
        self.records
            .iter()
            .filter(|record| record.machines.iter().any(|known| known == machine))
            .max_by_key(|record| record.changed)
            .map_or(&[], |record| record.rows.as_slice())
    }

    /// How many records are kept.
    pub fn len(&self) -> usize {
        self.records.len()
    }

    /// Whether no record is kept.
    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    fn evict(&mut self) {
        while self.records.len() > MAX_RECORDS {
            let Some(stalest) = self
                .records
                .iter()
                .enumerate()
                .min_by_key(|(_, record)| record.changed)
                .map(|(at, _)| at)
            else {
                return;
            };
            self.records.remove(stalest);
        }
    }
}

#[cfg(test)]
mod tests;
