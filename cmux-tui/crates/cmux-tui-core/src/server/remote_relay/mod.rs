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

use serde_json::{Value, json};

use super::{ClientTransport, Command, MessageWriter, Mux, Response};
use crate::remote_relay_state::{LinkPeer, StreamPolicy, remote_participant};

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
const DENIED_REJECT_CODES: &[&str] = &["unknown_conversation", "unknown_message", "not_participant"];

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
    /// True for a connection that came through the remote entry.
    pub(super) fn is_remote(&self, client: u64) -> bool {
        self.state
            .lock()
            .unwrap()
            .clients
            .get(&client)
            .is_some_and(|record| matches!(record.transport, ClientTransport::Remote))
    }
}

impl Mux {
    /// Record the verified link peer of remote connection `client` and bind
    /// its participant `remote_<install>`. A peer whose install may not open
    /// new streams (section 10) is not recorded and the connection is
    /// closed, so every later frame fails closed.
    pub(crate) fn bind_remote_peer(self: &Arc<Self>, client: u64, peer: &LinkPeer) {
        let _ = (client, peer);
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }

    /// The principal of `client`, or `None` for a remote connection without
    /// a peer record and any other connection that is not trusted local
    /// (refused, never `user_local`).
    pub(super) fn principal(&self, client: u64) -> Option<Principal> {
        let _ = client;
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }

    /// The conversation principal of `client` as a participant id:
    /// `user_local`, the bound agent, or `remote_<install>`. A connection
    /// without a principal (a remote one without a peer record, or one that is
    /// not trusted local) gets [`NO_PRINCIPAL`], which names no participant,
    /// so it fails closed and never falls back to `user_local`.
    pub(crate) fn conversation_principal(&self, client: u64) -> String {
        let bindings = self.bound_conversation_participant(client);
        bindings.unwrap_or_else(|| crate::conversation_store::LOCAL_USER.to_string())
    }

    /// Install the pairing records (`cmux server pair`) the owner scope
    /// reads.
    pub fn set_pairing_records(
        &self,
        records: Arc<dyn crate::PairingRecords>,
    ) {
        *self.remote_relay().pairing.lock().unwrap() = Some(records);
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
        if !mux.control_clients.is_remote(client) {
            return None;
        }
        let _ = (cmd, writer);
        None
    }

/// The remote `identify` reply: protocol version and the conversation
/// capability only. No socket path, pid, state directory, host name, window
/// or client ids.
fn identify() -> Value {
    json!({
        "app": "cmux-tui",
        "protocol": crate::provider_management::PROTOCOL_VERSION,
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
        let _ = (mux, client);
        (response, reason)
    }

/// The section 8 mapping of a conversation reject `reason` (or a remote
/// refusal) to the code a peer sees.
pub(super) fn remote_error_code(reason: Option<&str>, error: Option<&str>) -> &'static str {
        let _ = (reason, error);
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }

#[cfg(all(test, unix))]
mod tests;
