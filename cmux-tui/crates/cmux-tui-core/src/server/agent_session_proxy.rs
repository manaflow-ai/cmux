//! Host proxy identity is attested by the same-user socket, not by network JSON.
//! Local same-user processes already have owner access. Remote relay transports
//! cannot bind; the host proxy never forwards this verb from a teammate.
//! A link share's guest binds the same way (`link_guest`, agent_session_shares.rs).
use super::*;

#[path = "agent_session_shares.rs"]
pub(super) mod shares;

// The verbs of a teammate, a talking guest and a viewer: one source with acpmux's Cloud carrier
// rules (`cmux_agent_pane_policy::share_roles`).
use cmux_agent_pane_policy::share_roles::{
    DRIVER_VERBS, GUEST_VERBS, TEAMMATE_VERBS, VIEWER_VERBS,
};

/// A Cloud team member on a teammate's team machine (`member.rs`): the chat's own verbs, its
/// steer, typing and view. Never start, trust, media, children, permission, a queue decision,
/// a setting or the owner's sign-in. Its prompts steer like the owner's and are never held.
const MEMBER_VERBS: [&str; 8] = [
    "agent-session-attach",
    "agent-session-events",
    "agent-session-prompt",
    "agent-session-cancel",
    "agent-session-typing",
    "agent-session-view",
    "agent-session-detach",
    "agent-session-permission",
];

/// Whether `author` is a Cloud team member's (`user_<id>`, named by its signed link token).
pub(super) fn is_member(author: &Value) -> bool {
    author["id"].as_str().is_some_and(|id| id.starts_with(MEMBER_PREFIX))
}

/// The id prefix of a Cloud account (cmux-platform `userIdFor`), as acpmux's author takes it.
pub(super) const MEMBER_PREFIX: &str = "user_";

/// Whether `author` is a link guest's (`guest:<share_id>.<guest_id>`).
pub(super) fn is_guest(author: &Value) -> bool {
    author["id"].as_str().is_some_and(|id| id.starts_with(shares::GUEST_PREFIX))
}

/// The refusal of a frame outside a bound link's verbs.
pub(super) fn scope_refusal(mux: &Mux, client: u64) -> Refusal {
    match author(mux, client) {
        Some(author) if is_guest(&author) => Refusal::ScopeNotGranted,
        _ => Refusal::NotTrusted,
    }
}

/// A frame `check` accepted: a bound link's frame outside its verbs is refused; the owner's own
/// verbs (`agent-session-of`, `agent-session-share-*`) are answered here. `None` goes on.
pub(super) fn scope(
    mux: &Arc<Mux>,
    client: u64,
    object: &mut serde_json::Map<String, Value>,
    author: Option<&Value>,
    writer: &MessageWriter,
) -> Option<bool> {
    let cmd = object.get("cmd").and_then(Value::as_str).unwrap_or_default().to_owned();
    if let Some(author) = author {
        let guest = is_guest(author);
        // `agent-session-permission` is in the member's list only so it is answered
        // `agent_session.owner_only` (`run_on_worker`), not a bare not-trusted.
        let verbs: &[&str] = match (guest, shares::view_only(author)) {
            (true, true) => &VIEWER_VERBS,
            (true, false) if author.get("role").and_then(Value::as_str) == Some("drive") => {
                &DRIVER_VERBS
            }
            (true, false) => &GUEST_VERBS,
            (false, _) if is_member(author) => &MEMBER_VERBS,
            (false, _) => &TEAMMATE_VERBS,
        };
        if !verbs.contains(&cmd.as_str()) {
            let refusal = if guest { Refusal::ScopeNotGranted } else { Refusal::NotTrusted };
            return Some(refuse(writer, object.remove("id"), refusal));
        }
    }
    if cmd == "agent-session-of" {
        return Some(session_of(mux, client, std::mem::take(object), author.is_some(), writer));
    }
    if cmd.starts_with("agent-session-share-") {
        let object = std::mem::take(object);
        return Some(shares::handle(mux, client, &cmd, object, author.is_some(), writer));
    }
    None
}

pub(super) fn author(mux: &Mux, client: u64) -> Option<Value> {
    let authors = &mux.control_clients.agent_sessions.proxy_authors;
    if authors.publishing() {
        // The published binds (R-DAEMON-STATE stage S1): every line asks, and none waits for a bind or a disconnect.
        return authors.load().unwrap_or_else(|e| e.into_inner()).get(&client).cloned();
    }
    authors.lock().unwrap_or_else(|e| e.into_inner()).get(&client).cloned()
}

pub(super) fn bind(
    mux: &Arc<Mux>,
    client: u64,
    mut object: serde_json::Map<String, Value>,
    writer: &MessageWriter,
) -> bool {
    let id = object.remove("id");
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    // The bind carries no host markers: those are only ever the proxy's stamps on later frames.
    if object.keys().any(|key| key.starts_with("_host_")) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    // Only as the connection's first line: a link that already subscribed or asked for anything
    // else keeps no daemon state into the teammate's session.
    if mux.control_clients.agent_sessions.past_first_line(client) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    let author = match (object.remove("author"), object.remove("link_guest")) {
        (Some(author), None) => {
            let login = author["login"].as_str().unwrap_or_default();
            let node = author["node"].as_str().unwrap_or_default();
            if login.is_empty() || login.len() > 320 || node.is_empty() || node.len() > 255 {
                return refuse(writer, id, Refusal::BadRequest);
            }
            let login = login.trim().to_ascii_lowercase();
            json!({"id": format!("tailnet:{login}"), "name": login, "login": login, "node": node})
        }
        // A redeemed guest of a live share: the daemon names it, never the binding connection.
        (None, Some(link)) => match shares::guest_author(mux, link) {
            Ok(author) => author,
            Err(refusal) => return refuse(writer, id, refusal),
        },
        _ => return refuse(writer, id, Refusal::BadRequest),
    };
    let mut authors =
        mux.control_clients.agent_sessions.proxy_authors.lock().unwrap_or_else(|e| e.into_inner());
    if authors.contains_key(&client) || mux.control_clients.agent_sessions.lock().count(client) != 0
    {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    authors.insert(client, author.clone());
    drop(authors);
    // A share or guest that ended while this bind ran: its sweep may have missed this connection,
    // which was not bound yet. Checked after the insert, so any end later sees it bound.
    if is_guest(&author) && !mux.control_clients.agent_sessions.link_shares().guest_live(&author) {
        mux.control_clients
            .agent_sessions
            .proxy_authors
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&client);
        return refuse(writer, id, Refusal::ShareEnded);
    }
    // No host paths, session inventory or machine metadata in the handshake.
    ok(
        writer,
        id,
        json!({"app": "cmux-tui", "protocol": super::super::PROTOCOL_VERSION,
        "version": crate::release::distribution_version(), "generation": mux.registry_identity().1,
        "capabilities": ["agent-session-attach-v1", "agent-session-observe-v1"]}),
    )
}

/// A bound teammate's request, as [`check`] accepted it: the author and the chat its share
/// pinned (`None` only for a detach). The caller uses exactly this chat, never a later lookup a
/// rebind could change.
pub(super) struct Teammate {
    pub(super) author: Value,
    pub(super) pinned: Option<String>,
}

/// The request's author, checked against the connection's binding: `Ok(None)` for the owner's
/// own client, `Ok(Some(teammate))` for a bound teammate, a refusal otherwise. The caller uses this
/// answer, never a later lookup a disconnect could empty. A bound teammate's frame also names the
/// chat its share pinned (`_host_session`), and is refused unless the surface shows that chat now:
/// a surface rebound to another chat is not shared. A detach needs no chat.
pub(super) fn check(
    mux: &Mux,
    client: u64,
    object: &mut serde_json::Map<String, Value>,
) -> Result<Option<Teammate>, Refusal> {
    let supplied = object.remove("_host_author");
    let pinned = object.remove("_host_session");
    // Only the proxy's two markers exist; any other `_host_` field is a forgery.
    if object.keys().any(|key| key.starts_with("_host_")) {
        return Err(Refusal::NotTrusted);
    }
    let Some(bound) = author(mux, client) else {
        return if supplied.is_none() && pinned.is_none() {
            Ok(None)
        } else {
            Err(Refusal::NotTrusted)
        };
    };
    if is_guest(&bound) {
        return shares::check_guest(mux, client, bound, supplied, pinned, object).map(Some);
    }
    if supplied.as_ref() != Some(&bound) {
        return Err(Refusal::NotTrusted);
    }
    if object.get("cmd").and_then(Value::as_str) == Some("agent-session-detach") {
        return Ok(Some(Teammate { author: bound, pinned: None }));
    }
    let pinned = pinned.as_ref().and_then(Value::as_str).filter(|s| !s.is_empty());
    let current = object.get("surface").and_then(Value::as_u64).and_then(|s| tab_session(mux, s));
    if pinned.is_none() || pinned != current.as_deref() {
        return Err(Refusal::NotShared);
    }
    Ok(Some(Teammate { author: bound, pinned: pinned.map(str::to_owned) }))
}

/// `agent-session-of {surface}`: the surface's agent session, for `cmux host share` to pin. The
/// owner's own same-user client only; a teammate learns no session ids.
pub(super) fn session_of(
    mux: &Mux,
    client: u64,
    mut object: serde_json::Map<String, Value>,
    bound: bool,
    writer: &MessageWriter,
) -> bool {
    let id = object.remove("id");
    if bound
        || (!mux.control_clients.is_unix(client) || mux.is_remote_client(client))
            && !mux.cloud_mobile_client(client)
            && !mux.is_native_agent_owner(client)
    {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    let Some(surface) = object.get("surface").and_then(Value::as_u64) else {
        return refuse(writer, id, Refusal::BadRequest);
    };
    match tab_session(mux, surface) {
        Some(session) => ok(writer, id, json!({"surface": surface, "session": session})),
        None => refuse(writer, id, Refusal::UnknownTab),
    }
}

#[cfg(test)]
#[path = "agent_session_proxy_tests.rs"]
mod tests;
