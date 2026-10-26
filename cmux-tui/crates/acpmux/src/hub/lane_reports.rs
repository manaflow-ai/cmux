//! Part of `Hub`; see `hub/mod.rs`. A lane and the session that started it: the link a lane's
//! reports of its turns go along to its parent.
//!
//! Who a lane reports to is the link the daemon keeps, set from the session its connection
//! proved it runs in (its caller token). The lane's tag `lane.reportsTo` (the parent's exact
//! session id) shows it; changing or removing that tag changes nothing.
//!
//! - `session/new` from inside a session: that session is the new one's parent. A run tied to
//!   its connection (`--ephemeral`) is no lane and gets none.
//! - A lane keeps the parent that started it; a session that gives it a later task does not
//!   take it over yet (a follow-up).
//! - A session is never linked under itself or its own descendant, and never to a parent that
//!   is closed or gone. A link either end of which closes or is purged is retired.
//!
//! Lane and parent are sessions of this daemon; a lane or parent on a peer comes later. The
//! daemon keeps each link in memory.

use super::*;
use std::collections::BTreeMap;

/// The lane's tag naming the session it reports to.
pub const TAG: &str = "lane.reportsTo";
/// Parents walked up from a session at most. A chain this deep without the session in it is
/// refused too, since a link map that was written wrong could loop past the walk.
const MAX_DEPTH: usize = 16;

/// One lane's link to its parent.
#[derive(Debug, Clone, Default)]
struct Link {
    parent: String,
}

/// The links by lane id.
#[derive(Default)]
pub(crate) struct LaneReports {
    links: StdMutex<BTreeMap<String, Link>>,
}

impl Hub {
    fn lane_links<R>(&self, f: impl FnOnce(&mut BTreeMap<String, Link>) -> R) -> R {
        f(&mut self.lane_reports.links.lock().unwrap_or_else(|e| e.into_inner()))
    }

    /// Whether `ancestor` is `id`'s parent, or its parent's, up the links.
    fn lane_below(&self, id: &str, ancestor: &str) -> bool {
        let mut at = id.to_owned();
        for _ in 0..MAX_DEPTH {
            let Some(parent) = self.lane_links(|links| links.get(&at).map(|l| l.parent.clone()))
            else {
                return false;
            };
            if parent == ancestor {
                return true;
            }
            at = parent;
        }
        tracing::warn!(
            id,
            ancestor,
            "lane link refused: its parents are more than {MAX_DEPTH} deep"
        );
        true
    }

    /// Links `child` to `parent` (both exact ids): tags the child and keeps the link.
    pub(crate) fn lane_link(&self, parent: &str, child: &str) {
        // A session never becomes the child of itself or of its own descendant.
        if parent == child || self.lane_below(parent, child) {
            return;
        }
        let Some(s) = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(child).cloned()
        else {
            return;
        };
        // A close sets the status before `lane_retire` takes this lock: read under it, a parent
        // or child that closed meanwhile is never linked, and one that closes after has its link
        // retired.
        let linked = self.lane_links(|links| {
            if !self.lane_open(parent) || !self.lane_open(child) {
                return false;
            }
            let link = Link { parent: parent.to_owned() };
            links.insert(child.to_owned(), link);
            true
        });
        if !linked {
            return;
        }
        let set = serde_json::Map::from_iter([(TAG.to_owned(), json!(parent))]);
        self.set_tags(&s, Some(&set), &[], None);
    }

    /// Whether session `id` is here and not closed.
    fn lane_open(&self, id: &str) -> bool {
        let s = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
        s.is_some_and(|s| s.status() != SessionStatus::Closed)
    }

    /// `id` was closed or purged: a link it is either end of is retired, so nothing of a
    /// closed lane stays here and nothing links to a closed parent.
    pub(super) fn lane_retire(&self, id: &str) {
        self.lane_links(|links| links.retain(|lane, l| lane != id && l.parent != id));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_parent_that_closed_while_its_lane_started_is_never_linked() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut cfg: crate::config::Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let start = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let parent = hub.new_session(start()).await.unwrap();
        let child = hub.new_session(start()).await.unwrap();
        // The parent closes after `session/new` read it and before the link goes in.
        hub.kill(&parent, false).await.unwrap();
        hub.lane_link(&parent.id, &child.id);
        assert!(!hub.lane_links(|l| l.contains_key(&child.id)));
        // A child that closed after `lane_link` read it and before the link went in is not
        // linked again: its close retired its links already.
        let closing = hub.new_session(start()).await.unwrap();
        let open_parent = hub.new_session(start()).await.unwrap();
        hub.kill(&closing, false).await.unwrap();
        hub.lane_link(&open_parent.id, &closing.id);
        assert!(!hub.lane_links(|l| l.contains_key(&closing.id)));
        hub.kill(&closing, true).await.unwrap();
        hub.kill(&open_parent, true).await.unwrap();
        // An open parent is linked.
        let open = hub.new_session(start()).await.unwrap();
        hub.lane_link(&open.id, &child.id);
        assert!(hub.lane_links(|l| l.get(&child.id).is_some_and(|l| l.parent == open.id)));
        // Its parent closing retires it; a child is never linked under its own descendant.
        hub.kill(&open, false).await.unwrap();
        assert!(!hub.lane_links(|l| l.contains_key(&child.id)));
        let grandchild = hub.new_session(start()).await.unwrap();
        hub.lane_link(&child.id, &grandchild.id);
        hub.lane_link(&grandchild.id, &child.id);
        assert!(!hub.lane_links(|l| l.contains_key(&child.id)));
        hub.kill(&grandchild, true).await.unwrap();
        for s in [&child, &open] {
            hub.kill(s, true).await.unwrap();
        }
        hub.kill(&parent, true).await.unwrap();
    }
}
