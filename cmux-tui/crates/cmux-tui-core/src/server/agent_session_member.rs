//! A Cloud team member in a chat on a teammate's team machine (cloud multiplayer, lane C,
//! contract C5: a Cloud chat is `cloud:<team>/<machine>/<session>`).
//!
//! The member's app dials this machine over the same Native link as the owner's. CloudDO signs
//! the dial's link token with the caller's role on this machine (`vm_kind`: `owner` or `team`)
//! and mints one only for a member of the machine's team who holds `team.resources` (never a team
//! guest or billing role, never anyone outside the team), and only on a team machine (a personal
//! machine is its creator's alone). So a signed `team` dial is a current team member, named by the
//! token's `user` (`user_<id>`). The receiver rechecks every open stream at each policy renewal,
//! so a member removed from the team loses the stream (and every attachment on it) at once.
//!
//! What a member may do, on any agent chat of the machine: read its transcript, prompt it (a
//! prompt steers into the running turn like the owner's, `agent-session-steer-v1`), cancel the
//! running turn, say it types and views (presence). The daemon stamps the member as the author of
//! every call (`_meta.acpmux.author {id: user_…, name}`), so acpmux records who asked; a frame's
//! own `_host_*` markers or author are refused. Never: start, trust, a folder, media, children, a
//! fork, a side chat (`agent-session-side`, nor an attach to one the owner opened), a move, a model, mode or option change, the owner's sign-in, an answer to an ask, a
//! decision on a prompt held for the owner, a share, a terminal or the workspace layout. Those stay
//! the owner's (`agent_session.owner_only` for an answer, `remote_denied` for the rest).
//!
//! The member's display name is its own app's claim (`set-client-info` `person_name`), shown
//! next to the signed id: the id is the record of who asked, the name only labels it.
use super::*;
use crate::server::{ClientTransport, remote_relay};
use cmux_link::token::VmKind;

/// `agent-session-team-list` and the member's attach verbs on a teammate's team machine.
pub const AGENT_SESSION_MEMBER_CAPABILITY: &str = "agent-session-member-v1";
/// `agent-session-prompt` takes `steer` (the owner's and a member's; a link guest is held).
pub const AGENT_SESSION_STEER_CAPABILITY: &str = "agent-session-steer-v1";
/// `agent-session-queue-approve` / `-queue-decline`: the owner decides a held guest prompt.
pub const AGENT_SESSION_QUEUE_DECISION_CAPABILITY: &str = "agent-session-queue-decision-v1";

/// What a member's identify lists, and the only capabilities its `set-client-info` keeps.
const MEMBER_CAPABILITIES: [&str; 4] = [
    AGENT_SESSION_ATTACH_CAPABILITY,
    AGENT_SESSION_PRESENCE_CAPABILITY,
    AGENT_SESSION_MEMBER_CAPABILITY,
    AGENT_SESSION_STEER_CAPABILITY,
];

/// The verbs a member's frame may name; every other frame takes the remote entry's policy.
const MEMBER_FRAMES: [&str; 9] = [
    "agent-session-attach",
    "agent-session-events",
    "agent-session-prompt",
    "agent-session-cancel",
    "agent-session-typing",
    "agent-session-view",
    "agent-session-detach",
    "agent-session-permission",
    "agent-session-team-list",
];

/// Whether the remote entry lets a member's `line` through to [`try_handle`]: the handshake and
/// the member's verbs, for a peer whose signed account is a Cloud account, nothing else (the
/// entry's own gate must admit it as well).
pub(in crate::server) fn admits(peer: &cmux_link::stamp::LinkPeer, line: &str) -> bool {
    if !valid_user(&peer.user) {
        return false;
    }
    let Ok(Value::Object(fields)) = serde_json::from_str::<Value>(line) else { return false };
    !fields.contains_key("protocol")
        && fields.get("cmd").and_then(Value::as_str).is_some_and(|cmd| {
            matches!(cmd, "identify" | "set-client-info") || MEMBER_FRAMES.contains(&cmd)
        })
}

/// A name shown for a member whose app named none (or one acpmux would refuse).
const FALLBACK_NAME: &str = "Teammate";
const MAX_NAME_CHARS: usize = 64;

impl Mux {
    /// A remote stream whose Native link token CloudDO signed `team` for this machine, still
    /// admitted now (revocation, host policy), for a Cloud account id. Signed connection metadata
    /// only: no frame can make a connection a member, and a member is never the owner.
    #[cfg(unix)]
    pub(in crate::server) fn is_native_team_member(&self, client: u64) -> bool {
        let signed_team = self.control_clients.state.lock().ok().is_some_and(|state| {
            state.clients.get(&client).is_some_and(|record| {
                matches!(record.transport, ClientTransport::Remote)
                    && record.native_vm_kind == Some(Some(VmKind::Team))
            })
        });
        signed_team && member_peer(self, client).is_some()
    }

    #[cfg(not(unix))]
    pub(in crate::server) fn is_native_team_member(&self, _client: u64) -> bool {
        false
    }
}

/// The member's signed peer: a live remote principal with a Cloud account id.
fn member_peer(mux: &Mux, client: u64) -> Option<cmux_link::stamp::LinkPeer> {
    match mux.frame_principal(client)? {
        remote_relay::Principal::Remote(peer) if valid_user(&peer.user) => Some(peer),
        _ => None,
    }
}

fn valid_user(user: &str) -> bool {
    user.strip_prefix(proxy::MEMBER_PREFIX).is_some_and(|rest| {
        (1..=64).contains(&rest.len()) && rest.bytes().all(|b| b.is_ascii_alphanumeric())
    })
}

/// A display name acpmux takes (one line, at most 64 characters, nothing that changes how it
/// reads), or the fallback.
fn display_name(raw: Option<&str>) -> String {
    let name = raw.map(str::trim).unwrap_or_default();
    let shown = !name.is_empty()
        && name.chars().count() <= MAX_NAME_CHARS
        && !name.chars().any(|c| {
            c.is_control()
                || (c.is_whitespace() && c != ' ')
                || matches!(c, '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}' | '\u{FEFF}')
        });
    if shown { name.to_owned() } else { FALLBACK_NAME.to_owned() }
}

/// The member's bound author: bound once per connection from the signed peer (the name from
/// the first `set-client-info`, else the fallback). `None` when the peer is gone.
fn bound_author(mux: &Mux, client: u64, name: Option<&str>) -> Option<Value> {
    let peer = member_peer(mux, client)?;
    let mut authors =
        mux.control_clients.agent_sessions.proxy_authors.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(author) = authors.get(&client) {
        // Only this module binds a remote member; a bind under another id is never reused.
        return (author["id"].as_str() == Some(peer.user.as_str())).then(|| author.clone());
    }
    let author = json!({"id": peer.user, "name": display_name(name)});
    authors.insert(client, author.clone());
    Some(author)
}

/// A member's frame on its signed Native dial; `None` for every other connection, and for a
/// member frame outside its verbs (the remote entry then refuses it as before).
pub(in crate::server) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !mux.is_native_team_member(client) {
        return None;
    }
    let Ok(Value::Object(mut object)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    if object.contains_key("protocol") {
        return None;
    }
    let cmd = object.get("cmd").and_then(Value::as_str).unwrap_or_default().to_owned();
    match cmd.as_str() {
        "identify" => {
            let id = object.remove("id");
            Some(ok(writer, id, identify(mux)))
        }
        "set-client-info" => Some(set_client_info(mux, client, object, writer)),
        cmd if MEMBER_FRAMES.contains(&cmd) => {
            // The markers are the daemon's own, here: a member's frame carrying one is a forgery.
            if object.keys().any(|key| key.starts_with("_host_") || key == "_meta") {
                return Some(refuse(writer, object.remove("id"), Refusal::NotTrusted));
            }
            let Some(author) = bound_author(mux, client, None) else {
                return Some(refuse(writer, object.remove("id"), Refusal::NotTrusted));
            };
            if cmd == "agent-session-team-list" {
                let id = object.remove("id");
                return Some(ok(writer, id, team_list(mux, client)));
            }
            if cmd != "agent-session-detach" {
                // The chat the surface shows now is the one the member reaches: any agent chat
                // of this team machine. `proxy::check` checks the surface again under the frame.
                let surface = object.get("surface").and_then(Value::as_u64);
                let Some(session) = surface.and_then(|s| tab_session(mux, s)) else {
                    return Some(refuse(writer, object.remove("id"), Refusal::UnknownTab));
                };
                object.insert("_host_session".into(), json!(session));
            }
            object.insert("_host_author".into(), author);
            let frame = Value::Object(object).to_string();
            Some(
                super::try_handle(mux, client, &frame, writer)
                    .unwrap_or_else(|| refuse(writer, None, Refusal::NotTrusted)),
            )
        }
        _ => None,
    }
}

/// identify for a member: no host paths, inventory or machine metadata (as a proxied teammate's).
fn identify(mux: &Mux) -> Value {
    json!({"app": "cmux-tui", "protocol": super::super::PROTOCOL_VERSION,
        "version": crate::release::distribution_version(), "generation": mux.registry_identity().1,
        "capabilities": MEMBER_CAPABILITIES})
}

fn set_client_info(
    mux: &Mux,
    client: u64,
    mut object: serde_json::Map<String, Value>,
    writer: &MessageWriter,
) -> bool {
    let id = object.remove("id");
    let name = object.get("name").and_then(Value::as_str).map(str::to_owned);
    let kind = object.get("kind").and_then(Value::as_str).map(str::to_owned);
    let person = object.get("person_name").and_then(Value::as_str).map(str::to_owned);
    // A capability declaration never grants a verb: only the member's own vocabulary stays.
    let capabilities = object.get("capabilities").and_then(Value::as_array).map(|caps| {
        caps.iter()
            .filter_map(Value::as_str)
            .filter(|cap| MEMBER_CAPABILITIES.contains(cap))
            .map(str::to_owned)
            .collect::<Vec<_>>()
    });
    if mux.control_clients.set_info(client, name, kind, capabilities).is_err() {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    if bound_author(mux, client, person.as_deref()).is_none() {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    ok(writer, id, json!({}))
}

/// `agent-session-team-list`: this machine's agent chats as a team member (or the owner) may
/// open them: `{team, machine, role, chats: [{surface, session, harness, cloud_id}]}`, where
/// `cloud_id` is the chat's C5 address `cloud:<team>/<machine>/<session>` (null when this
/// machine does not know its machine id). No folders, titles or other inventory.
pub(in crate::server) fn team_list(mux: &Mux, client: u64) -> Value {
    let team = match mux.frame_principal(client) {
        Some(remote_relay::Principal::Remote(peer)) => Some(peer.team),
        _ => None,
    };
    let machine = std::env::var("CMUX_PLATFORM_MACHINE_ID")
        .ok()
        .filter(|id| !id.is_empty() && id.len() <= 128 && id.bytes().all(id_byte));
    let surfaces = {
        let state = mux.state.lock().unwrap_or_else(|e| e.into_inner());
        state.surfaces.iter().map(|(id, surface)| (*id, surface.clone())).collect::<Vec<_>>()
    };
    let listed: Vec<_> = surfaces
        .into_iter()
        .filter_map(|(surface, runtime)| match mux.conversation_tab_of(&runtime)? {
            ConversationTabRecord::AgentSession { session: Some(session), harness, .. } => {
                Some((surface, session, harness))
            }
            _ => None,
        })
        .collect();
    // A side chat is its owner's alone: never listed (and never attached, `attach`). acpmux's
    // own `side` tags are read now, so a daemon that restarted (and remembers none) lists none
    // either; a list that cannot be read shows no chat.
    let tagged =
        if listed.is_empty() { Some(Default::default()) } else { side_known::tagged_now(mux) };
    let known = &mux.control_clients.agent_sessions.sides;
    let mut chats: Vec<Value> = listed
        .into_iter()
        .filter(|(_, session, _)| {
            tagged.as_ref().is_some_and(|tagged| !tagged.contains(session))
                && !known.contains(session)
        })
        .map(|(surface, session, harness)| {
            let cloud_id = match (&team, &machine) {
                (Some(team), Some(machine)) => json!(format!("cloud:{team}/{machine}/{session}")),
                _ => Value::Null,
            };
            json!({"surface": surface, "session": session, "harness": harness,
                "cloud_id": cloud_id})
        })
        .collect();
    chats.sort_by_key(|chat| chat["surface"].as_u64());
    // The caller's role on this machine, as its signed dial says (the owner's own Native dial,
    // or a team member's).
    let role = if mux.is_native_team_member(client) { "member" } else { "owner" };
    json!({"team": team, "machine": machine, "role": role, "chats": chats})
}

fn id_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b':')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_member_name_is_one_short_line_or_the_fallback() {
        assert_eq!(display_name(Some("  Ana  ")), "Ana");
        assert_eq!(display_name(None), FALLBACK_NAME);
        assert_eq!(display_name(Some("")), FALLBACK_NAME);
        assert_eq!(display_name(Some("Ana\nOwner")), FALLBACK_NAME);
        assert_eq!(display_name(Some("A\u{202E}na")), FALLBACK_NAME);
        assert_eq!(display_name(Some(&"x".repeat(65))), FALLBACK_NAME);
    }

    #[test]
    fn only_a_cloud_account_id_is_a_member() {
        assert!(valid_user("user_0123456789abcdef0123"));
        assert!(!valid_user("42"));
        assert!(!valid_user("user_"));
        assert!(!valid_user("user_a b"));
        assert!(!valid_user("tailnet:ana@example.com"));
        assert!(!valid_user("guest:abc"));
    }
}
