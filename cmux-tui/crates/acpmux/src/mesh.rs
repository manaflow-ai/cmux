//! The mesh relay: a send reaches a session on any host by name, through a team hub
//! (cmux-platform), with no ssh peer list and no tailnet. This module is the hub's shape as the
//! daemon sees it: [`MeshHub`], which the HTTPS client implements and tests fake, and the
//! records it carries (cmux-platform `openapi.json` 1.3.0, `/v1/mesh`). `server/mesh_relay.rs`
//! runs the daemon's side: it heartbeats its sessions, long-polls its inbox, delivers each message
//! into the session it names as a local send does, acks with the prompt id, and posts the sends
//! this daemon's sessions make to a name no one here resolves. `mesh_http.rs` is the HTTPS client.
//!
//! Delivery is at least once: a message stays leased until acked and comes back when its lease
//! ends. The prompt id of a delivery is the message id, so a message delivered twice runs once
//! (`hub/prompt_ledger.rs`).

use futures::future::BoxFuture;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::Arc;
use std::time::Duration;

/// One session as the address book lists it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionRow {
    pub name: String,
    pub session_id: String,
    pub harness: String,
    /// `idle`, `ready`, `running`, `waiting` or `disconnected` (`store::SessionStatus`).
    pub state: String,
    /// Why a session whose harness keeps failing is stuck, once the daemon reports it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stuck_reason: Option<String>,
    /// Optional team-scoped address claimed by this session (for example
    /// `coordinator`). The hub prefixes it with the member/team namespace.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub team_address: Option<String>,
    /// The session's working directory, which the hub keeps and its address book returns, so
    /// another machine lists the chat under its folder. Left out past [`MAX_CWD_UNITS`]: the hub
    /// refuses a whole heartbeat over one long field.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// The rest of what a local row lists, which the hub keeps and its address book returns
    /// (`mesh_book::row_of`), so another machine lists the chat as this one does. Each text is
    /// left out past [`MAX_META_UNITS`] (`heartbeat_meta`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title_source: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name_given: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_build: Option<String>,
    /// The session's given handle, its call name (`acpmux rename ... --handle`): only one a person
    /// or agent gave, never the one derived from its id (`session_handle::default_handle`), which
    /// every reader derives itself. Without it another machine's `ls`, `resolve` and `send` know
    /// the chat only by its older name (Leo, 2026-11-23: "the renaming paradigm still hasn't hit
    /// yet"). A hub that does not know the key drops it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle: Option<String>,
    /// Names that still reach it (plans/cmux-next/message-delivery-successors.md, "Wire"): a bare
    /// NAME is one of its own former names, `HOST/NAME` a session it took over (`acpmux
    /// succeed`). At most [`MAX_FORMER_NAMES`], each 1..=[`MAX_FORMER_NAME`] chars.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub former_names: Vec<String>,
    /// The role addresses it claimed (`acpmux role claim`), at most [`MAX_ROLES`].
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub roles: Vec<RoleClaim>,
    /// When the session last changed here (ms since the epoch, its meta's `updated_at`): what
    /// another machine's row shows as `updatedAt`. Without it a reading daemon stamps each hub row
    /// with its own clock whenever it first sees it, so every restart of a reader moved all of a
    /// fleet's rows to one millisecond (`mesh_book::set_mesh_book`). A hub that does not know the
    /// key drops it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<u64>,
}

/// The most `formerNames` one heartbeat row lists.
pub const MAX_FORMER_NAMES: usize = 16;
/// The longest name `formerNames` lists, in chars.
pub const MAX_FORMER_NAME: usize = 160;
/// The most role addresses one heartbeat row lists.
pub const MAX_ROLES: usize = 16;

/// A role address a session claimed: `goal:SLUG`, `area:NAME` or `topic:NAME`. The hub sends a
/// message for the address to the session with the latest claim.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RoleClaim {
    pub address: String,
    /// Ms since the epoch.
    pub claimed_at: u64,
}

/// Whether `address` is a role address: `^(goal|area|topic):[A-Za-z0-9._-]{1,128}$`.
pub fn valid_role(address: &str) -> bool {
    let Some((kind, rest)) = address.split_once(':') else {
        return false;
    };
    matches!(kind, "goal" | "area" | "topic")
        && (1..=128).contains(&rest.len())
        && rest.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// The `formerNames` a heartbeat lists for a session: its former names, then the sessions it
/// took over, no repeat, each 1..=[`MAX_FORMER_NAME`] chars, the newest [`MAX_FORMER_NAMES`].
pub fn heartbeat_former_names(former: &[String], succeeds: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for name in former.iter().chain(succeeds) {
        let n = name.chars().count();
        if (1..=MAX_FORMER_NAME).contains(&n) && !out.contains(name) {
            out.push(name.clone());
        }
    }
    let over = out.len().saturating_sub(MAX_FORMER_NAMES);
    out.drain(..over);
    out
}

/// The `roles` a heartbeat lists: valid addresses only, the newest [`MAX_ROLES`].
pub fn heartbeat_roles(roles: &[RoleClaim]) -> Vec<RoleClaim> {
    let mut out: Vec<RoleClaim> =
        roles.iter().filter(|r| valid_role(&r.address)).cloned().collect();
    out.sort_by_key(|r| r.claimed_at);
    let over = out.len().saturating_sub(MAX_ROLES);
    out.drain(..over);
    out
}

/// The given handle of session `id` as a heartbeat lists it: none for an invalid one, or one that
/// is its derived handle, which costs the heartbeat bytes and says nothing a reader cannot derive.
pub fn heartbeat_handle(handle: Option<&str>, id: &str) -> Option<String> {
    handle
        .filter(|h| {
            crate::session_handle::valid(h) && *h != crate::session_handle::default_handle(id)
        })
        .map(str::to_owned)
}

/// The longest `cwd` (UTF-16 units, as the hub counts) a heartbeat lists (`MeshSessionAnnouncement`).
pub const MAX_CWD_UNITS: usize = 1024;

/// `cwd` as a heartbeat may list it: none when the hub would refuse its length.
pub fn heartbeat_cwd(cwd: &str) -> Option<String> {
    (!cwd.is_empty() && cwd.encode_utf16().count() <= MAX_CWD_UNITS).then(|| cwd.to_owned())
}

/// The longest title, model, agent session id or build (UTF-16 units) a heartbeat lists; the
/// hub stores a longer one as null.
pub const MAX_META_UNITS: usize = 1024;

/// A text field as a heartbeat lists it: none when empty or past [`MAX_META_UNITS`].
pub fn heartbeat_meta(text: &str) -> Option<String> {
    (!text.is_empty() && text.encode_utf16().count() <= MAX_META_UNITS).then(|| text.to_owned())
}

/// The hub's address book (`GET /v1/mesh/sessions`): the team's live daemons and sessions.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct AddressBook {
    #[serde(default)]
    pub daemons: Vec<BookDaemon>,
    #[serde(default)]
    pub sessions: Vec<BookSession>,
}

/// One live daemon in the address book: whose it is, on which host.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookDaemon {
    pub daemon_id: String,
    pub host: String,
    #[serde(default)]
    pub user: String,
    #[serde(default)]
    pub last_seen_at: u64,
    /// The host health its last heartbeat carried, and when the hub took it (ms); none from an
    /// old hub or a daemon that sent none.
    #[serde(default)]
    pub health: Option<Value>,
    #[serde(default)]
    pub health_at: Option<u64>,
}

/// One live session in the address book, as its daemon's heartbeat listed it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookSession {
    pub name: String,
    pub session_id: String,
    pub host: String,
    pub daemon_id: String,
    #[serde(default)]
    pub harness: String,
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub last_seen_at: u64,
    /// The rest of a row a local one carries: read whenever the hub returns them, each `None`
    /// when it does not. Every hub row lists every one of these keys, null when unknown, so a
    /// reader never tells a hub row from a local one by a missing key (`mesh_book::row_of`).
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub title_source: Option<String>,
    #[serde(default)]
    pub name_given: Option<bool>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub agent_session_id: Option<String>,
    #[serde(default)]
    pub host_build: Option<String>,
    /// The session's given handle, as its heartbeat listed it (`SessionRow::handle`).
    #[serde(default)]
    pub handle: Option<String>,
    /// Its heartbeat's `formerNames` (`SessionRow::former_names`), when the hub returns them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub former_names: Vec<String>,
    /// Its heartbeat's `roles` (`SessionRow::roles`), when the hub returns them.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub roles: Vec<RoleClaim>,
    /// Its heartbeat's `updatedAt` (`SessionRow::updated_at`), when the hub returns it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<u64>,
}

/// A heartbeat: it replaces this daemon's sessions in the address book.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Heartbeat {
    pub host: String,
    pub sessions: Vec<SessionRow>,
    /// The last heartbeat as the relay stops: the hub ends this daemon's waiting inbox polls, so
    /// a message sent before the restarted daemon polls again is not leased to the dead one.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub leaving: bool,
    /// This daemon's host health now, trimmed (`peer_health::wire`, under 2 KiB), so a placer
    /// reads it from the address book with no ask of its own (RFD 0181 T1). Old daemons send
    /// none; an old hub ignores it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub health: Option<Value>,
}

/// The most sessions one heartbeat lists.
pub const MAX_HEARTBEAT_SESSIONS: usize = 256;

/// The hub took a heartbeat: this daemon's rows expire `ttlSeconds` after it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HeartbeatReply {
    #[serde(default)]
    pub daemon_id: String,
    pub ttl_seconds: u64,
}

/// A joined machine's free capacity (cmux-platform `POST /v1/machines/joined/heartbeat`, RFD 0004
/// step 3): what its team's placement reads to pick it for a session. The hub keys it by the
/// machine id of the credential that sent it, whatever `host_id` says, and drops it two minutes
/// after the last one.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Capacity {
    pub host_id: String,
    pub region: String,
    pub capabilities: CapacityLimits,
    pub free_vcpu: f64,
    pub free_mem_gib: f64,
    pub free_disk_gib: f64,
    pub sessions_running: u64,
    pub load: f64,
    pub state: String,
}

/// What a [`Capacity`] machine is and the most one session there can have.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CapacityLimits {
    pub memory_pause: bool,
    pub fork: bool,
    pub gpu: bool,
    /// `arm64` or `x86_64`.
    pub arch: String,
    /// `linux` or `macos`.
    pub os: String,
    pub max_vcpu: f64,
    #[serde(rename = "maxMemGiB")]
    pub max_mem_gib: f64,
}

/// Whom a message is for: a session id, or a name (with `host` when several hosts have it); a
/// daemon (`daemonId`, or `host` alone) for a control message. The hub fills what it resolved.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    /// A team-scoped address (`@member/agent` or `@team/role`). The hub
    /// resolves this field; it is never interpreted as a host name locally.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "teamAddress", alias = "address")]
    pub team_address: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub daemon_id: Option<String>,
}

/// Who sent a message: the session as its daemon named it; the hub adds the daemon id and the
/// user from the sender's token.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sender {
    /// The sender's team-scoped address, when it has claimed one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "teamAddress", alias = "address")]
    pub team_address: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub daemon_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    /// The harness or app the send came from, as the sender says (`sender_harness.rs`), kept by
    /// the receiver as self-reported only: what the sending daemon checked is not carried, since
    /// the receiver cannot look at another machine's processes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claim: Option<serde_json::Value>,
    /// For a send no session made: the relay record (`{by, machine, session}`,
    /// `prompt_provenance::FROM_RELAY`) the sending daemon took from a relay on its own unix
    /// socket, its word on where the message came from, as a peer link's `fromRelay` is. A hub
    /// that does not carry it drops it, and the receiver names the machine the hub proved.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay: Option<serde_json::Value>,
}

/// When a message reaches a busy session: after its turn (`turn-end`), or into the running
/// turn (`now`, a steer), as `acpmux send` and `--steer` do.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Mode {
    #[default]
    TurnEnd,
    Now,
}

/// A message's kind: text for a session, or a request to its daemon (start, resume or stop a
/// session, `server::mesh_relay::ControlHook`). A kind this build does not know is refused.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    #[default]
    Prompt,
    Control,
    #[serde(other)]
    Unknown,
}

/// The hub's single start-work decision. The hub overwrites this field; clients
/// accept only these announced strings and never infer permission from a sender hint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StartWork {
    Allowed,
    Information,
}

/// A message this daemon's inbox holds for one of its sessions.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InMessage {
    pub message_id: String,
    /// Required: a message without one is malformed, never taken for a prompt.
    pub kind: Kind,
    /// A control message's request: `start`, `resume` or `stop`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub op: Option<String>,
    #[serde(default)]
    pub mode: Mode,
    #[serde(default)]
    pub to: Target,
    #[serde(default)]
    pub from: Sender,
    #[serde(default, deserialize_with = "nullable_body")]
    pub body: String,
    /// How many times it was leased (1 for the first).
    #[serde(default)]
    pub attempt: u32,
    /// The hub's policy decision: `allowed` may start work; `information` is
    /// delivered at a turn boundary without starting a turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_work: Option<StartWork>,
    /// Durable hub state (`queued`, `delivered`, `read`, or `acked`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
}

fn nullable_body<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<String, D::Error> {
    Ok(Option::<String>::deserialize(deserializer)?.unwrap_or_default())
}

/// A page of durable recipient messages. Browsing never changes delivery state.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TeamPage {
    pub messages: Vec<InMessage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next: Option<u64>,
}

/// A listen: the right to read what another member's agent address receives, until `expires_at`
/// (ms). The hub opens one only for an address whose owner granted the listener's user.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Listen {
    pub id: String,
    pub team_address: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub listener: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opened_by: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opened_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<u64>,
}

/// The open listens the hub names for this caller: its own, and others' on its addresses.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Listens {
    #[serde(default)]
    pub listening: Vec<Listen>,
    #[serde(default)]
    pub listeners: Vec<Listen>,
}

/// Whether `id` has the hub's listen id shape, `lsn_` and 32 lowercase hex digits, so it is safe
/// in a path.
pub fn is_listen_id(id: &str) -> bool {
    id.strip_prefix("lsn_").is_some_and(|hex| {
        hex.len() == 32 && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

/// A message to post.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutMessage {
    pub to: Target,
    pub from: Sender,
    pub kind: Kind,
    /// A control operation. The hub rejects an operation on prompts and a control without one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub op: Option<String>,
    pub body: String,
    pub mode: Mode,
    /// The sender's prompt id: the same send posted again is the same message.
    pub idempotency_key: String,
}

impl OutMessage {
    /// Validate the platform wire invariant before an HTTP request is posted.
    pub fn validate(&self) -> Result<(), String> {
        match (self.kind, self.op.as_deref()) {
            (Kind::Control, Some("start" | "resume" | "stop" | "read")) => Ok(()),
            // A chat moved through the hub (`hub/transfer_pull.rs`).
            (Kind::Control, Some(crate::mesh_relay_config::MOVE_OP))
            | (Kind::Control, Some(crate::mesh_relay_config::MOVE_OUT_OP))
            | (Kind::Control, Some(crate::mesh_relay_config::MOVE_FORGET_OP)) => Ok(()),
            (Kind::Control, _) => {
                Err("control messages require op start, resume, stop, read, move, move_out or move_forget"
                    .into())
            }
            (Kind::Prompt, None) => Ok(()),
            (Kind::Prompt, Some(_)) => Err("prompt messages cannot carry an operation".into()),
            (Kind::Unknown, _) => Err("messages must use a known kind".into()),
        }
    }
}

/// A message's receipt: `queued`, `leased`, `delivered`, `refused` or `expired`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Receipt {
    pub message_id: String,
    pub state: String,
    #[serde(default)]
    pub to: Target,
    #[serde(default)]
    pub attempt: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// When the hub took it, leased it last and had its ack (ms since the epoch).
    #[serde(default)]
    pub created_at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub leased_until: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acked_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub delivered_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_by: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acked_by: Option<String>,
    /// The hub's resolved destination for a team address.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<Value>,
    /// Whether the hub permits this message to start work on an idle agent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub start_work: Option<StartWork>,
    /// A read control's answer (`server/mesh_read.rs`), which the hub shows only to its sender.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<String>,
}

/// How a delivery settled.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AckState {
    Delivered,
    Refused,
}

/// The ack of one message.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ack {
    pub state: AckState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prompt_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// A read control's answer, or one part of it: JSON text, at most [`MAX_READ_RESULT_BYTES`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<String>,
}

/// The largest read answer one hub message carries (its 64 KiB body bound). A larger answer
/// goes in parts, each one message (`server/mesh_read.rs`), so no page is refused for its size.
pub const MAX_READ_RESULT_BYTES: usize = 64 * 1024;

impl Ack {
    pub fn delivered(prompt_id: &str, detail: Option<String>) -> Self {
        Self {
            state: AckState::Delivered,
            prompt_id: Some(prompt_id.to_owned()),
            detail,
            result: None,
        }
    }

    pub fn refused(detail: impl Into<String>) -> Self {
        Self {
            state: AckState::Refused,
            prompt_id: None,
            detail: Some(detail.into()),
            result: None,
        }
    }

    /// A read control's answer.
    pub fn answered(prompt_id: &str, result: String) -> Self {
        Self { result: Some(result), ..Self::delivered(prompt_id, None) }
    }
}

/// A failed hub call. `refused`: the hub answered and said no (a 4xx other than a timeout or a
/// rate limit), so the same call fails the same way; else the hub may answer later.
#[derive(Debug, Clone, PartialEq)]
pub struct HubError {
    pub message: String,
    pub refused: bool,
    /// The hub's code (`mesh.unknown_recipient`, `mesh.ambiguous`, ...).
    pub code: Option<String>,
    /// The sessions an ambiguous name names (`mesh.ambiguous`).
    pub candidates: Option<serde_json::Value>,
    /// How long a rate-limited caller waits (429 `retryAfterSeconds`).
    pub retry_after: Option<Duration>,
    /// The HTTP status the hub answered, when it answered one.
    pub status: Option<u16>,
    /// Where the failure came from: this daemon before it asked, the hub's answer, or no answer.
    /// It words a failure (`server/team.rs` `inbox_failure`); `refused` alone says whether to
    /// try again.
    pub source: HubErrorSource,
}

/// Where a [`HubError`] came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HubErrorSource {
    /// This daemon, before it asked the hub: no token command, a token command that failed, a
    /// request it would not send.
    Daemon,
    /// The hub's answer: a status, a revoked credential, two tokens refused, an answer too large
    /// or not the shape of the contract.
    Hub,
    /// No answer: no connection, a dropped one, or none in time.
    NoAnswer,
}

impl HubError {
    /// Whether the hub refused this daemon's credential: a 401 or 403 (a Cloud VM token, a token
    /// without a team, a revoked machine) or a refusal from no answer at all (no token command).
    /// The relay's loops pause on one and try again every `refused_retry`, since a refusal can
    /// pass; any other refusal (a request the hub took issue with) is tried again with backoff.
    pub fn ends_relay(&self) -> bool {
        self.refused && self.status.is_none_or(|s| s == 401 || s == 403)
    }

    /// A failure that may pass, with no answer from the hub (no connection, none in time).
    pub fn unavailable(message: impl Into<String>) -> Self {
        Self { refused: false, source: HubErrorSource::NoAnswer, ..Self::refused(message) }
    }

    /// A failure that may pass, made by this daemon before it asked (a token command that failed).
    pub fn local(message: impl Into<String>) -> Self {
        Self { source: HubErrorSource::Daemon, ..Self::unavailable(message) }
    }

    /// A refusal this daemon made before it asked; [`HubError::from_hub`] marks the hub's.
    pub fn refused(message: impl Into<String>) -> Self {
        let message = message.into();
        Self {
            message,
            refused: true,
            code: None,
            candidates: None,
            retry_after: None,
            status: None,
            source: HubErrorSource::Daemon,
        }
    }

    /// This failure, as the hub's answer.
    pub fn from_hub(self) -> Self {
        Self { source: HubErrorSource::Hub, ..self }
    }
}

impl std::fmt::Display for HubError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for HubError {}

/// The hub, as one daemon (its `daemonId` and credential are the implementation's) calls it.
pub trait MeshHub: Send + Sync {
    /// Up to `max` messages for this daemon, leased to it, waiting up to `wait` for one.
    fn inbox(&self, wait: Duration, max: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>>;
    /// Browse recipient team messages without acquiring a delivery lease.
    fn team_messages<'a>(
        &'a self,
        _unread_only: bool,
        _team_address: Option<&'a str>,
        _before: Option<u64>,
    ) -> BoxFuture<'a, Result<TeamPage, HubError>> {
        Box::pin(async { Err(HubError::unavailable("team inbox is unavailable")) })
    }
    /// Mark a team message read, preserving the hub's idempotent receipt.
    fn read<'a>(&'a self, _message_id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async { Err(HubError::unavailable("team message read is unavailable")) })
    }
    /// Explicit recipient acknowledgement, separate from the relay's delivery ack.
    fn acknowledge<'a>(&'a self, _message_id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async { Err(HubError::unavailable("team acknowledgement is unavailable")) })
    }
    /// Open a listen on another member's agent address, for `ttl_seconds` or the hub's default.
    fn listen_open<'a>(
        &'a self,
        _team_address: &'a str,
        _ttl_seconds: Option<u64>,
    ) -> BoxFuture<'a, Result<Listen, HubError>> {
        Box::pin(async { Err(HubError::unavailable("team listens are unavailable")) })
    }
    /// The open listens: this caller's, and others' on its addresses.
    fn listens(&self) -> BoxFuture<'_, Result<Listens, HubError>> {
        Box::pin(async { Err(HubError::unavailable("team listens are unavailable")) })
    }
    /// Close one of this caller's listens; the open listens after it.
    fn listen_close<'a>(&'a self, _id: &'a str) -> BoxFuture<'a, Result<Listens, HubError>> {
        Box::pin(async { Err(HubError::unavailable("team listens are unavailable")) })
    }
    fn ack<'a>(&'a self, message_id: &'a str, ack: &'a Ack) -> BoxFuture<'a, Result<(), HubError>>;
    /// Replace this daemon's sessions in the address book.
    fn heartbeat<'a>(
        &'a self,
        beat: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>>;
    fn send<'a>(&'a self, message: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>>;
    fn receipt<'a>(&'a self, message_id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>>;
    /// The team's address book. A hub without one lists nothing.
    fn sessions(&self) -> BoxFuture<'_, Result<AddressBook, HubError>> {
        Box::pin(async { Err(HubError::unavailable("the address book is unavailable")) })
    }
    /// The receipt of a message this daemon sent, waiting up to `wait` (at most 25 s) for the
    /// receiver's answer; a read's `result` is in it. A hub without the wait answers at once.
    fn answer<'a>(
        &'a self,
        message_id: &'a str,
        _wait: Duration,
    ) -> BoxFuture<'a, Result<Receipt, HubError>> {
        self.receipt(message_id)
    }
    /// Report this joined machine's free capacity to its team's placement. A hub that takes no
    /// report refuses it.
    fn capacity<'a>(&'a self, _report: &'a Capacity) -> BoxFuture<'a, Result<(), HubError>> {
        Box::pin(async { Err(HubError::refused("this hub takes no capacity report")) })
    }
}

/// The team hub client sends go through (`Hub::mesh`): set when a mesh relay starts, cleared
/// when a sign-out's leave stops it, and replaced when a later enroll starts one again, perhaps
/// against another hub. Each read takes the client then in use; the lock is never held across
/// a call.
#[derive(Default)]
pub struct MeshSlot(std::sync::RwLock<Option<Arc<dyn MeshHub>>>, crate::mesh_gate::Gate);

impl MeshSlot {
    /// The client in use, if a relay runs.
    pub fn get(&self) -> Option<Arc<dyn MeshHub>> {
        use crate::no_panic::RwLockExt;
        self.0.read_or_recover().clone()
    }

    /// Make `client` the one in use; the one it replaced, if any.
    pub fn set(&self, client: Arc<dyn MeshHub>) -> Option<Arc<dyn MeshHub>> {
        use crate::no_panic::RwLockExt;
        // Another hub, perhaps: what the last one answered says nothing of it.
        self.1.answered();
        self.0.write_or_recover().replace(client)
    }

    /// How often sends try the hub while it fails (`mesh_gate.rs`).
    pub fn gate(&self) -> &crate::mesh_gate::Gate {
        &self.1
    }

    /// No client: the relay stopped. The one it removed, if any.
    pub fn clear(&self) -> Option<Arc<dyn MeshHub>> {
        use crate::no_panic::RwLockExt;
        self.0.write_or_recover().take()
    }
}

#[cfg(test)]
mod wire_tests {
    use super::*;

    fn message(kind: Kind, op: Option<&str>) -> OutMessage {
        OutMessage {
            to: Target::default(),
            from: Sender::default(),
            kind,
            op: op.map(str::to_owned),
            body: String::new(),
            mode: Mode::Now,
            idempotency_key: "mesh-test-1".into(),
        }
    }

    #[test]
    fn control_wire_requires_a_known_operation_and_prompts_have_none() {
        assert!(message(Kind::Control, Some("start")).validate().is_ok());
        assert!(message(Kind::Control, None).validate().is_err());
        assert!(message(Kind::Control, Some("pause")).validate().is_err());
        assert!(message(Kind::Prompt, None).validate().is_ok());
        assert!(message(Kind::Prompt, Some("start")).validate().is_err());
    }
}

/// The waits after consecutive failures: doubling from `first` to `cap`, each with up to a
/// fifth taken off at random, so daemons that lost the hub together do not return together.
#[derive(Debug, Clone)]
pub struct Backoff {
    first: Duration,
    cap: Duration,
    next: Duration,
}

impl Backoff {
    pub fn new(first: Duration, cap: Duration) -> Self {
        Self { first, cap, next: first.min(cap) }
    }

    pub fn reset(&mut self) {
        self.next = self.first.min(self.cap);
    }

    pub fn next_wait(&mut self) -> Duration {
        let wait = self.next.min(self.cap);
        self.next = wait.checked_mul(2).unwrap_or(self.cap).min(self.cap);
        let fifth = wait.as_millis() as u64 / 5;
        let jitter = if fifth == 0 { 0 } else { uuid::Uuid::now_v7().as_u128() as u64 % fifth };
        wait.saturating_sub(Duration::from_millis(jitter))
    }
}

/// Whether a hub-given message id is safe to use: 1 to 128 of `A-Z a-z 0-9 . _ : -` (the
/// hub's own ids are `msg_...`). The id goes into the ack's URL path and into log lines, so a
/// message whose id is anything else is skipped, never delivered, acked or logged.
pub fn is_message_id(id: &str) -> bool {
    (1..=128).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"._:-".contains(&b))
}

/// The heartbeat claims only an agent suffix; the platform supplies its member namespace.
pub(crate) fn valid_team_suffix(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"._:-".contains(&b))
}

#[cfg(test)]
#[path = "mesh_tests.rs"]
mod tests;
