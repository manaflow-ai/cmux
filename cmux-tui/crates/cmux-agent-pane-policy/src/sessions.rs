//! The pane's session scope and handoff records (CmuxNextAgentPane
//! `AcpmuxPaneSessions`): the sessions the pane started or shows, and what it
//! knows of handoffs for the source rule (`source_scoped`). State only, no
//! I/O: the host feeds it what the pane sent and what the daemon answered.
//! The folders the daemon reports (`observeFolder`) stay host-owned.

use crate::check::PaneScope;
use crate::frame::raw_id;
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Mutex;

/// The requests whose reply names a session the pane started.
pub const STARTING: [&str; 3] = ["session/new", "acp.session.fork", "_acpmux/handoff_start"];
/// The requests whose reply is a handoff record (`handoffId`, `source.sessionId`).
pub const HANDOFF_RECORDS: [&str; 4] = [
    "_acpmux/handoff_prepare",
    "_acpmux/handoff_get",
    "_acpmux/handoff_draft",
    "_acpmux/handoff_start",
];

#[derive(Default)]
struct State {
    sessions: BTreeSet<String>,
    /// Raw ids of the starting requests waiting for their reply.
    awaiting: BTreeSet<String>,
    /// handoffId -> its source session.
    handoff_sources: BTreeMap<String, String>,
    /// The handoffs a click let the pane take from outside its scope.
    owned_handoffs: BTreeSet<String>,
    /// Raw ids of the handoff requests waiting for their record, and whether
    /// a click let the pane take that handoff.
    awaiting_handoff: BTreeMap<String, bool>,
}

/// One pane's scope.
#[derive(Default)]
pub struct PaneSessions {
    state: Mutex<State>,
}

impl PaneSessions {
    pub fn new() -> Self {
        Self::default()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The user or the host opened `session` in this pane.
    pub fn add(&self, session: &str) {
        self.lock().sessions.insert(session.to_owned());
    }

    /// The pane sent `method` with raw id `id`. `owned`: a click let the pane
    /// take this fork or handoff (`handoff`, when the frame names one) from a
    /// session outside its scope.
    pub fn sent(&self, method: &str, id: Option<&str>, handoff: Option<&str>, owned: bool) {
        let starting = STARTING.contains(&method);
        let record = HANDOFF_RECORDS.contains(&method);
        if !(owned || starting || record) {
            return;
        }
        let mut s = self.lock();
        if owned && let Some(h) = handoff {
            s.owned_handoffs.insert(h.to_owned());
        }
        let Some(id) = id else { return };
        if starting {
            s.awaiting.insert(id.to_owned());
        }
        if record {
            s.awaiting_handoff.insert(id.to_owned(), owned);
        }
    }

    /// A parsed daemon frame (its id already the page's): a reply to a
    /// starting request makes its sessions the pane's; a reply to a handoff
    /// request records the handoff's source.
    pub fn observe(&self, object: &Map<String, Value>) {
        if object.contains_key("method") {
            return;
        }
        let (Some(result), Some(id)) =
            (object.get("result").and_then(Value::as_object), object.get("id").and_then(raw_id))
        else {
            return;
        };
        let mut s = self.lock();
        if s.awaiting.is_empty() && s.awaiting_handoff.is_empty() {
            return;
        }
        let text = |k: &str| result.get(k).and_then(Value::as_str).map(str::to_owned);
        let named: Vec<String> =
            ["sessionId", "targetSessionId"].iter().filter_map(|k| text(k)).collect();
        let handoff = text("handoffId");
        let source = result.get("source").and_then(|s| s.get("sessionId")).and_then(Value::as_str);
        if let Some(owned) = s.awaiting_handoff.remove(&id)
            && let Some(h) = handoff
        {
            if let Some(src) = source {
                s.handoff_sources.insert(h.clone(), src.to_owned());
            }
            if owned {
                s.owned_handoffs.insert(h);
            }
        }
        if s.awaiting.remove(&id) {
            s.sessions.extend(named);
        }
    }
}

impl PaneScope for PaneSessions {
    fn contains(&self, session: &str) -> bool {
        self.lock().sessions.contains(session)
    }

    /// `holdsSource`: a handoff the pane owns or whose source session is the
    /// pane's (a handoff it never saw a record of is outside), else
    /// `sessionId` in the scope.
    fn holds_source(&self, params: &Map<String, Value>) -> bool {
        let s = self.lock();
        if let Some(h) = params.get("handoffId").and_then(Value::as_str) {
            return s.owned_handoffs.contains(h)
                || s.handoff_sources.get(h).is_some_and(|src| s.sessions.contains(src));
        }
        params.get("sessionId").and_then(Value::as_str).is_some_and(|x| s.sessions.contains(x))
    }
}
