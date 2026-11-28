//! Lane death watch: a session on a peer that died tells the session that started it, once.
//!
//! Leo: "well we just need to move over to using our stuff. start feeling more nih syndrome
//! because we genuinley have good-ass shit." The fleet found dead lanes with a Python pass every
//! five minutes on one host (leo-workspace `tools/lane_deaths.py`), which read every host's
//! session list, decided which lanes were dead and sent their coordinator a line. Over the week
//! to 2026-11-26 it saw 23 deaths a median 63 minutes after they happened. Each daemon already
//! holds every peer's session rows live (`hub/remote_rows.rs`), and a lane names its starter in
//! its tags, so the starter's own daemon can see the death when the row changes and say so in
//! the starter's chat (`hub/lane_death_watch.rs`).
//!
//! This module is the pure part: whether a row reads dead ([`dead_why`]), who started it
//! ([`parent_of`]), the once-per-death memory ([`Watch`]) and the notice, which names the step
//! the product's recovery decision takes next ([`crate::death_route::route`]). Nothing here
//! reads the hub or a clock.
//!
//! Dead, as `lane_deaths.py` reads it (`lane_failover.is_dead`): the agent stopped
//! (`disconnected`), its turn failed (`failed`), it has been stuck past the grace
//! (`stuckSince`), or its machine has not answered past the grace (`unreachable`, a row
//! `peer_cache::mark_stale` marked). A closed row is never dead. A row that reads alive again
//! ends that death: a later one is told again.
//!
//! Restart intensity (RFD 0181 B8): the watch counts each session's deaths across deaths (a
//! death is a new `since`), over [`WINDOW_MS`]. The [`MAX_DEATHS`]th death in the window is
//! logged on every daemon; with `ACPMUX_RESTART_INTENSITY=1` its notice also tells the starter
//! to take the work over instead of restarting it (`death_route` `Ending::Intensity`).
//! The default comes from the fleet's own record (cmux-cp-1 `lane-deaths.jsonl`, 11-23 to
//! 11-26: 35 deaths of 19 lanes): 3 in 60 min catches the three lanes that looped (one died 8
//! times in 5 h 20 min of account 503s) and no lane that died twice; 2 would catch 5, and 5
//! in 60 min catches none.

use crate::death_route::{Facts, Route};
use serde_json::Value;
use std::collections::HashMap;

/// How long a stuck or unreachable row waits before it reads dead (`lane-deaths.json`
/// `unreachable_minutes`).
pub const GRACE_MS: u64 = 10 * 60 * 1000;
/// How long a machine that does not answer gets to come back before recovery routes its
/// sessions elsewhere (`death_route::Facts::host_grace_seconds`). Longer than [`GRACE_MS`]: a
/// row reads dead at 10 min, and its notice then asks for the machine to be started, not moved
/// off, until this has passed.
pub const HOST_GRACE_MS: u64 = 20 * 60 * 1000;
/// Restarts and successors recovery allows (`lane-deaths.json` `max_restarts`,
/// `max_failovers`).
pub const MAX_RESTARTS: u32 = 2;
pub const MAX_FAILOVERS: u32 = 2;
/// Restart intensity: deaths of one session within [`WINDOW_MS`] that hand it over (module docs).
pub const MAX_DEATHS: u32 = 3;
pub const WINDOW_MS: u64 = 60 * 60 * 1000;
/// The provenance kind of the notice.
pub const KIND: &str = "lane_death";

/// The tags that name who started a session, first found wins: the coordinator's parent tag,
/// the spawner, the lane's report target (`hub/lane_reports.rs`).
const PARENT_TAGS: [&str; 3] = ["mux.parent", "spawnedBy", "lane.reportsTo"];

/// Why a row reads dead and since when (ms since the epoch; 0 when the row does not say).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Dead {
    pub why: &'static str,
    pub since_ms: u64,
    /// Its machine does not answer (not the agent).
    pub host_down: bool,
}

/// A time a row carries, in ms: a number below 1e11 is seconds.
fn ms(v: &Value) -> Option<u64> {
    let n = v.as_u64().or_else(|| v.as_f64().map(|f| f as u64))?;
    (n > 0).then_some(if n < 100_000_000_000 { n * 1000 } else { n })
}

/// Whether `row` (a session summary) reads dead at `now_ms`, and why.
pub fn dead_why(row: &Value, now_ms: u64, grace_ms: u64) -> Option<Dead> {
    let status = row["status"].as_str().unwrap_or_default();
    if status == "closed" {
        return None;
    }
    let past = |since: u64| since > 0 && now_ms.saturating_sub(since) >= grace_ms;
    match status {
        "disconnected" => {
            let since = ms(&row["updatedAt"]).unwrap_or(0);
            return Some(Dead { why: "its agent stopped", since_ms: since, host_down: false });
        }
        "failed" => {
            let since = ms(&row["updatedAt"]).unwrap_or(0);
            return Some(Dead { why: "its turn failed", since_ms: since, host_down: false });
        }
        "unreachable" => {
            let since = ms(&row["lastSeen"]).unwrap_or(0);
            return past(since).then_some(Dead {
                why: "its machine does not answer",
                since_ms: since,
                host_down: true,
            });
        }
        _ => {}
    }
    let since = ms(&row["stuckSince"])?;
    past(since).then_some(Dead { why: "it is stuck", since_ms: since, host_down: false })
}

/// A tag's text: a string, or `{"value": string}`.
fn tag_text(v: &Value) -> Option<&str> {
    v.as_str().or_else(|| v["value"].as_str()).map(str::trim).filter(|s| !s.is_empty())
}

/// Who started `row`: its parent tags in order, else its `parentId`.
pub fn parent_of(row: &Value) -> Option<String> {
    let tags = &row["tags"];
    PARENT_TAGS
        .iter()
        .find_map(|t| tag_text(&tags[*t]))
        .or_else(|| tag_text(&row["parentId"]))
        .map(str::to_owned)
}

/// One death to tell.
#[derive(Debug, Clone, PartialEq)]
pub struct Notice {
    /// The row's key in this daemon's remote rows.
    pub key: String,
    pub name: String,
    pub host: String,
    /// Who started it, as its tag names it.
    pub parent: String,
    pub dead: Dead,
    /// What recovery does next (`death_route::route` over what the row says).
    pub route: Route,
    /// Its deaths within [`WINDOW_MS`], this one included.
    pub deaths: u32,
}

impl Notice {
    /// The prompt id: the same for every try of this death.
    pub fn prompt_id(&self) -> String {
        format!("lane-death-{}-{}", self.key, self.dead.since_ms)
    }

    /// The line the starter reads.
    pub fn text(&self, now_ms: u64) -> String {
        let at = format!("{}/{}", self.host, self.name);
        let ago = if self.dead.since_ms == 0 {
            String::new()
        } else {
            format!(" ({} min ago)", now_ms.saturating_sub(self.dead.since_ms) / 60_000)
        };
        format!(
            "[lane death] `{at}`, which you started, died: {}{ago}. Its work is yours until it \
is back. Recovery's next step: {}",
            self.dead.why,
            step_line(&self.route, &at),
        )
    }
}

/// One line for `route`, with the command that runs it.
pub fn step_line(route: &Route, at: &str) -> String {
    match route {
        Route::None => "nothing to do.".into(),
        Route::Wait { why } => format!("wait ({why})."),
        Route::Resume => format!("send it one resume prompt (`acpmux send {at} -`)."),
        Route::FinishMove { to } => format!("finish its move once it reads alive on {to}."),
        Route::Respawn { to, .. } if to.is_empty() => {
            "start it again from its briefs on a healthy host.".into()
        }
        Route::Respawn { to, .. } => format!("start it again from its briefs on {to}."),
        Route::StartHost => "start its machine again; it resumes in place.".into(),
        Route::Move { to, .. } => format!("`acpmux session move {at} --host {to}`."),
        Route::MoveFromCopy { to } => {
            format!("`acpmux session move {at} --from-snapshot --host {to}`.")
        }
        Route::Restart { number } => {
            format!("`acpmux session restart {at}` (restart {number} of {MAX_RESTARTS}).")
        }
        Route::Successor { number, .. } => {
            format!("start a successor (failover {number} of {MAX_FAILOVERS}).")
        }
        Route::Handoff { why, .. } => format!("hand its work over: {why}."),
    }
}

/// What recovery does next for a dead row, from what the row says (`death_route::Facts`; what
/// the row cannot say, such as which hosts have room, stays at its default). `host_grace_ms` is
/// how long a machine that does not answer gets to come back ([`HOST_GRACE_MS`]).
///
/// A row cannot say whether its machine can be started, so a machine that does not answer reads
/// as one: within the grace the starter is told to start it (`Route::StartHost`), the one step
/// that brings the lane back in place. With `host_startable` left false, `death_route` answered
/// `Route::None` there, and the notice said "nothing to do" for a machine that was down.
pub fn route_of(
    key: &str,
    host: &str,
    dead: &Dead,
    now_ms: u64,
    host_grace_ms: u64,
    deaths: u32,
    max_deaths: u32,
) -> Route {
    let dead_seconds =
        if dead.since_ms == 0 { 0.0 } else { now_ms.saturating_sub(dead.since_ms) as f64 / 1000.0 };
    crate::death_route::route(&Facts {
        key: key.into(),
        host: host.into(),
        has_row: true,
        host_down: dead.host_down,
        dead_seconds,
        host_grace_seconds: host_grace_ms as f64 / 1000.0,
        host_startable: dead.host_down,
        max_restarts: MAX_RESTARTS,
        max_failovers: MAX_FAILOVERS,
        deaths_in_window: deaths,
        max_deaths,
        window_seconds: WINDOW_MS as f64 / 1000.0,
        ..Facts::default()
    })
}

/// The deaths told so far: row key to the death's `since_ms`; and each row's deaths within
/// [`WINDOW_MS`], for restart intensity.
#[derive(Debug, Default)]
pub struct Watch {
    told: HashMap<String, u64>,
    /// Each row's deaths within the window: the death's `since_ms` (counted once) and when it
    /// counts from (`since_ms`, or when first read for a row that does not say).
    deaths: HashMap<String, Vec<(u64, u64)>>,
    /// Deaths in the window that hand a session over; 0 counts and logs only.
    max_deaths: u32,
}

impl Watch {
    /// A watch whose `max_deaths`th death in the window hands over (0: counts only).
    pub fn new(max_deaths: u32) -> Self {
        Self { max_deaths, ..Self::default() }
    }

    /// Counts the death `dead` of `key` once and answers its deaths within the window.
    fn count(&mut self, key: &str, dead: &Dead, now_ms: u64) -> u32 {
        let times = self.deaths.entry(key.to_owned()).or_default();
        if !times.iter().any(|(since, _)| *since == dead.since_ms) {
            let at = if dead.since_ms == 0 { now_ms } else { dead.since_ms };
            times.push((dead.since_ms, at));
        }
        times.iter().filter(|(_, at)| now_ms.saturating_sub(*at) < WINDOW_MS).count() as u32
    }

    /// One pass over `rows` (`(key, host, summary)`): a notice for each row that reads dead,
    /// names a starter `is_local` accepts and was not told for this death. A row that reads
    /// alive or is gone is forgotten, so its next death is told again. A host `idle_closed`
    /// names (its link closed because nothing used it) is not down: its rows read
    /// `unreachable` until the next use dials it, so they are not a dead machine.
    pub fn pass<'a>(
        &mut self,
        rows: impl IntoIterator<Item = (&'a str, &'a str, &'a Value)>,
        now_ms: u64,
        grace_ms: u64,
        mut is_local: impl FnMut(&str) -> bool,
        mut idle_closed: impl FnMut(&str) -> bool,
    ) -> Vec<Notice> {
        let mut seen = HashMap::new();
        let mut out = Vec::new();
        for (key, host, row) in rows {
            let Some(dead) = dead_why(row, now_ms, grace_ms) else { continue };
            if dead.host_down && idle_closed(host) {
                continue;
            }
            let Some(parent) = parent_of(row).filter(|p| is_local(p)) else { continue };
            seen.insert(key.to_owned(), dead.since_ms);
            let deaths = self.count(key, &dead, now_ms);
            if self.told.get(key) == Some(&dead.since_ms) {
                continue;
            }
            let name = row["name"].as_str().unwrap_or(key).to_owned();
            let route = route_of(key, host, &dead, now_ms, HOST_GRACE_MS, deaths, self.max_deaths);
            out.push(Notice {
                key: key.into(),
                name,
                host: host.into(),
                parent,
                dead,
                route,
                deaths,
            });
        }
        // What is still dead keeps its mark; a notice not yet sent is marked by `told`. A row
        // that lived again ends its death; its death times stay until they leave the window.
        self.told.retain(|k, _| seen.contains_key(k));
        self.deaths.retain(|_, v| {
            v.retain(|(_, at)| now_ms.saturating_sub(*at) < WINDOW_MS);
            !v.is_empty()
        });
        out
    }

    /// `notice` reached its starter: it is not told again for this death.
    pub fn told(&mut self, notice: &Notice) {
        self.told.insert(notice.key.clone(), notice.dead.since_ms);
    }
}

#[cfg(test)]
#[path = "lane_death_watch_tests.rs"]
mod tests;
