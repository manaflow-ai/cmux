//! `agent-session-children-v1`: the chats an attached tab's session started
//! on this machine, so an app on another Mac shows a Cloud VM chat's
//! children (its Subagents summary, the sidebar tree) and opens them.
//!
//! A descendant is a session of this machine's acpmux whose `startedBy` (a
//! sub-session's proven link, any depth) or `spawnedBy` (`acpmux new` run
//! inside the session; acpmux keeps it one level) names the attached session
//! or another descendant. Only those are listed or followed: never the
//! machine's whole session list, and never a peer's session.
//!
//! - `agent-session-children {surface}` answers `{sessions}`: the attached
//!   session's descendants as acpmux summarizes them (`_acpmux/sessions`),
//!   in acpmux's order, at most [`MAX_CHILDREN`] and [`MAX_PAGE_BYTES`]. On
//!   the v2 list (row 7c) they are found by `page` with `family` and read by
//!   id ([`kin_ids`]); the edge followed is then each chat's one list parent,
//!   and where that lists other chats than v1's walk the parity test names
//!   them (`agent_session_kin_parity_tests.rs`, decision 146).
//! - The attachment follows its descendants: their `session_changed` go out
//!   as `agent-session-changed`, so the app sees a child appear, run, wait
//!   and finish. A change whose summary names a followed parent adds that
//!   session.
//! - Every descendant listed or followed is remembered here
//!   ([`KnownChildren`]), so `new-conversation-tab` may file it under this
//!   store's `registry:` host: a child chat opens in a tab of its own, as a
//!   chat this machine started (conversation_tabs_wire.rs `record_of`).
//!
//! What this trusts: the ids come from this machine's acpmux list, never
//! from the request, and peer daemons' sessions are left out. They are not
//! proof of who started what: the root is whichever bound tab the trusted
//! local client attached, and `spawnedBy` is a tag acpmux's client sets from
//! `ACPMUX_SESSION_ID` with no caller token, so any process of this
//! machine's user may tag a chat under another. Every id is still a session
//! of this machine's own acpmux, which is what a `registry:` tab may show.

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Mutex;

use serde_json::{Value, json};

use super::agent_session_link::list_source::{self, INFO_ROWS, Opened};
use super::agent_session_link::{AcpmuxLink, LinkError};
use super::{Attachment, CALL_TIMEOUT, MAX_PAGE_BYTES, Refusal};

pub const AGENT_SESSION_CHILDREN_CAPABILITY: &str = "agent-session-children-v1";
/// Descendants one answer lists, and one attachment follows, at most.
pub(crate) const MAX_CHILDREN: usize = 256;
/// Descendant ids the daemon remembers for tab records (the oldest goes first).
const MAX_KNOWN: usize = 1024;

/// The descendants this daemon listed or followed, newest last.
#[derive(Default)]
pub(crate) struct KnownChildren(Mutex<VecDeque<String>>);

impl KnownChildren {
    pub(crate) fn remember<'a>(&self, ids: impl IntoIterator<Item = &'a str>) {
        let mut known = self.0.lock().unwrap_or_else(|e| e.into_inner());
        for id in ids {
            if known.iter().any(|old| old == id) {
                continue;
            }
            if known.len() >= MAX_KNOWN {
                known.pop_front();
            }
            known.push_back(id.to_owned());
        }
    }

    /// True when acpmux answered `session` as a descendant of an attached tab's session.
    pub(crate) fn contains(&self, session: &str) -> bool {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|id| id == session)
    }

    /// Forgets `session`: it is moving away from this machine, or acpmux purged it.
    pub(crate) fn forget(&self, session: &str) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).retain(|id| id != session);
    }
}

/// The sessions a summary names as its parent: `startedBy`, then `spawnedBy`.
fn parents(summary: &Value) -> impl Iterator<Item = &str> {
    ["startedBy", "spawnedBy"].into_iter().filter_map(|key| summary.get(key)?.as_str())
}

fn session_id(summary: &Value) -> Option<&str> {
    summary.get("sessionId")?.as_str().filter(|id| !id.is_empty())
}

/// A session of a peer daemon (acpmux lists those beside its own).
fn is_peer(summary: &Value) -> bool {
    summary.get("peer").is_some_and(|peer| !peer.is_null())
}

/// The summaries of `sessions` (acpmux's list) that descend from `root`, in
/// list order, at most [`MAX_CHILDREN`]. `root` itself and peer sessions
/// are never in it.
pub(crate) fn descendants(root: &str, sessions: &[Value]) -> Vec<Value> {
    let mut by_parent: HashMap<&str, Vec<usize>> = HashMap::new();
    for (index, summary) in sessions.iter().enumerate() {
        if is_peer(summary) || session_id(summary).is_none_or(|id| id == root) {
            continue;
        }
        for parent in parents(summary) {
            by_parent.entry(parent).or_default().push(index);
        }
    }
    let mut taken = vec![false; sessions.len()];
    let mut family: HashSet<&str> = HashSet::from([root]);
    let mut next = VecDeque::from([root]);
    while let Some(parent) = next.pop_front() {
        for &index in by_parent.get(parent).into_iter().flatten() {
            let Some(id) = sessions.get(index).and_then(|session| session_id(session)) else {
                continue;
            };
            if family.len() > MAX_CHILDREN || !family.insert(id) {
                continue;
            }
            if let Some(slot) = taken.get_mut(index) {
                *slot = true;
            }
            next.push_back(id);
        }
    }
    sessions.iter().zip(taken).filter(|(_, taken)| *taken).map(|(s, _)| s.clone()).collect()
}

/// The v2 list (row 7c) the kin readers read through ([`kin_ids`]): `None` when the daemon
/// serves no v2 list or no rows by id (`info-rows-v1`), and the caller reads v1's list.
pub(super) fn kin_source(
    socket: &std::path::Path,
    link: &AcpmuxLink,
) -> Result<Option<list_source::Source>, LinkError> {
    if !link.capabilities(None, CALL_TIMEOUT).iter().any(|c| c == INFO_ROWS) {
        return Ok(None);
    }
    Ok(match list_source::open(socket, CALL_TIMEOUT).map_err(list_error)? {
        Opened::List(source) => Some(source),
        Opened::V1 => None,
    })
}

/// `root`'s descendants' ids through `source` ([`list_source::kin`], at most
/// [`MAX_CHILDREN`]). With `cold` false, the hot part only (the attach, decision 301): the hub
/// says `coldUnread` whenever its snapshot is not empty, and a cold part is the snapshot's
/// pager (256 KiB a request, its closed rows / 400 requests a pass, 1 + the cold kin found
/// passes), so a cold read would grow an attach with the machine's closed chats. With `cold`,
/// the cold kin too, at that cost (the children verb).
pub(super) fn kin_ids(
    source: &mut list_source::Source,
    root: &str,
    cold: bool,
) -> Result<Vec<String>, LinkError> {
    let kin = list_source::kin(source, root, MAX_CHILDREN, cold).map_err(list_error)?;
    Ok(kin.into_iter().map(|row| row.chat_id).collect())
}

/// The attached session's descendants, cold kin too ([`kin_ids`]), then their rows by id as
/// `_acpmux/sessions` writes them, in v1's order.
fn kin_rows(attachment: &Attachment) -> Result<Option<Vec<Value>>, LinkError> {
    let Some(socket) =
        attachment.mux.upgrade().and_then(|mux| mux.control_clients.agent_sessions.socket())
    else {
        return Ok(None);
    };
    let Some(mut source) = kin_source(&socket, &attachment.link)? else {
        return Ok(None);
    };
    let ids = kin_ids(&mut source, &attachment.session, true)?;
    list_source::rows_by_id(&attachment.link, ids, CALL_TIMEOUT).map(Some)
}

/// A list read that failed: past its deadline, or a socket or wire error.
fn list_error(error: std::io::Error) -> LinkError {
    match error.kind() {
        std::io::ErrorKind::TimedOut => LinkError::Timeout,
        _ => LinkError::BadList(error.to_string()),
    }
}

/// The ids of `root`'s descendants in an `_acpmux/sessions` or `_acpmux/watch` answer.
pub(super) fn descendant_ids(root: &str, answer: &Value) -> Vec<String> {
    let sessions = answer.get("sessions").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
    descendants(root, sessions)
        .iter()
        .filter_map(|summary| session_id(summary).map(str::to_owned))
        .collect()
}

impl Attachment {
    /// Follows `ids` (descendants acpmux answered) up to [`MAX_CHILDREN`] and
    /// remembers the followed ones for tab records; answers those ids (an id
    /// past the cap is neither followed nor remembered).
    pub(super) fn follow_children<'a>(&self, ids: &'a [String]) -> Vec<&'a str> {
        let followed: Vec<&str> = {
            let mut family = self.children.lock().unwrap_or_else(|e| e.into_inner());
            ids.iter()
                .filter(|id| {
                    family.contains(id.as_str())
                        || (family.len() < MAX_CHILDREN && family.insert((*id).clone()))
                })
                .map(String::as_str)
                .collect()
        };
        if let Some(mux) = self.mux.upgrade() {
            mux.control_clients.agent_sessions.known_children.remember(followed.iter().copied());
        }
        followed
    }

    /// Stops following `session` and forgets it for tab records (acpmux purged it).
    fn drop_child(&self, session: &str) {
        self.children.lock().unwrap_or_else(|e| e.into_inner()).remove(session);
        if let Some(mux) = self.mux.upgrade() {
            mux.control_clients.agent_sessions.known_children.forget(session);
        }
    }

    /// True when `params` name a descendant the attachment already follows.
    pub(super) fn follows_session(&self, params: &Value) -> bool {
        let Some(id) = params.get("sessionId").and_then(Value::as_str) else { return false };
        self.children.lock().unwrap_or_else(|e| e.into_inner()).contains(id)
    }

    /// True when a `session_changed` (its `params`) is about a descendant the
    /// attachment follows; a change naming a followed parent (or the
    /// attached session) adds its session first.
    pub(super) fn follows_change(&self, params: &Value) -> bool {
        let Some(id) = params.get("sessionId").and_then(Value::as_str) else { return false };
        if id == self.session {
            return false;
        }
        let summary = params.get("session").unwrap_or(&Value::Null);
        let new_child = {
            let family = self.children.lock().unwrap_or_else(|e| e.into_inner());
            if family.contains(id) {
                drop(family);
                // The purge still reaches the client, which drops the chat.
                if params.get("kind").and_then(Value::as_str) == Some("purged") {
                    self.drop_child(id);
                }
                return true;
            }
            !is_peer(params)
                && !is_peer(summary)
                && parents(summary).any(|parent| parent == self.session || family.contains(parent))
        };
        new_child && !self.follow_children(&[id.to_owned()]).is_empty()
    }
}

/// `agent-session-children`: the attached session's descendants, read from
/// acpmux's own list, bounded, and followed from now on.
pub(super) fn list(attachment: &Attachment) -> Result<Value, Refusal> {
    let found = match kin_rows(attachment).map_err(Refusal::of)? {
        Some(rows) => rows,
        // The daemon has no v2 list: v1's whole list, read and walked here (a named fallback,
        // `agent_session_list_scan_tests.rs`).
        None => {
            let all = attachment
                .link
                .call_whole_list("_acpmux/sessions", json!({}), CALL_TIMEOUT)
                .map_err(Refusal::of)?;
            let sessions =
                all.get("sessions").and_then(Value::as_array).map_or(&[][..], Vec::as_slice);
            descendants(&attachment.session, sessions)
        }
    };
    let mut listed = Vec::new();
    let mut bytes = 0;
    for summary in found {
        bytes += serde_json::to_string(&summary).map_or(0, |text| text.len());
        if listed.len() >= MAX_CHILDREN || bytes > MAX_PAGE_BYTES {
            break;
        }
        listed.push(summary);
    }
    let ids: Vec<String> =
        listed.iter().filter_map(|summary| session_id(summary).map(str::to_owned)).collect();
    let followed: HashSet<&str> = attachment.follow_children(&ids).into_iter().collect();
    // Only what the attachment follows (and so streams and may open) is listed.
    listed.retain(|summary| session_id(summary).is_some_and(|id| followed.contains(id)));
    Ok(json!({"sessions": listed}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn summary(id: &str, started_by: Option<&str>, spawned_by: Option<&str>) -> Value {
        json!({"sessionId": id, "startedBy": started_by, "spawnedBy": spawned_by})
    }

    #[test]
    fn descendants_follow_both_links_at_any_depth_and_nothing_else() {
        let sessions = vec![
            summary("grandchild", Some("child"), None),
            summary("unrelated", None, None),
            summary("child", Some("root"), Some("root")),
            summary("spawned", None, Some("root")),
            summary("root", None, None),
            summary("other-child", Some("unrelated"), None),
            json!({"sessionId": "peer-child", "startedBy": "root", "peer": "mac"}),
            summary("loop-a", Some("loop-b"), None),
            summary("loop-b", Some("loop-a"), None),
        ];
        let ids: Vec<_> = descendants("root", &sessions)
            .iter()
            .map(|s| s["sessionId"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(ids, ["grandchild", "child", "spawned"], "list order, root and peers left out");
        assert!(descendants("nobody", &sessions).is_empty());
        let looped: Vec<_> =
            descendants("loop-a", &sessions).iter().map(|s| s["sessionId"].clone()).collect();
        assert_eq!(looped, [json!("loop-b")], "a loop of links ends");
    }

    #[test]
    fn descendants_stop_at_the_cap() {
        let mut sessions: Vec<Value> =
            (0..MAX_CHILDREN + 10).map(|n| summary(&format!("c{n}"), Some("root"), None)).collect();
        sessions.push(summary("root", None, None));
        assert_eq!(descendants("root", &sessions).len(), MAX_CHILDREN);
    }

    #[test]
    fn known_children_keep_the_newest() {
        let known = KnownChildren::default();
        let ids: Vec<String> = (0..MAX_KNOWN + 1).map(|n| format!("s{n}")).collect();
        known.remember(ids.iter().map(String::as_str));
        assert!(!known.contains("s0"), "the oldest went first");
        assert!(known.contains("s1") && known.contains(&format!("s{MAX_KNOWN}")));
        assert!(!known.contains("never-listed"));
        known.forget("s1");
        assert!(!known.contains("s1") && known.contains("s2"));
    }
}
