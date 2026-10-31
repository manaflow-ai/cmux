//! A signed Native owner may use the agent carrier without becoming a local
//! connection. Every other command retains the remote entry's original policy.
use super::*;
use cmux_link::token::VmKind;
use serde::Deserialize;

#[path = "native_owner_terminal.rs"]
mod terminal;

// Exact names: adding a new local command never makes it remotely callable.
const COMMANDS: &[&str] = &[
    "attach-surface",
    "send",
    "resize-surface",
    "resize-attached-view",
    "set-client-sizing",
    "set-size-policy",
    "set-size-counts",
    "release-attached-view-size",
    "detach-attached-view",
    "snapshot-request",
    "identify",
    "subscribe",
    "list-workspaces",
    "create-workspace",
    "create-terminal",
    "new-conversation-tab",
    "set-client-info",
    "agent-session-start",
    "agent-session-trust",
    "agent-session-attach",
    "agent-session-events",
    "agent-session-prompt",
    "agent-session-cancel",
    "agent-session-permission",
    "agent-session-detach",
    "agent-session-children",
    "agent-session-media",
    "agent-session-typing",
    "agent-session-view",
    "agent-transfer-receive",
    "agent-transfer-write",
    "agent-transfer-finish",
    "agent-transfer-receive-abort",
    "agent-transfer-begin",
    "agent-transfer-read",
    "agent-transfer-commit",
    "agent-transfer-abort",
    "agent-transfer-source",
    "agent-inventory",
    "agent-inventory-refresh",
    "agent-inventory-watch",
];

const CAPABILITIES: &[&str] = &[
    VIEW_ATTACHMENT_LEASE_CAPABILITY,
    VIEW_ATTACHMENT_DETACH_CAPABILITY,
    ATTACH_INITIAL_SIZE_CAPABILITY,
    SHARED_SIZING_CAPABILITY,
    "attach-identity-v1",
    terminal_snapshot::TERMINAL_SNAPSHOT_CAPABILITY,
    terminal_snapshot::TERMINAL_SNAPSHOT_HISTORY_CAPABILITY,
    terminal_snapshot::TERMINAL_SNAPSHOT_LOCAL_HISTORY_CAPABILITY,
    terminal_snapshot::TERMINAL_SNAPSHOT_IMAGES_CAPABILITY,
    WORKSPACE_REGISTRY_CAPABILITY,
    LAYOUT_DELTA_CAPABILITY,
    SESSION_IDENTITY_CAPABILITY,
    TERMINAL_ENV_CAPABILITY,
    TERMINAL_PLACEMENT_ENV_CAPABILITY,
    crate::state::conversation_tabs_store::CONVERSATION_TABS_CAPABILITY,
    crate::state::conversation_tabs_store::AGENT_SESSION_TABS_CAPABILITY,
    conversation_tabs_wire::CONVERSATION_TAB_TRANSACTION_CAPABILITY,
    "machine-identity-v1",
    AGENT_SESSION_ATTACH_CAPABILITY,
    AGENT_SESSION_START_CAPABILITY,
    AGENT_SESSION_TRUST_CAPABILITY,
    AGENT_SESSION_TRUST_VM_KIND_CAPABILITY,
    AGENT_SESSION_START_KEYED_REASON_CAPABILITY,
    AGENT_SESSION_START_VM_KIND_CAPABILITY,
    AGENT_SESSION_START_MODEL_CAPABILITY,
    agent_session_attach::AGENT_SESSION_PRESENCE_CAPABILITY,
    agent_session_attach::agent_session_children::AGENT_SESSION_CHILDREN_CAPABILITY,
    agent_transfer::AGENT_TRANSFER_CAPABILITY,
    agent_transfer::AGENT_TRANSFER_VM_KIND_CAPABILITY,
    agent_inventory::CAPABILITY,
    agent_inventory::OWNER_CAPABILITY,
    agent_inventory::REFRESH_CAPABILITY,
    agent_inventory::watch::CAPABILITY,
    agent_inventory::watch::FENCED_CAPABILITY,
    agent_inventory::watch::ADMISSION_CAPABILITY,
];

pub(super) fn admits(frame: &str) -> bool {
    let Ok(Value::Object(fields)) = serde_json::from_str::<Value>(frame) else { return false };
    !fields.contains_key("protocol")
        && fields.get("cmd").and_then(Value::as_str).is_some_and(|cmd| {
            COMMANDS.contains(&cmd)
                && (cmd != "set-size-policy" || terminal::latest_policy_frame(&fields))
        })
}

impl Mux {
    /// Signed connection metadata only; no request or local guest marker can
    /// manufacture this authority. Revocation and host policy are read again
    /// on every request, including read/attach/transfer continuation requests.
    pub(super) fn is_native_agent_owner(&self, client: u64) -> bool {
        let signed_owner = self.control_clients.state.lock().ok().is_some_and(|state| {
            state.clients.get(&client).is_some_and(|record| {
                matches!(record.transport, ClientTransport::Remote)
                    && record.native_vm_kind == Some(Some(VmKind::Owner))
            })
        });
        signed_owner
            && matches!(self.frame_principal(client), Some(remote_relay::Principal::Remote(_)))
            && self.agent_host_gate(client, None).is_ok()
    }

    pub(super) fn agent_carrier_allowed(&self, client: u64) -> bool {
        (self.control_clients.is_unix(client) && !self.is_remote_client(client))
            || self.is_native_agent_owner(client)
    }
}

/// Called only on the remote dispatch path. A denied Native owner request
/// falls back to the original remote policy, never to unrestricted local dispatch.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !admits(message) || !mux.is_native_agent_owner(client) {
        return None;
    }
    let mut fields = serde_json::from_str::<serde_json::Map<String, Value>>(message).ok()?;
    let command = fields.remove("cmd")?.as_str()?.to_owned();
    let id = fields.remove("id");
    if command == "identify" || command == "set-client-info" {
        let result = handshake(mux, client, &command, Value::Object(fields));
        let response = match result {
            Ok(data) => json!({"id": id, "ok": true, "data": data}),
            Err(_) => remote_relay::refusal(message, "remote_denied"),
        };
        return Some(writer.send_control(&response).is_ok());
    }
    if let Ok(request) = serde_json::from_str::<Request>(message)
        && raw_command(mux, client, &request.cmd)
    {
        return Some(handle_request(mux, client, request, writer));
    }
    agent_session_attach::try_handle(mux, client, message, writer)
        .or_else(|| agent_transfer::try_handle(mux, client, message, writer))
        .or_else(|| agent_inventory::try_handle(mux, client, message, writer))
        .or_else(|| agent_inventory::watch::try_handle(mux, client, message, writer))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Identify {
    #[serde(default)]
    machine_metadata: bool,
    #[serde(default)]
    revisions: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ClientInfo {
    name: Option<String>,
    kind: Option<String>,
    capabilities: Option<Vec<String>>,
    // The app sends these display hints; neither changes the stamped identity.
    #[serde(rename = "device_kind")]
    _device_kind: Option<String>,
    #[serde(rename = "device_name")]
    _device_name: Option<String>,
}

fn handshake(mux: &Arc<Mux>, client: u64, command: &str, fields: Value) -> anyhow::Result<Value> {
    if command == "identify" {
        let params: Identify = serde_json::from_value(fields)?;
        let mut identity = cmd_server::identify(mux, params.machine_metadata, params.revisions)?;
        identity["capabilities"] = json!(
            identify_capabilities(mux)
                .into_iter()
                .filter(|cap| CAPABILITIES.contains(cap))
                .collect::<Vec<_>>()
        );
        return Ok(identity);
    }
    let params: ClientInfo = serde_json::from_value(fields)?;
    // Frontends advertise their full vocabulary. Retain only this carrier
    // vocabulary: a capability declaration never grants another command.
    let capabilities = params
        .capabilities
        .map(|caps| caps.into_iter().filter(|cap| CAPABILITIES.contains(&cap.as_str())).collect());
    mux.control_clients.set_info(client, params.name, params.kind, capabilities)?;
    Ok(json!({}))
}

/// The only raw commands that may reach existing generic command handlers.
/// This is checked both before routing and again by the remote interceptor.
pub(super) fn raw_command(mux: &Mux, client: u64, command: &Command) -> bool {
    match command {
        Command::Subscribe { surface: None, .. }
        | Command::ListWorkspaces
        | Command::CreateWorkspace { .. }
        | Command::CreateTerminal { .. } => true,
        Command::NewConversationTab(params) => params.native_agent_tab(mux),
        _ => terminal::allows(mux, client, command),
    }
}
