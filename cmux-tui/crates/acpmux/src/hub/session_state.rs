//! A session's one state of four: working, waiting, done or errored. Never unknown.
//!
//! Leo, 2026-11-27: "if things are unreachable, they're waiting or they're working or they're
//! done or they're errored and may or may not need to be continued", and "that goes for
//! everybody". A row's `status` keeps the daemon's own words (`idle`, `ready`, `running`,
//! `waiting`, `disconnected`, `closed`, and `unreachable` for a peer's last-known row,
//! `peer_cache::mark_stale`) for older clients; [`of_row`] reads them, with the facts the row
//! already holds, into one of the four, written as the summary's `sessionState`
//! (`views::decide`) and read by `acpmux ls` and the sidebar.
//!
//! - working: a turn runs (or acpmux goes on by itself: a capacity hold, subagents, commands).
//! - waiting: on what (`on`) and until when (`until`, ms, when known): the person (a
//!   permission, a question, the next prompt) or, for a host that stopped answering less than
//!   [`HOST_GRACE_MS`] ago, the host coming back.
//! - done: closed; its log is kept and the lifecycle archives it (`hub/session_lifecycle.rs`).
//! - errored: needs a decision (`decision`): continue it elsewhere, or drop it. A failed or
//!   lost turn, an agent that stopped, a host gone past the grace with work unfinished.
//!
//! An unreachable host's rows resolve from what this daemon holds outside that host: the
//! last-known row (its last turn, pending asks, `lastSeen`). The fleet's death pass
//! (leo-workspace `tools/lane_deaths.py`) then continues errored lanes on a healthy host or marks
//! them done from PRs, branches and the lease and goal ledgers. Pure: no hub, no clock.

use serde_json::{Value, json};

/// How long a host may not answer before its unfinished sessions read errored, not waiting
/// (Leo's brief: "When a host has been unreachable for 15 minutes or more ...").
pub const HOST_GRACE_MS: u64 = 15 * 60 * 1000;

/// The four states.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Working,
    Waiting,
    Done,
    Errored,
}

impl State {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Working => "working",
            Self::Waiting => "waiting",
            Self::Done => "done",
            Self::Errored => "errored",
        }
    }
}

/// A row's state with what it waits on, until when, and the decision an errored one needs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Resolved {
    pub state: State,
    /// Waiting: on what. Errored: why.
    pub on: String,
    /// Waiting: until when (ms), when known.
    pub until: Option<u64>,
}

impl Resolved {
    fn new(state: State, on: impl Into<String>) -> Self {
        Self { state, on: on.into(), until: None }
    }

    /// The summary's `sessionState`.
    pub fn to_json(&self) -> Value {
        let decision = (self.state == State::Errored).then_some("continue elsewhere or drop");
        json!({"state": self.state.as_str(), "on": self.on, "until": self.until,
               "decision": decision})
    }

    /// One cell: `waiting: permission`, `errored: its agent stopped`, `working`.
    #[allow(dead_code)] // a one-cell form kept for its listing callers; none reads it today
    pub fn short(&self) -> String {
        match self.state {
            State::Working | State::Done => self.state.as_str().to_owned(),
            _ => format!("{}: {}", self.state.as_str(), self.on),
        }
    }
}

fn ms(v: &Value) -> Option<u64> {
    let n = v.as_u64().or_else(|| v.as_f64().map(|f| f as u64))?;
    (n > 0).then_some(if n < 100_000_000_000 { n * 1000 } else { n })
}

/// Whether the row is a last-known one from a host that does not answer.
pub fn host_unreachable(row: &Value) -> bool {
    row["status"] == "unreachable"
        || row["stale"] == true
        || row["peerState"].as_str().is_some_and(|s| !matches!(s, "connected" | "degraded" | ""))
}

/// What the person's open ask is, from the row's own words.
fn ask(row: &Value) -> Option<String> {
    let pending = row["pendingPermissions"].as_u64().unwrap_or(0);
    if let Some(on) = row["waitingOn"].as_str().filter(|s| !s.is_empty()) {
        return Some(on.to_owned());
    }
    if pending > 0 || row["status"] == "waiting" {
        return Some("permission".into());
    }
    (row["subsessionsWaiting"].as_u64().unwrap_or(0) > 0).then(|| "a sub-session's ask".into())
}

/// The row's state at `now_ms` (`paused` names a host the fleet registry means to be down).
pub fn of_row(row: &Value, now_ms: u64, paused: Option<&str>) -> Resolved {
    let status = row["status"].as_str().unwrap_or_default();
    if status == "closed" {
        return Resolved::new(State::Done, "closed");
    }
    let indicator = super::views::status_indicator(row);
    if host_unreachable(row) {
        let host = row["peer"].as_str().unwrap_or("its host");
        if let Some(why) = paused {
            return Resolved::new(State::Waiting, format!("{host} {why}"));
        }
        let seen = ms(&row["lastSeen"]).or_else(|| ms(&row["asOfMs"]));
        let gone = seen.map(|s| now_ms.saturating_sub(s));
        // A host that just went quiet: its sessions wait on it, until the grace ends.
        if gone.is_none_or(|g| g < HOST_GRACE_MS) {
            let mut r = Resolved::new(State::Waiting, format!("{host} answering"));
            r.until = seen.map(|s| s + HOST_GRACE_MS);
            return r;
        }
        // Past the grace: an answered, idle chat still only waits on the person (its last
        // reply is in the mirror); anything mid-turn or unanswered needs a decision.
        let mid = !row["turn"].is_null() || matches!(indicator, Some("lost" | "failed"));
        if !mid && ask(row).is_none() {
            return Resolved::new(State::Waiting, format!("a prompt (its host {host} is down)"));
        }
        return Resolved::new(State::Errored, format!("its host {host} does not answer"));
    }
    if let Some(on) = ask(row) {
        return Resolved::new(State::Waiting, on);
    }
    match indicator {
        Some("working") => return Resolved::new(State::Working, "a turn"),
        Some("failed") => return Resolved::new(State::Errored, "its turn failed"),
        Some("lost") => return Resolved::new(State::Errored, "its turn was lost"),
        _ => {}
    }
    if status == "disconnected" {
        return Resolved::new(State::Errored, "its agent stopped");
    }
    if status == "running" {
        return Resolved::new(State::Working, "a turn");
    }
    Resolved::new(State::Waiting, "a prompt")
}

/// The summary's `sessionState` member, set at `now_ms`.
pub fn set(summary: &mut Value, now_ms: u64) {
    if !summary.is_object() {
        return;
    }
    let state = of_row(summary, now_ms, None).to_json();
    summary["sessionState"] = state;
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_800_000_000_000;
    const MIN: u64 = 60_000;

    fn st(row: Value) -> &'static str {
        of_row(&row, NOW, None).state.as_str()
    }

    #[test]
    fn every_status_reads_one_of_four() {
        for status in [
            "idle",
            "ready",
            "running",
            "waiting",
            "disconnected",
            "closed",
            "unreachable",
            "failed",
            "",
            "something-new",
        ] {
            let s = st(json!({"status": status, "lastSeen": NOW - 30 * MIN}));
            assert!(["working", "waiting", "done", "errored"].contains(&s), "{status}: {s}");
        }
    }

    #[test]
    fn local_rows() {
        assert_eq!(st(json!({"status": "running", "turn": {"startedAt": 1}})), "working");
        assert_eq!(st(json!({"status": "idle"})), "waiting");
        assert_eq!(st(json!({"status": "ready", "lastTurn": {"status": "completed"}})), "waiting");
        assert_eq!(st(json!({"status": "closed"})), "done");
        assert_eq!(st(json!({"status": "disconnected"})), "errored");
        assert_eq!(st(json!({"status": "ready", "lastTurn": {"status": "failed"}})), "errored");
        let w = of_row(&json!({"status": "waiting", "waitingOn": "question"}), NOW, None);
        assert_eq!((w.state, w.on.as_str()), (State::Waiting, "question"));
    }

    #[test]
    fn unreachable_waits_then_resolves() {
        let row = |ago: u64, turn: Value| {
            json!({"status": "unreachable", "stale": true, "peer": "h", "lastSeen": NOW - ago,
                   "turn": turn, "lastTurn": {"status": "completed"}})
        };
        let fresh = of_row(&row(5 * MIN, Value::Null), NOW, None);
        assert_eq!(fresh.state, State::Waiting);
        assert_eq!(fresh.until, Some(NOW - 5 * MIN + HOST_GRACE_MS));
        assert_eq!(st(row(20 * MIN, Value::Null)), "waiting", "answered: waits on the person");
        assert_eq!(st(row(20 * MIN, json!({"startedAt": 1}))), "errored", "mid-turn");
        let paused = of_row(&row(20 * MIN, json!({"startedAt": 1})), NOW, Some("retired"));
        assert_eq!(paused.state, State::Waiting);
        // No lastSeen at all: waits on the host, never unknown.
        assert_eq!(st(json!({"status": "unreachable"})), "waiting");
    }

    #[test]
    fn json_names_the_decision() {
        let mut row = json!({"status": "disconnected"});
        set(&mut row, NOW);
        assert_eq!(row["sessionState"]["state"], "errored");
        assert_eq!(row["sessionState"]["decision"], "continue elsewhere or drop");
    }
}
