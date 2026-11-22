//! The follower's data, in the shapes the app's Codable types and its saved list use: a time is
//! seconds since 2001-01-01 (Swift's `JSONEncoder` default for a `Date`), a card is the base64 of
//! its JSON (the default for `Data`), and an absent optional is left out.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Seconds since 2001-01-01 00:00 UTC.
pub type Time = f64;

/// A task this app handed off (a sandboxed Run, or a hand-off), as it is kept across a relaunch.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub id: String,
    /// The task as the person wrote it (a hand-off's summary).
    pub task: String,
    /// The page's attempt key (a hand-off's chat).
    pub key: String,
    /// The signed-in user that created it: only that user's session may read it.
    pub user: String,
    /// The team the create went to; the waits go there too.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub team: Option<String>,
    pub started: Time,
    /// The source's position after the last wait (a hand-off's version).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<i64>,
    /// The notice keys already told, newest last, at most [`crate::follower::TOLD_LIMIT`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub told: Option<Vec<String>>,
    /// When it last changed; its age counts from here (none: from `started`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changed: Option<Time>,
    /// Its current turn runs (`Some(true)`, never `Some(false)`): not given up for age since it
    /// changed, only for that long without an answer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub running: Option<bool>,
    /// The acpmux host of a hand-off's chat, when this app made it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    /// Sent from an incognito window's chat: never saved, and its banner names nothing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub incognito: Option<bool>,
}

impl Record {
    pub fn is_incognito(&self) -> bool {
        self.incognito == Some(true)
    }
}

/// How a task ended, or what a hand-off's turn tells (`needsYou` is no end).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Outcome {
    Succeeded,
    Failed,
    TimedOut,
    Cancelled,
    NeedsYou,
}

/// Something to tell about a task that goes on, once per `key` (a hand-off's `"2:done"`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Notice {
    pub key: String,
    pub outcome: Outcome,
}

/// A task that ended here, kept for [`crate::follower::KEPT_ENDED`] so a late follow never tells
/// it again and its banner's click still finds its card.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Ended {
    pub record: Record,
    pub outcome: Outcome,
    /// The base64 of `{"receipt": …}`, the final snapshot's receipt; none when it had none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub card: Option<String>,
    pub at: Time,
    /// Its end was told, or is never to be told; one saved untold is told at the next launch.
    pub told: bool,
}

/// Everything the follower knows. The app holds it between calls and sends it with each event.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct State {
    /// The tasks in flight, oldest `started` first.
    #[serde(default)]
    pub records: Vec<Record>,
    /// The tasks that ended here, newest last.
    #[serde(default)]
    pub ended: Vec<Ended>,
    /// The Runs this app asked to cancel, newest last, at most [`crate::follower::CANCEL_LIMIT`].
    #[serde(default)]
    pub cancelled: Vec<String>,
    /// Incognito tasks that may still be open, newest last (ids only). Never evicted for count.
    #[serde(default)]
    pub incognito: Vec<String>,
    /// The account of each id in `incognito` (none: saved before owners were kept).
    #[serde(default)]
    pub incognito_owners: BTreeMap<String, String>,
    /// The signed-in user (none: none, or the session still loading).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
}

impl State {
    pub fn record(&self, id: &str) -> Option<&Record> {
        self.records.iter().find(|record| record.id == id)
    }

    pub fn record_mut(&mut self, id: &str) -> Option<&mut Record> {
        self.records.iter_mut().find(|record| record.id == id)
    }

    /// Takes record `id` out of the tasks in flight.
    pub fn remove_record(&mut self, id: &str) -> Option<Record> {
        let index = self.records.iter().position(|record| record.id == id)?;
        Some(self.records.remove(index))
    }

    /// Keeps `record` in `started` order, after every record that started no later.
    pub fn insert_record(&mut self, record: Record) {
        let index = self.records.partition_point(|kept| kept.started <= record.started);
        self.records.insert(index, record);
    }

    /// The task `id` that ended here, if still kept.
    pub fn ended_run(&self, id: &str) -> Option<&Ended> {
        self.ended.iter().rev().find(|ended| ended.record.id == id)
    }

    /// Whether task `id` is followed now or ended here (still kept).
    pub fn knows(&self, id: &str) -> bool {
        self.record(id).is_some() || self.ended_run(id).is_some()
    }
}

/// The saved list (UserDefaults `cmux.next.sandboxRuns.following`, `cmux.next.handoffs.following`),
/// with the field names the app has always written.
#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Saved {
    following: Vec<Record>,
    ended: Vec<Ended>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    cancelled: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    incognito: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    incognito_owners: Option<BTreeMap<String, String>>,
}

/// The state a launch starts from: the saved list, or nothing when there is none or it does not
/// read. A record saved twice keeps its first copy.
pub fn load(saved: Option<&str>) -> State {
    let Some(saved) = saved.and_then(|text| serde_json::from_str::<Saved>(text).ok()) else {
        return State::default();
    };
    let mut state = State {
        ended: saved.ended,
        cancelled: saved.cancelled.unwrap_or_default(),
        incognito: saved.incognito.unwrap_or_default(),
        incognito_owners: saved.incognito_owners.unwrap_or_default(),
        ..State::default()
    };
    for record in saved.following {
        if state.record(&record.id).is_none() {
            state.insert_record(record);
        }
    }
    state
}

/// The saved list of `state`. Nothing of an incognito chat's tasks outlives this run (leo-workspace
/// design/spaces.md "Incognito"): only their bare ids, while they may be open.
pub fn saved(state: &State) -> String {
    let saved = Saved {
        following: state.records.iter().filter(|record| !record.is_incognito()).cloned().collect(),
        ended: state.ended.iter().filter(|ended| !ended.record.is_incognito()).cloned().collect(),
        cancelled: Some(state.cancelled.clone()),
        incognito: Some(state.incognito.clone()),
        incognito_owners: Some(state.incognito_owners.clone()),
    };
    serde_json::to_string(&saved).unwrap_or_default()
}
