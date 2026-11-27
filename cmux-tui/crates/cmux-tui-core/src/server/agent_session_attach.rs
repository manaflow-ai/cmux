//! Remote agent session attachment for trusted local Unix clients. It streams
//! a store tab's bound acpmux session with bounded replay and live records,
//! and can drive prompts, cancels and permission answers. Every request is
//! scoped to the tab's stored session. The explicit Native owner carrier also
//! reaches these handlers; other remote relay and WebSocket clients are refused. Attachments have bounded pages, calls and outbound buffering, and
//! close with a replay cursor when acpmux or the client falls behind.

use crate::panic_free::JsonFields;
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock, Weak};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

#[path = "agent_session_children.rs"]
pub(super) mod agent_session_children;
#[path = "agent_session_folders.rs"]
mod agent_session_folders;
#[cfg(all(test, unix))]
#[path = "agent_session_kin_parity_tests.rs"]
mod agent_session_kin_parity_tests;
#[path = "agent_session_link.rs"]
pub(super) mod agent_session_link;
#[path = "agent_session_observe.rs"]
pub(super) mod agent_session_observe;
#[path = "agent_session_start.rs"]
pub(super) mod agent_session_start;
#[path = "agent_session_trust.rs"]
mod agent_session_trust;
#[path = "agent_session_bad_field.rs"]
mod bad_field;
#[path = "agent_session_context.rs"]
mod context;
#[path = "agent_session_inventory_socket.rs"]
mod inventory_socket;
#[path = "agent_session_side.rs"]
mod side;
#[path = "agent_session_side_known.rs"]
mod side_known;
#[cfg(test)]
#[path = "agent_session_test_hooks.rs"]
mod test_hooks;
use super::{MessageWriter, OutboundStream, Response, SurfaceId, send_response};
use crate::mux::Mux;
use crate::state::conversation_tabs_store::ConversationTabRecord;
pub use agent_session_folders::AGENT_SESSION_FOLDERS_CAPABILITY;
use agent_session_link::{AcpmuxLink, Inbound, LinkError};
pub(crate) use agent_session_start::chat_folder_prewarm_on;
pub use agent_session_start::{
    AGENT_SESSION_PREWARM_CAPABILITY, AGENT_SESSION_PREWARM_CHAT_FOLDER_CAPABILITY,
    AGENT_SESSION_START_CAPABILITY, AGENT_SESSION_START_CODEX_CREDENTIALS_CAPABILITY,
    AGENT_SESSION_START_CREDENTIALS_CAPABILITY, AGENT_SESSION_START_KEYED_REASON_CAPABILITY,
    AGENT_SESSION_START_MODE_CAPABILITY, AGENT_SESSION_START_MODEL_CAPABILITY,
    AGENT_SESSION_START_NO_CWD_CAPABILITY, AGENT_SESSION_START_OWNER_CLOUD_CAPABILITY,
    AGENT_SESSION_START_PERMISSION_MODE_CAPABILITY, AGENT_SESSION_START_VM_KIND_CAPABILITY,
    AcpmuxStarter, AgentStartHost, AgentStartHostSource,
};
pub use agent_session_trust::{
    AGENT_SESSION_TRUST_CAPABILITY, AGENT_SESSION_TRUST_VM_KIND_CAPABILITY,
};

pub const AGENT_SESSION_ATTACH_CAPABILITY: &str = "agent-session-attach-v1";
/// Ordered ACP content on `agent-session-prompt`; older clients keep sending `text`.
pub const AGENT_SESSION_CONTENT_CAPABILITY: &str = "agent-session-content-v1";
/// A Cloud mobile carrier connection may use the native agent-session JSON
/// verbs over an authenticated remote link. The carrier is still constrained
/// to tab-scoped attach/events/prompt/cancel/detach; it never receives a raw
/// acpmux socket.
pub const CLOUD_MOBILE_CHAT_CAPABILITY: &str = "cloud-mobile-chat-v1";
/// `agent-session-fork`: fork the attached chat through its latest completed turn.
pub const AGENT_SESSION_FORK_CAPABILITY: &str = "agent-session-fork-v1";
/// `agent-session-side`: New side chat and `/side [prompt]` of the attached chat, on this machine
/// (`agent_session_side.rs`).
pub const AGENT_SESSION_SIDE_CAPABILITY: &str = "agent-session-side-v1";
/// `agent-session-typing` and `agent-session-view`, and the `agent-session-presence` event: who
/// is in the attached chat (chat multiplayer, hq#4389), through acpmux's `_acpmux/typing`,
/// `_acpmux/view` and `_acpmux/presence`. The event goes only to a connection that echoed the
/// capability in `set-client-info`: an older app ends its attachment on an event it does not know.
pub const AGENT_SESSION_PRESENCE_CAPABILITY: &str = "agent-session-presence-v1";
/// `attending` and `seen_seq` on `agent-session-view`: whether the person attends the chat their
/// window shows, passed to acpmux's `_acpmux/view`, so a chat on this machine keeps its turns
/// unread while they are away from it (acpmux `hub/seen.rs`), and the answer's `lastReturn`.
pub const AGENT_SESSION_ATTENTION_CAPABILITY: &str = "agent-session-attention-v1";
/// `agent-session-set-model`, `agent-session-set-mode` and `agent-session-set-config`: the
/// person's model, mode and option picks for the attached chat, as acpmux's ACP
/// `session/set_model`, `session/set_mode` and `session/set_config_option` on the tab's own
/// session. An app without it says the picks need that machine's cmux-tui updated.
pub const AGENT_SESSION_SETTINGS_CAPABILITY: &str = "agent-session-settings-v1";
/// `agent-session-login`: a Cloud chat's own sign-in on this machine (the app's sign-in card), as
/// acpmux's `_acpmux/agent_login/{start,finish,api_key,cancel}`. Only the chat's owner, never a
/// teammate or link guest and never a read-only attachment. acpmux's refusal reason comes back
/// in the answer (`refused.reason`), so the card can say why.
pub const AGENT_SESSION_LOGIN_CAPABILITY: &str = "agent-session-login-v1";
/// The `agent-session-share-changed` event on `subscribe`: a chat's link shares or invites
/// changed (made, invited, uninvited, joined, kicked, revoked, expired, ended by the room or the
/// chat), so the owner's open Invite People sheet reads its rows again instead of polling. Only
/// to the owner's own connections that may run the share verbs and echoed it in
/// `set-client-info`.
pub const AGENT_SESSION_SHARE_EVENTS_CAPABILITY: &str = "agent-session-share-events-v1";
/// `agent-session-login` for an unbound agent tab of this store (a new chat whose start was refused
/// because its agent is not signed in, hq#11225): the step runs on this machine's acpmux with no
/// `sessionId`, so the sign-in is this machine's own. Gated as `agent-session-start` is: a trusted
/// carrier, the same host check (`vm_kind: "owner"` on a Cloud VM), never a teammate or link guest.
/// A daemon without it answers such a step `agent_session.not_attached`.
pub const AGENT_SESSION_LOGIN_MACHINE_CAPABILITY: &str = "agent-session-login-machine-v1";
/// Owner-only context inventory and cmux-added overrides on the attached session.
pub const AGENT_SESSION_CONTEXT_CAPABILITY: &str = "agent-session-context-v1";
/// `agent-session-btw`: the composer's `/btw <question>` on a Cloud chat, as acpmux's inline
/// `_acpmux/btw` on the attached session (`hub/btw.rs`): a read-only answer about the chat that
/// never touches it. The side question approves reads on this machine, so only the chat's owner
/// asks one: never a teammate or link guest, the Cloud mobile carrier (its prompts keep the Web's
/// asking policy, which this would widen) or a read-only attachment.
pub const AGENT_SESSION_BTW_CAPABILITY: &str = "agent-session-btw-v1";
/// `max_bytes` on `agent-session-attach` and `agent-session-events`: the page's byte budget,
/// passed to acpmux as `maxBytes` (at most [`MAX_PAGE_BYTES`]). The agent pane asks 128 KiB for a
/// chat's open page and read-ahead; without it acpmux answers its 1 MiB default, so a Cloud
/// chat's open, read-ahead and reconnect each read up to 8x what a local chat's do (hq#14027).
pub const AGENT_SESSION_PAGE_BYTES_CAPABILITY: &str = "agent-session-page-bytes-v1";
/// How long a side question may wait for its answer: acpmux gives an inline one 110 seconds.
const BTW_TIMEOUT: Duration = Duration::from_secs(120);
/// The longest side question, in bytes (a question about the chat, not a prompt).
const MAX_QUESTION_BYTES: usize = 16 * 1024;
/// How long a login's finish may wait: Codex's waits for the person's approval in the browser.
const LOGIN_FINISH_TIMEOUT: Duration = Duration::from_secs(15 * 60);
/// The longest login id, code or API key a login step carries, in bytes.
const MAX_LOGIN_BYTES: usize = 4096;

// Attached tabs are not capped by count: each holds one acpmux link (a unix socket, two
// descriptors here) and its reader thread with a [`THREAD_STACK_BYTES`] stack, a constant cost.
/// Records per attach or events page.
pub(crate) const MAX_PAGE: u64 = 500;
pub(crate) const MAX_PROMPT_BYTES: usize = 64 * 1024;
/// The most bytes of a question's `answers` (as JSON) one permission answer
/// carries; acpmux bounds each item itself.
const MAX_ANSWERS_BYTES: usize = 64 * 1024;
/// Permission ids remembered per attachment (announced, not yet answered).
const MAX_PERMISSIONS: usize = 64;
/// Record kinds or categories one page may ask for: the agent pane asks for all
/// the kinds it draws (9 since prompt bookmarks, cx-kpd0v), with room to grow.
const MAX_KINDS: usize = 32;
/// Worker calls (pages, prompts, permission answers) per attachment.
const MAX_CALLS: usize = 8;
const CALL_TIMEOUT: Duration = Duration::from_secs(5);
/// How long a prompt waits for acpmux's `prompt_accepted`. acpmux accepts before it starts the
/// agent, but the first prompt of a chat started a moment ago first waits for that chat's log and
/// adoption on a daemon that just started, which took over 5 s on a fresh Cloud machine (HQ's
/// cloud-start-matrix phone-start row, run 42617701877: `agent_session.timeout` 1.4 s after the
/// start). The prompt was already sent then, so a refusal there was a turn that might still run
/// while the phone said it failed. Bounded as the login start is.
pub(super) const PROMPT_ACCEPT_TIMEOUT: Duration = Duration::from_secs(30);
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
    /// WhoIs attestations from the same-user host proxy, fixed for each link. Every line of every connection asks
    /// whether it is a proxy's link, so with publishing on (R-DAEMON-STATE stage S1) that read loads the published
    /// copy and never waits for a bind or for another client's disconnect.
    proxy_authors: crate::published::Published<HashMap<u64, Value>, HashMap<u64, Value>>,
    /// Link shares for guests (`agent-session-share-*`, agent_session_shares.rs).
    link_shares: proxy::shares::LinkShares,
    /// Unix connections past their first line: a proxy binds only on its first.
    spoken: Mutex<HashSet<u64>>,
    /// A tab's session changes under the write side; every write to or for a teammate's
    /// attachment checks the tab under the read side, so none lands after a rebind.
    rebinding: RwLock<()>,
    /// `agent-session-start-v1`: the acpmux starter and the tabs starting.
    starts: agent_session_start::AgentSessionStarts,
    /// `agent-session-children-v1`: the descendants acpmux answered, which
    /// a `registry:` tab of this store may show.
    pub(crate) known_children: agent_session_children::KnownChildren,
    /// `agent-session-side-v1`: the side chats this daemon opened or saw tagged. The owner's
    /// alone: no teammate attaches to one, and the team list leaves them out.
    pub(crate) sides: side_known::SideSessions,
}

#[derive(Default)]
struct AttachState {
    attachments: HashMap<(u64, SurfaceId), Arc<Attachment>>,
    /// Slots taken by attaches that are still connecting.
    reserved: HashSet<(u64, SurfaceId)>,
}

impl AttachState {
    /// The client's attached and reserved tabs (the proxy-author trust check reads it; no cap does).
    fn count(&self, client: u64) -> usize {
        self.attachments.keys().chain(self.reserved.iter()).filter(|(c, _)| *c == client).count()
    }
}

impl AgentSessions {
    /// The attachments of a daemon whose stage S1 switch (R-DAEMON-STATE) is `publish_proxy_authors`.
    pub(crate) fn new(publish_proxy_authors: bool) -> Self {
        Self {
            proxy_authors: crate::published::Published::new(
                HashMap::new(),
                HashMap::clone,
                publish_proxy_authors,
            ),
            ..Self::default()
        }
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

    /// Held while a tab's session changes (`bind-conversation-tab-session`, a start's bind).
    pub(super) fn rebinding(&self) -> std::sync::RwLockWriteGuard<'_, ()> {
        self.rebinding.write().unwrap_or_else(|e| e.into_inner())
    }

    /// Held by a write to or for a teammate's attachment, from its tab check to the write.
    pub(super) fn shared(&self) -> std::sync::RwLockReadGuard<'_, ()> {
        self.rebinding.read().unwrap_or_else(|e| e.into_inner())
    }

    /// The connection's first line was handled: it can no longer bind a proxy identity.
    pub(crate) fn first_line_done(&self, client: u64) {
        self.spoken.lock().unwrap_or_else(|e| e.into_inner()).insert(client);
    }

    /// The link shares (`agent-session-share-*`).
    pub(super) fn link_shares(&self) -> &proxy::shares::LinkShares {
        &self.link_shares
    }

    pub(super) fn past_first_line(&self, client: u64) -> bool {
        self.spoken.lock().unwrap_or_else(|e| e.into_inner()).contains(&client)
    }

    /// The connection ended: every attachment of it closes.
    pub(crate) fn disconnect(&self, client: u64) {
        self.inventory_watches.disconnect(client);
        {
            let mut authors = self.proxy_authors.lock().unwrap_or_else(|e| e.into_inner());
            // A client that never bound (all but a proxy's links) changes nothing, so it publishes nothing.
            if let Some(author) = authors.get(&client) {
                // A link guest's end is noted first, so a prune never sees it neither bound nor
                // just gone (`LinkShares::present`).
                self.link_shares.left(author);
                authors.remove(&client);
            }
        }
        self.spoken.lock().unwrap_or_else(|e| e.into_inner()).remove(&client);
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
}

/// One attached tab: its acpmux link and the client stream it feeds.
struct Attachment {
    author: Option<Value>,
    client: u64,
    surface: SurfaceId,
    /// The acpmux session id (resolved by acpmux from the record's session).
    session: String,
    /// The session the tab's store record named at attach; the attachment
    /// ends when the record changes or the tab closes.
    record_session: String,
    read_only: AtomicBool,
    /// This attachment was opened by the authenticated Cloud mobile carrier.
    /// Prompt dispatch carries the Web asking policy under the same native
    /// attachment/session lock; ordinary local clients never inherit it.
    cloud_mobile: bool,
    mux: Weak<Mux>,
    link: Arc<AcpmuxLink>,
    writer: MessageWriter,
    outbound: OutboundStream,
    /// Calls running on worker threads (at most [`MAX_CALLS`]).
    calls: AtomicUsize,
    /// An unfiltered stream of a chat this machine's acpmux owns has a
    /// contiguous sequence. Filtered streams, and a peer's chat (its link is
    /// not sent every record: `MUX_UNSENT`), have holes and skip the check.
    ordered_stream: bool,
    /// The seq the next live record should have; 0 until the page's
    /// `lastSeq` or the first live record seeds it.
    next_stream_seq: AtomicU64,
    ended: AtomicBool,
    /// Permission ids acpmux announced on this attachment, oldest first.
    permissions: Mutex<VecDeque<String>>,
    /// Prompt ids waiting for `_acpmux/prompt_accepted`, with their reply slot: the acceptance
    /// (`Ok`), or the `session/prompt` reply itself when that comes first (a refusal).
    prompts: Mutex<HashMap<String, std::sync::mpsc::SyncSender<Result<Value, LinkError>>>>,
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

    fn stamp(&self, mut params: Value) -> Value {
        if let Some(author) = &self.author {
            params["_meta"]["acpmux"]["author"] = author.clone();
        }
        params
    }

    /// A page as this attachment may see it: a proxied teammate gets no `composer` records, and
    /// nothing once the tab shows another chat than the shared one (a rebind while acpmux answered).
    fn private(&self, page: Value) -> Result<Value, Refusal> {
        if self.author.is_none() {
            return Ok(page);
        }
        if !self.tab_current() {
            return Err(Refusal::NotShared);
        }
        Ok(stream::without_drafts(page))
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

    /// Runs `write` for this attachment: at once for the owner's; for a teammate's, only while
    /// its tab still shows the shared chat, with no rebind in between (`AgentSessions::shared`).
    fn while_shared<T>(&self, write: impl FnOnce() -> T) -> Result<T, Refusal> {
        if self.author.is_none() {
            return Ok(write());
        }
        let Some(mux) = self.mux.upgrade() else { return Err(Refusal::NotShared) };
        let _shared = mux.control_clients.agent_sessions.shared();
        if self.ended.load(Ordering::Acquire) || !self.tab_current() {
            return Err(Refusal::NotShared);
        }
        Ok(write())
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

    /// Ends the attachment after a push to its stream failed. The client always hears it: the
    /// stream's own `overflow` notice when the queue already sent it, else `send_failed`. A
    /// silent end left a client holding a dial that answered requests and a chat that never
    /// moved, with nothing that told it to attach again (cloud-carrier-chaos-staging, drop 60 s).
    pub(super) fn end_unsent(&self) {
        self.end(unsent_reason(&self.outbound));
    }

    /// A newer live record arriving before an older one leaves the client with
    /// no way to recover the gap from the stream. End the attachment so its
    /// normal after-seq replay fetches the missing records. A record at or
    /// below what the stream already covers (one written while the attach read
    /// its page) is an overlap the client drops: it passes and moves nothing.
    /// `deliver` runs one record at a time, so load-then-store does not race.
    pub(super) fn accepts_stream_seq(&self, seq: u64) -> bool {
        if !self.ordered_stream || seq == 0 {
            return true;
        }
        let expected = self.next_stream_seq.load(Ordering::Relaxed);
        if expected != 0 && seq > expected {
            return false;
        }
        if expected == 0 || seq == expected {
            self.next_stream_seq.store(seq.saturating_add(1), Ordering::Relaxed);
        }
        true
    }
}

/// The attachment ended. Records queued for it may be dropped, but what
/// the client received is always a gap-free prefix, so it attaches again
/// with `after_seq` = the newest seq it holds.
fn closed_event(surface: SurfaceId, reason: &str) -> Value {
    json!({"event": "agent-session-closed", "surface": surface, "reason": reason})
}

/// The close reason the client still needs after a failed push to `stream`: none when the
/// stream's own overflow notice is already queued (`terminal_enqueued`), else `send_failed`.
fn unsent_reason(stream: &OutboundStream) -> Option<&'static str> {
    (!stream.terminal_enqueued.load(Ordering::Acquire)).then_some("send_failed")
}

// MARK: Requests

/// Page params shared by attach and events.
#[derive(Deserialize, Default)]
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
    #[serde(default)]
    max_bytes: Option<u64>,
}

/// Params no agent-session verb takes because they would name another session, folder,
/// program or ACP request: refused (a bad request) even though other unknown params are
/// ignored.
const REDIRECT_PARAMS: &[&str] =
    &["session", "sessionId", "cwd", "command", "initial_command", "mcpServers", "_meta"];

enum AgentSessionCommand {
    Attach(PageParams),
    Events(PageParams),
    Prompt(PromptParams),
    Cancel(SurfaceParams),
    Permission(PermissionParams),
    Detach(SurfaceParams),
    Children(SurfaceParams),
    Fork(ForkParams),
    Side(side::Params),
    Media(MediaParams),
    Typing(TypingParams),
    View(ViewParams),
    SetModel(SetModelParams),
    SetMode(SetModeParams),
    SetConfig(SetConfigParams),
    Login(LoginParams),
    Context(context::Params),
    QueueApprove(QueueDecisionParams),
    QueueDecline(QueueDecisionParams),
    Btw(BtwParams),
}

impl AgentSessionCommand {
    /// The command of one frame object without `id` and `cmd`. A param no
    /// struct declares (a newer page's field) is dropped unread: no request
    /// is refused over a field this daemon does not know. The names that
    /// would aim a verb somewhere else ([`REDIRECT_PARAMS`]: a session id, cwd,
    /// command, MCP servers or ACP `_meta`) are never a new field: they stay a
    /// bad request on every verb.
    fn parse(cmd: &str, params: Value) -> Option<Self> {
        use serde_json::from_value;
        if params.as_object()?.keys().any(|key| REDIRECT_PARAMS.contains(&key.as_str())) {
            return None;
        }
        Some(match cmd {
            "agent-session-attach" => Self::Attach(from_value(params).ok()?),
            "agent-session-events" => Self::Events(from_value(params).ok()?),
            "agent-session-prompt" => Self::Prompt(from_value(params).ok()?),
            "agent-session-cancel" => Self::Cancel(from_value(params).ok()?),
            "agent-session-permission" => Self::Permission(from_value(params).ok()?),
            "agent-session-detach" => Self::Detach(from_value(params).ok()?),
            "agent-session-children" => Self::Children(from_value(params).ok()?),
            "agent-session-fork" => Self::Fork(from_value(params).ok()?),
            "agent-session-side" => Self::Side(from_value(params).ok()?),
            "agent-session-media" => Self::Media(from_value(params).ok()?),
            "agent-session-typing" => Self::Typing(from_value(params).ok()?),
            "agent-session-view" => Self::View(from_value(params).ok()?),
            "agent-session-set-model" => Self::SetModel(from_value(params).ok()?),
            "agent-session-set-mode" => Self::SetMode(from_value(params).ok()?),
            "agent-session-set-config" => Self::SetConfig(from_value(params).ok()?),
            "agent-session-login" => Self::Login(from_value(params).ok()?),
            "agent-session-context" => Self::Context(from_value(params).ok()?),
            "agent-session-queue-approve" => Self::QueueApprove(from_value(params).ok()?),
            "agent-session-queue-decline" => Self::QueueDecline(from_value(params).ok()?),
            "agent-session-btw" => Self::Btw(from_value(params).ok()?),
            _ => return None,
        })
    }
}

#[derive(Deserialize)]
struct SurfaceParams {
    surface: SurfaceId,
}

#[derive(Deserialize)]
struct ForkParams {
    surface: SurfaceId,
    through_seq: u64,
    #[serde(default)]
    name: Option<String>,
}

/// `agent-session-typing`: the person starts (`on`) or stops typing in the attached chat.
#[derive(Deserialize)]
struct TypingParams {
    surface: SurfaceId,
    on: bool,
}

/// `agent-session-view`: whether the person's window shows the attached chat now.
#[derive(Deserialize)]
struct ViewParams {
    surface: SurfaceId,
    visible: bool,
    /// Whether the person attends the chat it shows (`agent-session-attention-v1`, acpmux
    /// `hub/seen.rs`); absent, acpmux counts them attending.
    #[serde(default)]
    attending: Option<bool>,
    /// The chat's log seq at the person's last input, where a chat they stopped attending is left
    /// off.
    #[serde(default)]
    seen_seq: Option<u64>,
}

/// `agent-session-set-model`: the model the attached chat uses from its next turn.
#[derive(Deserialize)]
struct SetModelParams {
    surface: SurfaceId,
    model_id: String,
}

/// `agent-session-set-mode`: one of the modes the attached chat's agent reported.
#[derive(Deserialize)]
struct SetModeParams {
    surface: SurfaceId,
    mode_id: String,
}

/// `agent-session-set-config`: one value of a config option the attached chat's agent reported.
#[derive(Deserialize)]
struct SetConfigParams {
    surface: SurfaceId,
    config_id: String,
    value: String,
}

/// `agent-session-btw`: the person's side question about the attached chat.
#[derive(Deserialize)]
struct BtwParams {
    surface: SurfaceId,
    question: String,
}

/// `agent-session-login`: one step of the chat's agent's own sign-in on this machine (`op`
/// `start` with `agent`, `finish` with `login_id` and Claude's `code`, `api_key` with `agent` and
/// `key`, `cancel` with `login_id`).
#[derive(Deserialize)]
struct LoginParams {
    surface: SurfaceId,
    op: String,
    #[serde(default)]
    agent: Option<String>,
    #[serde(default)]
    login_id: Option<String>,
    #[serde(default)]
    code: Option<String>,
    #[serde(default)]
    key: Option<String>,
    /// The Cloud API's `vmKind` for the caller, as `agent-session-start` takes it: read only for a
    /// tab with no session (`agent-session-login-machine-v1`), whose sign-in is gated as a start.
    #[serde(default, deserialize_with = "crate::server::command_args::present_nullable")]
    vm_kind: Option<Option<String>>,
}

/// acpmux's params of one login step, each naming the attached `session` (acpmux runs the sign-in
/// on the machine that chat lives on, and restarts its agent signed in), or none for a new chat's
/// sign-in on this machine; `None` for a step whose fields are missing or out of bounds.
fn login_request(session: Option<&str>, params: LoginParams) -> Option<(String, Value, Duration)> {
    fn text(value: &Option<String>) -> Option<&str> {
        value.as_deref().filter(|v| (1..=MAX_LOGIN_BYTES).contains(&v.len()) && !v.contains('\0'))
    }
    // Any agent id: acpmux's `agent_login::Agent` decides which it signs in and how
    // (`unsupported_agent`, `unsupported`), so an agent it gains needs no change here (a list here
    // fell behind acpmux's more than once).
    let agent = || {
        text(&params.agent).filter(|a| {
            a.len() <= 32
                && a.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        })
    };
    let (mut body, timeout) = match params.op.as_str() {
        "start" => (json!({"agent": agent()?}), CALL_TIMEOUT * 6),
        "finish" => {
            let login_id = text(&params.login_id)?;
            let body = match &params.code {
                Some(_) => json!({"loginId": login_id, "code": text(&params.code)?}),
                None => json!({"loginId": login_id}),
            };
            (body, LOGIN_FINISH_TIMEOUT)
        }
        // acpmux waits up to 60 s for a Codex key to save.
        "api_key" => (json!({"agent": agent()?, "key": text(&params.key)?}), CALL_TIMEOUT * 15),
        "cancel" => (json!({"loginId": text(&params.login_id)?}), CALL_TIMEOUT),
        _ => return None,
    };
    if let Some(session) = session {
        body["sessionId"] = json!(session);
    }
    Some((format!("_acpmux/agent_login/{}", params.op), body, timeout))
}

/// One login step on the attached session's acpmux. acpmux's refusal is an answer, not an error:
/// `{"refused": {"reason": ...}}` with its `data.reason` (`unsupported` from an acpmux without the
/// method), so the card words why. The code and key are never logged.
fn login(attachment: &Attachment, params: LoginParams) -> Result<Value, Refusal> {
    let (method, body, timeout) =
        login_request(Some(&attachment.session), params).ok_or(Refusal::BadRequest)?;
    login_answer(attachment.link.call(&method, attachment.stamp(body), timeout))
}

/// A login step's answer as the page reads it ([`login`]).
fn login_answer(answer: Result<Value, LinkError>) -> Result<Value, Refusal> {
    match answer {
        Ok(result) => Ok(result),
        Err(LinkError::Rpc(_, data)) => {
            let reason = data.get("reason").and_then(Value::as_str).unwrap_or("failed");
            Ok(json!({"refused": {"reason": reason}}))
        }
        Err(LinkError::MethodNotFound(_)) => Ok(json!({"refused": {"reason": "unsupported"}})),
        Err(error) => Err(Refusal::of(error)),
    }
}

/// The person's side question on the attached session's acpmux, answered inline (`{text}`).
/// acpmux's refusal is an answer, as a login step's is: `{"refused": {"reason": ...}}` with its
/// `data.reason` (`btw.no_read_only_mode`, `trust.pending`, `unsupported` from an acpmux without
/// the method). acpmux's message stays in this daemon.
///
/// It is the app's pane asking (`via: app`), so acpmux's folder-trust gate holds it as it holds
/// the app's own inline `/btw` (`trust_gate.rs`): no side question starts an agent in a folder
/// that is pending or untrusted. An acpmux from before inline answers ignores `inline` and opens
/// a lasting side session (`{sessionId}`): that session is ended at once and the answer is
/// `unsupported`, so no hidden work is left running.
fn btw(attachment: &Attachment, question: String) -> Result<Value, Refusal> {
    let question = question.trim();
    if question.is_empty() || question.len() > MAX_QUESTION_BYTES {
        return Err(Refusal::BadRequest);
    }
    let params = json!({"sessionId": attachment.session, "question": question, "inline": true,
                        "_meta": {"acpmux": {"via": "app"}}});
    match attachment.link.call("_acpmux/btw", attachment.stamp(params), BTW_TIMEOUT) {
        Ok(result) if result.get("text").is_some_and(Value::is_string) => Ok(result),
        Ok(result) => {
            if let Some(side) = result.get("sessionId").and_then(Value::as_str) {
                let kill = json!({"sessionId": side, "purge": true});
                let _ = attachment.link.call("_acpmux/kill", kill, CALL_TIMEOUT);
            }
            Ok(json!({"refused": {"reason": "unsupported"}}))
        }
        Err(LinkError::Rpc(_, data)) => {
            let reason = data.get("reason").and_then(Value::as_str).unwrap_or("failed");
            Ok(json!({"refused": {"reason": reason}}))
        }
        Err(LinkError::MethodNotFound(_)) => Ok(json!({"refused": {"reason": "unsupported"}})),
        Err(error) => Err(Refusal::of(error)),
    }
}

/// The longest model id, mode id, option id or option value a setting carries, in bytes.
const MAX_SETTING_BYTES: usize = 256;

/// One id or value of a setting as agents name them (`claude-opus-5-5[1m]`, `provider/model:tag`,
/// `acceptEdits`, `high`): 1 to [`MAX_SETTING_BYTES`] ASCII letters, digits and `._-/:@[]+`, not
/// starting with `-`. No whitespace, control, quote, shell or template character (the app's
/// `AcpmuxPaneMethods.isModelID` rule).
fn is_setting_id(value: &str) -> bool {
    (1..=MAX_SETTING_BYTES).contains(&value.len())
        && !value.starts_with('-')
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-/:@[]+".contains(&b))
}

#[derive(Deserialize)]
struct MediaParams {
    surface: SurfaceId,
    path: String,
    /// A video's byte range (`agent_session_media.rs` `media_range`): its first byte; none for a
    /// whole image.
    #[serde(default)]
    offset: Option<u64>,
    /// The range's most bytes, at most `MAX_RANGE` (the default).
    #[serde(default)]
    length: Option<u64>,
    /// The open file an earlier range answered, so the next range reads the same file.
    #[serde(default)]
    handle: Option<String>,
}

#[derive(Deserialize)]
struct PromptParams {
    surface: SurfaceId,
    prompt_id: String,
    text: Option<String>,
    content: Option<Vec<Value>>,
    /// Steer into the running turn (acpmux `_meta.acpmux.steer`) instead of queueing behind
    /// it (`agent-session-steer-v1`). acpmux still decides: a prompt that waits for the owner
    /// (a link guest's) is held whatever this says, and a chat that cannot steer now queues it.
    #[serde(default)]
    steer: bool,
}

/// `agent-session-queue-approve`: the owner runs a prompt held for them (a link guest's) in
/// its queue place; `agent-session-queue-decline` drops it. acpmux's `_acpmux/queue_approve`
/// and `_acpmux/queue_decline` on the tab's own session. The owner's only.
#[derive(Deserialize)]
struct QueueDecisionParams {
    surface: SurfaceId,
    prompt_id: String,
    #[serde(default)]
    turn_id: Option<String>,
    #[serde(default)]
    revision: Option<u64>,
}

#[derive(Deserialize)]
struct PermissionParams {
    surface: SurfaceId,
    permission_id: String,
    option_id: String,
    /// A question's answers (a JSON object, acpmux `hub/questions.rs`):
    /// passed to acpmux unchanged; the decision proof covers them.
    #[serde(default)]
    answers: Option<Value>,
    /// A question's annotations beside its answers (Claude Code's chosen
    /// preview and notes, acpmux `questions::check_annotations`): passed to
    /// acpmux unchanged; the decision proof covers them too.
    #[serde(default)]
    annotations: Option<Value>,
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
    /// acpmux's session list could not be read whole (`LinkError::BadList`).
    BadList,
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
    /// A proxied teammate's frame for a surface that shows another chat than the shared one.
    NotShared,
    /// A link guest's frame for anything but the shared chat's guest verbs.
    ScopeNotGranted,
    /// A link guest whose share expired or was revoked, or who was removed.
    ShareEnded,
    /// A Cloud team member's answer to a permission ask, or approval of a held prompt: the
    /// chat's owner decides what runs on their machine.
    OwnerOnly,
    /// `agent-session-start`: the agent answered that it is not signed in on this machine
    /// (acpmux `agent.sign_in_required`); `data` names the harness (hq#11225).
    SignInRequired,
    /// `agent-session-start`: the agent asked for is not in this machine's acpmux catalog (not
    /// installed there); `data` names the harness (hq#11225).
    HarnessMissing,
    /// `agent-session-start`: the agent's model route cannot serve it on this machine (acpmux
    /// `route.*`); `data` names the route's reason and the harness (hq#11225).
    RouteUnavailable,
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
            Self::BadList => "agent_session.bad_list",
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
            Self::NotShared => "agent_session.not_shared",
            Self::ScopeNotGranted => "agent_session.scope_not_granted",
            Self::ShareEnded => "agent_session.share_ended",
            Self::OwnerOnly => "agent_session.owner_only",
            Self::SignInRequired => "agent_session.sign_in_required",
            Self::HarnessMissing => "agent_session.harness_missing",
            Self::RouteUnavailable => "agent_session.route_unavailable",
        }
    }

    fn message(self) -> &'static str {
        match self {
            Self::NotTrusted => "agent session attach needs a trusted local connection",
            Self::Unavailable => "this daemon has no acpmux to attach to",
            Self::BadRequest => "bad request",
            Self::UnknownTab => "not an agent tab with a session in this daemon",
            Self::NotAttached => "the tab is not attached on this connection",
            Self::Limit => "the agent tab could not attach now; try again",
            Self::Timeout => "acpmux did not answer in time",
            Self::Refused => "acpmux refused the request",
            Self::BadList => "acpmux's session list could not be read whole",
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
            Self::NotShared => "the surface does not show the chat that was shared",
            Self::ScopeNotGranted => "a link guest only watches and writes to the shared chat",
            Self::ShareEnded => "the share ended, or the owner removed this guest",
            Self::OwnerOnly => "only the chat's owner answers its asks and approves held prompts",
            Self::SignInRequired => "the agent is not signed in on this machine",
            Self::HarnessMissing => "this agent is not installed on this machine",
            Self::RouteUnavailable => "the agent's model route cannot serve it on this machine",
        }
    }

    fn of(error: LinkError) -> Self {
        match error {
            LinkError::Closed => Self::Unavailable,
            LinkError::Timeout => Self::Timeout,
            LinkError::Rpc(..) | LinkError::MethodNotFound(_) => Self::Refused,
            LinkError::BadList(_) => Self::BadList,
        }
    }
}

/// Handles an `agent-session-*` frame of a local connection; `None` for any
/// other frame. The remote path admits only its explicit Native-owner subset.
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
    if object.get("cmd").and_then(Value::as_str) == Some("agent-session-proxy-bind") {
        return Some(proxy::bind(mux, client, object, writer));
    }
    // A peer cannot self-attribute: only the preface's fixed identity is accepted, for the chat
    // the share pinned.
    let (author, pinned) = match proxy::check(mux, client, &mut object) {
        Ok(Some(teammate)) => (Some(teammate.author), teammate.pinned),
        Ok(None) => (None, None),
        Err(refusal) => return Some(refuse(writer, object.remove("id"), refusal)),
    };
    // A bound link reaches its own verbs only; the owner's own verbs are answered there.
    if let Some(handled) = proxy::scope(mux, client, &mut object, author.as_ref(), writer) {
        return Some(handled);
    }
    if object.get("cmd").and_then(Value::as_str) == Some("agent-session-observe") {
        let clean = Value::Object(object).to_string();
        return agent_session_observe::try_handle(mux, client, &clean, writer, author, pinned);
    }
    let cmd = match object.remove("cmd") {
        Some(Value::String(cmd)) if cmd.starts_with("agent-session-") => cmd,
        _ => return None,
    };
    let id = object.remove("id");
    if cmd == "agent-session-start" {
        return Some(start(mux, client, id, object, writer));
    }
    // The owner's coming start, warmed ahead (cmux#45953): never a teammate's, guest's or member's link.
    if cmd == "agent-session-prewarm" {
        if author.is_some() {
            return Some(refuse(writer, id, Refusal::NotTrusted));
        }
        return Some(prewarm(mux, client, id, object, writer));
    }
    // The owner's refreshed model credential: never a teammate's, guest's or member's link.
    if cmd == "agent-session-credentials" {
        if author.is_some() {
            return Some(refuse(writer, id, Refusal::NotTrusted));
        }
        return Some(credentials(mux, client, id, object, writer));
    }
    if cmd == "agent-session-trust" {
        return Some(trust(mux, client, id, object, writer));
    }
    if cmd == "agent-session-folders" {
        return Some(folders(mux, client, id, object, writer));
    }
    let Some(command) = AgentSessionCommand::parse(&cmd, Value::Object(object)) else {
        return Some(refuse(writer, id, Refusal::BadRequest));
    };
    // Remote trust comes from the verified Cloud mobile peer
    // (`cloud_mobile_client`), never from the declared capability alone.
    // A Cloud team member's signed Native dial reaches its member verbs (`member.rs`), stamped
    // with the member the link token names.
    let member = author.as_ref().is_some_and(proxy::is_member) && mux.is_native_team_member(client);
    if !mux.agent_carrier_allowed(client) && !mux.cloud_mobile_client(client) && !member {
        return Some(refuse(writer, id, Refusal::NotTrusted));
    }
    let sessions = &mux.control_clients.agent_sessions;
    let Some(socket) = sessions.socket() else {
        return Some(refuse(writer, id, Refusal::Unavailable));
    };
    Some(match command {
        AgentSessionCommand::Attach(params) => {
            attach(mux, client, id, socket, params, false, author, pinned, writer)
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
            match (sessions.attachment(client, surface), command) {
                // A teammate's attachment is for the chat this request's share pins, only.
                (Some(attachment), _)
                    if author.is_some()
                        && pinned.as_deref() != Some(attachment.record_session.as_str()) =>
                {
                    refuse(writer, id, Refusal::NotShared)
                }
                (Some(attachment), command) => run_on_worker(mux, attachment, id, command, writer),
                // A new chat with no session yet signs its agent in on this machine (hq#11225).
                (None, AgentSessionCommand::Login(params)) => {
                    machine_login(mux, client, id, socket, author.is_some(), params, writer)
                }
                (None, _) => refuse(writer, id, Refusal::NotAttached),
            }
        }
    })
}

/// `agent-session-login` for a tab with no attachment (`agent-session-login-machine-v1`): an
/// unbound agent tab of this store (a new chat whose start was refused because its agent is not
/// signed in, hq#11225) runs the step on this machine's acpmux with no `sessionId`, so the sign-in
/// is this machine's own and no chat restarts. Gated exactly as `agent-session-start`: a trusted
/// carrier (never a teammate's or link guest's proxied link), the same host check
/// ([`Mux::agent_host_gate`] on the caller's `vm_kind`) and the same unbound tab of this store. Any
/// other tab (one with a session, another store's) still needs its attachment (`not_attached`).
/// The step runs on a worker, never on the connection's reader. The code and key are never logged.
fn machine_login(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    socket: PathBuf,
    teammate: bool,
    params: LoginParams,
    writer: &MessageWriter,
) -> bool {
    if agent_session_start::startable(mux, params.surface).is_err() {
        return refuse(writer, id, Refusal::NotAttached);
    }
    if teammate || !mux.agent_carrier_allowed(client) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    if let Err(refusal) = mux.agent_host_gate(client, agent_session_start::vm_word(&params.vm_kind))
    {
        return refuse(writer, id, refusal);
    }
    let Some((method, body, timeout)) = login_request(None, params) else {
        return refuse(writer, id, Refusal::BadRequest);
    };
    let worker_mux = mux.clone();
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new()
        .name("mux-agent-login".into())
        .stack_size(THREAD_STACK_BYTES)
        .spawn(move || {
            let answer = agent_session_start::connect(&worker_mux, &socket).and_then(|link| {
                let answer = login_answer(link.call(&method, body, timeout));
                link.close();
                answer
            });
            match answer {
                Ok(data) => ok(&worker_writer, worker_id, data),
                Err(refusal) => refuse(&worker_writer, worker_id, refusal),
            };
        });
    if spawned.is_err() {
        return refuse(writer, id, Refusal::Limit);
    }
    true
}

/// `agent-session-prewarm` (agent_session_prewarm.rs), with the start's trust and acpmux checks.
fn prewarm(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    params: serde_json::Map<String, Value>,
    writer: &MessageWriter,
) -> bool {
    let params = match bad_field::decode(params) {
        Ok(params) => params,
        Err(field) => return bad_field::refuse_field(writer, id, field.as_deref()),
    };
    if !mux.agent_carrier_allowed(client) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return refuse(writer, id, Refusal::Unavailable);
    };
    agent_session_start::prewarm(mux, client, id, socket, params, writer)
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
    let params = match bad_field::decode(params) {
        Ok(params) => params,
        Err(field) => return bad_field::refuse_field(writer, id, field.as_deref()),
    };
    if !mux.agent_carrier_allowed(client) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return refuse(writer, id, Refusal::Unavailable);
    };
    agent_session_start::start(mux, client, id, socket, params, writer)
}

/// `agent-session-credentials {surface, env, vm_kind}`: the owner's refreshed model credential
/// for the chat tab `surface` shows (a refreshed ChatGPT token), relayed to acpmux as
/// `agent/credentials.update` on that tab's own session, which restarts its agent on it and
/// resumes the chat. Only the owner's own app on the owner's own Cloud VM
/// ([`agent_session_start::credentials_admitted`]), through the start verb's trust checks.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CredentialsParams {
    surface: SurfaceId,
    env: std::collections::BTreeMap<String, String>,
    #[serde(default, deserialize_with = "crate::server::command_args::present_nullable")]
    vm_kind: Option<Option<String>>,
}

fn credentials(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    params: serde_json::Map<String, Value>,
    writer: &MessageWriter,
) -> bool {
    let CredentialsParams { surface, env, vm_kind } = match bad_field::decode(params) {
        Ok(params) => params,
        Err(field) => return bad_field::refuse_field(writer, id, field.as_deref()),
    };
    let credential = agent_session_start::StartCredentials { env };
    if !credential.valid() {
        return bad_field::refuse_field(writer, id, Some("env"));
    }
    if !mux.agent_carrier_allowed(client) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    if !agent_session_start::credentials_admitted(mux, client, &vm_kind) {
        return refuse(writer, id, Refusal::OwnerOnly);
    }
    // The tab's own session, of a tab this store hosts: never a session id the caller names.
    let session =
        mux.surface(surface).and_then(|runtime| match mux.conversation_tab_of(&runtime) {
            Some(ConversationTabRecord::AgentSession { host, session: Some(session), .. })
                if host == agent_session_start::store_host(mux) =>
            {
                Some(session)
            }
            _ => None,
        });
    let Some(session) = session else {
        return refuse(writer, id, Refusal::UnknownTab);
    };
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return refuse(writer, id, Refusal::Unavailable);
    };
    let (worker_mux, worker_writer, worker_id) = (mux.clone(), writer.clone(), id.clone());
    let spawned =
        std::thread::Builder::new().name("mux-agent-credentials".into()).spawn(move || {
            let answer = agent_session_start::connect(&worker_mux, &socket).and_then(|link| {
                let params = json!({"sessionId": session, "env": credential.env});
                // A restart waits for the agent's new process (spawn, initialize, resume).
                let reply = link.call("agent/credentials.update", params, CREDENTIALS_TIMEOUT);
                link.close();
                reply.map_err(Refusal::of)
            });
            match answer {
                Ok(reply) => {
                    let restart = reply.get("restart").cloned().unwrap_or(Value::Null);
                    ok(&worker_writer, worker_id, json!({"surface": surface, "restart": restart}))
                }
                Err(refusal) => refuse(&worker_writer, worker_id, refusal),
            };
        });
    if spawned.is_err() {
        return refuse(writer, id, Refusal::Limit);
    }
    true
}

/// A credential update restarts the agent between turns and waits for its new process.
const CREDENTIALS_TIMEOUT: Duration = Duration::from_secs(60);

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
    if !mux.agent_carrier_allowed(client) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return refuse(writer, id, Refusal::Unavailable);
    };
    agent_session_trust::trust(mux, client, id, socket, params, writer)
}

/// `agent-session-folders` (agent_session_folders.rs), with the same checks
/// as `agent-session-trust` (no acpmux needed).
fn folders(
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
    agent_session_folders::folders(mux, id, params, writer)
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
        AgentSessionCommand::Fork(params) => params.surface,
        AgentSessionCommand::Side(params) => params.surface,
        AgentSessionCommand::Media(params) => params.surface,
        AgentSessionCommand::Typing(params) => params.surface,
        AgentSessionCommand::View(params) => params.surface,
        AgentSessionCommand::SetModel(params) => params.surface,
        AgentSessionCommand::SetMode(params) => params.surface,
        AgentSessionCommand::SetConfig(params) => params.surface,
        AgentSessionCommand::Login(params) => params.surface,
        AgentSessionCommand::Context(params) => params.surface(),
        AgentSessionCommand::QueueApprove(params) | AgentSessionCommand::QueueDecline(params) => {
            params.surface
        }
        AgentSessionCommand::Btw(params) => params.surface,
    }
}

/// True when `client` is a host proxy's link for a teammate (`agent-session-proxy-bind`).
pub(super) fn proxy_bound(mux: &Mux, client: u64) -> bool {
    proxy::author(mux, client).is_some()
}

/// Whether `client` hears `agent-session-share-changed`: one of the owner's connections that may
/// run the share verbs (same-user unix, not bound, not a remote relay) and echoed
/// [`AGENT_SESSION_SHARE_EVENTS_CAPABILITY`]. Read at each event, as a bind can come later.
pub(super) fn hears_share_events(mux: &Mux, client: u64) -> bool {
    mux.control_clients.is_unix(client)
        && !mux.is_remote_client(client)
        && !proxy_bound(mux, client)
        && mux.control_clients.supports_capability(client, AGENT_SESSION_SHARE_EVENTS_CAPABILITY)
}

/// A frame of a teammate's link: the agent-session verbs [`try_handle`] allows it, and a refusal
/// for anything else the daemon serves (pages, resources, workspaces, terminals).
pub(super) fn handle_bound(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> bool {
    try_handle(mux, client, message, writer).unwrap_or_else(|| {
        let id =
            serde_json::from_str::<Value>(message).ok().and_then(|frame| frame.get("id").cloned());
        refuse(writer, id, proxy::scope_refusal(mux, client))
    })
}

pub(super) fn tab_session(mux: &Mux, surface: SurfaceId) -> Option<String> {
    let runtime = mux.surface(surface)?;
    match mux.conversation_tab_of(&runtime)? {
        ConversationTabRecord::AgentSession { session: Some(session), .. } => Some(session),
        _ => None,
    }
}

/// acpmux page params from the client's, with the session pinned and the
/// limit and kinds bounded.
/// The record kinds a teammate (a bound proxy author) may read, whatever it asked for:
/// the chat's transcript (acpmux `paging.rs` `transcript`), which holds no drafts and no raw
/// protocol traffic. acpmux filters the attachment's live records by the same kinds.
fn teammate_kinds(params: &mut Value) {
    params["kinds"] = json!(["transcript"]);
}

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
    if let Some(bytes) = params.max_bytes {
        if bytes == 0 {
            return Err(Refusal::BadRequest);
        }
        out.insert("maxBytes", json!(bytes.min(MAX_PAGE_BYTES as u64)));
    }
    if attach {
        out.insert("eventStream", json!(true));
        // The page opening the chat asks for its newest records at once, as the app's local
        // attach does (`direct.ts` `sendAttach`): waiting for a restarted daemon's log restore
        // of a long chat outlasted `CALL_TIMEOUT`, and the remote chat opened empty.
        out.insert("waitLogs", json!(false));
    }
    Ok(out)
}

#[allow(clippy::too_many_arguments)]
fn attach(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    socket: PathBuf,
    params: PageParams,
    read_only: bool,
    author: Option<Value>,
    pinned: Option<String>,
    writer: &MessageWriter,
) -> bool {
    let cloud_mobile =
        mux.control_clients.supports_capability(client, CLOUD_MOBILE_CHAT_CAPABILITY);
    let sessions = &mux.control_clients.agent_sessions;
    if let Some(attachment) = sessions.attachment(client, params.surface) {
        if author.is_some() && pinned.as_deref() != Some(attachment.record_session.as_str()) {
            return refuse(writer, id, Refusal::NotShared);
        }
        if attachment.read_only.load(Ordering::Acquire) != read_only {
            return refuse(writer, id, Refusal::ModeConflict);
        }
        // Already attached in the same mode: page only, on the attachment's own link.
        return run_on_worker(mux, attachment, id, AgentSessionCommand::Attach(params), writer);
    }
    let Some(session) = tab_session(mux, params.surface) else {
        return refuse(writer, id, Refusal::UnknownTab);
    };
    // A teammate attaches to the chat its share pinned, as `proxy::check` saw it: a rebind since
    // then is refused, never followed.
    if author.is_some() && pinned.as_deref() != Some(session.as_str()) {
        return refuse(writer, id, Refusal::NotShared);
    }
    // A side chat is the owner's alone, whoever shares or lists its tab.
    if author.is_some() && sessions.sides.contains(&session) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    let record_session = session.clone();
    let mut acpmux_params = match page_params(&session, &params, true) {
        Ok(value) => value,
        Err(refusal) => return refuse(writer, id, refusal),
    };
    // The author `proxy::check` accepted for this request: the worker stamps it on the session
    // watch too, so a disconnect (which forgets the binding) never leaves a call unstamped.
    if let Some(author) = &author {
        acpmux_params["_meta"]["acpmux"]["author"] = author.clone();
        // A teammate reads the transcript only, never raw wire records or other kinds, live or replayed.
        teammate_kinds(&mut acpmux_params);
    }
    {
        let mut state = sessions.lock();
        let key = (client, params.surface);
        if state.reserved.contains(&key) {
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
                cloud_mobile,
                author,
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

#[path = "agent_session_media.rs"]
mod media;
#[path = "agent_session_member.rs"]
pub(super) mod member;
#[path = "agent_session_proxy.rs"]
mod proxy;
use media::{media, media_range};
pub use proxy::shares::room::{set_link_share_app_scheme, start_link_share_bridge};
pub(crate) use proxy::shares::{
    TRANSFER_FIELD, abort_transferred_chat_shares, close_chat_shares, close_listed_chat_shares,
    close_unlisted_chat_shares, detach_transferred_chat_shares, finish_transferred_chat_shares,
    freeze_transferred_chat_shares, open_chat_shares, stage_transferred_chat_shares,
};

pub(crate) fn export_transferred_chat_shares(mux: &Mux, session: &str) -> Option<Value> {
    mux.control_clients
        .agent_sessions
        .link_shares
        .export_for_transfer(mux.session_state_directory().as_deref(), session)
}

#[path = "agent_session_stream.rs"]
mod stream;
pub(crate) use stream::bound_page;
use stream::connect_and_attach;
#[path = "agent_session_call.rs"]
mod call;
use call::call;

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
                | AgentSessionCommand::Fork(_)
                | AgentSessionCommand::Side(_)
                | AgentSessionCommand::SetModel(_)
                | AgentSessionCommand::SetMode(_)
                | AgentSessionCommand::SetConfig(_)
                | AgentSessionCommand::Login(_)
                | AgentSessionCommand::Context(_)
                | AgentSessionCommand::QueueApprove(_)
                | AgentSessionCommand::QueueDecline(_)
                | AgentSessionCommand::Btw(_)
        )
    {
        return refuse(writer, id, Refusal::ReadOnly);
    }
    // A teammate or link guest never changes the owner's chat's model, mode or options: a mode
    // can stop the agent asking before it acts on the owner's machine. Nor does it sign the
    // owner's agent in: that sets whose account the machine's agent runs as. Context includes
    // the owner's instructions and saved overrides, beyond what sharing a chat grants. A side
    // question approves reads on the owner's machine without asking, which a guest's prompt
    // never does; for the Cloud mobile carrier it would widen the Web's asking policy.
    if (attachment.author.is_some()
        && matches!(
            &command,
            AgentSessionCommand::SetModel(_)
                | AgentSessionCommand::SetMode(_)
                | AgentSessionCommand::SetConfig(_)
                | AgentSessionCommand::Login(_)
                | AgentSessionCommand::Context(_)
                | AgentSessionCommand::Btw(_)
        ))
        || (attachment.cloud_mobile && matches!(&command, AgentSessionCommand::Btw(_)))
    {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    // A teammate (a bound proxy author) never answers the host's asks: an allow
    // would run a tool on the owner's machine (design section 7). Nor does it say it types or
    // views yet: acpmux would count that as the owner's own presence. A link guest's typing and
    // view carry its author.
    let guest = attachment.author.as_ref().is_some_and(proxy::is_guest);
    // A Cloud team member's typing and view carry its own author (acpmux presence), like a guest's.
    let member = attachment.author.as_ref().is_some_and(proxy::is_member);
    // Only the owner answers an ask or decides a held prompt (acpmux refuses an author too).
    if attachment.author.is_some()
        && matches!(
            &command,
            AgentSessionCommand::Permission(_)
                | AgentSessionCommand::QueueApprove(_)
                | AgentSessionCommand::QueueDecline(_)
        )
    {
        return refuse(writer, id, if member { Refusal::OwnerOnly } else { Refusal::NotTrusted });
    }
    if attachment.author.is_some()
        && (!(guest || member) || matches!(&command, AgentSessionCommand::Permission(_)))
        && matches!(
            &command,
            AgentSessionCommand::Permission(_)
                | AgentSessionCommand::Typing(_)
                | AgentSessionCommand::View(_)
        )
    {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    // A cancel is a notification on the link and never waits.
    if let AgentSessionCommand::Cancel(_) = command {
        let sent = attachment
            .while_shared(|| {
                attachment
                    .link
                    .notify(
                        "session/cancel",
                        attachment.stamp(json!({"sessionId": attachment.session})),
                    )
                    .map_err(Refusal::of)
            })
            .and_then(|sent| sent);
        return match sent {
            Ok(()) => ok(writer, id, json!({})),
            Err(refusal) => refuse(writer, id, refusal),
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
            // A teammate's answer goes out only while its tab still shows the shared chat.
            let replied = worker.while_shared(|| match result {
                Ok(data) => ok(&worker_writer, worker_id.clone(), data),
                Err(refused) => refused.send(&worker_writer, worker_id.clone()),
            });
            if let Err(refusal) = replied {
                refuse(&worker_writer, worker_id, refusal);
            }
        });
    if spawned.is_err() {
        attachment.calls.fetch_sub(1, Ordering::AcqRel);
        return refuse(writer, id, Refusal::Limit);
    }
    true
}

/// One setting (`session/set_model`, `session/set_mode` or `session/set_config_option`) on the
/// attached session: `params` beside the pinned `sessionId`, sent only when its ids are `valid`.
fn setting(
    attachment: &Attachment,
    valid: bool,
    method: &str,
    mut params: Value,
) -> Result<Value, Refusal> {
    if !valid {
        return Err(Refusal::BadRequest);
    }
    params.insert("sessionId", json!(attachment.session));
    attachment.link.call(method, attachment.stamp(params), CALL_TIMEOUT).map_err(Refusal::of)
}

/// Only content fields, never ACP routing or provenance. Preserve the ordered blocks verbatim.
fn valid_prompt_block(block: &Value) -> bool {
    let Some(object) = block.as_object() else { return false };
    let nonempty =
        |key| block.get(key).and_then(Value::as_str).is_some_and(|s| !s.trim().is_empty());
    let allowed: &[&str] = match block.get("type").and_then(Value::as_str) {
        Some("text") if block.get("text").is_some_and(Value::is_string) => {
            if block.get("_meta").is_some_and(|meta| meta != &json!({"cmux": {"pasted": true}})) {
                return false;
            }
            &["type", "text", "_meta"]
        }
        Some("image" | "audio" | "document") if nonempty("mimeType") && nonempty("data") => {
            &["type", "mimeType", "data", "name"]
        }
        Some("resource_link") if nonempty("uri") => &["type", "uri", "name"],
        _ => return false,
    };
    object.keys().all(|key| allowed.contains(&key.as_str()))
        && block.get("name").is_none_or(Value::is_string)
}

/// A prompt id as the attach verbs take it: 1 to 128 of `[A-Za-z0-9_-]`.
fn valid_prompt_id(prompt_id: &str) -> bool {
    (1..=128).contains(&prompt_id.len())
        && prompt_id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// Sends one prompt and answers once acpmux recorded it. The turn's
/// reply streams as records; the `session/prompt` result (at the end of the
/// turn) is not waited for.
fn prompt(
    attachment: &Attachment,
    prompt_id: String,
    text: Option<String>,
    content: Option<Vec<Value>>,
    steer: bool,
) -> Result<Value, Refused> {
    if !valid_prompt_id(&prompt_id) {
        return Err(Refusal::BadRequest.into());
    }
    let blocks = match (text, content) {
        (Some(text), None) if !text.trim().is_empty() && text.len() <= MAX_PROMPT_BYTES => {
            vec![json!({"type": "text", "text": text})]
        }
        (None, Some(blocks)) if !blocks.is_empty() && blocks.iter().all(valid_prompt_block) => {
            blocks
        }
        _ => return Err(Refusal::BadRequest.into()),
    };
    if blocks.iter().all(|block| {
        block["type"] == "text" && block["text"].as_str().is_some_and(|text| text.trim().is_empty())
    }) {
        return Err(Refusal::BadRequest.into());
    }
    // Guests previously supplied text only. Do not grant access to files on the owner's host.
    if attachment.author.is_some() && blocks.iter().any(|block| block["type"] != "text") {
        return Err(Refusal::NotTrusted.into());
    }
    submit_steering_prompt(attachment, &attachment.session, blocks, prompt_id, steer)
}

/// Sends `blocks` to `session` (the attached chat, or a side chat it opened) as prompt
/// `prompt_id` and answers once acpmux accepted it (`_acpmux/prompt_accepted`), or refuses: a
/// prompt acpmux never took is never reported sent.
fn submit_prompt(
    attachment: &Attachment,
    session: &str,
    blocks: Vec<Value>,
    prompt_id: String,
) -> Result<Value, Refused> {
    submit_steering_prompt(attachment, session, blocks, prompt_id, false)
}

/// [`submit_prompt`], with `steer`: into the running turn instead of behind it
/// (`agent-session-steer-v1`).
fn submit_steering_prompt(
    attachment: &Attachment,
    session: &str,
    blocks: Vec<Value>,
    prompt_id: String,
    steer: bool,
) -> Result<Value, Refused> {
    // One slot for the acceptance, one for the request's own reply: a prompt acpmux refuses
    // (its remote guard, a mode that does not ask, a chat it does not run) is answered with an
    // error and never accepted. Dropping that reply told the phone `agent_session.timeout`
    // `PROMPT_ACCEPT_TIMEOUT` later for every refused prompt (HQ's cloud-start-matrix
    // phone-start row, run 43626610988).
    let (sender, receiver) = std::sync::mpsc::sync_channel(2);
    {
        let mut prompts = attachment.prompts.lock().unwrap_or_else(|e| e.into_inner());
        if prompts.len() >= MAX_CALLS || prompts.contains_key(&prompt_id) {
            return Err(Refusal::Limit.into());
        }
        prompts.insert(prompt_id.clone(), sender.clone());
    }
    let mut params = json!({
        "sessionId": session,
        "prompt": blocks,
        "_meta": {"acpmux": {"promptId": prompt_id}},
    });
    // The native daemon connection is Local, but the authenticated Cloud
    // mobile carrier must retain the Web asking policy for this prompt. This
    // marker is inserted by the typed agent-session path, never accepted from
    // the phone or forwarded as arbitrary ACP metadata.
    if attachment.cloud_mobile {
        params["_meta"]["acpmux"]["via"] = json!("cloud-mobile");
    }
    // The owner's and a team member's steer. A link guest never steers: its prompt waits for
    // the owner (acpmux holds it whatever the flag says; the flag is not even sent).
    let guest = attachment.author.as_ref().is_some_and(proxy::is_guest);
    if steer
        && !guest
        && let Some(meta) = params.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut)
    {
        meta.insert("steer".to_owned(), json!(true));
    }
    // The request's own reply comes at the end of the turn: it is listened to only until the
    // acceptance and forgotten then, so a queued prompt holds no call slot past it (permission
    // answers stay possible while turns queue). At most [`MAX_CALLS`] listen at once.
    let sent = attachment
        .while_shared(|| {
            attachment
                .link
                .send_replying_to("session/prompt", attachment.stamp(params), sender)
                .map_err(Refusal::of)
        })
        .and_then(|sent| sent);
    let request = match sent {
        Ok(request) => request,
        Err(refusal) => {
            attachment.prompts.lock().unwrap_or_else(|e| e.into_inner()).remove(&prompt_id);
            return Err(refusal.into());
        }
    };
    let heard = receiver.recv_timeout(PROMPT_ACCEPT_TIMEOUT);
    attachment.link.forget(request);
    attachment.prompts.lock().unwrap_or_else(|e| e.into_inner()).remove(&prompt_id);
    match heard {
        // The acceptance, or the turn's own result when it ended before one was seen.
        Ok(Ok(accepted)) => Ok(json!({
            "prompt_id": prompt_id,
            "turn_id": accepted.get("turnId").cloned().unwrap_or(Value::Null),
            "queued": accepted.get("queued").cloned().unwrap_or(json!(false)),
            // `steered`, `queued` or `started` (acpmux's own word; null from an older acpmux).
            "state": accepted.get("state").cloned().unwrap_or(Value::Null),
            // Held for the owner's approval (a link guest's prompt).
            "awaiting_owner": accepted.get("awaitingOwner").cloned().unwrap_or(json!(false)),
        })),
        Ok(Err(error)) => Err(Refused::of_prompt(error)),
        Err(_) => Err(Refusal::Timeout.into()),
    }
}

/// A prompt's refusal, with acpmux's reason code when it gave one (`data.reason`, such as
/// `remote.local_claude_session`), so the client can say why acpmux did not take the prompt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Refused {
    pub(super) refusal: Refusal,
    pub(super) reason: Option<String>,
}

impl From<Refusal> for Refused {
    fn from(refusal: Refusal) -> Self {
        Self { refusal, reason: None }
    }
}

impl Refused {
    /// The `session/prompt` reply's error. Only a short code of acpmux's is passed on, never
    /// its message text.
    fn of_prompt(error: LinkError) -> Self {
        let reason = match &error {
            LinkError::Rpc(_, data) => data.get("reason").and_then(Value::as_str).filter(|code| {
                (1..=64).contains(&code.len())
                    && code.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
            }),
            _ => None,
        };
        Self { reason: reason.map(str::to_owned), refusal: Refusal::of(error) }
    }

    /// The refusal as the reply to request `id`: its code, its text with acpmux's reason, and
    /// that reason as `data.reason`.
    fn send(self, writer: &MessageWriter, id: Option<Value>) -> bool {
        let Some(reason) = self.reason else { return refuse(writer, id, self.refusal) };
        send_response(
            writer,
            Response {
                id,
                ok: false,
                data: Some(json!({"reason": reason})),
                error: Some(format!("{} ({reason})", self.refusal.message())),
                error_code: Some(self.refusal.code().to_string()),
                error_delivery: None,
            },
        )
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

/// A refusal with its typed reason in `data` (`needs_keyed_start`). The generic `refused` also
/// names acpmux's reason code in its text, as a prompt's refusal does ([`Refused::send`]).
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
            error: Some(refusal_text(refusal, &data)),
            data: Some(data),
            error_code: Some(refusal.code().to_string()),
            error_delivery: None,
        },
    )
}

/// The text of `refusal` with `data`: the generic `refused` names `data.reason` (acpmux's code)
/// and a bad request `data.field` (the param, [`bad_field`]), so a reader of the error alone sees
/// why; every other refusal's text is its own.
fn refusal_text(refusal: Refusal, data: &Value) -> String {
    let text = |key: &str| data.get(key).and_then(Value::as_str);
    match (refusal, text("reason"), text("field")) {
        (Refusal::Refused, Some(reason), _) => format!("{} ({reason})", refusal.message()),
        (Refusal::BadRequest, _, Some(field)) => format!("{} (field: {field})", refusal.message()),
        _ => refusal.message().to_string(),
    }
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

    /// True when `agent-session-start` starts any agent here on the
    /// caller's owner word: this machine reads as a Cloud VM with no team
    /// evidence. A Mac, an SSH host and a team VM never advertise
    /// `agent-session-start-owner-cloud-v1`, so the app never lets a Codex
    /// or opencode chat send to a session there.
    pub(crate) fn serves_owner_cloud_start(&self) -> bool {
        self.serves_agent_session_start()
            && self.control_clients.agent_sessions.starts.owner_cloud(true)
    }
}

#[cfg(test)]
#[path = "agent_session_attach_unsent_tests.rs"]
mod unsent_tests;

#[cfg(test)]
#[path = "agent_session_attach_unknown_params_tests.rs"]
mod unknown_params_tests;
