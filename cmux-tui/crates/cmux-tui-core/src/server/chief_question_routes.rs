//! Bounded, daemon-owned ACP routes for a stored Chief approval card. Resolving a route
//! neither starts a daemon nor proves delivery; the caller checks an exact ACP receipt.

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::mux::Mux;

pub(super) struct ChiefQuestionRoutes {
    pub chief_home_id: String,
    /// Named brain, default Chief home, then the app; identical paths occur only once.
    pub candidates: Vec<PathBuf>,
}

/// `chief` must be the stored message's Chief author, never a caller-selected route.
pub(super) fn resolve(
    mux: &Mux,
    chief: &str,
) -> Result<ChiefQuestionRoutes, (&'static str, &'static str)> {
    let (root, brain) = super::chief_work::trusted_homes(mux, chief)?;
    // SAFETY: geteuid has no preconditions. Homes come from the daemon's launch config.
    let uid = unsafe { libc::geteuid() };
    Ok(ChiefQuestionRoutes {
        chief_home_id: super::chief_work::home_id(&brain),
        candidates: candidates(&root, &brain, mux.control_clients.agent_sessions.socket(), uid),
    })
}

fn candidates(root: &Path, brain: &Path, app: Option<PathBuf>, uid: u32) -> Vec<PathBuf> {
    let socket = |home: &Path| {
        PathBuf::from(cmux_agent_pane_policy::environment::default_socket_path(
            &home.join("acpmux"),
            uid,
        ))
    };
    let mut paths = Vec::with_capacity(3);
    for path in [Some(socket(brain)), Some(socket(root)), app].into_iter().flatten() {
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    paths
}

/// Only a full raw local id or its single `local/` qualification. The caller must still
/// compare ACP's returned session id exactly: ACP's general resolver also accepts names.
pub(super) fn local_session_id(session: &str) -> Option<&str> {
    let raw = session.strip_prefix("local/").unwrap_or(session);
    (!raw.is_empty() && raw.len() <= 256 && raw != "." && raw != ".." && !raw.contains('/'))
        .then_some(raw)
}

/// Normal `_acpmux/info` metadata, not its deliveryAttempt-only response. Matches native
/// AcpmuxPersonLine.isOwnerSubagent: exact local session, this Chief's owner subagent,
/// never a peer, a turn, or the other-person ask floor. Receipt validation is separate.
pub(super) fn is_owner_subagent(info: &Value, session: &str, home: &str) -> bool {
    let Some(raw) = local_session_id(session) else { return false };
    let Some(tags) = info.get("tags").and_then(Value::as_object) else { return false };
    if home.len() != 8
        || !home.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        || info.get("sessionId").and_then(Value::as_str) != Some(raw)
        || info.get("peer").is_some()
        || !tags.values().all(Value::is_string)
    {
        return false;
    }
    let parent = format!("optchat-chief:{home}");
    tags.get("mux.parent").and_then(Value::as_str) == Some(parent.as_str())
        && tags.get("optchat.subagent").and_then(Value::as_str).is_some_and(|s| !s.is_empty())
        && tags.get("optchat.policy").and_then(Value::as_str) != Some("ask")
        && info.get("policy").and_then(Value::as_str) != Some("ask")
        && tags.get("cmux.chief.role").and_then(Value::as_str) != Some("turn")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn routes_keep_brain_home_app_order_and_deduplicate() {
        let root = Path::new("/chief");
        let brain = Path::new("/chief/c/12345678");
        let app = PathBuf::from("/app/acpmux.sock");
        let paths = candidates(root, brain, Some(app.clone()), 501);
        assert_eq!(
            paths,
            vec![brain.join("acpmux/acpmux.sock"), root.join("acpmux/acpmux.sock"), app]
        );
        assert_eq!(
            candidates(root, root, Some(root.join("acpmux/acpmux.sock")), 501),
            vec![root.join("acpmux/acpmux.sock")]
        );
        assert_eq!(candidates(root, root, None, 501).len(), 1);
    }

    fn owned() -> Value {
        json!({"sessionId":"session-id", "policy":"approve-all", "tags":{
            "mux.parent":"optchat-chief:1234abcd", "optchat.subagent":"worker"
        }})
    }

    #[test]
    fn exact_owner_accepts_only_the_same_local_session() {
        assert!(is_owner_subagent(&owned(), "local/session-id", "1234abcd"));
        assert!(is_owner_subagent(&owned(), "session-id", "1234abcd"));
        for session in
            ["", "local/", "local/local/session-id", "peer/session-id", "session", ".", ".."]
        {
            assert!(!is_owner_subagent(&owned(), session, "1234abcd"));
        }
        assert!(!is_owner_subagent(&owned(), "session-id", "87654321"));
    }

    #[test]
    fn peers_turns_ask_floor_and_missing_ownership_are_refused() {
        for (pointer, replacement) in [
            ("/peer", json!("remote")),
            ("/peer", Value::Null),
            ("/policy", json!("ask")),
            ("/tags/optchat.policy", json!("ask")),
            ("/tags/cmux.chief.role", json!("turn")),
            ("/tags/optchat.subagent", json!("")),
            ("/tags/optchat.subagent", Value::Null),
            ("/tags/mux.parent", json!("optchat-chief:87654321")),
        ] {
            let mut info = owned();
            let (parent, key) = pointer.rsplit_once('/').unwrap();
            let fields =
                if parent.is_empty() { &mut info } else { info.pointer_mut(parent).unwrap() };
            fields.as_object_mut().unwrap().insert(key.into(), replacement);
            assert!(!is_owner_subagent(&info, "session-id", "1234abcd"), "{pointer}");
        }
        let mut info = owned();
        info["tags"].as_object_mut().unwrap().remove("mux.parent");
        assert!(!is_owner_subagent(&info, "session-id", "1234abcd"));
    }
}
