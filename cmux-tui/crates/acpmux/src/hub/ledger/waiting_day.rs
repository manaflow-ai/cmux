//! The waiting day (`_acpmux/waiting_day`): when each chat worked, waited on the person, or sat
//! idle, for the Home's "Waiting on me" lanes (wow idea 86; Leo, 2026-11-08: "go think of
//! things/look at things, esp valuable things that people would think \"wow this is awesome\"").
//!
//! Fed as records are appended, O(1) each: a `status` record
//! is a mark (`running` is working, `waiting` is blocked on an answer, every other status idle),
//! and `turn_started` names the turn the next marks belong to, so a blocked stretch opens the
//! chat at its turn. No log or transcript is read, ever.
//!
//! Bounded: marks older than [`RETAIN_MS`] are dropped (the last one before stays, so the state
//! at the window's start is known), each chat keeps at most [`MAX_MARKS`], and at most
//! [`MAX_LANES`] chats are kept (the one quiet longest goes first). Sub-sessions are left out:
//! the session above them answers them, not the person.
//!
//! Part of the cost ledger (`hub/ledger`), which feeds it from `Hub::append_record_locked`, drops
//! a purged chat's marks, and writes them whole to `<home>/ledger/waiting-day.json` when the daemon
//! seals its logs at shutdown; the next daemon reads it back. A stretch the old daemon left open
//! ends when it wrote the file. A daemon that dies without sealing loses the marks since its start.

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Mutex, PoisonError};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::store::EventRecord;

const HOUR_MS: u64 = 3_600_000;
/// How far back marks are kept, and the widest range a query reads: a day in any time zone.
pub(crate) const RETAIN_MS: u64 = 48 * HOUR_MS;
/// Marks kept per chat; a status change is a few per turn.
pub(crate) const MAX_MARKS: usize = 512;
/// Chats kept.
pub(crate) const MAX_LANES: usize = 1024;
/// Lanes one reply carries, most waiting first: 512 spans each stay far under the RPC frame limit.
/// The totals still count every chat.
pub(crate) const MAX_REPLY_LANES: usize = 200;
pub(crate) const FILE: &str = "waiting-day.json";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Working,
    Blocked,
    Idle,
}

impl State {
    /// The state a `status` record's status puts a chat in.
    fn of(status: &str) -> Option<Self> {
        match status {
            "running" => Some(Self::Working),
            "waiting" => Some(Self::Blocked),
            "idle" | "ready" | "disconnected" | "closed" => Some(Self::Idle),
            _ => None,
        }
    }
}

/// A chat entering a state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Mark {
    pub at: u64,
    pub state: State,
    /// The `status` record's seq in the chat's log.
    pub seq: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn: Option<String>,
}

#[derive(Debug, Default)]
struct Lane {
    marks: VecDeque<Mark>,
    /// The turn the last `turn_started` named.
    turn: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Saved {
    saved_at: u64,
    lanes: HashMap<String, Vec<Mark>>,
}

/// One stretch of work or of waiting, clipped to the query's range.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Span {
    pub state: State,
    pub start: u64,
    pub end: u64,
    pub seq: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LaneReply {
    pub session_id: String,
    pub working_ms: u64,
    pub blocked_ms: u64,
    /// When the chat last changed state.
    pub last_at: u64,
    pub spans: Vec<Span>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Reply {
    pub since: u64,
    pub until: u64,
    pub working_ms: u64,
    pub blocked_ms: u64,
    /// Chats that worked or waited in the range, most waiting first, then most recent.
    pub lanes: Vec<LaneReply>,
}

/// A query's range from `{since?, until?}` at `now`: until defaults to now and is never past it;
/// since defaults to a day before until and reaches back at most [`RETAIN_MS`].
pub fn range(params: &Value, now: u64) -> (u64, u64) {
    let until = params.get("until").and_then(Value::as_u64).unwrap_or(now).min(now);
    let floor = until.saturating_sub(RETAIN_MS);
    let since = params
        .get("since")
        .and_then(Value::as_u64)
        .unwrap_or(until.saturating_sub(24 * HOUR_MS))
        .clamp(floor, until);
    (since, until)
}

#[derive(Debug)]
pub struct WaitingDay {
    lanes: Mutex<HashMap<String, Lane>>,
    /// `<home>/waiting-day.json`; `None` keeps it in memory only (a memory store).
    path: Option<PathBuf>,
}

impl WaitingDay {
    /// Reads what the last daemon saved at `path`, closing the stretches it left open. The file
    /// is removed once read: the next save writes it again, so a chat deleted in between is never
    /// read back, even after a crash.
    pub fn open(path: Option<PathBuf>, now: u64) -> Self {
        let mut lanes = HashMap::new();
        let saved = path
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|bytes| serde_json::from_slice::<Saved>(&bytes).ok());
        if let Some(p) = &path
            && let Err(e) = std::fs::remove_file(p)
            && e.kind() != std::io::ErrorKind::NotFound
        {
            tracing::warn!("waiting day: remove {}: {e}", p.display());
        }
        if let Some(saved) = saved {
            for (id, marks) in saved.lanes {
                let mut lane = Lane { marks: marks.into(), turn: None };
                if let Some(last) = lane.marks.back()
                    && last.state != State::Idle
                {
                    let seq = last.seq;
                    let end = saved.saved_at.max(last.at);
                    lane.marks.push_back(Mark { at: end, state: State::Idle, seq, turn: None });
                }
                prune(&mut lane.marks, now);
                if !lane.marks.is_empty() {
                    lanes.insert(id, lane);
                }
            }
        }
        Self { lanes: Mutex::new(lanes), path }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Lane>> {
        self.lanes.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Observes one appended record of session `id`; only `status` and `turn_started` do anything.
    pub fn record(&self, id: &str, record: &EventRecord) {
        if record.dir != "mux" {
            return;
        }
        match record.kind.as_str() {
            "turn_started" => {
                let turn = record.msg.get("turnId").and_then(Value::as_str);
                if let Some(turn) = turn {
                    // A new chat's first turn starts before its first `running` status: the lane
                    // is made here, so that status and a wait in the turn carry the turn.
                    let mut lanes = self.lock();
                    let lane = lane_mut(&mut lanes, id);
                    lane.turn = Some(turn.to_owned());
                    // The turn's working mark came before its start record: it is this turn's.
                    if let Some(last) = lane.marks.back_mut()
                        && last.state == State::Working
                        && last.turn.is_none()
                    {
                        last.turn = Some(turn.to_owned());
                    }
                }
            }
            "status" => {
                let Some(state) =
                    record.msg.get("status").and_then(Value::as_str).and_then(State::of)
                else {
                    return;
                };
                self.mark(id, state, record.at, record.seq);
            }
            _ => {}
        }
    }

    fn mark(&self, id: &str, state: State, at: u64, seq: u64) {
        let mut lanes = self.lock();
        // A chat's first mark that is idle says nothing.
        if state == State::Idle && lanes.get(id).is_none_or(|l| l.marks.is_empty()) {
            return;
        }
        let lane = lane_mut(&mut lanes, id);
        if lane.marks.back().is_some_and(|m| m.state == state) {
            return;
        }
        let turn = match state {
            State::Idle => {
                lane.turn = None;
                None
            }
            _ => lane.turn.clone(),
        };
        lane.marks.push_back(Mark { at, state, seq, turn });
        while lane.marks.len() > MAX_MARKS {
            lane.marks.pop_front();
        }
        prune(&mut lane.marks, at);
    }

    /// Session `id` was deleted: its marks go with it.
    pub fn forget(&self, id: &str) {
        self.lock().remove(id);
    }

    /// Writes every chat's marks to the file, at shutdown.
    pub fn save(&self, now: u64) {
        let Some(path) = &self.path else { return };
        let saved = {
            let mut lanes = self.lock();
            lanes.retain(|_, lane| {
                prune(&mut lane.marks, now);
                !lane.marks.is_empty()
            });
            Saved {
                saved_at: now,
                lanes: lanes
                    .iter()
                    .map(|(k, l)| (k.clone(), l.marks.iter().cloned().collect()))
                    .collect(),
            }
        };
        let written = serde_json::to_vec(&saved).map_err(std::io::Error::other).and_then(|bytes| {
            let tmp = path.with_extension("json.tmp");
            std::fs::write(&tmp, bytes)?;
            std::fs::rename(&tmp, path)
        });
        if let Err(e) = written {
            tracing::warn!("waiting day: save {}: {e}", path.display());
        }
    }

    /// The `_acpmux/waiting_day` reply for `[since, until]`.
    pub fn query(&self, since: u64, until: u64) -> Reply {
        let lanes = self.lock();
        let mut reply = Reply { since, until, working_ms: 0, blocked_ms: 0, lanes: Vec::new() };
        for (id, lane) in lanes.iter() {
            let spans = spans(&lane.marks, since, until);
            if spans.is_empty() {
                continue;
            }
            let total = |state: State| -> u64 {
                spans.iter().filter(|s| s.state == state).map(|s| s.end - s.start).sum()
            };
            let working_ms = total(State::Working);
            let blocked_ms = total(State::Blocked);
            reply.working_ms += working_ms;
            reply.blocked_ms += blocked_ms;
            reply.lanes.push(LaneReply {
                session_id: id.clone(),
                working_ms,
                blocked_ms,
                last_at: lane.marks.back().map_or(0, |m| m.at),
                spans,
            });
        }
        reply.lanes.sort_by(|a, b| {
            b.blocked_ms
                .cmp(&a.blocked_ms)
                .then(b.last_at.cmp(&a.last_at))
                .then(a.session_id.cmp(&b.session_id))
        });
        reply.lanes.truncate(MAX_REPLY_LANES);
        reply
    }
}

/// Session `id`'s lane, made when it has none; past [`MAX_LANES`] the chat quiet longest goes.
fn lane_mut<'a>(lanes: &'a mut HashMap<String, Lane>, id: &str) -> &'a mut Lane {
    if !lanes.contains_key(id) && lanes.len() >= MAX_LANES {
        let quietest = lanes
            .iter()
            .min_by_key(|(_, l)| l.marks.back().map_or(0, |m| m.at))
            .map(|(k, _)| k.clone());
        if let Some(k) = quietest {
            lanes.remove(&k);
        }
    }
    lanes.entry(id.to_owned()).or_default()
}

/// Drops marks older than [`RETAIN_MS`] before `now`, keeping the last one before the cut.
fn prune(marks: &mut VecDeque<Mark>, now: u64) {
    let cut = now.saturating_sub(RETAIN_MS);
    while marks.len() > 1 && marks[1].at <= cut {
        marks.pop_front();
    }
    // A lone old idle mark says nothing any more.
    if marks.len() == 1 && marks[0].at <= cut && marks[0].state == State::Idle {
        marks.clear();
    }
}

/// The working and blocked stretches of `marks`, clipped to `[since, until]`.
fn spans(marks: &VecDeque<Mark>, since: u64, until: u64) -> Vec<Span> {
    let mut out = Vec::new();
    for (i, mark) in marks.iter().enumerate() {
        if mark.state == State::Idle {
            continue;
        }
        let end = marks.get(i + 1).map_or(until, |next| next.at).min(until);
        let start = mark.at.max(since);
        if end <= start {
            continue;
        }
        out.push(Span { state: mark.state, start, end, seq: mark.seq, turn_id: mark.turn.clone() });
    }
    out
}

#[cfg(test)]
#[path = "waiting_day_tests.rs"]
mod tests;
