//! Remote agent session attachment for trusted local Unix clients. It streams
//! a store tab's bound acpmux session with bounded replay and live records,
//! and can drive prompts, cancels and permission answers. Every request is
//! scoped to the tab's stored session; remote relay and WebSocket clients are
//! refused. Attachments have bounded pages, calls and outbound buffering, and
//! close with a replay cursor when acpmux or the client falls behind.

use crate::panic_free::JsonFields;
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock, Weak};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

#[path = "agent_session_children.rs"]
pub(super) mod agent_session_children;
#[path = "agent_session_link.rs"]
pub(super) mod agent_session_link;
#[path = "agent_session_observe.rs"]
pub(super) mod agent_session_observe;
#[path = "agent_session_start.rs"]
pub(super) mod agent_session_start;
#[path = "agent_session_trust.rs"]
mod agent_session_trust;
#[path = "agent_session_inventory_socket.rs"]
mod inventory_socket;
use super::{MessageWriter, OutboundStream, Response, SurfaceId, send_response};
use crate::mux::Mux;
use crate::state::conversation_tabs_store::ConversationTabRecord;
use agent_session_link::{AcpmuxLink, Inbound, LinkError};
pub use agent_session_start::{
    AGENT_SESSION_START_CAPABILITY, AGENT_SESSION_START_KEYED_REASON_CAPABILITY, AcpmuxStarter,
    AgentStartHost, AgentStartHostSource,
};
pub use agent_session_trust::AGENT_SESSION_TRUST_CAPABILITY;

pub const AGENT_SESSION_ATTACH_CAPABILITY: &str = "agent-session-attach-v1";
/// `agent-session-typing` and `agent-session-view`, and the `agent-session-presence` event: who
/// is in the attached chat (chat multiplayer, hq#4389), through acpmux's `_acpmux/typing`,
/// `_acpmux/view` and `_acpmux/presence`. The event goes only to a connection that echoed the
/// capability in `set-client-info`: an older app ends its attachment on an event it does not know.
pub const AGENT_SESSION_PRESENCE_CAPABILITY: &str = "agent-session-presence-v1";

pub(crate) const MAX_ATTACHMENTS_PER_CLIENT: usize = 8;
pub(crate) const MAX_ATTACHMENTS_TOTAL: usize = 64;
/// Records per attach or events page.
pub(crate) const MAX_PAGE: u64 = 500;
pub(crate) const MAX_PROMPT_BYTES: usize = 64 * 1024;
/// Permission ids remembered per attachment (announced, not yet answered).
const MAX_PERMISSIONS: usize = 64;
/// Record kinds or categories one page may ask for: the agent pane asks for all
/// the kinds it draws (9 since prompt bookmarks, cx-kpd0v), with room to grow.
const MAX_KINDS: usize = 32;
/// Worker calls (pages, prompts, permission answers) per attachment.
const MAX_CALLS: usize = 8;
const CALL_TIMEOUT: Duration = Duration::from_secs(5);
/// Notifications held while the attach call waits for its reply.
const MAX_EARLY: usize = 256;
/// Largest attach or events page sent to the client (a control message);
/// older records past it are left for the next page (`hasMore`).
pub(crate) const MAX_PAGE_BYTES: usize = 8 << 20;
/// Bytes of notifications held while the attach call waits.
const MAX_EARLY_BYTES: usize = 16 << 20;
const THREAD_STACK_BYTES: usize = 256 * 1024;

// MARK: State

/// The daemon's acpmux socket and every live attachment.
#[derive(Default)]
pub(crate) struct AgentSessions {
    socket: RwLock<inventory_socket::SocketState>,
    #[cfg(test)]
    inventory_socket_hook: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    /// Bounded cache reads share this owner's socket, never its start path.
    pub(super) inventory_reads: AtomicUsize,
    pub(super) inventory_watches: super::agent_inventory::watch::Watches,
    state: Mutex<AttachState>,
    /// `agent-session-start-v1`: the acpmux starter and the tabs starting.
    starts: agent_session_start::AgentSessionStarts,
    /// `agent-session-children-v1`: the descendants acpmux answered, which
    /// a `registry:` tab of this store may show.
    pub(crate) known_children: agent_session_children::KnownChildren,
}

#[derive(Default)]
struct AttachState {
    attachments: HashMap<(u64, SurfaceId), Arc<Attachment>>,
    /// Slots taken by attaches that are still connecting.
    reserved: HashSet<(u64, SurfaceId)>,
}

impl AttachState {
    fn count(&self, client: u64) -> usize {
        self.attachments.keys().chain(self.reserved.iter()).filter(|(c, _)| *c == client).count()
    }

    fn total(&self) -> usize {
        self.attachments.len() + self.reserved.len()
    }
}

impl AgentSessions {
    /// The live attachment of `surface` on `client`; an ended one is dropped.
    fn attachment(&self, client: u64, surface: SurfaceId) -> Option<Arc<Attachment>> {
        let mut state = self.lock();
        let key = (client, surface);
        let attachment = state.attachments.get(&key).cloned()?;
        if attachment.ended.load(Ordering::Acquire) {
            state.attachments.remove(&key);
            return None;
        }
        Some(attachment)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, AttachState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The connection ended: every attachment of it closes.
    pub(crate) fn disconnect(&self, client: u64) {
        self.inventory_watches.disconnect(client);
        let gone: Vec<Arc<Attachment>> = {
            let mut state = self.lock();
            state.reserved.retain(|(c, _)| *c != client);
            let keys: Vec<_> =
                state.attachments.keys().filter(|(c, _)| *c == client).copied().collect();
            keys.iter().filter_map(|key| state.attachments.remove(key)).collect()
        };
        for attachment in gone {
            attachment.end(None);
        }
    }

    fn remove(&self, attachment: &Attachment) {
        let mut state = self.lock();
        let key = (attachment.client, attachment.surface);
        if state.attachments.get(&key).is_some_and(|live| std::ptr::eq(live.as_ref(), attachment)) {
            state.attachments.remove(&key);
        }
    }

    #[cfg(test)]
    pub(crate) fn attachment_count(&self) -> usize {
        self.lock().attachments.len()
    }
}

/// One attached tab: its acpmux link and the client stream it feeds.
struct Attachment {
    client: u64,
    surface: SurfaceId,
    /// The acpmux session id (resolved by acpmux from the record's session).
    session: String,
    /// The session the tab's store record named at attach; the attachment
    /// ends when the record changes or the tab closes.
    record_session: String,
    read_only: AtomicBool,
    mux: Weak<Mux>,
    link: Arc<AcpmuxLink>,
    writer: MessageWriter,
    outbound: OutboundStream,
    /// Calls running on worker threads (at most [`MAX_CALLS`]).
    calls: AtomicUsize,
    ended: AtomicBool,
    /// Permission ids acpmux announced on this attachment, oldest first.
    permissions: Mutex<VecDeque<String>>,
    /// Prompt ids waiting for `_acpmux/prompt_accepted`, with their reply slot.
    prompts: Mutex<HashMap<String, std::sync::mpsc::SyncSender<Value>>>,
    /// The session's descendants this attachment follows
    /// (`agent-session-children-v1`): their changes are streamed too.
    children: Mutex<HashSet<String>>,
}

impl Attachment {
    /// The connection echoed `agent-session-presence-v1` in `set-client-info`.
    fn wants_presence(&self) -> bool {
        self.mux.upgrade().is_some_and(|mux| {
            mux.control_clients.supports_capability(self.client, AGENT_SESSION_PRESENCE_CAPABILITY)
        })
    }

    fn note_permission(&self, id: &str) {
        let mut permissions = self.permissions.lock().unwrap_or_else(|e| e.into_inner());
        if permissions.iter().any(|known| known == id) {
            return;
        }
        if permissions.len() >= MAX_PERMISSIONS {
            permissions.pop_front();
        }
        permissions.push_back(id.to_string());
    }

    fn has_permission(&self, id: &str) -> bool {
        self.permissions.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|known| known == id)
    }

    /// An answered request: it cannot be answered again.
    fn forget_permission(&self, id: &str) {
        self.permissions.lock().unwrap_or_else(|e| e.into_inner()).retain(|known| known != id);
    }

    /// True while the tab's store record still shows the attached session.
    fn tab_current(&self) -> bool {
        self.mux.upgrade().is_some_and(|mux| {
            tab_session(&mux, self.surface).as_deref() == Some(self.record_session.as_str())
        })
    }

    /// Ends the attachment once; `reason` (when the client should hear it)
    /// goes out as `agent-session-closed`, a control message that can arrive
    /// before records still queued (those may be dropped; the client replays).
    fn end(&self, reason: Option<&str>) {
        if self.ended.swap(true, Ordering::AcqRel) {
            return;
        }
        self.link.close();
        if let Some(reason) = reason {
            // The stream may be full; the close notice is a control message.
            self.outbound.close();
            let _ = self.writer.send_control(&closed_event(self.surface, reason));
        } else {
            self.outbound.close();
        }
    }
}

/// The attachment ended. Records queued for it may be dropped, but what
/// the client received is always a gap-free prefix, so it attaches again
/// with `after_seq` = the newest seq it holds.
fn closed_event(surface: SurfaceId, reason: &str) -> Value {
    json!({"event": "agent-session-closed", "surface": surface, "reason": reason})
}

// MARK: Requests

/// Page params shared by attach and events.
#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct PageParams {
    surface: SurfaceId,
    #[serde(default)]
    after_seq: Option<u64>,
    #[serde(default)]
    before_seq: Option<u64>,
    #[serde(default)]
    limit: Option<u64>,
    #[serde(default)]
    kinds: Option<Vec<String>>,
}

enum AgentSessionCommand {
    Attach(PageParams),
    Events(PageParams),
    Prompt(PromptParams),
    Cancel(SurfaceParams),
    Permission(PermissionParams),
    Detach(SurfaceParams),
    Children(SurfaceParams),
    Media(MediaParams),
    Typing(TypingParams),
    View(ViewParams),
}

impl AgentSessionCommand {
    /// The command of one frame object without `id` and `cmd`. Every params
    /// struct denies unknown fields, so a session id, cwd, command, agent or
    /// MCP server param is a bad request.
    fn parse(cmd: &str, params: Value) -> Option<Self> {
        use serde_json::from_value;
        Some(match cmd {
            "agent-session-attach" => Self::Attach(from_value(params).ok()?),
            "agent-session-events" => Self::Events(from_value(params).ok()?),
            "agent-session-prompt" => Self::Prompt(from_value(params).ok()?),
            "agent-session-cancel" => Self::Cancel(from_value(params).ok()?),
            "agent-session-permission" => Self::Permission(from_value(params).ok()?),
            "agent-session-detach" => Self::Detach(from_value(params).ok()?),
            "agent-session-children" => Self::Children(from_value(params).ok()?),
            "agent-session-media" => Self::Media(from_value(params).ok()?),
            "agent-session-typing" => Self::Typing(from_value(params).ok()?),
            "agent-session-view" => Self::View(from_value(params).ok()?),
            _ => return None,
        })
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SurfaceParams {
    surface: SurfaceId,
}

/// `agent-session-typing`: the person starts (`on`) or stops typing in the attached chat.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TypingParams {
    surface: SurfaceId,
    on: bool,
}

/// `agent-session-view`: whether the person's window shows the attached chat now.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ViewParams {
    surface: SurfaceId,
    visible: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MediaParams {
    surface: SurfaceId,
    path: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PromptParams {
    surface: SurfaceId,
    prompt_id: String,
    text: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PermissionParams {
    surface: SurfaceId,
    permission_id: String,
    option_id: String,
    /// The person's decision proof for this answer (acpmux `hub/person.rs`,
    /// cx-0q7o): passed to acpmux unchanged, and acpmux decides.
    #[serde(default)]
    decision_nonce: Option<String>,
    #[serde(default)]
    person_decision: Option<String>,
    /// Which device the person answered on: acpmux records it only with a
    /// proof that counts.
    #[serde(default)]
    answered_by: Option<AnsweredBy>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AnsweredBy {
    device: String,
    feed_item: String,
}

/// An `answered_by` field as acpmux takes it (`hub/person.rs` answered_by):
/// 1 to 128 characters of `[A-Za-z0-9_.:-]`.
fn is_answer_id(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'))
}

/// 64 lowercase hex characters: a decision nonce or proof.
fn is_hex64(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Refusal codes (`error_code`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Refusal {
    NotTrusted,
    Unavailable,
    BadRequest,
    UnknownTab,
    NotAttached,
    Limit,
    Timeout,
    Refused,
    UnknownPermission,
    /// `agent-session-start`: the tab already has a session.
    Bound,
    /// `agent-session-start`: acpmux is not running and could not be started.
    AcpmuxUnavailable,
    /// `agent-session-start`: the agent has no mode that asks before acting.
    NotAsking,
    /// `agent-session-start`: the folder is not trusted on this machine.
    UntrustedFolder,
    /// `agent-session-start`: this daemon runs on a team VM.
    TeamVmBlocked,
    /// `agent-session-start`: a Cloud VM daemon that cannot tell its kind.
    HostUnverified,
    /// `agent-session-trust`: a folder above the home folder.
    AboveHome,
    /// `agent-session-trust`: the home folder without the person's choice of it.
    HomeUnconfirmed,
    /// `agent-session-start` with `require_person_key`: acpmux holds no
    /// person key for the caller's run (cx-0w0jj).
    NeedsKeyedStart,
    ReadOnly,
    ModeConflict,
}

impl Refusal {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::NotTrusted => "agent_session.not_trusted",
            Self::Unavailable => "agent_session.unavailable",
            Self::BadRequest => "agent_session.bad_request",
            Self::UnknownTab => "agent_session.unknown_tab",
            Self::NotAttached => "agent_session.not_attached",
            Self::Limit => "agent_session.limit",
            Self::Timeout => "agent_session.timeout",
            Self::Refused => "agent_session.refused",
            Self::UnknownPermission => "agent_session.unknown_permission",
            Self::Bound => "agent_session.bound",
            Self::AcpmuxUnavailable => "agent_session.acpmux_unavailable",
            Self::NotAsking => "agent_session.not_asking",
            Self::UntrustedFolder => "agent_session.untrusted_folder",
            Self::TeamVmBlocked => "agent_session.team_vm_blocked",
            Self::HostUnverified => "agent_session.host_unverified",
            Self::AboveHome => "agent_session.above_home",
            Self::HomeUnconfirmed => "agent_session.home_unconfirmed",
            Self::NeedsKeyedStart => "agent_session.needs_keyed_start",
            Self::ReadOnly => "agent_session.read_only",
            Self::ModeConflict => "agent_session.mode_conflict",
        }
    }

    fn message(self) -> &'static str {
        match self {
            Self::NotTrusted => "agent session attach needs a trusted local connection",
            Self::Unavailable => "this daemon has no acpmux to attach to",
            Self::BadRequest => "bad request",
            Self::UnknownTab => "not an agent tab with a session in this daemon",
            Self::NotAttached => "the tab is not attached on this connection",
            Self::Limit => "too many attached agent tabs",
            Self::Timeout => "acpmux did not answer in time",
            Self::Refused => "acpmux refused the request",
            Self::UnknownPermission => "no such pending permission request on this attachment",
            Self::Bound => "the agent tab already has a session",
            Self::AcpmuxUnavailable => {
                "acpmux is not running on this machine and could not be started"
            }
            Self::NotAsking => "this agent has no mode that asks before each action",
            Self::UntrustedFolder => "the folder is not trusted on this machine",
            Self::TeamVmBlocked => "agent chats cannot be started remotely on a team VM",
            Self::HostUnverified => {
                "this machine cannot tell whether it is a team VM, so it starts no remote chat"
            }
            Self::AboveHome => "a folder above the home folder is never trusted from here",
            Self::HomeUnconfirmed => {
                "the home folder is trusted only after the person chose it as the chat's folder"
            }
            Self::NeedsKeyedStart => {
                "acpmux on this machine holds no person key for this caller; restart it with one first"
            }
            Self::ReadOnly => "this agent session attachment is read-only",
            Self::ModeConflict => {
                "this connection already has the same surface attached in another mode"
            }
        }
    }

    fn of(error: LinkError) -> Self {
        match error {
            LinkError::Closed => Self::Unavailable,
            LinkError::Timeout => Self::Timeout,
            LinkError::Busy => Self::Limit,
            LinkError::Rpc(..) | LinkError::MethodNotFound(_) => Self::Refused,
        }
    }
}

/// Handles an `agent-session-*` frame of a local connection; `None` for any
/// other frame. Remote-relay connections never get here (they take
/// `remote_relay::handle_frame` first).
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if let Some(handled) = agent_session_observe::try_handle(mux, client, message, writer) {
        return Some(handled);
    }
    if !message.contains("\"agent-session-") {
        return None;
    }
    let Ok(Value::Object(mut object)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    let cmd = match object.remove("cmd") {
        Some(Value::String(cmd)) if cmd.starts_with("agent-session-") => cmd,
        _ => return None,
    };
    let id = object.remove("id");
    if cmd == "agent-session-start" {
        return Some(start(mux, client, id, object, writer));
    }
    if cmd == "agent-session-trust" {
        return Some(trust(mux, client, id, object, writer));
    }
    let Some(command) = AgentSessionCommand::parse(&cmd, Value::Object(object)) else {
        return Some(refuse(writer, id, Refusal::BadRequest));
    };
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Some(refuse(writer, id, Refusal::NotTrusted));
    }
    let sessions = &mux.control_clients.agent_sessions;
    let Some(socket) = sessions.socket() else {
        return Some(refuse(writer, id, Refusal::Unavailable));
    };
    Some(match command {
        AgentSessionCommand::Attach(params) => {
            attach(mux, client, id, socket, params, false, writer)
        }
        AgentSessionCommand::Detach(SurfaceParams { surface }) => {
            if let Some(attachment) = sessions.attachment(client, surface) {
                sessions.remove(&attachment);
                attachment.end(None);
            }
            ok(writer, id, json!({}))
        }
        command => {
            let surface = command_surface(&command);
            match sessions.attachment(client, surface) {
                Some(attachment) => run_on_worker(mux, attachment, id, command, writer),
                None => refuse(writer, id, Refusal::NotAttached),
            }
        }
    })
}

/// `agent-session-start` (agent_session_start.rs), with the attach verbs'
/// trust and acpmux checks.
fn start(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    params: serde_json::Map<String, Value>,
    writer: &MessageWriter,
) -> bool {
    let Ok(params) = serde_json::from_value(Value::Object(params)) else {
        return refuse(writer, id, Refusal::BadRequest);
    };
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return refuse(writer, id, Refusal::Unavailable);
    };
    agent_session_start::start(mux, client, id, socket, params, writer)
}

/// `agent-session-trust` (agent_session_trust.rs), with the same checks.
fn trust(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    params: serde_json::Map<String, Value>,
    writer: &MessageWriter,
) -> bool {
    let Ok(params) = serde_json::from_value(Value::Object(params)) else {
        return refuse(writer, id, Refusal::BadRequest);
    };
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return refuse(writer, id, Refusal::Unavailable);
    };
    agent_session_trust::trust(mux, id, socket, params, writer)
}

/// The page router's owner `agent_session.trust` (page_router.rs).
pub(super) fn routed_trust(
    mux: &Arc<Mux>,
    client: u64,
    operation: &str,
    params: serde_json::Map<String, Value>,
) -> Result<Value, crate::resource::ResourceError> {
    agent_session_trust::routed(mux, client, operation, params)
}

fn command_surface(command: &AgentSessionCommand) -> SurfaceId {
    match command {
        AgentSessionCommand::Attach(params) | AgentSessionCommand::Events(params) => params.surface,
        AgentSessionCommand::Prompt(params) => params.surface,
        AgentSessionCommand::Permission(params) => params.surface,
        AgentSessionCommand::Cancel(params)
        | AgentSessionCommand::Detach(params)
        | AgentSessionCommand::Children(params) => params.surface,
        AgentSessionCommand::Media(params) => params.surface,
        AgentSessionCommand::Typing(params) => params.surface,
        AgentSessionCommand::View(params) => params.surface,
    }
}

/// The tab's bound acpmux session, if `surface` is an agent tab of this
/// store with one.
fn tab_session(mux: &Mux, surface: SurfaceId) -> Option<String> {
    let runtime = mux.surface(surface)?;
    match mux.conversation_tab_of(&runtime)? {
        ConversationTabRecord::AgentSession { session: Some(session), .. } => Some(session),
        _ => None,
    }
}

/// acpmux page params from the client's, with the session pinned and the
/// limit and kinds bounded.
fn page_params(session: &str, params: &PageParams, attach: bool) -> Result<Value, Refusal> {
    let mut out =
        json!({"sessionId": session, "limit": params.limit.unwrap_or(200).clamp(1, MAX_PAGE)});
    if let Some(after) = params.after_seq {
        out.insert("afterSeq", json!(after));
    }
    if let Some(before) = params.before_seq {
        out.insert("beforeSeq", json!(before));
    }
    if let Some(kinds) = &params.kinds {
        let valid = kinds.len() <= MAX_KINDS
            && kinds.iter().all(|kind| {
                (1..=64).contains(&kind.len())
                    && kind.bytes().all(|b| b.is_ascii_lowercase() || b == b'_' || b == b'.')
            });
        if !valid {
            return Err(Refusal::BadRequest);
        }
        out.insert("kinds", json!(kinds));
    }
    if attach {
        out.insert("eventStream", json!(true));
    }
    Ok(out)
}

fn attach(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    socket: PathBuf,
    params: PageParams,
    read_only: bool,
    writer: &MessageWriter,
) -> bool {
    let sessions = &mux.control_clients.agent_sessions;
    if let Some(attachment) = sessions.attachment(client, params.surface) {
        if attachment.read_only.load(Ordering::Acquire) != read_only {
            return refuse(writer, id, Refusal::ModeConflict);
        }
        // Already attached in the same mode: page only, on the attachment's own link.
        return run_on_worker(mux, attachment, id, AgentSessionCommand::Attach(params), writer);
    }
    let Some(session) = tab_session(mux, params.surface) else {
        return refuse(writer, id, Refusal::UnknownTab);
    };
    let record_session = session.clone();
    let acpmux_params = match page_params(&session, &params, true) {
        Ok(value) => value,
        Err(refusal) => return refuse(writer, id, refusal),
    };
    {
        let mut state = sessions.lock();
        let key = (client, params.surface);
        if state.reserved.contains(&key)
            || state.count(client) >= MAX_ATTACHMENTS_PER_CLIENT
            || state.total() >= MAX_ATTACHMENTS_TOTAL
        {
            return refuse(writer, id, Refusal::Limit);
        }
        state.reserved.insert(key);
    }
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let surface = params.surface;
    let spawned = std::thread::Builder::new()
        .name("mux-agent-attach".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            connect_and_attach(
                worker_mux,
                client,
                worker_id,
                socket,
                surface,
                record_session,
                acpmux_params,
                read_only,
                worker_writer,
            );
        });
    if spawned.is_err() {
        sessions.lock().reserved.remove(&(client, surface));
        return refuse(writer, id, Refusal::Limit);
    }
    true
}

/// What the link's reader thread hands notifications to. Until the attach
/// reply is queued, notifications wait here (bounded) so a record never
/// overtakes the reply (control messages leave before stream messages) and
/// the reader never blocks: the attach reply itself comes through it.
#[derive(Default)]
struct ReaderSlot {
    attachment: Option<Arc<Attachment>>,
    early: VecDeque<Inbound>,
    early_bytes: usize,
    overflowed: bool,
    /// The resolved session once the attach answered: other sessions'
    /// notifications (the watch) are not held.
    session: Option<String>,
}

impl ReaderSlot {
    /// Holds one early notification; false when the attachment is live.
    fn hold(&mut self, inbound: Inbound) -> Result<(), Inbound> {
        if self.attachment.is_some() {
            return Err(inbound);
        }
        if let (Some(session), Inbound::Notification(_, params)) = (&self.session, &inbound)
            && params.get("sessionId").and_then(Value::as_str).is_some_and(|id| id != session)
        {
            return Ok(());
        }
        let bytes = match &inbound {
            Inbound::Notification(method, params) => {
                method.len() + serde_json::to_string(params).map_or(0, |text| text.len())
            }
            Inbound::Closed(_) => 0,
        };
        if self.overflowed
            || self.early.len() >= MAX_EARLY
            || self.early_bytes + bytes > MAX_EARLY_BYTES
        {
            self.overflowed = true;
        } else {
            self.early_bytes += bytes;
            self.early.push_back(inbound);
        }
        Ok(())
    }
}

#[path = "agent_session_stream.rs"]
mod stream;
pub(crate) use stream::bound_page;
use stream::connect_and_attach;

/// Runs a call that waits on acpmux off the connection thread. Calls of one
/// attachment may run side by side; the link bounds how many wait.
fn run_on_worker(
    mux: &Arc<Mux>,
    attachment: Arc<Attachment>,
    id: Option<Value>,
    command: AgentSessionCommand,
    writer: &MessageWriter,
) -> bool {
    // The tab must still show the attached session (closed or rebound tabs
    // end their attachment).
    if tab_session(mux, attachment.surface).as_deref() != Some(attachment.record_session.as_str()) {
        mux.control_clients.agent_sessions.remove(&attachment);
        attachment.end(Some("detached"));
        return refuse(writer, id, Refusal::UnknownTab);
    }
    if attachment.read_only.load(Ordering::Acquire)
        && matches!(
            &command,
            AgentSessionCommand::Prompt(_)
                | AgentSessionCommand::Cancel(_)
                | AgentSessionCommand::Permission(_)
                | AgentSessionCommand::Typing(_)
        )
    {
        return refuse(writer, id, Refusal::ReadOnly);
    }
    // A cancel is a notification on the link and never waits.
    if let AgentSessionCommand::Cancel(_) = command {
        let sent =
            attachment.link.notify("session/cancel", json!({"sessionId": attachment.session}));
        return match sent {
            Ok(()) => ok(writer, id, json!({})),
            Err(error) => refuse(writer, id, Refusal::of(error)),
        };
    }
    if attachment.calls.fetch_add(1, Ordering::AcqRel) >= MAX_CALLS {
        attachment.calls.fetch_sub(1, Ordering::AcqRel);
        return refuse(writer, id, Refusal::Limit);
    }
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let worker = attachment.clone();
    let spawned = std::thread::Builder::new()
        .name("mux-agent-call".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            let result = call(&worker, command);
            worker.calls.fetch_sub(1, Ordering::AcqRel);
            match result {
                Ok(data) => ok(&worker_writer, worker_id, data),
                Err(refusal) => refuse(&worker_writer, worker_id, refusal),
            };
        });
    if spawned.is_err() {
        attachment.calls.fetch_sub(1, Ordering::AcqRel);
        return refuse(writer, id, Refusal::Limit);
    }
    true
}

fn call(attachment: &Attachment, command: AgentSessionCommand) -> Result<Value, Refusal> {
    let session = attachment.session.as_str();
    match command {
        AgentSessionCommand::Attach(params) => {
            let newest_first = params.after_seq.is_none() || params.before_seq.is_some();
            let params = page_params(session, &params, true)?;
            let page = attachment.link.call("_acpmux/attach", params, CALL_TIMEOUT);
            page.map(|page| bound_page(page, newest_first)).map_err(Refusal::of)
        }
        AgentSessionCommand::Events(params) => {
            let newest_first = params.before_seq.is_some();
            let params = page_params(session, &params, false)?;
            let page = attachment.link.call("_acpmux/events", params, CALL_TIMEOUT);
            page.map(|page| bound_page(page, newest_first)).map_err(Refusal::of)
        }
        AgentSessionCommand::Prompt(PromptParams { prompt_id, text, .. }) => {
            prompt(attachment, prompt_id, text)
        }
        AgentSessionCommand::Permission(PermissionParams {
            permission_id,
            option_id,
            decision_nonce,
            person_decision,
            answered_by,
            ..
        }) => {
            if option_id.is_empty() || option_id.len() > 256 {
                return Err(Refusal::BadRequest);
            }
            if !decision_nonce.as_deref().is_none_or(is_hex64)
                || !person_decision.as_deref().is_none_or(is_hex64)
                || answered_by
                    .as_ref()
                    .is_some_and(|a| !is_answer_id(&a.device) || !is_answer_id(&a.feed_item))
            {
                return Err(Refusal::BadRequest);
            }
            if !attachment.has_permission(&permission_id) {
                return Err(Refusal::UnknownPermission);
            }
            let mut params =
                json!({"sessionId": session, "permissionId": permission_id, "optionId": option_id});
            let mut meta = serde_json::Map::new();
            if let Some(nonce) = decision_nonce {
                meta.insert("decisionNonce".into(), Value::String(nonce));
            }
            if let Some(proof) = person_decision {
                meta.insert("personDecision".into(), Value::String(proof));
            }
            if let Some(by) = answered_by {
                meta.insert(
                    "answeredBy".into(),
                    json!({"device": by.device, "feedItem": by.feed_item}),
                );
            }
            if !meta.is_empty() {
                params.insert("_meta", json!({"acpmux": meta}));
            }
            let answered = attachment.link.call("_acpmux/permission_respond", params, CALL_TIMEOUT);
            // A failed answer stays answerable; a delivered one is spent.
            if answered.is_ok() {
                attachment.forget_permission(&permission_id);
            }
            answered.map_err(Refusal::of)
        }
        AgentSessionCommand::Children(_) => agent_session_children::list(attachment),
        AgentSessionCommand::Media(MediaParams { path, .. }) => media(attachment, path),
        // The session is the tab's own; acpmux bounds typing (2 a second, `typing.rate_limited`).
        // acpmux's rate refusal is the attachment's bound (`agent_session.limit`): the pane says
        // so again with its next keystroke.
        AgentSessionCommand::Typing(TypingParams { on, .. }) => attachment
            .link
            .call("_acpmux/typing", json!({"sessionId": session, "on": on}), CALL_TIMEOUT)
            .map_err(|error| match &error {
                LinkError::Rpc(_, data)
                    if data.get("reason").and_then(Value::as_str)
                        == Some("typing.rate_limited") =>
                {
                    Refusal::Limit
                }
                _ => Refusal::of(error),
            }),
        AgentSessionCommand::View(ViewParams { visible, .. }) => attachment
            .link
            .call("_acpmux/view", json!({"sessionId": session, "visible": visible}), CALL_TIMEOUT)
            .map_err(Refusal::of),
        AgentSessionCommand::Cancel(_) | AgentSessionCommand::Detach(_) => Ok(json!({})),
    }
}

/// Reads one image from the attached chat's host acpmux. The attachment daemon keeps the path
/// scoped to the bound session; this command only relays the already checked media reader bytes.
fn media(attachment: &Attachment, path: String) -> Result<Value, Refusal> {
    use base64::Engine;
    let image_extension = std::path::Path::new(&path)
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            matches!(
                extension.to_ascii_lowercase().as_str(),
                "png" | "jpg" | "jpeg" | "gif" | "webp"
            )
        });
    if !image_extension {
        return Err(Refusal::BadRequest);
    }
    if path.is_empty() || path.len() > 4096 {
        return Err(Refusal::BadRequest);
    }
    let opened = attachment
        .link
        .call(
            "_acpmux/media_open",
            json!({"sessionId": attachment.session, "path": path}),
            CALL_TIMEOUT,
        )
        .map_err(Refusal::of)?;
    let handle = opened.get("handle").and_then(Value::as_str).ok_or(Refusal::BadRequest)?;
    let size = opened.get("size").and_then(Value::as_u64).ok_or(Refusal::BadRequest)?;
    const MAX_BYTES: u64 = 10 << 20;
    const MAX_RANGE: u64 = 6 << 20;
    if size == 0 || size > MAX_BYTES {
        return Err(Refusal::BadRequest);
    }
    let mut bytes = Vec::with_capacity(usize::try_from(size).map_err(|_| Refusal::BadRequest)?);
    let mut offset = 0u64;
    while offset < size {
        let length = (size - offset).min(MAX_RANGE);
        let range = attachment
            .link
            .call(
                "_acpmux/media_range",
                json!({"sessionId": attachment.session, "handle": handle, "offset": offset, "length": length}),
                CALL_TIMEOUT,
            )
            .map_err(Refusal::of)?;
        let actual = range.get("offset").and_then(Value::as_u64).ok_or(Refusal::BadRequest)?;
        if actual != offset {
            return Err(Refusal::BadRequest);
        }
        let encoded = range.get("data").and_then(Value::as_str).ok_or(Refusal::BadRequest)?;
        let chunk = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| Refusal::BadRequest)?;
        if chunk.is_empty() || chunk.len() as u64 > length {
            return Err(Refusal::BadRequest);
        }
        offset = offset.saturating_add(chunk.len() as u64);
        bytes.extend_from_slice(&chunk);
    }
    Ok(json!({
        "mimeType": opened.get("mimeType").cloned().unwrap_or(Value::Null),
        "data": base64::engine::general_purpose::STANDARD.encode(bytes),
    }))
}

/// Sends one text prompt and answers once acpmux recorded it. The turn's
/// reply streams as records; the `session/prompt` result (at the end of the
/// turn) is not waited for.
fn prompt(attachment: &Attachment, prompt_id: String, text: String) -> Result<Value, Refusal> {
    let valid_id = (1..=128).contains(&prompt_id.len())
        && prompt_id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    if !valid_id || text.trim().is_empty() || text.len() > MAX_PROMPT_BYTES {
        return Err(Refusal::BadRequest);
    }
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    {
        let mut prompts = attachment.prompts.lock().unwrap_or_else(|e| e.into_inner());
        if prompts.len() >= MAX_CALLS || prompts.contains_key(&prompt_id) {
            return Err(Refusal::Limit);
        }
        prompts.insert(prompt_id.clone(), sender);
    }
    // Only a text content block: the client sends content, never a command,
    // a path or an MCP server.
    let params = json!({
        "sessionId": attachment.session,
        "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": prompt_id}},
    });
    // The request's own reply comes at the end of the turn and is not
    // waited for, so a queued prompt holds no call slot (permission answers
    // stay possible while turns queue).
    if let Err(error) = attachment.link.send_ignoring_reply("session/prompt", params) {
        attachment.prompts.lock().unwrap_or_else(|e| e.into_inner()).remove(&prompt_id);
        return Err(Refusal::of(error));
    }
    let accepted = receiver.recv_timeout(CALL_TIMEOUT);
    attachment.prompts.lock().unwrap_or_else(|e| e.into_inner()).remove(&prompt_id);
    match accepted {
        Ok(accepted) => Ok(json!({
            "prompt_id": prompt_id,
            "turn_id": accepted.get("turnId").cloned().unwrap_or(Value::Null),
            "queued": accepted.get("queued").cloned().unwrap_or(json!(false)),
        })),
        Err(_) => Err(Refusal::Timeout),
    }
}

fn ok(writer: &MessageWriter, id: Option<Value>, data: Value) -> bool {
    send_response(
        writer,
        Response {
            id,
            ok: true,
            data: Some(data),
            error: None,
            error_code: None,
            error_delivery: None,
        },
    )
}

fn refuse(writer: &MessageWriter, id: Option<Value>, refusal: Refusal) -> bool {
    send_response(
        writer,
        Response {
            id,
            ok: false,
            data: None,
            error: Some(refusal.message().to_string()),
            error_code: Some(refusal.code().to_string()),
            error_delivery: None,
        },
    )
}

/// A refusal with its typed reason in `data` (`needs_keyed_start`).
fn refuse_with_data(
    writer: &MessageWriter,
    id: Option<Value>,
    refusal: Refusal,
    data: Value,
) -> bool {
    send_response(
        writer,
        Response {
            id,
            ok: false,
            data: Some(data),
            error: Some(refusal.message().to_string()),
            error_code: Some(refusal.code().to_string()),
            error_delivery: None,
        },
    )
}

impl Mux {
    /// This machine's acpmux unix socket (the binary resolves it at start
    /// like `cmux acp`). Without one the daemon does not advertise
    /// `agent-session-attach-v1` and refuses the verbs.
    pub fn set_acpmux_socket(&self, socket: Option<PathBuf>) {
        self.control_clients.agent_sessions.set_socket(socket);
    }

    /// True when the daemon resolved an acpmux socket path at start. The
    /// capability says the verbs exist; an attach while nothing listens there
    /// answers `agent_session.unavailable` (acpmux starts and stops on its own
    /// schedule, so the socket's presence at `identify` time proves nothing).
    pub(crate) fn serves_agent_session_attach(&self) -> bool {
        self.control_clients.agent_sessions.socket().is_some()
    }

    /// How this daemon starts its machine's acpmux when an
    /// `agent-session-start` finds nothing on the socket (the binary's
    /// `cmux acp daemon start`). Without one a start answers
    /// `agent_session.acpmux_unavailable` while acpmux is down.
    pub fn set_acpmux_starter(&self, starter: Option<AcpmuxStarter>) {
        self.control_clients.agent_sessions.starts.set_starter(starter);
    }

    /// How the binary reads this machine's kind from its own identity (at
    /// each `agent-session-start`). Until it is set, the verb refuses
    /// (`agent_session.host_unverified`).
    pub fn set_agent_start_host(&self, host: AgentStartHostSource) {
        self.control_clients.agent_sessions.starts.set_host(host);
    }

    /// True when the daemon serves `agent-session-start` (as attach: an
    /// acpmux socket path; without a starter a start needs acpmux running).
    pub(crate) fn serves_agent_session_start(&self) -> bool {
        self.serves_agent_session_attach()
    }
}
