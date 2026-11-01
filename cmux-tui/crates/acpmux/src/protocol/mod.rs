//! The acpmux JSON-RPC surface as one registry: every method and
//! notification name, and for the typed ones the serde types of their
//! params, result or payload. `ir()` emits it as `spec/acpmux-protocol.json`
//! (JSON Schema 2020-12 subschemas from schemars); the web generates its
//! types and typed client from that file (`webviews/scripts/acpmux-protocol-codegen.ts`).
//!
//! A method whose types are not declared yet is listed with `params` and
//! `result` of `true` (any JSON), so the registry names the whole surface.
//! Tests fail when the committed IR is stale or when the dispatcher serves
//! a name this registry lacks (`protocol/tests.rs`).

pub mod auth;
pub mod events;
pub mod inventory;
pub mod mailbox;
pub mod peer_state;
pub mod permission;
pub mod presence;
pub mod process;
pub mod session;
#[cfg(test)]
mod tests;

use std::collections::BTreeMap;

use schemars::JsonSchema;
use schemars::generate::{SchemaGenerator, SchemaSettings};
use serde_json::{Map, Value, json};

use crate::rpc::method;

/// The IR format version. Bump on a change to the IR's own shape.
pub const IR_VERSION: &str = "1";

/// Who sends a message, and whether it is answered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// A client asks the daemon and gets a result.
    Request,
    /// A client tells the daemon; no answer (`session/cancel`).
    ClientNotification,
    /// The daemon tells clients; no answer.
    Notification,
    /// The daemon asks a client and gets a result (`session/request_permission`).
    ServerRequest,
    /// Never on the wire: the client library puts it on its own stream.
    ClientLocal,
}

impl Kind {
    fn as_str(self) -> &'static str {
        match self {
            Kind::Request => "request",
            Kind::ClientNotification => "client_notification",
            Kind::Notification => "notification",
            Kind::ServerRequest => "server_request",
            Kind::ClientLocal => "client_local",
        }
    }
}

/// `_acpmux/protocol` takes no params.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, JsonSchema)]
#[schemars(deny_unknown_fields)]
pub struct ProtocolParams {}

/// The sender and receiver projection of a persisted session-to-session message.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct MessageEvent {
    pub at: u64,
    pub message_id: String,
    pub sender: MessageSender,
    pub session_id: String,
    pub text: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct MessageSender {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    pub name: String,
    pub session_id: String,
}

/// What `_acpmux/protocol` answers: `ir()`, built once per daemon run.
pub fn served() -> &'static Value {
    static IR: std::sync::OnceLock<Value> = std::sync::OnceLock::new();
    IR.get_or_init(ir)
}

type SchemaFn = fn(&mut SchemaGenerator) -> schemars::Schema;

/// One registry entry.
#[derive(Clone, Copy)]
pub struct MethodDecl {
    pub name: &'static str,
    pub kind: Kind,
    /// Standard ACP, passed through to the session's agent.
    pub acp: bool,
    /// `None`: not declared yet (any JSON).
    pub params: Option<SchemaFn>,
    /// `None`: not declared yet, or a notification.
    pub result: Option<SchemaFn>,
}

fn schema_of<T: JsonSchema>(generator: &mut SchemaGenerator) -> schemars::Schema {
    generator.subschema_for::<T>()
}

const fn untyped(name: &'static str, kind: Kind) -> MethodDecl {
    MethodDecl { name, kind, acp: false, params: None, result: None }
}

const fn acp(name: &'static str, kind: Kind) -> MethodDecl {
    MethodDecl { name, kind, acp: true, params: None, result: None }
}

fn request<P: JsonSchema, R: JsonSchema>(name: &'static str) -> MethodDecl {
    MethodDecl {
        name,
        kind: Kind::Request,
        acp: false,
        params: Some(schema_of::<P>),
        result: Some(schema_of::<R>),
    }
}

fn notification<P: JsonSchema>(name: &'static str) -> MethodDecl {
    MethodDecl {
        name,
        kind: Kind::Notification,
        acp: false,
        params: Some(schema_of::<P>),
        result: None,
    }
}

/// Every method and notification acpmux serves or sends, in wire-name order
/// within each group.
pub fn registry() -> Vec<MethodDecl> {
    use Kind::*;
    use mailbox::*;
    use permission::*;
    use process::*;
    use session::*;
    vec![
        // Standard ACP.
        acp(method::INITIALIZE, Request),
        acp(method::AUTHENTICATE, Request),
        acp(method::SESSION_NEW, Request),
        acp(method::SESSION_LOAD, Request),
        acp(method::SESSION_RESUME, Request),
        acp(method::SESSION_LIST, Request),
        acp(method::SESSION_FORK, Request),
        acp(method::SESSION_CLOSE, Request),
        acp(method::SESSION_DELETE, Request),
        acp(method::SESSION_PROMPT, Request),
        acp(method::SESSION_CANCEL, ClientNotification),
        acp(method::SESSION_SET_MODE, Request),
        acp(method::SESSION_SET_MODEL, Request),
        acp(method::SESSION_SET_CONFIG_OPTION, Request),
        acp(method::SESSION_UPDATE, Notification),
        acp(method::SESSION_REQUEST_PERMISSION, ServerRequest),
        acp(method::CANCEL_REQUEST, ClientNotification),
        // ACP extensions acpmux names in the acp.* space.
        untyped(method::ACP_SESSION_FORK, Request),
        untyped(method::ACP_TRUST_GET, Request),
        untyped(method::ACP_TRUST_SET, Request),
        untyped("catalog.get", Request),
        untyped("catalog.refresh", Request),
        untyped("catalog.changed", Notification),
        // Embedded tailnet controls (also report not_built in unsupported builds).
        untyped(method::MUX_TAILNET_LOGIN, Request),
        untyped(method::MUX_TAILNET_LOGOUT, Request),
        untyped(method::MUX_TAILNET_START, Request),
        untyped(method::MUX_TAILNET_STATE, Request),
        // Sessions.
        untyped(method::MUX_STATUS, Request),
        // Cloud whole-machine turn fencing. These methods are served by the
        // daemon's request dispatcher and intentionally use untyped envelopes
        // while the owner capability payload remains private to Cloud clients.
        untyped(method::AGENT_SESSION_TURN_PREPARE, Request),
        untyped(method::AGENT_SESSION_TURN_ABANDON, Request),
        // Scoped Cloud trigger chat operations.
        untyped(method::TRIGGER_CHAT_ENSURE, Request),
        untyped(method::TRIGGER_CHAT_SEND, Request),
        untyped(method::TRIGGER_CHAT_STATUS, Request),
        request::<SessionsParams, SessionsResult>(method::MUX_SESSIONS),
        request::<events::AttachParams, events::AttachResult>(method::MUX_ATTACH),
        request::<events::SessionRef, events::Done>(method::MUX_DETACH),
        request::<events::ViewParams, events::Done>(method::MUX_VIEW),
        request::<presence::TypingParams, events::Done>(method::MUX_TYPING),
        request::<events::SessionRef, events::Done>(method::MUX_MARK_UNREAD),
        request::<events::WatchParams, session::SessionsResult>(method::MUX_WATCH),
        untyped(method::MUX_RENAME, Request),
        untyped(method::MUX_OFFER_SESSION, Request),
        untyped(method::MUX_OFFER_RESPOND, Request),
        // Sub-sessions (`server/subsessions.rs`).
        untyped(method::MUX_SUBSESSION_ANSWER, Request),
        untyped(method::MUX_SUBSESSION_GET, Request),
        untyped(method::MUX_SUBSESSION_LIMITS, Request),
        untyped(method::MUX_SUBSESSION_LIST, Request),
        untyped(method::MUX_SUBSESSION_RETRY, Request),
        untyped(method::MUX_SUBSESSION_SEND, Request),
        untyped(method::MUX_SUBSESSION_START, Request),
        untyped(method::MUX_SUBSESSION_STOP, Request),
        // Forum announcements (`server/forum.rs`).
        untyped(method::MUX_FORUM_ACK, Request),
        untyped(method::MUX_FORUM_ANNOUNCE, Request),
        untyped(method::MUX_FORUM_RULES, Request),
        untyped(method::MUX_SET_TOOLS, Request),
        untyped(method::MUX_MCP_RECONNECT, Request),
        untyped(method::MUX_SUBAGENT_STOP, Request),
        untyped(method::MUX_SUBAGENT_TRANSCRIPT, Request),
        untyped(method::MUX_NATIVE_HISTORY, Request),
        untyped(method::MUX_WORKFLOWS, Request),
        untyped(method::MUX_APP_REPLY, Request),
        untyped(method::MUX_STATS, Request),
        untyped(method::MUX_GITHUB_ACTION, Request),
        untyped(method::MUX_GITHUB_APP_LEASE, Request),
        untyped(method::MUX_BOOKMARK_GET, Request),
        untyped(method::MUX_BOOKMARK_SET, Request),
        untyped(method::MUX_PROMPT_WITHDRAW, Request),
        untyped(method::MUX_INBOX_DIGEST, Request),
        untyped(method::MUX_SEND_QUEUE, Request),
        untyped(method::MUX_SEND_STATUS, Request),
        untyped(method::MUX_MESH_CONTROL, Request),
        // The hub asks a session's agent adapter (claude_stdio, the Codex bridge).
        untyped(method::MUX_STEP_NOW, Request),
        untyped(method::MUX_STEER_WITHDRAW, Request),
        untyped(method::MUX_AGENT_PAIR_RESUME, Request),
        request::<RetryParams, RetryResult>(method::MUX_RETRY),
        request::<auth::SessionAuthParams, auth::SessionAuthResult>(method::MUX_SESSION_AUTH),
        untyped(method::MUX_PROCESS_LIST, Request),
        untyped(method::MUX_PROCESS_TAIL, Request),
        untyped(method::MUX_PROCESS_KILL, Request),
        untyped(method::MUX_BG_START, Request),
        untyped(method::MUX_BG_LIST, Request),
        untyped(method::MUX_BG_OUTPUT, Request),
        untyped(method::MUX_BG_STOP, Request),
        request::<ProcessBackgroundParams, ProcessBackgroundResult>(method::MUX_PROCESS_BACKGROUND),
        untyped(method::MUX_WORKTREE_REPORT, Request),
        untyped(method::MUX_WORKTREE_CLEAN, Request),
        untyped(method::MUX_WORKTREE_RESTORE, Request),
        untyped(method::MUX_RETENTION, Request),
        untyped(method::MUX_PROCESS_UPDATE, Notification),
        untyped(method::MUX_KILL, Request),
        untyped(method::MUX_KEEP, Request),
        untyped(method::MUX_WATCH_TAKE_OVER, Request),
        untyped(method::MUX_ARCHIVE, Request),
        untyped(method::MUX_SIDE, Request),
        untyped(method::MUX_BTW, Request),
        untyped(method::MUX_TAG, Request),
        untyped(method::MUX_INFO, Request),
        untyped(method::MUX_SESSION_FILES, Request),
        request::<events::EventsParams, events::EventsResult>(method::MUX_EVENTS),
        untyped(method::MUX_ATTACHMENT, Request),
        request::<MailSendParams, MailSendResult>(method::MUX_MAIL_SEND),
        request::<MailReadParams, MailPageResult>(method::MUX_MAIL_READ),
        request::<MailWaitParams, MailPageResult>(method::MUX_MAIL_WAIT),
        request::<MailAckParams, MailAckResult>(method::MUX_MAIL_ACK),
        untyped(method::MUX_TEAM_SEND, Request),
        untyped(method::MUX_TEAM_INBOX, Request),
        untyped(method::MUX_TEAM_READ, Request),
        untyped(method::MUX_TEAM_ACK, Request),
        untyped(method::MUX_HISTORY, Request),
        untyped(method::MUX_COMPLETE, Request),
        untyped(method::MUX_WAIT, Request),
        untyped(method::MUX_WATCH_ADD, Request),
        untyped(method::MUX_WATCH_LS, Request),
        untyped(method::MUX_WATCH_RM, Request),
        untyped(method::MUX_ASK, Request),
        untyped(method::MUX_WARM, Request),
        untyped(method::MUX_PREWARM, Request),
        untyped(method::MUX_START_MODE, Request),
        untyped(method::MUX_QUEUE_REMOVE, Request),
        untyped(method::MUX_QUEUE_EDIT, Request),
        untyped(method::MUX_QUEUE_APPROVE, Request),
        untyped(method::MUX_QUEUE_DECLINE, Request),
        untyped(method::MUX_QUEUE_TEXT, Request),
        untyped(method::MUX_DRAFT_GET, Request),
        untyped(method::MUX_DRAFT_SET, Request),
        untyped(method::MUX_COMPOSER_SET, Request),
        untyped(method::MUX_COMPOSERS, Request),
        untyped(method::MUX_EXPORT, Request),
        untyped(method::MUX_IMPORT, Request),
        untyped(method::MUX_FILE_PUT, Request),
        untyped(method::MUX_FILE_PUT_BEGIN, Request),
        untyped(method::MUX_FILE_PUT_CHUNK, Request),
        untyped(method::MUX_FILE_PUT_FINISH, Request),
        untyped(method::MUX_FILE_PUT_CANCEL, Request),
        untyped(method::MUX_FILE_PUT_STATUS, Request),
        untyped(method::MUX_FILE_PUT_DATA, Request),
        untyped(method::MUX_DISPATCH, Request),
        untyped(method::MUX_STEER, Request),
        untyped(method::MUX_BRIEFS, Request),
        untyped(method::MUX_REPORT, Request),
        untyped(method::MUX_TASK_NEW, Request),
        untyped(method::MUX_TASKS, Request),
        untyped(method::MUX_RESOLVE, Request),
        untyped(method::MUX_MEDIA_OPEN, Request),
        untyped(method::MUX_MEDIA_RANGE, Request),
        // Permissions.
        request::<PermissionRespondParams, PermissionRespondResult>(method::MUX_PERMISSION_RESPOND),
        request::<PermissionGroupsParams, PermissionGroupList>(method::MUX_PERMISSION_GROUPS),
        request::<PermissionGroupRespondParams, PermissionGroupReceipt>(
            method::MUX_PERMISSION_GROUP_RESPOND,
        ),
        request::<PermissionChatRevokeParams, PermissionChatRevokeReceipt>(
            method::MUX_PERMISSION_CHAT_REVOKE,
        ),
        untyped(method::MUX_SET_POLICY, Request),
        untyped("_acpmux/set_default_policy", Request),
        untyped(method::MUX_SET_RULES, Request),
        untyped(method::MUX_SET_TURN_CAP, Request),
        untyped(method::MUX_INBOX_THREADS, Request),
        untyped(method::MUX_INBOX_THREAD, Request),
        untyped(method::MUX_INBOX_REPLY, Request),
        untyped(method::MUX_PERSON_ENROLL, Request),
        untyped(method::MUX_COMPUTER_USE_ENROLL, Request),
        untyped(method::MUX_PERSON_PROVE, Request),
        untyped(method::MUX_PERSON_HOLDS, Request),
        // The person's phones and their chats (`hub/approvers.rs`, `hub/person.rs`).
        untyped(method::MUX_APPROVERS, Request),
        untyped(method::MUX_APPROVERS_SET, Request),
        // Enrolled Macs (`hub/mac_approvers.rs`).
        untyped(method::MUX_MAC_APPROVER_SET, Request),
        untyped(method::MUX_MAC_APPROVERS, Request),
        untyped(method::MUX_NEW_CHAT_PICKS_SET, Request),
        untyped(method::MUX_WORKSPACE_ROOTS_SET, Request),
        untyped(method::MUX_SECRET_REQUEST, Request),
        untyped(method::MUX_SECRET_SUBMIT, Request),
        untyped(method::MUX_SECRET_RUN, Request),
        // Chats (`server/chats.rs`).
        untyped("_acpmux/chats", Request),
        untyped("_acpmux/chats_watch", Request),
        untyped("_acpmux/chat_open", Request),
        untyped("_acpmux/chat_roots", Request),
        untyped("_acpmux/chat_roots_record", Request),
        untyped("_acpmux/chat_settings", Request),
        untyped("_acpmux/chat_settled", Request),
        untyped("_acpmux/chat_transcript", Request),
        untyped("_acpmux/chats_search", Request),
        untyped("_acpmux/chat_fork", Request),
        untyped("_acpmux/chat_projects", Request),
        untyped("_acpmux/chat_changed", Notification),
        untyped("_acpmux/chats_lagged", Notification),
        // A client's window over the chat index (`server/chat_windows.rs`).
        untyped("_acpmux/chats_window", Request),
        untyped("_acpmux/chats_window_close", Request),
        untyped("_acpmux/chats_window_changed", Notification),
        // Moving a chat to another daemon (`transfer_out.rs`).
        untyped("_acpmux/transfer_abort", Request),
        untyped("_acpmux/transfer_begin", Request),
        untyped("_acpmux/transfer_commit", Request),
        untyped("_acpmux/transfer_finish", Request),
        untyped("_acpmux/transfer_forget", Request),
        untyped("_acpmux/transfer_read", Request),
        untyped("_acpmux/transfer_receive", Request),
        untyped("_acpmux/transfer_write", Request),
        // Handoff.
        untyped(method::MUX_HANDOFF_PREPARE, Request),
        untyped(method::MUX_HANDOFF_GET, Request),
        untyped(method::MUX_HANDOFF_DRAFT, Request),
        untyped(method::MUX_HANDOFF_START, Request),
        untyped(method::MUX_HANDOFF_DISCARD, Request),
        // Harnesses, models, routes.
        untyped(method::MUX_HARNESSES, Request),
        untyped(method::MUX_HARNESS_ENABLE, Request),
        untyped(method::MUX_HARNESS_ADD, Request),
        untyped(method::MUX_HARNESS_REMOVE, Request),
        untyped(method::MUX_HARNESS_RESTORE, Request),
        untyped(method::MUX_HARNESS_DOCTOR, Request),
        untyped(method::MUX_HARNESS_SECRET_SET, Request),
        untyped(method::MUX_HARNESS_ICON, Request),
        untyped(method::MUX_HARNESS_HEALTH, Request),
        untyped(method::MUX_AGENT_LOGIN_START, Request),
        untyped(method::MUX_AGENT_LOGIN_FINISH, Request),
        untyped(method::MUX_AGENT_LOGIN_CANCEL, Request),
        untyped(method::MUX_AGENT_LOGIN_API_KEY, Request),
        request::<inventory::InventoryWatchParams, Value>(method::MUX_HARNESS_INVENTORY_WATCH),
        request::<inventory::InventoryRefreshParams, Value>(method::MUX_HARNESS_INVENTORY_REFRESH),
        request::<inventory::HarnessUpdatePlanParams, Value>(method::MUX_HARNESS_UPDATE_PLAN),
        request::<inventory::HarnessUpdatePlanParams, Value>(method::MUX_HARNESS_UPDATE_PREPARE),
        untyped(method::MUX_HARNESS_UPDATE, Request),
        untyped(method::MUX_SESSIONS_RESTART_HARNESS, Request),
        untyped(method::MUX_REGISTRY, Request),
        untyped(method::MUX_DEFAULTS, Request),
        untyped(method::MUX_PRESETS, Request),
        untyped("_acpmux/models", Request),
        untyped("_acpmux/directories", Request),
        untyped(method::MUX_ROUTE_LIST, Request),
        untyped(method::MUX_ROUTE_SHOW, Request),
        untyped(method::MUX_ROUTE_ADD, Request),
        untyped(method::MUX_ROUTE_EDIT, Request),
        untyped(method::MUX_ROUTE_REMOVE, Request),
        untyped(method::MUX_ROUTE_RESTORE, Request),
        untyped(method::MUX_ROUTE_TEST, Request),
        untyped(method::MUX_ROUTE_DEFAULT_SET, Request),
        untyped(method::MUX_CHAT_ROUTE_SET, Request),
        // Daemon.
        untyped(method::MUX_WEB_MODES, Request),
        untyped(method::MUX_WEB_TOKEN_ROTATE, Request),
        untyped(method::MUX_RELOAD_CONFIG, Request),
        untyped(method::MUX_SCHEMA, Request),
        // The result is this IR document (`ir()`), left open: its own
        // schema would describe itself.
        request::<ProtocolParams, Value>(method::MUX_PROTOCOL),
        untyped(method::MUX_SHUTDOWN, Request),
        untyped("_acpmux/peers", Request),
        untyped("_acpmux/peer_status", Request),
        untyped("_acpmux/host_health", Request),
        untyped("_acpmux/vm_host", Request),
        untyped("_acpmux/host_notice", Request),
        untyped("_acpmux/place", Request),
        untyped("_acpmux/peer_add", Request),
        untyped("_acpmux/peer_lease", Request),
        untyped("_acpmux/peer_reconnect", Request),
        untyped("_acpmux/peer_remove", Request),
        untyped("_acpmux/peer_snapshot", Request),
        untyped(method::MUX_PAIR_TICKET_NEW, Request),
        untyped(method::MUX_PAIR_LIST, Request),
        untyped(method::MUX_PAIR_REVOKE, Request),
        untyped(method::MUX_PAIR_ISSUE, Request),
        untyped(method::MUX_PAIR_SET, Request),
        untyped(method::MUX_MACHINE_CONSENT_SET, Request),
        untyped(method::MUX_MACHINE_CONSENT_GET, Request),
        untyped(method::MUX_MACHINE_CONSENT_REFUSED, Request),
        untyped(method::MUX_PAIR_REDEEM, Request),
        untyped(method::MUX_TURN_ATTESTATION, Request),
        // Notifications.
        notification::<events::SessionEvent>(method::MUX_EVENT),
        notification::<MessageEvent>(method::MUX_MESSAGE),
        notification::<SessionChanged>(method::MUX_SESSION_CHANGED),
        notification::<PermissionPending>(method::MUX_PERMISSION_PENDING),
        notification::<presence::PresenceNote>(method::MUX_PRESENCE),
        notification::<peer_state::PeerStateChanged>(method::MUX_PEER_STATE_CHANGED),
        untyped(method::MUX_HARNESSES_CHANGED, Notification),
        untyped(method::MUX_HARNESS_INVENTORY, Notification),
        untyped(method::MUX_START_MODE_CHANGED, Notification),
        untyped(method::MUX_PROMPT_ACCEPTED, Notification),
        untyped(method::MUX_CANCEL_REFUSED, Notification),
        untyped("_acpmux/lagged", Notification),
        untyped(method::MUX_DISCONNECTED, ClientLocal),
    ]
}

/// The registry as the IR document: `{version, methods[], types{}}`. Each
/// method's `params` and `result` is `{"$ref": "#/types/<Name>"}`, `true`
/// (not declared yet) or absent (a notification has no result).
pub fn ir() -> Value {
    let mut settings = SchemaSettings::draft2020_12();
    settings.definitions_path = "/types".into();
    let mut generator = settings.into_generator();
    let mut methods = Vec::new();
    for decl in registry() {
        let mut entry = Map::new();
        entry.insert("name".into(), json!(decl.name));
        entry.insert("kind".into(), json!(decl.kind.as_str()));
        if decl.acp {
            entry.insert("acp".into(), json!(true));
        }
        let typed = |schema: Option<SchemaFn>, generator: &mut SchemaGenerator| {
            schema.map_or(Value::Bool(true), |f| f(generator).to_value())
        };
        entry.insert("params".into(), typed(decl.params, &mut generator));
        if matches!(decl.kind, Kind::Request | Kind::ServerRequest) {
            entry.insert("result".into(), typed(decl.result, &mut generator));
        }
        methods.push(Value::Object(entry));
    }
    let types: BTreeMap<String, Value> = generator
        .definitions()
        .iter()
        .map(|(name, schema)| (name.clone(), schema.clone()))
        .collect();
    canonical(&json!({"version": IR_VERSION, "methods": methods, "types": types}))
}

/// The IR as committed: two-space JSON with a final newline.
pub fn ir_text() -> String {
    let mut text = serde_json::to_string_pretty(&ir()).unwrap_or_default();
    text.push('\n');
    text
}

/// A schemars transform: every property is required, `Option` ones too
/// (they stay nullable). For shapes whose nullable fields are always on
/// the wire, as `json!` wrote them.
pub fn require_all(schema: &mut schemars::Schema) {
    let Some(object) = schema.as_object_mut() else { return };
    let names: Vec<Value> = object
        .get("properties")
        .and_then(Value::as_object)
        .map(|properties| properties.keys().map(|name| Value::String(name.clone())).collect())
        .unwrap_or_default();
    object.insert("required".into(), Value::Array(names));
}

/// `value` with every object's keys sorted, so the IR does not depend on
/// serde_json's map order in this build.
fn canonical(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let sorted: BTreeMap<&String, Value> =
                map.iter().map(|(key, value)| (key, canonical(value))).collect();
            Value::Object(sorted.into_iter().map(|(key, value)| (key.clone(), value)).collect())
        }
        Value::Array(items) => Value::Array(items.iter().map(canonical).collect()),
        other => other.clone(),
    }
}
