//! A phone's channel on a carrier stream (hq#8003 step 3): a unix connection that declared
//! `cloud-mobile-chat-v1` (hostd's `cloud-acpmux`, cmux-next-ios/SECURITY.md) reaches only what
//! hostd's Cloud ACP adapter sends, a chat start (#37242) included, and nothing else this
//! daemon serves. The declaration is sticky (`set-client-info` only adds capabilities), so once
//! made the connection stays held to this list.
//!
//! Default deny, by exact command name. Command-bearing params are refused on every command.
//! A new tab must be an agent tab of this machine's own store, and a close may end only an
//! agent tab no chat is bound to yet (a start the phone left; hostd's `abandon`), or a tab whose
//! chat this same connection started (hostd closes a start past its session limit). Every other
//! rule (the owner's signed role, the phone floor at the start and on every prompt) stays with
//! the command's own handler.

use super::*;
use crate::panic_free::RecoverPoison;

/// The commands hostd's Cloud ACP adapter sends (`cloud_acp.rs`, `services.rs`
/// `cloud_mobile_handshake`), and the read verbs the remote Cloud mobile path already allows.
const COMMANDS: &[&str] = &[
    "identify",
    "set-client-info",
    "list-workspaces",
    "create-workspace",
    "new-conversation-tab",
    "close-surface",
    "agent-session-of",
    "agent-session-start",
    "agent-session-attach",
    "agent-session-events",
    "agent-session-prompt",
    "agent-session-cancel",
    "agent-session-detach",
    "agent-session-context",
];

impl Mux {
    /// A unix connection that declared the phone's capability. Every line of every connection
    /// asks, so with the input lane on this reads the registry's published facts, never its lock
    /// (R-DAEMON-STATE S1, as `incognito_remote::is_remote_device`).
    pub(super) fn phone_carrier_client(&self, client: u64) -> bool {
        if self.control_clients.input_lane.on() {
            let facts = self.control_clients.state.load().recover_poison();
            return facts.clients.get(&client).is_some_and(|connection| connection.phone_carrier);
        }
        self.control_clients.is_unix(client)
            && self
                .control_clients
                .supports_capability(client, agent_session_attach::CLOUD_MOBILE_CHAT_CAPABILITY)
    }
}

/// `None` for an admitted line (the normal path serves it); otherwise the refusal was sent.
pub(super) fn refuse_line(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !mux.phone_carrier_client(client) || admits(mux, client, message) {
        return None;
    }
    Some(writer.send_control(&remote_relay::refusal(message, remote_relay::REMOTE_DENIED)).is_ok())
}

fn admits(mux: &Mux, client: u64, message: &str) -> bool {
    let Ok(Value::Object(fields)) = serde_json::from_str::<Value>(message) else { return false };
    let Some(command) = fields.get("cmd").and_then(Value::as_str) else { return false };
    if !COMMANDS.contains(&command)
        || remote_relay::gate::COMMAND_PARAMS.iter().any(|param| fields.contains_key(*param))
    {
        return false;
    }
    match command {
        "new-conversation-tab" | "close-surface" => {
            let Ok(request) = serde_json::from_str::<Request>(message) else { return false };
            match request.cmd {
                Command::NewConversationTab(params) => params.native_agent_tab(mux),
                Command::CloseSurface { surface } => {
                    unbound_agent_tab(mux, surface)
                        || mux.control_clients.started_tab(client, surface)
                }
                _ => false,
            }
        }
        _ => true,
    }
}

/// An agent tab of this machine's store with no chat bound to it.
fn unbound_agent_tab(mux: &Mux, surface: SurfaceId) -> bool {
    let Some(runtime) = mux.surface(surface) else { return false };
    matches!(
        mux.conversation_tab_of(&runtime),
        Some(crate::state::conversation_tabs_store::ConversationTabRecord::AgentSession {
            host,
            session: None,
            ..
        }) if host == agent_session_attach::agent_session_start::store_host(mux)
    )
}

#[cfg(test)]
#[path = "phone_carrier_tests.rs"]
mod tests;
