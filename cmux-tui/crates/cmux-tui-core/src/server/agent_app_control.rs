//! `agents.appControl` (Settings > Agents > Agents Can Change cmux): the
//! person's one switch over whether agents in cmux may change the app or only
//! read it. `change` (unset) is the behavior before the switch existed;
//! `read` makes the daemon refuse every app-changing request an agent sends.
//!
//! An agent here is what the daemon itself can prove, never what a line
//! claims:
//! - a process in a cmux terminal (the connection's kernel peer ancestry,
//!   `Actor::Terminal`), which is how Claude Code, Codex or any agent typed
//!   into a cmux terminal reaches the socket through the `cmux` CLI;
//! - an agent chat (an acpmux ACP session), proved by the launch credential
//!   its `cmux` CLI sends (`Actor::AcpSession`), and a terminal's launch
//!   credential likewise.
//!
//! The daemon cannot tell a person typing `cmux` in a cmux terminal from an
//! agent doing it, so on `read` both are refused: the switch is for the
//! person who wants agents to look, not touch. A process outside cmux (the
//! app, another terminal app, a script the person runs) is the person's and
//! is never refused.
//!
//! What is allowed on `read`: every `cmux.protocol/2` operation that is not a
//! mutation (reads, streams, connection control), an agent's own reports
//! ([`REPORT_OPERATIONS`]: hooks, notifications, status, progress, log), and
//! the legacy commands in [`LEGACY_ALLOWED`] (reads and reports). Everything
//! else, including a line no rule here knows, is refused (deny by default):
//! `origin.forbidden` with reason `agents_read_only` on a v2 line, the error
//! `agents_read_only: ...` on a legacy one.
//!
//! The setting itself is userOnly (schemas/settings/source/agent-policy.json):
//! an agent cannot turn it back to `change`, and on `read` its settings writes
//! are refused here before the store sees them.

use serde_json::{Value, json};

use super::MessageWriter;
use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};
use crate::workspace_registry::Actor;

/// The refusal's `details.reason`.
pub(crate) const REASON: &str = "agents_read_only";

/// Mutations an agent may still send on `read`: its own reports, which
/// change no workspace, pane, tab, terminal or setting.
const REPORT_OPERATIONS: [ResourceOperation; 9] = [
    ResourceOperation::SessionJournalAppend,
    ResourceOperation::AgentReport,
    ResourceOperation::NotificationCreate,
    ResourceOperation::WorkspaceStatusSet,
    ResourceOperation::WorkspaceStatusClear,
    ResourceOperation::WorkspaceProgressSet,
    ResourceOperation::WorkspaceProgressClear,
    ResourceOperation::WorkspaceLogAppend,
    ResourceOperation::ConversationTyping,
];

/// Legacy commands (`{"cmd": ...}`) an agent may still send on `read`:
/// reads, streams of reads, connection metadata and its own reports.
/// Not `detach-client` (it detaches another viewer) or
/// `set-terminal-command-history` (it writes a setting). Sorted (binary
/// search).
pub(super) const LEGACY_ALLOWED: [&str; 77] = [
    "cloud-attachment-read",
    "cloud-conversation-history",
    "cloud-conversation-run",
    "cloud-conversation-runs",
    "cloud-conversation-snapshot",
    "cloud-conversation-thread",
    "cloud-host-replica-status",
    "cloud-inbox-list",
    "cloud-participant-avatar-get",
    "cloud-requests-list",
    "cloud-selfhost-info",
    "cloud-session-status",
    "conversation-attachment-read",
    "conversation-history",
    "conversation-link-resolve",
    "conversation-list",
    "conversation-live",
    "conversation-run",
    "conversation-runs",
    "conversation-search",
    "conversation-snapshot",
    "conversation-thread",
    "export-layout",
    "feed-local-list",
    "feed-local-read",
    "get-blob",
    "get-browser-provider",
    "get-cell-pixels",
    "get-frontend-browser-history",
    "get-frontend-projection",
    "get-host-size-policy",
    "get-size-state",
    "history-search",
    "home-inbox",
    "identify",
    "ids",
    "list-agents",
    "list-bookmarks",
    "list-clients",
    "list-notifications",
    "list-personal",
    "list-saved-screen-groups",
    "list-saved-tab-groups",
    "list-tab-groups",
    "list-terminal-commands",
    "list-terminals",
    "list-workspace-groups",
    "list-workspaces",
    "machine-listening-tcp",
    "machine-usage",
    "notify",
    "pane-neighbor",
    "ping",
    "process-info",
    "read-screen",
    "read-scrollback",
    "remote-host-status",
    "remote-terminal-snapshot",
    "report-agent",
    "resolve-terminal",
    "server-stats",
    "set-client-info",
    "shell-read",
    "snapshot-request",
    "subscribe",
    "subscribe-activity",
    "terminal-command-context",
    "terminal-events",
    "terminal-find",
    "terminal-history",
    "terminal-last-command",
    "terminal-ports",
    "terminal-read-range",
    "terminal-resources",
    "terminal-resume-command",
    "vt-state",
    "wait-for",
];

/// What one line asks for, as far as the switch cares.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Ask<'a> {
    /// A `cmux.protocol/2` line naming this operation (None: no catalog
    /// operation, such as a routed namespace).
    Resource(Option<ResourceOperation>),
    /// A legacy command by its wire name.
    Legacy(&'a str),
    /// Neither: another wire on the socket.
    Other,
}

impl Ask<'_> {
    /// Reads the line's `protocol`, `operation` and `cmd` members.
    pub(crate) fn of(line: &Value) -> Ask<'_> {
        if line.get("protocol").is_some() {
            let operation = line
                .get("operation")
                .cloned()
                .and_then(|name| serde_json::from_value::<ResourceOperation>(name).ok());
            return Ask::Resource(operation);
        }
        match line.get("cmd").and_then(Value::as_str) {
            Some(name) => Ask::Legacy(name),
            None => Ask::Other,
        }
    }

    /// Whether an agent may send it on `read`.
    pub(crate) fn allowed_read_only(&self) -> bool {
        match self {
            Ask::Resource(Some(operation)) => {
                !operation.is_mutation() || REPORT_OPERATIONS.contains(operation)
            }
            Ask::Resource(None) | Ask::Other => false,
            Ask::Legacy(name) => LEGACY_ALLOWED.binary_search(name).is_ok(),
        }
    }

    fn name(&self) -> String {
        match self {
            Ask::Resource(Some(operation)) => operation.wire_name().to_string(),
            Ask::Resource(None) => "this operation".to_string(),
            Ask::Legacy(name) => (*name).to_string(),
            Ask::Other => "this request".to_string(),
        }
    }
}

/// Whether `actor` is an agent for the switch (see the module doc).
pub(crate) fn is_agent(actor: &Actor) -> bool {
    matches!(actor, Actor::Terminal { .. } | Actor::AcpSession { .. })
}

/// Refuses `message` when `agents.appControl` is `read`, its sender is an
/// agent and it changes the app. None lets the line through (one atomic load
/// while the switch is `change`).
pub(super) fn refuse_line(
    mux: &Mux,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !mux.agents_read_only() {
        return None;
    }
    let line = serde_json::from_str::<Value>(message).ok()?;
    let ask = Ask::of(&line);
    if ask.allowed_read_only() {
        return None;
    }
    let connection = super::origin_gate::connection_actor(mux, client);
    let credential = line.get("credential").and_then(Value::as_str);
    // A refused credential is refused again where the line is dispatched;
    // here it counts as the connection's own actor.
    let actor = mux.request_actor(connection.clone(), credential).unwrap_or(connection);
    if !is_agent(&actor) {
        return None;
    }
    let text = format!(
        "{}: agents in cmux may read the app but not change it (Settings > Agents > Agents Can Change cmux, {})",
        ask.name(),
        crate::mux::settings::AGENTS_APP_CONTROL_SETTING
    );
    if let Ask::Resource(_) = ask {
        let error = ResourceError::new(
            crate::request_origin::ORIGIN_FORBIDDEN,
            text,
            // OriginForbiddenDetails takes no other member: the setting is
            // named in the message.
            json!({
                "derived": super::origin_gate::derived_origin(mux, client).wire_name(),
                "reason": REASON,
            }),
            false,
        );
        let response = crate::resource_router::malformed_resource_response(message, error);
        return Some(writer.send_control(&response).is_ok());
    }
    let id = line.get("id").cloned();
    Some(super::responses::send_request_error(writer, id, &format!("{REASON}: {text}")))
}
