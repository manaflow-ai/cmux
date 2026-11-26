//! The per-lane fan-out cap: an agent's lane may not hold more than N live
//! descendant sessions on this host.
//!
//! Leo (2026-11-25): "**Cap fan-out per lane**, starting with the 209 live
//! sessions under competitive-beyond-dictator."
//!
//! - A lane is the tree under one root session. A session's parent is its
//!   `lineage.parent`, else its sub-session parent (`subsession.started_by`),
//!   else the agent session that created it (`createdBy`, which also covers a
//!   fork an agent made, which lineage leaves a root). The walk up stops at a
//!   session with no parent or at a parent this host does not hold (a peer's
//!   session): that id is the lane.
//! - The cap counts the lane's live sessions here (`admission::is_live`) but
//!   its root, plus the creates admitted for the lane and not yet running.
//!   Counting and reserving are one step under the admission lock, so
//!   concurrent starts never pass it.
//! - Only an agent's create is capped: one whose connection proved it runs in
//!   a session (`acpmux new` in an agent's shell, a fork it asks for), or a
//!   `start_session` tool call. A person, the app and a script outside a chat
//!   are never refused.
//! - The limit: `ACPMUX_MAX_LANE_SESSIONS`, else the setting
//!   `agents.subsessions.maxLaneSessions`, else [`DEFAULT_MAX`]; at most
//!   [`CEILING`]. A forced create (`acpmux new --force-admit`) goes past it
//!   with a warning.

use super::admission::Making;
use super::*;
use crate::store::CreatorKind;
use cmux_json::JsonSet as _;
use std::collections::HashSet;

/// The refusal's `data.reason`.
pub(crate) const REASON: &str = "lane.fanout_cap";
pub(crate) const SETTING: &str = "agents.subsessions.maxLaneSessions";
pub(crate) const ENV: &str = "ACPMUX_MAX_LANE_SESSIONS";
pub(crate) const DEFAULT_MAX: u32 = 32;
pub(crate) const CEILING: u32 = 1000;
/// A link loop (a moved chat whose parent id came back) ends the walk here.
const MAX_WALK: usize = 1024;

/// The session `m`'s parent for the lane walk (module docs).
pub(crate) fn parent_of(m: &SessionMeta) -> Option<String> {
    if let Some(l) = &m.lineage {
        return Some(l.parent.clone());
    }
    if let Some(s) = &m.subsession {
        return Some(s.started_by.clone());
    }
    m.created_by
        .as_ref()
        .filter(|c| c.kind == CreatorKind::Agent)
        .and_then(|c| c.session.clone())
        .filter(|p| p != &m.id)
}

/// The lane `id` belongs to: the top of its parent walk in `links`.
pub(crate) fn lane_of(links: &HashMap<String, Option<String>>, id: &str) -> String {
    let mut at = id.to_owned();
    for _ in 0..MAX_WALK {
        match links.get(&at) {
            Some(Some(parent)) if parent != &at => at = parent.clone(),
            _ => break,
        }
    }
    at
}

/// The limit in force: env, then setting, then default; within 1..=CEILING.
pub(crate) fn max_from(env: Option<&str>, setting: Option<u32>) -> (u32, &'static str) {
    if let Some(n) = env.and_then(|v| v.trim().parse::<u32>().ok()) {
        return (n.clamp(1, CEILING), "env");
    }
    if let Some(n) = setting {
        return (n.clamp(1, CEILING), "settings");
    }
    (DEFAULT_MAX, "default")
}

fn max() -> (u32, &'static str) {
    max_from(std::env::var(ENV).ok().as_deref(), super::subsessions::setting_u32(SETTING, CEILING))
}

/// One session as the count reads it.
pub(crate) struct Row {
    pub id: String,
    pub parent: Option<String>,
    pub live: bool,
}

/// The live sessions in `lane` but its root, plus the open admissions for it
/// whose session is not one of them.
pub(crate) fn count(rows: &[Row], open: &[Arc<Making>], lane: &str) -> usize {
    let links: HashMap<String, Option<String>> =
        rows.iter().map(|r| (r.id.clone(), r.parent.clone())).collect();
    let live: HashSet<&str> = rows
        .iter()
        .filter(|r| r.live && r.id != lane && lane_of(&links, &r.id) == lane)
        .map(|r| r.id.as_str())
        .collect();
    live.len()
        + open
            .iter()
            .filter(|m| m.lane() == Some(lane))
            .filter(|m| m.made_id().is_none_or(|id| !live.contains(id)))
            .count()
}

/// The refusal text: the reason, the next step and the override.
pub(crate) fn refusal(lane: &str, live: usize, max: u32, source: &str) -> RpcError {
    let message = format!(
        "new session refused: lane fan-out cap reached. Lane {lane} already has {live} live sessions under it on this host (cap {max}, source: {source}). Next: close or hibernate the lane's idle sessions (acpmux close/hibernate), do the work in this session, or use your harness's own subagents. Override: acpmux new --force-admit, or raise {SETTING} (or {ENV})."
    );
    let data = json!({"lane": lane, "live": live, "max": max, "source": source});
    super::subsession_guard::refusal(REASON, message, data)
}

/// The warning a forced create past the cap carries.
pub(crate) fn forced_warning(lane: &str, live: usize, max: u32) -> String {
    format!(
        "lane {lane} is past its fan-out cap ({live} live, cap {max}); started because it was forced."
    )
}

/// What the admission learned about the caller's lane.
pub(crate) struct Lane {
    pub id: String,
    pub live: usize,
    pub max: u32,
    pub source: &'static str,
}

impl Lane {
    pub(crate) fn over(&self) -> bool {
        self.live >= self.max as usize
    }
}

impl Hub {
    /// The lane `caller` runs in and its count, read under the admission lock (`open`).
    pub(super) fn lane_fanout(
        &self,
        caller: &str,
        open: &[Arc<Making>],
        hosted: &HashSet<String>,
    ) -> Lane {
        let sessions: Vec<Arc<Session>> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        let rows: Vec<Row> = sessions
            .iter()
            .map(|s| {
                let (parent, status) = s.read_meta(|m| (parent_of(m), m.status));
                Row {
                    id: s.id.clone(),
                    parent,
                    live: super::admission::is_live(status, hosted.contains(&s.id)),
                }
            })
            .collect();
        let links: HashMap<String, Option<String>> =
            rows.iter().map(|r| (r.id.clone(), r.parent.clone())).collect();
        let id = lane_of(&links, caller);
        let (max, source) = max();
        let live = count(&rows, open, &id);
        Lane { id, live, max, source }
    }
}

/// The warning JSON with `text` added to any warning already there.
pub(crate) fn add_warning(warning: Option<Value>, text: &str, lane: &Lane) -> Value {
    let mut warning = warning.unwrap_or_else(|| json!({}));
    let combined = match warning.get("warning").and_then(Value::as_str) {
        Some(other) => format!("{other} {text}"),
        None => text.to_owned(),
    };
    warning.set("warning", json!(combined));
    warning.set("laneFanout", json!({"lane": lane.id, "live": lane.live, "max": lane.max}));
    warning
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, parent: Option<&str>, live: bool) -> Row {
        Row { id: id.into(), parent: parent.map(Into::into), live }
    }

    fn links(rows: &[Row]) -> HashMap<String, Option<String>> {
        rows.iter().map(|r| (r.id.clone(), r.parent.clone())).collect()
    }

    #[test]
    fn a_lane_is_the_top_of_the_walk_or_a_parent_held_elsewhere() {
        let rows =
            [row("root", None, true), row("a", Some("root"), true), row("b", Some("a"), true)];
        assert_eq!(lane_of(&links(&rows), "b"), "root");
        assert_eq!(lane_of(&links(&rows), "root"), "root");
        let remote = [row("x", Some("peer-session"), true), row("y", Some("x"), true)];
        assert_eq!(lane_of(&links(&remote), "y"), "peer-session");
        let looped = [row("p", Some("q"), true), row("q", Some("p"), true)];
        let _ = lane_of(&links(&looped), "p"); // ends
    }

    #[test]
    fn the_count_is_the_lanes_live_descendants_and_its_open_creates() {
        let rows = [
            row("root", None, true),
            row("a", Some("root"), true),
            row("b", Some("a"), true),
            row("c", Some("a"), false),
            row("other", None, true),
            row("d", Some("other"), true),
        ];
        assert_eq!(count(&rows, &[], "root"), 2, "root itself and the closed one do not count");
        let open = Making::for_lane(Some("root".into()));
        let made = Making::for_lane(Some("root".into()));
        made.set_made("b");
        let elsewhere = Making::for_lane(Some("other".into()));
        let open = [Arc::new(open), Arc::new(made), Arc::new(elsewhere)];
        assert_eq!(
            count(&rows, &open, "root"),
            3,
            "a create is counted once, as its session once it runs"
        );
    }

    #[test]
    fn the_limit_reads_env_then_settings_within_the_ceiling() {
        assert_eq!(max_from(None, None), (DEFAULT_MAX, "default"));
        assert_eq!(max_from(None, Some(5)), (5, "settings"));
        assert_eq!(max_from(Some("7"), Some(5)), (7, "env"));
        assert_eq!(max_from(Some("0"), None), (1, "env"));
        assert_eq!(max_from(Some("99999"), None), (CEILING, "env"));
        assert_eq!(max_from(Some("nope"), Some(5)), (5, "settings"));
    }

    #[test]
    fn the_refusal_names_reason_next_step_and_override() {
        let e = refusal("root", 32, 32, "default");
        let text = format!("{e:?}");
        assert!(text.contains(REASON));
        assert!(text.contains("close or hibernate"));
        assert!(text.contains("--force-admit"));
        assert!(Lane { id: "r".into(), live: 32, max: 32, source: "default" }.over());
        assert!(!Lane { id: "r".into(), live: 31, max: 32, source: "default" }.over());
    }
}
