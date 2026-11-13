//! The rules a Cloud machine session follows over its record (`CloudMachineSession.listed`,
//! `applyRecord`, `connect`), the start-chat plan's machine entries, and a new machine's default
//! name.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::record::{Machine, Status};

/// This list read's `record` taken over `current`, the session's copy. A connect since the read
/// began (`connected_since_read`: a click's, which starts a paused machine) is newer than the
/// answer, so a record that is not live keeps `current`'s live status, pause reason and running
/// start, and takes the record's other fields.
pub fn listed(record: &Machine, current: &Machine, connected_since_read: bool) -> Machine {
    let mut accepted = record.clone();
    if current.status.is_live() && !record.status.is_live() && connected_since_read {
        accepted.status = current.status;
        accepted.pause_reason = current.pause_reason;
        accepted.running_since = current.running_since;
    }
    accepted
}

/// What a session does when a record replaces one whose status was `previous`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Edge {
    /// Suspend its link: the machine is no longer live.
    Suspend,
    /// Connect it: the machine became live.
    Connect,
    /// Retry a machine whose daemon answers only now.
    Retry,
}

/// `record`'s edge over `previous`; `was_resuming`: that one showed a pending resume;
/// `connected`: the session's daemon has a connection. None: nothing to do.
pub fn edge(
    record: &Machine,
    previous: Status,
    was_resuming: bool,
    connected: bool,
) -> Option<Edge> {
    if previous.is_live() && !record.status.is_live() {
        return Some(Edge::Suspend);
    }
    if !previous.is_live() && record.status.is_live() {
        return Some(Edge::Connect);
    }
    // A read can report running while the resume still awaits acknowledgement: clearing its
    // overlay is a second live edge.
    if was_resuming && record.pending_change.is_none() && record.status.is_live() && !connected {
        return Some(Edge::Connect);
    }
    // A new machine is live while it provisions, but its daemon answers only once it runs.
    if matches!(previous, Status::Starting | Status::Provisioning)
        && record.status == Status::Running
        && !connected
    {
        return Some(Edge::Retry);
    }
    None
}

/// Who asked for a connect.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    User,
    Script,
}

/// Whether a pending change holds back a connect from `origin`: a person's app-link connect runs
/// through `starting`, which a passive typing wake reads too (cmux#34974); a pause, a delete and
/// every legacy link keep the strict hold.
pub fn holds_connect(machine: &Machine, origin: Origin, app_link: bool) -> bool {
    let shown = machine.shown_status();
    shown.is_changing() && !(origin == Origin::User && app_link && shown == Status::Starting)
}

/// The ids of the store's `machines` the account's list did not name (`listed`): made since,
/// kept for a pin (the plan's `stored`), never picked. Never one the server failed or is
/// removing, which may stay in the store after the list dropped it.
pub fn kept_for_pin(machines: &[Machine], listed: &[String]) -> Vec<String> {
    machines
        .iter()
        .filter(|machine| !listed.contains(&machine.id))
        .filter(|machine| {
            !matches!(machine.shown_status(), Status::Failed | Status::Destroyed | Status::Deleting)
        })
        .map(|machine| machine.id.clone())
        .collect()
}

/// This machine's entry in `cmux link start-chat plan`'s `machines` (cmux-tui
/// `link/start_chat_cli/pick.rs`): its id, title, shown status (so a change on its way shows)
/// and whether this app is connected to its daemon; its slug, maker and pause reason when known;
/// and `chats`, its chat tabs, which only a connected daemon can count.
pub fn start_chat_plan_entry(
    machine: &Machine,
    connected: bool,
    chats: Option<i64>,
) -> Map<String, Value> {
    let mut entry = Map::new();
    entry.insert("id".into(), json!(machine.id));
    entry.insert("title".into(), json!(machine.title()));
    entry.insert("status".into(), json!(machine.shown_status()));
    entry.insert("connected".into(), json!(connected));
    let optional = [
        ("slug", machine.slug.clone().map(Value::from)),
        ("created_by", machine.created_by.clone().map(Value::from)),
        ("pause_reason", machine.pause_reason.map(|reason| json!(reason))),
        ("chats", chats.map(Value::from)),
    ];
    for (key, value) in optional {
        if let Some(value) = value {
            entry.insert(key.into(), value);
        }
    }
    entry
}

/// The name a new machine gets when the person typed none: the first of `candidates` (the base
/// name, then the numbered names from 2) that no title in `taken` is. Titles compare trimmed
/// and case-insensitively, so a renamed "cloud machine" still counts. The app passes one
/// numbered name more than there are titles, so one is always free.
pub fn default_name(taken: &[String], candidates: &[String]) -> Option<String> {
    let used: Vec<String> = taken.iter().map(|title| title.trim().to_lowercase()).collect();
    candidates.iter().find(|candidate| !used.contains(&candidate.to_lowercase())).cloned()
}

#[cfg(test)]
mod tests;
