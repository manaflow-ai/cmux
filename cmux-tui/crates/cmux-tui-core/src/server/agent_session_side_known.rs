//! The side chats this daemon knows, for the owner-only rules around `agent-session-side`
//! (`agent_session_side.rs`) and `agent-session-btw`.
//!
//! A side chat is its owner's alone. A teammate, a Cloud team member and a link guest never reach
//! one: the daemon remembers every side chat it opened or saw tagged ([`SideSessions`]) and
//! refuses an authored attach to one, also when acpmux's attach page shows the `side` tag for a
//! chat the daemon had not seen yet (after a restart). `agent-session-team-list` reads acpmux's
//! own tags each time ([`tagged_now`]) and leaves every side chat out, so a daemon that restarted
//! lists none either; when acpmux's list cannot be read it lists no chat.

use std::collections::{HashSet, VecDeque};
use std::sync::Mutex;

use serde_json::{Value, json};

use super::{AcpmuxLink, CALL_TIMEOUT, Mux};

/// Side chat ids the daemon remembers (the oldest goes first).
const MAX_KNOWN: usize = 1024;

/// The side chats this daemon opened or saw tagged, newest last.
#[derive(Default)]
pub(crate) struct SideSessions(Mutex<VecDeque<String>>);

impl SideSessions {
    pub(crate) fn remember(&self, session: &str) {
        let mut known = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if session.is_empty() || known.iter().any(|old| old == session) {
            return;
        }
        if known.len() >= MAX_KNOWN {
            known.pop_front();
        }
        known.push_back(session.to_owned());
    }

    /// True when `session` is a side chat as far as this daemon knows.
    pub(crate) fn contains(&self, session: &str) -> bool {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|id| id == session)
    }
}

/// True when acpmux's attach page says its session is a side chat (the `side` tag, which only
/// acpmux sets: `_acpmux/side` and `_acpmux/btw`).
pub(super) fn tagged(page: &Value) -> bool {
    page.pointer("/session/tags/side").is_some_and(|tag| !tag.is_null())
}

/// The sessions acpmux tags `side` now, from its own list (`_acpmux/sessions`, the persisted
/// tags): what the daemon's memory cannot say after a restart. They are remembered from here
/// on. `None` when the list cannot be read whole: the caller then shows no chat at all.
pub(super) fn tagged_now(mux: &Mux) -> Option<HashSet<String>> {
    let sessions = &mux.control_clients.agent_sessions;
    let socket = sessions.socket()?;
    let link = AcpmuxLink::connect(&socket, |_| {}).ok()?;
    let list = link.call_whole_list("_acpmux/sessions", json!({}), CALL_TIMEOUT);
    link.close();
    let list = list.ok()?;
    let tagged: HashSet<String> = list
        .get("sessions")?
        .as_array()?
        .iter()
        .filter(|row| row.pointer("/tags/side").is_some_and(|tag| !tag.is_null()))
        // A tab's record may hold the chat's name instead of its id: both name the side chat.
        .flat_map(|row| [row.get("sessionId"), row.get("name")])
        .filter_map(|id| id.and_then(Value::as_str))
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .collect();
    for session in &tagged {
        sessions.sides.remember(session);
    }
    Some(tagged)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn side_sessions_keep_the_newest_and_only_a_tagged_page_is_a_side_chat() {
        let known = SideSessions::default();
        for index in 0..=MAX_KNOWN {
            known.remember(&format!("acp_{index}"));
        }
        known.remember("");
        assert!(!known.contains("acp_0"));
        assert!(known.contains("acp_1"));
        assert!(known.contains(&format!("acp_{MAX_KNOWN}")));
        assert!(!known.contains(""));
        assert!(tagged(&json!({"session": {"tags": {"side": "acp_chat"}}})));
        assert!(!tagged(&json!({"session": {"tags": {"bead:cx-1": "1"}}})));
        assert!(!tagged(&json!({"session": {"sessionId": "acp_chat"}})));
    }
}
