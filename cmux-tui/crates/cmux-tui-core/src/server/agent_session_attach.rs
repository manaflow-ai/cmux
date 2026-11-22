//! Remote agent session attach (`agent-session-attach-v1`): a client that
//! shows an agent chat tab of THIS daemon's store streams the tab's acpmux
//! session (history replay and live records) and types into it, through
//! this daemon, which is a local client of this machine's acpmux unix
//! socket. It is how an app on another Mac shows a chat that runs here
//! (plans/cmux-next/remote-agent-attach.md); no acpmux port is opened.
//!
//! Scope: every verb names a store tab by `surface`. The tab must be an
//! `agent_session` tab of this store with a bound session, and that session
//! must exist in this machine's acpmux (the attach resolves it there). The
//! verbs never take a session id, a cwd, a command, an agent name or an MCP
//! server from the client: the session comes from the store record.
//!
//! Who: trusted local (Unix) connections only. That includes the SSH/server
//! carrier, whose sidecar connects here over the same uid. The remote relay
//! (`remote_relay/gate.rs`, the conversations-only `cmux link` entry) runs
//! before this handler and does not list these verbs (default deny); a
//! WebSocket client is refused here.
//!
//! Verbs (JSON lines, framing of every v12 command; they bypass the ordered
//! surface queue):
//! - `agent-session-attach {surface, after_seq?, before_seq?, limit?, kinds?}`
//!   subscribes the connection to the tab's session and answers acpmux's
//!   attach page `{session, events, hasMore, lastSeq}`. Again on an attached
//!   tab it only pages.
//! - `agent-session-events {surface, after_seq?, before_seq?, limit?, kinds?}`
//!   pages the log of an attached tab (replay after a disconnect).
//! - `agent-session-prompt {surface, prompt_id, text}` sends one text prompt
//!   and answers once acpmux recorded it (`{prompt_id, turn_id, queued}`).
//! - `agent-session-cancel {surface}` cancels the running turn.
//! - `agent-session-permission {surface, permission_id, option_id}` answers a
//!   permission request acpmux announced on this attachment. The daemon never
//!   answers one by itself.
//! - `agent-session-detach {surface}`.
//!
//! Events: `agent-session-record {surface, record}` (one acpmux record,
//! `eventStream` form), `agent-session-permission {surface, request}`,
//! `agent-session-changed {surface, change}` (acpmux `session_changed` of
//! that session: status, queue), and
//! `agent-session-closed {surface, reason}` (reasons `lagged`, `overflow`,
//! `acpmux_closed`, `too_large`, `detached`): what the client received is a
//! gap-free prefix of the log, so it attaches again with `after_seq` = the
//! newest seq it holds.
//!
//! Bounds: 8 attachments per connection, 64 per daemon, one acpmux link per
//! attachment with at most 16 calls in flight, pages of at most
//! [`MAX_PAGE`] records, prompts of at most [`MAX_PROMPT_BYTES`]. Live
//! records go to the connection's bounded outbound stream without waiting;
//! a client that does not keep up loses the attachment (`overflow`) and
//! replays, so nothing buffers without bound and the acpmux link is always
//! read (acpmux's own lag is reported as `lagged`).

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock, Weak};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

#[path = "agent_session_link.rs"]
mod agent_session_link;
use super::{MessageWriter, OutboundStream, Response, SurfaceId, send_response};
use crate::mux::Mux;
use crate::state::conversation_tabs_store::ConversationTabRecord;
use agent_session_link::{AcpmuxLink, Inbound, LinkError};

pub const AGENT_SESSION_ATTACH_CAPABILITY: &str = "agent-session-attach-v1";

pub(crate) const MAX_ATTACHMENTS_PER_CLIENT: usize = 8;
pub(crate) const MAX_ATTACHMENTS_TOTAL: usize = 64;
/// Records per attach or events page.
pub(crate) const MAX_PAGE: u64 = 500;
pub(crate) const MAX_PROMPT_BYTES: usize = 64 * 1024;
/// Permission ids remembered per attachment (announced, not yet answered).
const MAX_PERMISSIONS: usize = 64;
const MAX_KINDS: usize = 8;
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
    socket: RwLock<Option<PathBuf>>,
    state: Mutex<AttachState>,
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
    pub(crate) fn set_socket(&self, socket: Option<PathBuf>) {
        *self.socket.write().unwrap_or_else(|e| e.into_inner()) = socket;
    }

    pub(crate) fn socket(&self) -> Option<PathBuf> {
        self.socket.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

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
}

impl Attachment {
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
            _ => return None,
        })
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SurfaceParams {
    surface: SurfaceId,
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
        }
    }

    fn of(error: LinkError) -> Self {
        match error {
            LinkError::Closed => Self::Unavailable,
            LinkError::Timeout => Self::Timeout,
            LinkError::Busy => Self::Limit,
            LinkError::Rpc(_) => Self::Refused,
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
        AgentSessionCommand::Attach(params) => attach(mux, client, id, socket, params, writer),
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

fn command_surface(command: &AgentSessionCommand) -> SurfaceId {
    match command {
        AgentSessionCommand::Attach(params) | AgentSessionCommand::Events(params) => params.surface,
        AgentSessionCommand::Prompt(params) => params.surface,
        AgentSessionCommand::Permission(params) => params.surface,
        AgentSessionCommand::Cancel(params) | AgentSessionCommand::Detach(params) => params.surface,
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
        out["afterSeq"] = json!(after);
    }
    if let Some(before) = params.before_seq {
        out["beforeSeq"] = json!(before);
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
        out["kinds"] = json!(kinds);
    }
    if attach {
        out["eventStream"] = json!(true);
    }
    Ok(out)
}

fn attach(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    socket: PathBuf,
    params: PageParams,
    writer: &MessageWriter,
) -> bool {
    let sessions = &mux.control_clients.agent_sessions;
    if let Some(attachment) = sessions.attachment(client, params.surface) {
        // Already attached: page only, on the attachment's own link.
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

#[allow(clippy::too_many_arguments)]
fn connect_and_attach(
    mux: Arc<Mux>,
    client: u64,
    id: Option<Value>,
    socket: PathBuf,
    surface: SurfaceId,
    record_session: String,
    params: Value,
    writer: MessageWriter,
) {
    let sessions = &mux.control_clients.agent_sessions;
    let release = |sessions: &AgentSessions| sessions.lock().reserved.remove(&(client, surface));
    let newest_first = params.get("afterSeq").is_none() || params.get("beforeSeq").is_some();
    let slot: Arc<Mutex<ReaderSlot>> = Arc::default();
    let reader_slot = slot.clone();
    let reader_mux = Arc::downgrade(&mux);
    let link = AcpmuxLink::connect(&socket, move |inbound| {
        let inbound = match reader_slot.lock().unwrap_or_else(|e| e.into_inner()).hold(inbound) {
            Ok(()) => return,
            Err(inbound) => inbound,
        };
        let attachment = reader_slot.lock().unwrap_or_else(|e| e.into_inner()).attachment.clone();
        let Some(attachment) = attachment else { return };
        deliver(&attachment, inbound);
        if attachment.ended.load(Ordering::Acquire)
            && let Some(mux) = reader_mux.upgrade()
        {
            mux.control_clients.agent_sessions.remove(&attachment);
        }
    });
    let link = match link {
        Ok(link) => link,
        Err(_) => {
            release(sessions);
            refuse(&writer, id, Refusal::Unavailable);
            return;
        }
    };
    let page = match link.call("_acpmux/attach", params, CALL_TIMEOUT) {
        Ok(page) => bound_page(page, newest_first),
        Err(error) => {
            release(sessions);
            link.close();
            refuse(&writer, id, Refusal::of(error));
            return;
        }
    };
    let overflow = closed_event(surface, "overflow");
    let Ok(outbound) = writer.start_stream(&overflow) else {
        release(sessions);
        link.close();
        refuse(&writer, id, Refusal::Limit);
        return;
    };
    let resolved =
        page.pointer("/session/sessionId").and_then(Value::as_str).unwrap_or_default().to_string();
    // acpmux resolves an id, a name or a unique prefix of either: only the
    // session the record names exactly (its id or its full name) is the tab's.
    let named = page.pointer("/session/name").and_then(Value::as_str);
    if resolved != record_session && named != Some(record_session.as_str()) {
        release(sessions);
        link.close();
        refuse(&writer, id, Refusal::UnknownTab);
        return;
    }
    slot.lock().unwrap_or_else(|e| e.into_inner()).session = Some(resolved.clone());
    // Session status changes (`_acpmux/session_changed`) come only to
    // watchers; the reader keeps only this session's. The answer (every
    // session's summary) is dropped here and never reaches the client.
    let _ = link.call("_acpmux/watch", json!({"enabled": true}), CALL_TIMEOUT);
    let attachment = Arc::new(Attachment {
        client,
        surface,
        session: resolved,
        record_session,
        mux: Arc::downgrade(&mux),
        link: link.clone(),
        writer: writer.clone(),
        outbound,
        calls: AtomicUsize::new(0),
        ended: AtomicBool::new(false),
        permissions: Mutex::default(),
        prompts: Mutex::default(),
    });
    for pending in page.pointer("/session/pending").and_then(Value::as_array).into_iter().flatten()
    {
        if let Some(permission) = pending.get("permissionId").and_then(Value::as_str) {
            attachment.note_permission(permission);
        }
    }
    {
        let mut state = sessions.lock();
        state.reserved.remove(&(client, surface));
        // The connection ended while connecting: the slot is gone with it.
        if !writer.is_open() {
            drop(state);
            link.close();
            return;
        }
        state.attachments.insert((client, surface), attachment.clone());
    }
    let replied = ok(&writer, id, page);
    {
        // The held notifications go out after the reply, in order, before
        // any later one (the reader waits on this lock meanwhile).
        let mut reader = slot.lock().unwrap_or_else(|e| e.into_inner());
        for inbound in std::mem::take(&mut reader.early) {
            deliver(&attachment, inbound);
        }
        if reader.overflowed {
            attachment.end(Some("overflow"));
        }
        reader.attachment = Some(attachment.clone());
    }
    if !replied || attachment.ended.load(Ordering::Acquire) {
        sessions.remove(&attachment);
        attachment.end(None);
    }
}

/// `page` with at most [`MAX_PAGE_BYTES`] of records: a newest-first page
/// drops its oldest records, a forward page its newest; `hasMore` then says
/// more remain.
pub(crate) fn bound_page(mut page: Value, newest_first: bool) -> Value {
    let Some(events) = page.get_mut("events").and_then(Value::as_array_mut) else { return page };
    let sizes: Vec<usize> = events
        .iter()
        .map(|event| serde_json::to_string(event).map_or(0, |text| text.len()))
        .collect();
    let mut total: usize = sizes.iter().sum();
    if total <= MAX_PAGE_BYTES {
        return page;
    }
    let mut keep_from = 0;
    let mut keep_to = events.len();
    while total > MAX_PAGE_BYTES && keep_from < keep_to {
        if newest_first {
            total -= sizes[keep_from];
            keep_from += 1;
        } else {
            keep_to -= 1;
            total -= sizes[keep_to];
        }
    }
    let kept: Vec<Value> = events.drain(keep_from..keep_to).collect();
    *events = kept;
    page["hasMore"] = json!(true);
    page
}

/// One notification or the close from the attachment's acpmux link.
fn deliver(attachment: &Attachment, inbound: Inbound) {
    if attachment.ended.load(Ordering::Acquire) {
        return;
    }
    let (method, params) = match inbound {
        Inbound::Closed(reason) => return attachment.end(Some(reason)),
        Inbound::Notification(method, params) => (method, params),
    };
    let same_session = params.get("sessionId").and_then(Value::as_str) == Some(&attachment.session);
    // A closed tab, or one that now shows another session, stops streaming.
    if same_session && !attachment.tab_current() {
        return attachment.end(Some("detached"));
    }
    match method.as_str() {
        "_acpmux/event" if same_session => {
            let event = json!({"event": "agent-session-record", "surface": attachment.surface, "record": params});
            // Never blocks: a client that does not keep up overflows its
            // stream, which ends with the `overflow` close (the stream's own
            // overflow text), and the client replays from what it holds.
            if attachment.writer.send_stream(&event, &attachment.outbound).is_err() {
                attachment.end(None);
            }
        }
        "_acpmux/permission_pending" if same_session => {
            if let Some(permission) = params.get("permissionId").and_then(Value::as_str) {
                attachment.note_permission(permission);
            }
            let event = json!({"event": "agent-session-permission", "surface": attachment.surface, "request": params});
            if attachment.writer.send_stream(&event, &attachment.outbound).is_err() {
                attachment.end(None);
            }
        }
        "_acpmux/session_changed" if same_session => {
            let event = json!({"event": "agent-session-changed", "surface": attachment.surface, "change": params});
            if attachment.writer.send_stream(&event, &attachment.outbound).is_err() {
                attachment.end(None);
            }
        }
        "_acpmux/prompt_accepted" if same_session => {
            let prompt = params.get("promptId").and_then(Value::as_str).unwrap_or_default();
            let slot = attachment.prompts.lock().unwrap_or_else(|e| e.into_inner()).remove(prompt);
            if let Some(slot) = slot {
                let _ = slot.try_send(params);
            }
        }
        "_acpmux/lagged" => attachment.end(Some("lagged")),
        _ => {}
    }
}

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
        AgentSessionCommand::Permission(PermissionParams { permission_id, option_id, .. }) => {
            if option_id.is_empty() || option_id.len() > 256 {
                return Err(Refusal::BadRequest);
            }
            if !attachment.has_permission(&permission_id) {
                return Err(Refusal::UnknownPermission);
            }
            let params =
                json!({"sessionId": session, "permissionId": permission_id, "optionId": option_id});
            let answered = attachment.link.call("_acpmux/permission_respond", params, CALL_TIMEOUT);
            // A failed answer stays answerable; a delivered one is spent.
            if answered.is_ok() {
                attachment.forget_permission(&permission_id);
            }
            answered.map_err(Refusal::of)
        }
        AgentSessionCommand::Cancel(_) | AgentSessionCommand::Detach(_) => Ok(json!({})),
    }
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
}
