//! The remote-relay policy of the session daemon
//! (plans/cmux-next/server-remote-conversations.md sections 2 to 5, 7, 8 and
//! 10). A `cmux link` peer reaches the daemon only through the remote entry
//! (`remote_entry.rs`, lane 12) as a [`ClientTransport::Remote`] client. Three
//! layers keep it to its owned conversations:
//!
//! 1. [`gate::ConversationGate`] checks every frame before anything parses or
//!    dispatches it: exact command allowlist, exact params, no command-bearing
//!    params, text-only parts (sections 3, 4 and 7).
//! 2. [`intercept`] runs first in command dispatch for a remote client: a
//!    remote-only `identify`, a reduced `set-client-info`, a filtered
//!    `subscribe`, and a refusal of every other non-conversation command
//!    (defense in depth behind the gate).
//! 3. The conversation handlers ([`conversations`]) scope every id to the
//!    owner's conversations that list the install's participant and answer
//!    with remote-only projections ([`project`]); [`redact_response`] maps
//!    every error to a code (section 8).
//!
//! Unknown and unowned ids give the same `remote_denied`, so a peer cannot
//! probe which objects exist.

pub(super) mod conversations;
pub(super) mod gate;
pub(super) mod participants;
pub(super) mod project;
mod revocation;

use std::sync::Arc;
use std::sync::PoisonError;

use serde_json::{Value, json};

use super::{ClientTransport, Command, MessageWriter, Mux, Response};
use crate::remote_relay_state::{
    BindRefused, LinkPeer, RelayLock, StreamPolicy, lock_checked, remote_participant,
};

pub use gate::ConversationGate;

/// The error code of every refused remote request (the same as the remote
/// entry's refusal of a frame).
pub(super) const REMOTE_DENIED: &str = "remote_denied";
/// The principal of a connection that has none. Not a valid participant id
/// (no `user_`, `agent_` or `remote_` prefix), so it matches no participant.
pub(super) const NO_PRINCIPAL: &str = "none";
/// Every other remote error.
pub(super) const REMOTE_ERROR: &str = "remote_error";
/// Reject codes a remote peer may see unchanged (section 8).
const KEPT_REJECT_CODES: &[&str] = &[
    "actor_mismatch",
    "not_author",
    "invalid_parts",
    "idempotency_conflict",
    "cursor_regression",
    "approval_required",
];
/// Reject codes that would tell a peer whether an object exists.
const DENIED_REJECT_CODES: &[&str] =
    &["unknown_conversation", "unknown_message", "not_participant"];

/// A refusal with no detail: a gate refusal, an unowned or unknown id, or a
/// remote connection without a peer record.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct RemoteDenied;

impl std::fmt::Display for RemoteDenied {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(REMOTE_DENIED)
    }
}

impl std::error::Error for RemoteDenied {}

pub(super) fn denied() -> anyhow::Error {
    RemoteDenied.into()
}

/// Who a conversation request comes from (section 2). There is no default:
/// a remote connection without a peer record has no principal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Principal {
    /// The Mac's own user (`user_local`) on a trusted local connection.
    Local,
    /// A local connection bound to agent `participant` with its token.
    Agent(String),
    /// A paired install, from the link's stamp.
    Remote(LinkPeer),
}

impl super::ClientRegistry {
    /// The transport of a registered client, or `None` for an id the
    /// registry does not list (never registered, or already disconnected).
    /// A poisoned registry lock also gives `None`, which every caller treats
    /// as remote (fail closed).
    pub(super) fn transport_of(&self, client: u64) -> Option<ClientTransport> {
        lock_checked(&self.state, RelayLock::Clients)
            .ok()?
            .clients
            .get(&client)
            .map(|record| record.transport)
    }

    /// True for a connection that came through the remote entry (tests;
    /// dispatch uses `Mux::is_remote_client`, which also fails closed).
    #[cfg(test)]
    pub(super) fn is_remote(&self, client: u64) -> bool {
        matches!(self.transport_of(client), Some(ClientTransport::Remote))
    }
}

impl Mux {
    /// True for a client that gets the remote gates: it came through the
    /// remote entry, it has a peer record, or the registry does not list it
    /// at all. An unregistered id fails closed: it is never trusted as
    /// local (a frame racing its connection's disconnect, a stray id).
    pub(super) fn is_remote_client(&self, client: u64) -> bool {
        match self.control_clients.transport_of(client) {
            // A poisoned peers lock cannot say the client has no peer
            // record: remote (fail closed).
            Some(ClientTransport::Unix | ClientTransport::WebSocket) => {
                self.remote_relay().peer_checked(client).map_or(true, |peer| peer.is_some())
            }
            Some(ClientTransport::Remote) | None => true,
        }
    }

    /// Record the verified link peer of remote connection `client` and bind
    /// its participant `remote_<install>`. Refuses, and records nothing,
    /// when the install may not open new streams (section 10) or a relay
    /// lock is poisoned (fail closed); the connection loop then closes the
    /// stream before its first frame.
    ///
    /// Lock order: revocation, then peers. The revocation lock is held while
    /// the peer is added, so a concurrent revoke either sees the new stream
    /// (and closes it) or runs first (and this refuses it).
    pub(crate) fn bind_remote_peer(&self, client: u64, peer: &LinkPeer) -> Result<(), BindRefused> {
        let relay = self.remote_relay();
        let revocation = lock_checked(&relay.revocation, RelayLock::Revocation)?;
        if revocation.policy(&peer.install) != StreamPolicy::Serve {
            return Err(BindRefused::Policy);
        }
        lock_checked(&relay.peers, RelayLock::Peers)?.insert(client, peer.clone());
        self.bind_conversation_principal(client, remote_participant(&peer.install));
        drop(revocation);
        Ok(())
    }

    /// The principal of `client` for one frame, checked now: a remote
    /// principal also needs its install's revocation policy to allow its
    /// open streams (a revoked install, or one past the 72 h offline limit,
    /// is refused even before its streams close). A poisoned relay lock
    /// refuses (fail closed).
    pub(super) fn frame_principal(&self, client: u64) -> Option<Principal> {
        let principal = self.principal(client)?;
        if let Principal::Remote(peer) = &principal {
            let revocation =
                lock_checked(&self.remote_relay().revocation, RelayLock::Revocation).ok()?;
            if revocation.policy(&peer.install) == StreamPolicy::Close {
                return None;
            }
        }
        Some(principal)
    }

    /// The principal of `client`, or `None` for a remote connection without
    /// a peer record and any other connection that is not trusted local
    /// (refused, never `user_local`).
    pub(super) fn principal(&self, client: u64) -> Option<Principal> {
        // A poisoned peers lock gives no principal, never a local one.
        if let Some(peer) = self.remote_relay().peer_checked(client).ok()? {
            return Some(Principal::Remote(peer));
        }
        if !self.control_clients.is_unix(client) {
            return None;
        }
        Some(match self.bound_conversation_participant(client) {
            Some(participant) => Principal::Agent(participant),
            None => Principal::Local,
        })
    }

    /// The conversation principal of `client` as a participant id:
    /// `user_local`, the bound agent, or `remote_<install>`. A connection
    /// without a principal (a remote one without a peer record, or one that is
    /// not trusted local) gets [`NO_PRINCIPAL`], which names no participant,
    /// so it fails closed and never falls back to `user_local`.
    pub(crate) fn conversation_principal(&self, client: u64) -> String {
        match self.principal(client) {
            Some(Principal::Local) => crate::conversation_store::LOCAL_USER.to_string(),
            Some(Principal::Agent(participant)) => participant,
            Some(Principal::Remote(peer)) => remote_participant(&peer.install),
            None => NO_PRINCIPAL.to_string(),
        }
    }

    /// Install the pairing records (`cmux server pair`) the owner scope
    /// reads.
    pub fn set_pairing_records(&self, records: Arc<dyn crate::PairingRecords>) {
        // Safety: this replaces the whole value, and the lock stays poisoned,
        // so every owner read still fails closed (`owner_user`).
        *self.remote_relay().pairing.lock().unwrap_or_else(PoisonError::into_inner) = Some(records);
    }
}

/// Command dispatch for a remote client, before any local handler. `None`
/// for a local client and for the conversation commands, whose handlers
/// apply the owner scope themselves.
pub(super) fn intercept(
    mux: &Arc<Mux>,
    client: u64,
    cmd: &Command,
    writer: &MessageWriter,
) -> Option<anyhow::Result<Value>> {
    if !mux.is_remote_client(client) {
        return None;
    }
    Some(match cmd {
        Command::Identify => Ok(identify()),
        Command::SetClientInfo { name, capabilities, .. } => {
            set_client_info(mux, client, name.clone(), capabilities.clone())
        }
        Command::Subscribe { tree_events: None, surface: None } => {
            conversations::subscribe(mux, client, writer)
        }
        Command::ConversationList
        | Command::ConversationSnapshot(_)
        | Command::ConversationHistory(_)
        | Command::ConversationOp(_)
        | Command::ConversationTyping(_) => return None,
        _ => Err(denied()),
    })
}

/// Every frame of a remote client, from the top of the connection handler:
/// one path, so no local router or error path (url-open, vt-state,
/// shutdown, the pending-handoff refusal, a bad-request text) ever answers
/// a remote client. Refusals are codes only.
pub(super) fn handle_frame(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> bool {
    if mux.daemon_handoff_in_progress() {
        return writer.send_control(&refusal(message, REMOTE_ERROR)).is_ok();
    }
    // The seven `fs-v1` ops (exactly; fs_wire.rs) have their own owner and
    // checks, outside the conversation allowlist.
    #[cfg(unix)]
    if let Some(keep_open) = super::fs_wire::try_handle(mux, client, message, writer) {
        return keep_open;
    }
    if gate::check_frame(message).is_err() {
        return writer.send_control(&refusal(message, REMOTE_DENIED)).is_ok();
    }
    match serde_json::from_str::<super::Request>(message) {
        Ok(request) => super::handle_request(mux, client, request, writer),
        Err(_) => writer.send_control(&refusal(message, REMOTE_ERROR)).is_ok(),
    }
}

/// The in-process form of `handle_connection_frame` for tests: the
/// transport comes from the registry, and an unregistered id gets the
/// remote path (fail closed). Connections pass their own transport value.
#[cfg(test)]
pub(super) fn handle_connection_message(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
    scheduler: &Arc<super::ConnectionSurfaceScheduler>,
) -> bool {
    let transport = mux.control_clients.transport_of(client).unwrap_or(ClientTransport::Remote);
    super::handle_connection_frame(mux, client, transport, message, writer, scheduler)
}

#[cfg(test)]
impl Mux {
    /// Tests: make the fixed id `client` a registered trusted-local
    /// connection, so in-process tests that dispatch with a literal id get
    /// local trust only as a registered client (an unregistered id fails
    /// closed).
    pub(super) fn local_test_client(&self, client: u64) -> u64 {
        if self.control_clients.transport_of(client).is_none() {
            let sink = super::QueuedSink {
                outbound: Arc::new(super::BoundedOutbound::default()),
                control: None,
            };
            let id = self.control_clients.register(ClientTransport::Unix, MessageWriter::new(sink));
            let mut state =
                self.control_clients.state.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(record) = state.clients.remove(&id) {
                state.clients.entry(client).or_insert(record);
            }
        }
        client
    }
}

/// A refusal of `message` with `code` and no detail; its `id` when it has
/// one.
pub(super) fn refusal(message: &str, code: &str) -> Value {
    let id = serde_json::from_str::<Value>(message).ok().and_then(|frame| frame.get("id").cloned());
    let mut response = json!({"ok": false, "error": code, "error_code": code});
    if let Some(id) = id {
        response["id"] = id;
    }
    response
}

/// The remote `identify` reply: protocol version and the conversation
/// capability only. No socket path, pid, state directory, host name, window
/// or client ids.
fn identify() -> Value {
    json!({
        "app": "cmux-tui",
        // The daemon socket protocol, as the local `identify` answers (clients read it as that).
        "protocol": crate::server::PROTOCOL_VERSION,
        "capabilities": gate::REMOTE_CAPABILITIES,
    })
}

/// `set-client-info` reduced to `name` and the allowed capabilities. The
/// identity fields are ignored: identity is only the stamp.
fn set_client_info(
    mux: &Mux,
    client: u64,
    name: Option<String>,
    capabilities: Option<Vec<String>>,
) -> anyhow::Result<Value> {
    if capabilities.iter().flatten().any(|c| !gate::REMOTE_CAPABILITIES.contains(&c.as_str())) {
        return Err(denied());
    }
    mux.control_clients.set_info(client, name, None, capabilities)?;
    Ok(json!({}))
}

/// The response a remote client gets: errors are codes only, never text with
/// paths or ids (section 8). Local responses pass unchanged.
pub(super) fn redact_response(
    mux: &Mux,
    client: u64,
    response: Response,
    reason: Option<String>,
) -> (Response, Option<String>) {
    if response.ok || !mux.is_remote_client(client) {
        return (response, reason);
    }
    let code = remote_error_code(reason.as_deref(), response.error.as_deref());
    let response = Response {
        id: response.id,
        ok: false,
        data: None,
        error: Some(code.to_string()),
        error_code: Some(code.to_string()),
        error_delivery: None,
    };
    (response, None)
}

/// The section 8 mapping of a conversation reject `reason` (or a remote
/// refusal) to the code a peer sees.
pub(super) fn remote_error_code(reason: Option<&str>, error: Option<&str>) -> &'static str {
    match reason {
        Some(reason) if DENIED_REJECT_CODES.contains(&reason) => REMOTE_DENIED,
        Some(reason) => {
            KEPT_REJECT_CODES.iter().find(|kept| **kept == reason).copied().unwrap_or(REMOTE_ERROR)
        }
        None if error == Some(REMOTE_DENIED) => REMOTE_DENIED,
        None => REMOTE_ERROR,
    }
}

#[cfg(all(test, unix))]
mod tests;
