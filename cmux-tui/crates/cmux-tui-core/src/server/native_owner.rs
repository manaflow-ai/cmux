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
    "agent-session-fork",
    "agent-session-side",
    "agent-session-media",
    "agent-session-typing",
    "agent-session-view",
    "agent-session-context",
    // The owner's `/btw` on its Cloud chat (`agent-session-btw-v1`): owner-only in its handler.
    "agent-session-btw",
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
    // The app's terminal theme on connect (`set-default-colors`): the owner's own machine.
    "set-default-colors",
    // The owner's own terminals and layout (`cmux cloud ssh` opens a tab with new-tab, then types into
    // it): the commands the app's terminal panes send. Host administration (shutdown-daemon,
    // apps-*, remote-host-*, pairing, credentials) stays local only.
    "new-tab",
    "new-pane",
    "new-pane-right",
    "new-row",
    "split",
    "close-pane",
    "close-surface",
    "close-tabs",
    "close-terminal",
    "rename-surface",
    "rename-workspace",
    "rename-pane",
    "set-split-ratio",
    "set-divider-visible",
    "set-viewport-pane-width",
    "set-row-heights",
    "undo-layout",
    "zoom-pane",
    "swap-pane",
    "move-tab",
    "set-tab-pinned",
    "read-screen",
    "read-scrollback",
    "send-key",
    "list-terminals",
    "set-attach-visibility",
    "restart-tab",
    "clear-history",
    "terminal-clipboard-reply",
    "terminal-clipboard-subscribe",
    // Shell mode of a chat on this machine (`shell_wire.rs`): the owner's `!` commands run here.
    "shell-run",
    "shell-read",
    "shell-stop",
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
    WORKSPACE_REGISTRY_CAPABILITY,
    // The rest of what the app requires (`DaemonCapability.required`): the commands behind them
    // (`split`, `set-viewport-pane-width`, `undo-layout`) are in COMMANDS. A link that left them out
    // read as a refused daemon, and the app updated the machine on every reconnect, also one already
    // on its own build (2026-11-07: "started but its agent didn't (cmux-tui connection closed: EOF)").
    VIEWPORT_SPLITS_CAPABILITY,
    VIEWPORT_COLUMN_RESIZE_CAPABILITY,
    LAYOUT_UNDO_CAPABILITY,
    LAYOUT_DELTA_CAPABILITY,
    // Both ride commands this carrier already admits (`set-divider-visible`, `split`).
    crate::mux::SPLIT_DIVIDER_VISIBILITY_CAPABILITY,
    split_kind::SPLIT_AROUND_CAPABILITY,
    SESSION_IDENTITY_CAPABILITY,
    TERMINAL_ENV_CAPABILITY,
    TERMINAL_PLACEMENT_ENV_CAPABILITY,
    crate::state::conversation_tabs_store::CONVERSATION_TABS_CAPABILITY,
    crate::state::conversation_tabs_store::AGENT_SESSION_TABS_CAPABILITY,
    conversation_tabs_wire::CONVERSATION_TAB_TRANSACTION_CAPABILITY,
    "machine-identity-v1",
    AGENT_SESSION_ATTACH_CAPABILITY,
    agent_session_attach::AGENT_SESSION_CONTENT_CAPABILITY,
    AGENT_SESSION_START_CAPABILITY,
    // A start with no folder (`agent-session-start`, already admitted): the machine makes
    // `~/chats/<id>`. Without it here the app refuses a no-folder start before sending it.
    AGENT_SESSION_START_NO_CWD_CAPABILITY,
    AGENT_SESSION_TRUST_CAPABILITY,
    AGENT_SESSION_TRUST_VM_KIND_CAPABILITY,
    AGENT_SESSION_START_KEYED_REASON_CAPABILITY,
    AGENT_SESSION_START_VM_KIND_CAPABILITY,
    AGENT_SESSION_START_MODEL_CAPABILITY,
    AGENT_SESSION_START_MODE_CAPABILITY,
    agent_session_attach::AGENT_SESSION_PRESENCE_CAPABILITY,
    agent_session_attach::AGENT_SESSION_CONTEXT_CAPABILITY,
    agent_session_attach::AGENT_SESSION_BTW_CAPABILITY,
    agent_session_attach::agent_session_children::AGENT_SESSION_CHILDREN_CAPABILITY,
    AGENT_SESSION_FORK_CAPABILITY,
    agent_session_attach::AGENT_SESSION_SIDE_CAPABILITY,
    agent_transfer::AGENT_TRANSFER_CAPABILITY,
    agent_transfer::AGENT_TRANSFER_VM_KIND_CAPABILITY,
    agent_inventory::CAPABILITY,
    agent_inventory::OWNER_CAPABILITY,
    agent_inventory::REFRESH_CAPABILITY,
    agent_inventory::watch::CAPABILITY,
    agent_inventory::watch::FENCED_CAPABILITY,
    agent_inventory::watch::ADMISSION_CAPABILITY,
    // A Cloud chat's folder copy (`cmux link start-chat copy`, `seed push`, `sync push`) reaches
    // the owner's own machine over this carrier. Its frames pass the entry's `FsGate` and the
    // fs_wire principal check as on the classic entry; only the owner's Native dial may send them
    // (`fs_wire::native_dial_admits`). Listed only while the host serves them (identify's own
    // advertised set is filtered through this list), so a host without the file owner says so.
    crate::fs_ops::FS_CAPABILITY,
    crate::fs_ops::FS_SYMLINK_CAPABILITY,
    crate::fs_ops::FS_WRITE_DEFLATE_CAPABILITY,
    crate::fs_ops::FS_WRITE_NOFOLLOW_CAPABILITY,
    crate::fs_ops::FS_READ_NOFOLLOW_CAPABILITY,
    crate::git_seed::GIT_SEED_CAPABILITY,
    crate::git_seed::GIT_SEED_EXPORT_CAPABILITY,
    crate::git_seed::GIT_SEED_HOLD_CAPABILITY,
    crate::blob_fetch::BLOB_FETCH_CAPABILITY,
    crate::shell_runs::CAPABILITY,
];

/// Whether identify on this carrier lists `capability` (tests read the policy through this).
#[cfg(test)]
pub(super) fn commands() -> &'static [&'static str] {
    COMMANDS
}

#[cfg(test)]
pub(super) fn carries(capability: &str) -> bool {
    CAPABILITIES.contains(&capability)
}

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
        | Command::CreateTerminal { .. }
        | Command::SetDefaultColors { .. }
        | Command::NewTab { .. }
        | Command::NewPane { .. }
        | Command::NewPaneRight { .. }
        | Command::NewRow { .. }
        | Command::Split { .. }
        | Command::ClosePane { .. }
        | Command::CloseSurface { .. }
        | Command::CloseTabs { .. }
        | Command::CloseTerminal { .. }
        | Command::RenameSurface { .. }
        | Command::RenameWorkspace { .. }
        | Command::RenamePane { .. }
        | Command::SetSplitRatio { .. }
        | Command::SetDividerVisible { .. }
        | Command::SetViewportPaneWidth { .. }
        | Command::SetRowHeights { .. }
        | Command::UndoLayout { .. }
        | Command::ZoomPane { .. }
        | Command::SwapPane { .. }
        | Command::MoveTab { .. }
        | Command::SetTabPinned { .. }
        | Command::ReadScreen { .. }
        | Command::ReadScrollback { .. }
        | Command::SendKey { .. }
        | Command::ListTerminals
        | Command::SetAttachVisibility { .. }
        | Command::RestartTab { .. }
        | Command::ClearHistory { .. }
        | Command::TerminalClipboardReply { .. }
        | Command::TerminalClipboardSubscribe { .. }
        | Command::ShellRun(_)
        | Command::ShellRead(_)
        | Command::ShellStop(_) => true,
        Command::NewConversationTab(params) => params.native_agent_tab(mux),
        _ => terminal::allows(mux, client, command),
    }
}

#[cfg(test)]
mod fork_admission_tests {
    use super::*;

    #[test]
    fn a_native_owner_may_fork_its_attached_chat() {
        assert!(admits(r#"{"cmd":"agent-session-fork","surface":1,"through_seq":3}"#));
        assert!(CAPABILITIES.contains(&AGENT_SESSION_FORK_CAPABILITY));
    }

    /// A Cloud chat's New side chat and `/side` (agent_session_side.rs): the owner's carrier
    /// reaches it, and the carrier's identify names it.
    #[test]
    fn a_native_owner_may_open_a_side_chat_of_its_attached_chat() {
        assert!(admits(r#"{"cmd":"agent-session-side","surface":1,"live":true}"#));
        assert!(CAPABILITIES.contains(&agent_session_attach::AGENT_SESSION_SIDE_CAPABILITY));
    }
}
