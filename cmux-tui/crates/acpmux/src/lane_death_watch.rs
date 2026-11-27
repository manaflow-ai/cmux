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
pub fn route_of(key: &str, host: &str, dead: &Dead, now_ms: u64, host_grace_ms: u64) -> Route {
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
        ..Facts::default()
    })
}

/// The deaths told so far: row key to the death's `since_ms`.
#[derive(Debug, Default)]
pub struct Watch {
    told: HashMap<String, u64>,
}

impl Watch {
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
            if self.told.get(key) == Some(&dead.since_ms) {
                continue;
            }
            let name = row["name"].as_str().unwrap_or(key).to_owned();
            let route = route_of(key, host, &dead, now_ms, HOST_GRACE_MS);
            out.push(Notice { key: key.into(), name, host: host.into(), parent, dead, route });
        }
        // What is still dead keeps its mark; a notice not yet sent is marked by `told`.
        self.told.retain(|k, _| seen.contains_key(k));
        out
    }

    /// `notice` reached its starter: it is not told again for this death.
    pub fn told(&mut self, notice: &Notice) {
        self.told.insert(notice.key.clone(), notice.dead.since_ms);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const NOW: u64 = 1_800_000_000_000;
    const MIN: u64 = 60_000;

    #[test]
    fn dead_reads_like_lane_deaths() {
        let gone = json!({"status": "disconnected", "updatedAt": NOW - MIN});
        assert_eq!(dead_why(&gone, NOW, GRACE_MS).unwrap().why, "its agent stopped");
        assert!(dead_why(&json!({"status": "failed"}), NOW, GRACE_MS).is_some());
        assert!(dead_why(&json!({"status": "closed", "stuckSince": 1}), NOW, GRACE_MS).is_none());
        assert!(dead_why(&json!({"status": "idle"}), NOW, GRACE_MS).is_none());
        // Unreachable and stuck wait out the grace; seconds read as seconds.
        let away = |ago| json!({"status": "unreachable", "lastSeen": NOW - ago});
        assert!(dead_why(&away(5 * MIN), NOW, GRACE_MS).is_none());
        let d = dead_why(&away(11 * MIN), NOW, GRACE_MS).unwrap();
        assert!(d.host_down);
        let stuck = json!({"status": "running", "stuckSince": (NOW - 12 * MIN) / 1000});
        assert_eq!(dead_why(&stuck, NOW, GRACE_MS).unwrap().why, "it is stuck");
        assert!(dead_why(&json!({"status": "unreachable"}), NOW, GRACE_MS).is_none());
    }

    #[test]
    fn parent_is_the_first_tag_then_parent_id() {
        let row = json!({"tags": {"spawnedBy": {"value": "coord"}, "lane.reportsTo": "x"}});
        assert_eq!(parent_of(&row).as_deref(), Some("coord"));
        let row = json!({"tags": {"mux.parent": " ", "lane.reportsTo": "lead"}});
        assert_eq!(parent_of(&row).as_deref(), Some("lead"));
        assert_eq!(parent_of(&json!({"parentId": "p1"})).as_deref(), Some("p1"));
        assert_eq!(parent_of(&json!({"tags": {}})), None);
    }

    #[test]
    fn a_death_is_told_once_and_again_after_it_lived() {
        let dead = json!({"name": "lane-a", "status": "disconnected", "updatedAt": NOW - MIN,
                          "tags": {"spawnedBy": "coord"}});
        let alive = json!({"name": "lane-a", "status": "idle", "tags": {"spawnedBy": "coord"}});
        let mut w = Watch::default();
        let n = w.pass([("k", "vm-1", &dead)], NOW, GRACE_MS, |p| p == "coord", |_| false);
        assert_eq!(n.len(), 1);
        assert_eq!(n[0].route, Route::Restart { number: 1 });
        assert!(n[0].text(NOW).contains("`acpmux session restart vm-1/lane-a`"));
        // Not sent: told again next pass. Sent: quiet.
        assert_eq!(w.pass([("k", "vm-1", &dead)], NOW, GRACE_MS, |_| true, |_| false).len(), 1);
        w.told(&n[0]);
        assert!(w.pass([("k", "vm-1", &dead)], NOW, GRACE_MS, |_| true, |_| false).is_empty());
        // Alive, then dead again: a new death.
        assert!(w.pass([("k", "vm-1", &alive)], NOW, GRACE_MS, |_| true, |_| false).is_empty());
        assert_eq!(w.pass([("k", "vm-1", &dead)], NOW, GRACE_MS, |_| true, |_| false).len(), 1);
    }

    #[test]
    fn a_starter_on_another_machine_is_not_told_here() {
        let dead = json!({"status": "failed", "tags": {"spawnedBy": "elsewhere"}});
        let mut w = Watch::default();
        assert!(
            w.pass([("k", "vm-1", &dead)], NOW, GRACE_MS, |p| p == "coord", |_| false).is_empty()
        );
        let orphan = json!({"status": "failed"});
        assert!(w.pass([("k", "vm-1", &orphan)], NOW, GRACE_MS, |_| true, |_| false).is_empty());
    }

    /// A link this daemon closed because nothing used it (`peer_demand.rs` `idle_ended`) leaves
    /// the peer's rows `unreachable` until the next use dials it again. That machine is fine:
    /// its lanes are not told dead, ten minutes after every idle close (chief-subagents-2,
    /// 2026-11-27: six false deaths in four hours). A real outage, and a lane that died before
    /// the link went idle, are still told.
    #[test]
    fn an_idle_closed_link_is_not_a_dead_machine() {
        let away = json!({"name": "lane-a", "status": "unreachable", "lastSeen": NOW - 11 * MIN,
                          "tags": {"spawnedBy": "coord"}});
        let failed = json!({"name": "lane-b", "status": "failed", "tags": {"spawnedBy": "coord"}});
        let mut w = Watch::default();
        let idle = |h: &str| h == "vm-1";
        assert!(w.pass([("k", "vm-1", &away)], NOW, GRACE_MS, |_| true, idle).is_empty());
        assert_eq!(w.pass([("k2", "vm-1", &failed)], NOW, GRACE_MS, |_| true, idle).len(), 1);
        // The same row on a machine whose link dropped on its own is a dead machine.
        assert_eq!(w.pass([("k", "vm-2", &away)], NOW, GRACE_MS, |_| true, idle).len(), 1);
    }

    #[test]
    fn a_machine_down_within_the_grace_waits_without_known_startability() {
        let dead =
            Dead { why: "its machine does not answer", since_ms: NOW - 11 * MIN, host_down: true };
        // Past the 10 min watch grace but within the 20 min host grace recovery uses.
        let r = route_of("k", "vm-1", &dead, NOW, 20 * MIN);
        // A row does not say whether its host can be started; recovery supplies that fact.
        assert_eq!(r, Route::None);
    }
}
