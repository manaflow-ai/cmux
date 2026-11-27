//! Reading a session on a machine only the mesh hub reaches: no ssh peer, no tailnet. Leo,
//! 2026-11-05: "I don't want to deal with SSH keys. I just want the app to handle the thing for
//! me."
//!
//! A read is a control message with op `read` (cmux-platform `MeshOp`). Its body names one
//! read-only method and its params: `{"version": 1, "method": "_acpmux/events" | "_acpmux/info"
//! | "_acpmux/attach" | "_acpmux/history", "params": {...}}`. An attach there is a hidden one,
//! answered with the chat's detail and newest page; the connection it ran on ends with the read, so it streams
//! nothing (the chat opens as it is then). The receiving daemon runs it on its own session, as a peer daemon's request
//! (`Origin::Peer`), and puts the answer in the ack's `result`. The sender waits on the message's
//! receipt (`MeshHub::answer`), and the hub shows the result to the sender alone. That is
//! Tailscale's DERP shape: the relay forwards over connections both ends already hold, and only
//! the two machines read what it carries.
//!
//! Authority is the person's, twice over. The hub takes a read only between daemons of the same
//! user. The receiver checks the hub-stamped sender against its own `meshRelay.controlFrom`
//! (`sameUser`, the entry `host join` writes) before anything runs (`MeshControlHook::control`).
//!
//! An answer larger than one hub message (64 KiB) goes in parts (`mesh_read_parts.rs`): the
//! receiver holds it and answers `{"_acpmuxParts": {"id", "count"}}`, and the sender reads each
//! part with `_acpmux/readPart` and puts the answer together. A page always holds at least one
//! record, so without this a chat with one record over 64 KiB would not open. A sender asks for
//! parts in its body (`"parts": true`); an older sender gets `mesh.read_too_large` as before.
//!
//! The sending side is [`forward`]. An `_acpmux/info`, `_acpmux/events`, `_acpmux/attach` or
//! `_acpmux/history` for `HOST/KEY` that
//! nothing here and no ssh peer resolves (`Hub::mesh_may_route`, the send fallback's own test)
//! goes to the hub when this daemon has one. It is taken only from this machine's own socket or
//! the app's pane, never from a peer daemon's link. Its answer carries `peer: HOST` and
//! `via: "hub"`, so `acpmux last HOST/NAME`, the app's chat for a session there and the next page
//! route back the same way.

use super::*;
use crate::mesh::{
    Ack, HubError, InMessage, Kind, MAX_READ_RESULT_BYTES, Mode, OutMessage, Receipt, Sender,
    Target,
};
use base64::Engine;
use cmux_deadline::IdleDeadline;
use std::time::Duration;

#[path = "mesh_read_parts.rs"]
pub(crate) mod parts;

/// The methods a read may run: each answers a page of a session and changes nothing.
const READ_METHODS: &[&str] = &[
    method::MUX_INFO,
    method::MUX_EVENTS,
    method::MUX_ATTACH,
    method::MUX_HISTORY,
    method::MUX_SESSION_SEARCH,
];

/// The other reads of one session a client may ask of `HOST/KEY` (`pairing/read_only.rs`): no
/// read carries them, so a session only the hub reaches answers that, never `no session` from
/// this daemon's own handlers (2026-11-19: `acpmux history` of one answered no_session while
/// `acpmux last` of it worked).
const NOT_CARRIED: &[&str] = &[method::MUX_ATTACHMENT, method::MUX_QUEUE_TEXT, method::MUX_WAIT];

/// The changes a read message carries too: each changes one session so that running it twice (the
/// hub may lease a message again) leaves it as once. The receiver runs one only for a sender its
/// `controlFrom` trusts with a lifecycle op, never one granted `read` alone. Leo, 2026-11-23:
/// "the renaming paradigm still hasn't hit yet" (`acpmux rename HOST/ID NAME [--handle]` from a
/// lane VM answered no_session for every session only the hub reaches, while `acpmux info` of
/// the same `HOST/ID` worked). A retry of a failed turn too (`_acpmux/retry`): a second delivery
/// finds the first's turn under way (`retry.busy`) or the turn no longer failed
/// (`retry.nothing_failed`), so it sends nothing twice. 2026-11-24: `acpmux retry HOST/NAME` of
/// a lane only the hub reaches, cut by the SR2 pool's 503, answered "the mesh hub does not carry
/// _acpmux/retry", so nothing could resume it from here. A hold or release (`_acpmux/session_hold`
/// sets the hold tag to `held`) and a tag (`_acpmux/tag` sets and removes the keys it names) leave
/// a session as once when run twice too. 2026-11-26: a fleet pause's wake of a held lane only the
/// hub reaches from the waking machine answered "the mesh hub does not carry
/// _acpmux/session_hold" at `acpmux session release`, every pass, while its `send` went through.
const WRITE_METHODS: &[&str] =
    &[method::MUX_RENAME, method::MUX_RETRY, method::MUX_SESSION_HOLD, method::MUX_TAG];

/// Whether `m` reads a page of events, so its params cross and its budget halves.
fn pages(m: &str) -> bool {
    matches!(m, method::MUX_EVENTS | method::MUX_ATTACH)
}

/// The params of an events read that go across. The session is the target's; nothing else is
/// taken from the asker.
const EVENT_PARAMS: &[&str] = &[
    "afterSeq",
    "beforeSeq",
    "limit",
    "kinds",
    "maxBytes",
    "recordMaxBytes",
    "match",
    "promptIndex",
    "subagent",
    "waitLogs",
];

/// The params of `m` that go across: a page's, a history's count of turns, else none.
fn crossing(m: &str) -> &'static [&'static str] {
    match m {
        _ if pages(m) => EVENT_PARAMS,
        method::MUX_HISTORY => &["limit"],
        method::MUX_SESSION_SEARCH => &["query", "role", "sinceMs", "limit", "withTurnTime"],
        method::MUX_RENAME => &["newName", "to", "newHandle"],
        method::MUX_RETRY => &["subagentId"],
        method::MUX_SESSION_HOLD => &["held"],
        method::MUX_TAG => &["set", "remove", "ttlSeconds"],
        _ => &[],
    }
}

/// The largest events page a read asks for first. The JSON of a page runs past its byte budget
/// (`hub/paging.rs` counts records, not the reply around them), so this leaves the hub's 64 KiB
/// room; a page that still does not fit is asked for again at half the budget.
const READ_PAGE_BYTES: u64 = 40 * 1024;

/// The smallest budget a read halves to before it gives up on a page.
const MIN_READ_PAGE_BYTES: u64 = 4 * 1024;

/// How long a read waits for its answer with no progress: the hub taking it, or its receipt
/// moving (leased, a lease renewed, read, another attempt). Each restarts the wait, so a
/// receiver that is slow but working is not cut off; one that does nothing for this long is.
/// Leo, 2026-11-24: "if it's making good progress, it shiukd be allowed to keep going?" The hub
/// still expires a read no one took (`expired`).
pub(crate) const READ_WAIT: Duration = Duration::from_secs(50);

/// What of a receipt counts as the read moving: a change in any of these.
fn moved(receipt: &Receipt) -> (String, u32, Option<u64>, Option<u64>, Option<u64>) {
    (
        receipt.state.clone(),
        receipt.attempt,
        receipt.leased_until,
        receipt.delivered_at,
        receipt.read_at,
    )
}

/// One wait on the receipt (the hub holds it at most 25 s).
// timeout: one long-poll on the receipt (the hub holds it 25 s); READ_WAIT bounds the read.
const ANSWER_WAIT: Duration = Duration::from_secs(25);

/// The method that reads one part of an answer held in parts.
const READ_PART: &str = "_acpmux/readPart";

/// The key of an answer that goes in parts: `{"id", "count"}`.
const PARTS: &str = "_acpmuxParts";

/// The answer bytes one part carries: as base64 they are 60 KiB, so a part and the JSON around
/// it are one hub message.
const PART_BYTES: usize = 45 * 1024;

/// The refusal prefix of a session the receiving daemon does not have.
const NO_SESSION: &str = "mesh.read_no_session";

/// The receiving side: run one authorized read and answer it in the ack.
/// `writes`: the sender may also run a [`WRITE_METHODS`] change here.
pub(super) async fn answer(hub: &Arc<Hub>, message: &InMessage, writes: bool) -> Ack {
    match run(hub, message, writes).await {
        Ok(result) => Ack::answered(&message.message_id, result),
        Err(why) => Ack::refused(why),
    }
}

async fn run(hub: &Arc<Hub>, message: &InMessage, writes: bool) -> Result<String, String> {
    if message.body.len() > MAX_READ_RESULT_BYTES {
        return Err("read body exceeds 64 KiB".into());
    }
    let body: Value =
        serde_json::from_str(&message.body).map_err(|e| format!("invalid read body: {e}"))?;
    if body.get("version").and_then(Value::as_u64) != Some(1) {
        return Err("unsupported read body version".into());
    }
    let m = body.get("method").and_then(Value::as_str).unwrap_or_default();
    if WRITE_METHODS.contains(&m) && !writes {
        return Err("mesh.control_not_allowed".into());
    }
    // This machine's health, for placement on a machine only the hub reaches: of no session.
    if m == HOST_HEALTH {
        return health_answer(hub).await;
    }
    if !READ_METHODS.contains(&m) && !WRITE_METHODS.contains(&m) && m != READ_PART {
        return Err(format!("mesh.read_unsupported: {m:?} is not a read"));
    }
    // Only a session of this daemon, by its exact id or whole name, as a resume or stop does.
    let target = Target {
        session_id: message.to.session_id.clone(),
        name: message.to.name.clone(),
        ..Default::default()
    };
    let session = hub.mesh_target(&target, None).map_err(|why| format!("{NO_SESSION}: {why}"))?;
    let mut params = json!({"sessionId": session.id});
    let asked = body.get("params").and_then(Value::as_object);
    if m == READ_PART {
        let id = asked.and_then(|p| p.get("id")).and_then(Value::as_str).unwrap_or_default();
        let index = asked.and_then(|p| p.get("index")).and_then(Value::as_u64).unwrap_or(u64::MAX);
        let index = usize::try_from(index).unwrap_or(usize::MAX);
        return match hub.mesh_read_parts.part(id, &session.id, index, PART_BYTES) {
            Some(part) => Ok(json!({"part": part}).to_string()),
            None => Err("mesh.read_part_gone: this machine no longer holds that answer".into()),
        };
    }
    // Whether the sender reads an answer in parts: only when a smallest page still does not fit.
    let in_parts = body.get("parts").and_then(Value::as_bool) == Some(true);
    for key in crossing(m) {
        if let Some(value) = asked.and_then(|p| p.get(*key)) {
            params[*key] = value.clone();
        }
    }
    let mut budget = params
        .get("maxBytes")
        .and_then(Value::as_u64)
        .unwrap_or(READ_PAGE_BYTES)
        .clamp(MIN_READ_PAGE_BYTES, READ_PAGE_BYTES);
    let (tx, mut rx) = super::relay_connection(hub);
    let init = json!({
        "protocolVersion": 1,
        "clientCapabilities": {},
        "clientInfo": {"name": "acpmux-mesh-read", "version": crate::hub::VERSION},
    });
    super::rpc_call(&tx, &mut rx, 1, method::INITIALIZE, init).await.map_err(failure)?;
    if m == method::MUX_ATTACH {
        // Seen by no one here: it neither wakes the agent nor shows as a viewer.
        params["visible"] = json!(false);
    }
    for id in 2.. {
        if pages(m) {
            params["maxBytes"] = json!(budget);
        }
        let mut reply =
            super::rpc_call(&tx, &mut rx, id, m, params.clone()).await.map_err(failure)?;
        if m == method::MUX_INFO {
            fit_info(&mut reply);
        }
        let text = reply.to_string();
        if text.len() <= MAX_READ_RESULT_BYTES {
            return Ok(text);
        }
        if pages(m) && budget > MIN_READ_PAGE_BYTES {
            budget = (budget / 2).max(MIN_READ_PAGE_BYTES);
            continue;
        }
        // The smallest page (one record, or an answer that is no page) is still too large.
        if !in_parts {
            break;
        }
        let count = text.len().div_ceil(PART_BYTES);
        let held = hub.mesh_read_parts.hold(&session.id, text);
        return Ok(json!({PARTS: {"id": held, "count": count}}).to_string());
    }
    Err("mesh.read_too_large: the answer does not fit the hub's 64 KiB".into())
}

/// The read that asks a machine for its health (`peer_status.rs` `host_health`), as a direct
/// peer's link asks it every minute (`peer_health.rs`). Addressed to the machine, not a session.
/// A build before it refuses it as `mesh.read_unsupported`, which the asker keeps as
/// `{"unsupported": true}`: unknown, and `placement.rs` says to update that machine.
pub(crate) const HOST_HEALTH: &str = "_acpmux/host_health";

/// The most a health answer holds. A trimmed reading is about 1 KiB; one past this is refused,
/// never cut, so a reading is whole or none.
pub(crate) const HEALTH_BYTES: usize = 8 * 1024;

/// How long a health read waits for its answer: placement never waits on a slow machine.
// timeout: a missing reading reads as unknown; placement goes on without it.
pub(crate) const HEALTH_WAIT: Duration = Duration::from_secs(8);

/// The answer to a [`HOST_HEALTH`] read: `{"health": READING}`, the reading cut as a direct
/// peer's is (`peer_health.rs` `trim`), at most [`HEALTH_BYTES`].
async fn health_answer(hub: &Arc<Hub>) -> Result<String, String> {
    let reading = crate::server::peer_status::host_health(hub, Origin::Peer).await;
    let text = json!({"health": crate::peer::health::trim(reading)}).to_string();
    if text.len() > HEALTH_BYTES {
        return Err(format!("mesh.read_too_large: the health reading is {} bytes", text.len()));
    }
    Ok(text)
}

/// The body of a [`HOST_HEALTH`] read. Version 1, as every read: a build before the method
/// then answers `mesh.read_unsupported`, not `unsupported read body version`.
pub(crate) fn health_body() -> String {
    json!({"version": 1, "method": HOST_HEALTH, "params": {}}).to_string()
}

/// What a machine's answer to a [`HOST_HEALTH`] read says: its reading, or `{"unsupported":
/// true}` from a build without the method (its refusal names `mesh.read_unsupported`).
pub(crate) fn health_of(answer: Result<String, RpcError>) -> Result<Value, RpcError> {
    match answer {
        Ok(text) => {
            if text.len() > HEALTH_BYTES {
                return Err(RpcError::internal("the health reading is too large"));
            }
            let v: Value = serde_json::from_str(&text)
                .map_err(|_| RpcError::internal("the health reading is not JSON"))?;
            match v.get("health") {
                Some(h) if h.is_object() => Ok(h.clone()),
                _ => Err(RpcError::internal("the health answer has no reading")),
            }
        }
        Err(e) if e.message.starts_with("mesh.read_unsupported") => {
            Ok(json!({"unsupported": true}))
        }
        Err(e) => Err(e),
    }
}

/// `host`'s health through the hub, asked of the machine itself, within [`HEALTH_WAIT`].
///
/// `via` is one session the hub lists on `host` (`Hub::mesh_book_session_on`): the hub refuses a
/// read that names no session (`mesh.invalid: a read names one session by sessionId or name`,
/// cmux-platform `Core.ts`), so a read of the machine alone never reached one (every machine only
/// the hub reaches read "resources unknown", 2026-11-25). The machine answers its health before
/// it looks the session up, so any of its sessions carries it. With none, the machine alone is
/// asked, which a hub that takes machine reads answers.
pub(crate) async fn host_health(
    mesh: &dyn crate::mesh::MeshHub,
    host: &str,
    via: Option<&str>,
) -> Result<Value, RpcError> {
    let to = Target {
        host: Some(host.to_owned()),
        session_id: via.map(str::to_owned),
        ..Target::default()
    };
    // Capped at HEALTH_WAIT in total, progress or not: placement never waits on a slow machine.
    let mut wait = IdleDeadline::<tokio::time::Instant>::new(HEALTH_WAIT, Some(HEALTH_WAIT));
    let answer =
        ask_once(mesh, to, host, "", health_body(), &mut wait).await.map_err(|e| match e {
            Asked::Gone(e) => hub_error(host, "", e),
            Asked::Failed(e) => e,
        });
    health_of(answer)
}

/// The queued prompts an `_acpmux/info` through the hub carries: the next ones to run. The
/// rest are counted (`queueCount`, `queueTruncated`); `acpmux queue HOST/NAME` lists them all.
const HUB_QUEUE_KEEP: usize = 16;

/// The most an `_acpmux/info` answer through the hub holds: one hub message, with room for the
/// ack and the `peer`/`via` the sender adds.
const HUB_INFO_BYTES: usize = 56 * 1024;

/// A chat's detail as one hub message, whatever its queue or fields hold: its queue cut to
/// [`HUB_QUEUE_KEEP`], then its largest fields trimmed, marked `omitted` (`hub/reply_fit.rs`),
/// until it fits [`HUB_INFO_BYTES`]. A whole detail went in 45 KiB parts, one round trip each:
/// claude-sr2-coord's was 373 KB (229 KB of it 368 queued prompts, 76 KB `timeBreakdown`), ten
/// round trips through a busy host's inbox, 52 to 106 s, past the 50 s a read waits
/// (cmuxterm-hq#15806). `acpmux last HOST/NAME` reads it first, so it paid the same.
fn fit_info(reply: &mut Value) {
    let queued = reply.get_mut("queue").and_then(Value::as_array_mut).and_then(|queue| {
        let count = queue.len();
        (count > HUB_QUEUE_KEEP).then(|| {
            queue.truncate(HUB_QUEUE_KEEP);
            count
        })
    });
    if let Some(count) = queued
        && let Some(object) = reply.as_object_mut()
    {
        object.insert("queueCount".into(), json!(count));
        object.insert("queueTruncated".into(), json!(true));
    }
    crate::hub::reply_fit::fit_object(reply, HUB_INFO_BYTES);
}

fn failure(failure: super::ControlFailure) -> String {
    match failure {
        super::ControlFailure::Refused(why) => why,
        super::ControlFailure::Unknown => "the read did not finish".into(),
    }
}

/// The sending side: `m` for `HOST/KEY` through the hub, when nothing nearer has the session.
/// None leaves the request to this daemon's own handlers (and their `no session`).
pub(crate) async fn forward(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    let carried =
        READ_METHODS.contains(&m) || WRITE_METHODS.contains(&m) || m == method::MUX_DETACH;
    if !(carried || NOT_CARRIED.contains(&m)) || !may_reach_hub(conn) {
        return None;
    }
    let key = session_key(params).ok()?;
    // `HOST/KEY`, or the bare id of a chat the hub lists for one machine (`hub/mesh_book.rs`),
    // which is how the app opens a listed chat.
    // A chat named by its handle (`HOST/Mango`, `Mango`) is read by its id: the hub and the
    // far daemon know it by id and name only (`Hub::mesh_book_handle`).
    let named = match (hub.mesh_book_handle(key), key.split_once('/')) {
        (Some(found), _) => found,
        (None, Some((host, rest))) => (host.to_owned(), rest.to_owned()),
        (None, None) => (hub.mesh_book_host(key)?, key.to_owned()),
    };
    let (host, rest) = (named.0.as_str(), named.1.as_str());
    if host.is_empty() || rest.is_empty() || !hub.mesh_may_route(key) {
        return None;
    }
    if !carried {
        return Some(Err(RpcError::invalid_params(format!(
            "{host}/{rest} is reached only through the mesh hub, which does not carry {m}"
        ))
        .with_data(json!({"reason": "mesh.read_unsupported", "method": m, "peer": host}))));
    }
    let (mesh, device) = match read_hub(hub, conn)? {
        Ok(found) => found,
        Err(e) => return Some(Err(e)),
    };
    // A hub attach holds no stream, so there is nothing to detach.
    if m == method::MUX_DETACH {
        return Some(Ok(json!({})));
    }
    let reply = if READ_METHODS.contains(&m) {
        read_shared(hub, mesh, host, rest, m, params).await
    } else {
        read(mesh.as_ref(), host, rest, m, params).await
    };
    let mut reply = settle(conn, device.as_deref(), reply);
    // The opened chat reads as its listed row does (`HOST/name`, its `qualifiedSessionId`).
    if m == method::MUX_ATTACH
        && let Ok(reply) = reply.as_mut()
        && let Some(session) = reply.get_mut("session").filter(|s| s.is_object())
    {
        *session = Hub::remote_summary(host, session.take());
        session["via"] = json!("hub");
    }
    Some(reply)
}

/// `HOST/REST` for `key` when only the hub reaches it for `conn`: named so with a host the hub
/// lists (a typo of a host is no session), or the bare id of a chat the hub lists for one machine (`hub/mesh_book.rs`), and nothing here or on an ssh peer
/// resolves it.
fn hub_only<'a>(hub: &Hub, conn: &Conn, key: &'a str) -> Option<(String, &'a str)> {
    if !may_reach_hub(conn) {
        return None;
    }
    let (host, rest) = match key.split_once('/') {
        Some((host, rest)) if hub.mesh_book_has_host(host) => (host.to_owned(), rest),
        Some(_) => return None,
        None => (hub.mesh_book_host(key)?, key),
    };
    (!host.is_empty() && !rest.is_empty() && hub.mesh_may_route(key)).then_some((host, rest))
}

/// A session request this daemon answered `no session` for, whose `HOST/KEY` only the hub
/// reaches and the hub does not carry: said so, with what does reach it, never `no session`
/// (the session is there; this route to it is not). Every session verb the hub does not carry
/// gets this, not only the ones [`NOT_CARRIED`] names: 2026-11-23, `acpmux rename HOST/ID`
/// answered no_session while `acpmux info HOST/ID` worked, as `acpmux history` had on 2026-11-19.
/// Only a not-found answer changes, so a request this daemon answers for such a key (the app's
/// view or draft of a hub chat) answers as it did.
pub(crate) fn explain_no_session(
    hub: &Hub,
    conn: &Conn,
    m: &str,
    key: Option<&str>,
    reply: &mut Result<Value, RpcError>,
) {
    let Err(e) = reply else { return };
    if e.code != RpcError::not_found("").code
        || !super::super::peer_forward::names_a_session(m)
        || READ_METHODS.contains(&m)
        || WRITE_METHODS.contains(&m)
    {
        return;
    }
    let Some((host, rest)) = key.and_then(|key| hub_only(hub, conn, key)) else { return };
    let instead = match m {
        method::MUX_KILL => format!("; `acpmux session stop {host}/{rest} --mesh` stops it there"),
        method::MUX_WAKE | method::SESSION_RESUME => {
            format!("; `acpmux session resume {host}/{rest} --mesh` resumes it there")
        }
        _ => String::new(),
    };
    *reply = Err(RpcError::invalid_params(format!(
        "{host}/{rest} is reached only through the mesh hub, which does not carry {m}{instead}"
    ))
    .with_data(json!({"reason": "mesh.read_unsupported", "method": m, "peer": host})));
}

/// A prompt from the app's pane to a chat the hub lists for this person's other machine
/// (`hub/mesh_book.rs`): sent through the hub as `acpmux send HOST/ID` is (`mesh_send.rs`), never
/// refused as no session here. Its turn runs there; the pane reads it as it reads the chat. None
/// for anything else, which the usual prompt path takes.
pub(crate) async fn prompt(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if m != method::SESSION_PROMPT || !may_reach_hub(conn) {
        return None;
    }
    let key = params.get("sessionId").and_then(Value::as_str)?;
    let target = hub_prompt_target(hub, key)?;
    let (mesh, device) = match read_hub(hub, conn)? {
        Ok(found) => found,
        Err(e) => return Some(Err(e)),
    };
    let sent = super::super::mesh_send::send(hub, conn, Some(&mesh), params, &target).await;
    Some(settle(conn, device.as_deref(), sent))
}

/// The `HOST/ID` a prompt for `key` goes to through the hub: a chat the hub lists for one of the
/// person's other machines (`hub/mesh_book.rs`), that nothing here or on an ssh peer resolves.
/// None for anything else, which the usual prompt path takes.
pub(crate) fn hub_prompt_target(hub: &Hub, key: &str) -> Option<String> {
    // A chat named by its handle goes by its id (`Hub::mesh_book_handle`).
    if let Some((host, id)) = hub.mesh_book_handle(key) {
        return hub.mesh_may_route(key).then(|| format!("{host}/{id}"));
    }
    let target = match key.split_once('/') {
        Some((host, rest)) if !rest.is_empty() && hub.mesh_book_has_host(host) => key.to_owned(),
        Some(_) => return None,
        None => format!("{}/{key}", hub.mesh_book_host(key)?),
    };
    hub.mesh_may_route(&target).then_some(target)
}

/// The hub client a read or prompt on `conn` goes through, and the device client when it is
/// the browser's own (`web_device.rs`). A connection that presented a device reads with that
/// device's credential only, never with this daemon's. One with no device reads with this
/// daemon's identity only when [`may_read`] lets it; a web connection never may. None: nothing
/// here reaches the hub for it. `device.revoked` once the hub revoked its device: no later call
/// reaches the hub, and nothing falls back to this daemon's identity.
#[allow(clippy::type_complexity)]
fn read_hub(
    hub: &Hub,
    conn: &Conn,
) -> Option<Result<(Arc<dyn crate::mesh::MeshHub>, Option<Arc<crate::mesh_http::HttpHub>>), RpcError>>
{
    use super::super::web_device::Slot;
    match &*conn.device_mesh.lock().unwrap_or_else(|e| e.into_inner()) {
        Slot::Device(device) => {
            let mesh: Arc<dyn crate::mesh::MeshHub> = device.clone();
            return Some(Ok((mesh, Some(Arc::clone(device)))));
        }
        Slot::Revoked(reason) => return Some(Err(super::super::web_device::revoked(reason))),
        Slot::Empty => {}
    }
    if !may_read(conn) {
        return None;
    }
    Some(Ok((hub.mesh.get()?, None)))
}

/// `_acpmux/send_status` of a `mesh:` delivery `id` for `conn`. A connection that presented a
/// device reads it with that device alone (`device.revoked` once the hub refused it), and a web
/// connection with none reads nothing at the hub. Any other connection reads it as before, with
/// this daemon's identity (None when this daemon is on no hub).
pub(crate) async fn mesh_status(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    id: &str,
) -> Option<Result<Value, RpcError>> {
    use super::super::web_device::Slot;
    let device = match &*conn.device_mesh.lock().unwrap_or_else(|e| e.into_inner()) {
        Slot::Device(device) => Some(Arc::clone(device)),
        Slot::Revoked(reason) => return Some(Err(super::super::web_device::revoked(reason))),
        Slot::Empty => None,
    };
    let Some(device) = device else {
        if conn.origin == Origin::Web {
            return Some(Err(RpcError::invalid_params(format!(
                "no delivery {id}: a web connection reads the mesh hub only with its own device"
            ))
            .with_data(json!({"reason": "outbox.unknown", "deliveryId": id}))));
        }
        let Some(mesh) = hub.mesh.get() else {
            if hub.team_send_queue.lookup(id).await.is_some() {
                return Some(super::super::mesh_send::queued_status(hub, conn, id).await);
            }
            return None;
        };
        return Some(super::super::mesh_send::status(hub, conn, &mesh, id).await);
    };
    let mesh: Arc<dyn crate::mesh::MeshHub> = device.clone();
    let reply = super::super::mesh_send::status(hub, conn, &mesh, id).await;
    Some(settle(conn, Some(&device), reply))
}

/// Whether anything here may reach the hub for `conn`: [`may_read`], or a device it presented
/// (or had, until the hub revoked it). The cheap test before a request's routing.
fn may_reach_hub(conn: &Conn) -> bool {
    use super::super::web_device::Slot;
    may_read(conn)
        || !matches!(*conn.device_mesh.lock().unwrap_or_else(|e| e.into_inner()), Slot::Empty)
}

/// `reply` from the hub through `device`: when the hub refused the device's credential (401
/// `machine.revoked`: revoked or unknown; 401 `mesh.unauthorized`: no credential of its own),
/// the connection drops the device for good (its credential is wiped with the client) and the
/// answer is `device.revoked` or `device.unauthorized`.
fn settle(
    conn: &Conn,
    device: Option<&crate::mesh_http::HttpHub>,
    reply: Result<Value, RpcError>,
) -> Result<Value, RpcError> {
    let Some(reason) = device.and_then(crate::mesh_http::HttpHub::refused) else {
        return reply;
    };
    *conn.device_mesh.lock().unwrap_or_else(|e| e.into_inner()) =
        super::super::web_device::Slot::Revoked(reason);
    Err(super::super::web_device::revoked(reason))
}

/// Whether this connection may borrow this daemon's hub identity for a read: its own socket, or
/// the app's pane. A peer daemon's link, a web client or a paired device never may.
fn may_read(conn: &Conn) -> bool {
    match conn.origin {
        Origin::Local => conn.auth == ConnAuth::LocalSocket,
        Origin::LocalApp => true,
        Origin::Web | Origin::Peer => false,
    }
}

/// Whom `HOST/KEY` names at the hub: a session id when KEY is one (session ids are UUIDs), else
/// a name, on host HOST either way.
fn recipient(host: &str, key: &str) -> Target {
    let host = Some(host.to_owned());
    if uuid::Uuid::try_parse(key).is_ok() {
        Target { session_id: Some(key.to_owned()), host, ..Target::default() }
    } else {
        Target { name: Some(key.to_owned()), host, ..Target::default() }
    }
}

/// The request body a read carries: the method and only the params the receiver takes.
fn body(m: &str, params: &Value) -> String {
    let mut picked = serde_json::Map::new();
    for key in crossing(m) {
        if let Some(value) = params.get(*key) {
            picked.insert((*key).to_owned(), value.clone());
        }
    }
    json!({"version": 1, "method": m, "params": picked, "parts": true}).to_string()
}

pub(crate) async fn read(
    mesh: &dyn crate::mesh::MeshHub,
    host: &str,
    key: &str,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    read_body(mesh, host, key, body(m, params)).await
}

async fn read_body(
    mesh: &dyn crate::mesh::MeshHub,
    host: &str,
    key: &str,
    body: String,
) -> Result<Value, RpcError> {
    let text = ask(mesh, host, key, body).await?;
    let mut reply: Value = serde_json::from_str(&text)
        .map_err(|_| RpcError::internal(format!("{host}'s answer to the read is not JSON")))?;
    if let Some(held) = reply.get(PARTS).cloned() {
        reply = gather(mesh, host, key, &held).await?;
    }
    if let Some(object) = reply.as_object_mut() {
        object.insert("peer".into(), json!(host));
        object.insert("via".into(), json!("hub"));
    }
    Ok(reply)
}

#[derive(Clone, Eq, Hash, PartialEq)]
pub(crate) struct ReadKey {
    client: usize,
    host: String,
    session: String,
    body: String,
}

/// Read through the hub once for callers that arrive while the same route and request are active.
/// The mesh client's identity is part of the key so a browser device never joins the daemon's
/// credentialed read or another device's read.
async fn read_shared(
    hub: &Hub,
    mesh: Arc<dyn crate::mesh::MeshHub>,
    host: &str,
    key: &str,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let request = ReadKey {
        client: Arc::as_ptr(&mesh).cast::<()>() as usize,
        host: host.to_owned(),
        session: key.to_owned(),
        body: body(m, params),
    };
    hub.mesh_read_flights
        .run(request.clone(), || async move {
            read_body(mesh.as_ref(), &request.host, &request.session, request.body).await
        })
        .await
}

/// An answer the receiver holds in parts, read part by part and put together. A page's answer
/// is at most `rpc::MAX_MESSAGE_BYTES`, so a count past that is malformed.
async fn gather(
    mesh: &dyn crate::mesh::MeshHub,
    host: &str,
    key: &str,
    held: &Value,
) -> Result<Value, RpcError> {
    let malformed = || RpcError::internal(format!("{host}'s answer in parts is malformed"));
    let id = held.get("id").and_then(Value::as_str).ok_or_else(malformed)?;
    let most = crate::rpc::MAX_MESSAGE_BYTES.div_ceil(PART_BYTES) as u64;
    let count = held.get("count").and_then(Value::as_u64).filter(|n| (1..=most).contains(n));
    let count = count.ok_or_else(malformed)?;
    let read_part = |index: u64| async move {
        let body = json!({
            "version": 1, "method": READ_PART, "params": {"id": id, "index": index}
        });
        let part: Value = serde_json::from_str(&ask(mesh, host, key, body.to_string()).await?)
            .map_err(|_| malformed())?;
        let part = part.get("part").and_then(Value::as_str).ok_or_else(malformed)?;
        base64::engine::general_purpose::STANDARD.decode(part).map_err(|_| malformed())
    };
    // Every part but the last at once, then the last: one after another, each round trip
    // through a busy host's inbox added its wait to the read's (cmuxterm-hq#15806). The
    // receiver drops the answer once its last part is read (`mesh_read_parts.rs`, older
    // builds too), so that one goes after the rest.
    let last = count.saturating_sub(1);
    let mut text = futures::future::try_join_all((0..last).map(&read_part)).await?.concat();
    text.extend_from_slice(&read_part(last).await?);
    serde_json::from_slice(&text).map_err(|_| malformed())
}

/// How many times a read is sent afresh when the hub lets go of its receipt (404
/// `mesh.not_found` while it is awaited): a read changes nothing, so asking again is safe.
const READ_ROUNDS: usize = 2;

/// One read message to `HOST/KEY` through the hub, and the receiver's answer text. Each hub call
/// is tried again on a failure that passes (`mesh_retry`), and a read whose receipt the hub let
/// go of is sent again once, all within `READ_WAIT` of the read's last progress (`moved`): no
/// try runs past it, and nothing is sent again once it has passed.
async fn ask(
    mesh: &dyn crate::mesh::MeshHub,
    host: &str,
    key: &str,
    body: String,
) -> Result<String, RpcError> {
    let mut wait = IdleDeadline::<tokio::time::Instant>::new(READ_WAIT, None);
    let mut round = 1;
    loop {
        match ask_once(mesh, recipient(host, key), host, key, body.clone(), &mut wait).await {
            Ok(text) => return Ok(text),
            // A read sent again once its wait has run out is one no one waits for.
            Err(Asked::Gone(_)) if wait.stalled().is_some() => {
                return Err(unanswered(host));
            }
            Err(Asked::Gone(e)) if round < READ_ROUNDS => {
                tracing::debug!(host, error = %e, "the hub let go of a read's receipt; asking again");
                round += 1;
            }
            Err(Asked::Gone(e)) => return Err(hub_error(host, key, e)),
            Err(Asked::Failed(e)) => return Err(e),
        }
    }
}

/// How one round of [`ask`] ended without an answer.
enum Asked {
    /// The hub no longer knows the read's receipt (404 `mesh.not_found`): send it again.
    Gone(HubError),
    Failed(RpcError),
}

async fn ask_once(
    mesh: &dyn crate::mesh::MeshHub,
    to: Target,
    host: &str,
    key: &str,
    body: String,
    wait: &mut IdleDeadline<tokio::time::Instant>,
) -> Result<String, Asked> {
    // A failure once the read's wait has run out (a try it cut short among them) is no answer.
    let failed = |e, deadline: tokio::time::Instant| {
        Asked::Failed(if tokio::time::Instant::now() >= deadline {
            unanswered(host)
        } else {
            hub_error(host, key, e)
        })
    };
    let message = OutMessage {
        to,
        from: Sender { host: Some(crate::pairing::mesh_host()), ..Sender::default() },
        kind: Kind::Control,
        op: Some("read".into()),
        body,
        mode: Mode::Now,
        idempotency_key: format!("read-{}", uuid::Uuid::now_v7()),
    };
    // One idempotency key for every try, so a send the hub took before a lost answer is one read.
    let deadline = wait.end();
    let mut receipt = crate::mesh_retry::retry_within(true, deadline, || mesh.send(&message))
        .await
        .map_err(|e| failed(e, deadline))?;
    // The hub took it: progress.
    wait.progressed();
    let mut seen = moved(&receipt);
    loop {
        let now_moved = moved(&receipt);
        if now_moved != seen {
            seen = now_moved;
            wait.progressed();
        }
        match receipt.state.as_str() {
            "delivered" => break,
            "refused" => {
                let why = receipt.detail.unwrap_or_else(|| "the machine refused the read".into());
                return Err(Asked::Failed(if why.starts_with(NO_SESSION) {
                    RpcError::not_found(format!("no session matches \"{host}/{key}\""))
                } else {
                    RpcError::new(-32003, why).with_data(json!({"reason": "mesh.read_refused"}))
                }));
            }
            "expired" => return Err(Asked::Failed(unanswered(host))),
            _ => {}
        }
        let deadline = wait.end();
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        if left.is_zero() {
            return Err(Asked::Failed(unanswered(host)));
        }
        let id = receipt.message_id.clone();
        // Each try waits only as long as is left of the read's wait.
        let call = || {
            let left = deadline.saturating_duration_since(tokio::time::Instant::now());
            mesh.answer(&id, left.min(ANSWER_WAIT))
        };
        receipt = crate::mesh_retry::retry_within(false, deadline, call).await.map_err(|e| {
            if e.code.as_deref() == Some("mesh.not_found") {
                Asked::Gone(e)
            } else {
                failed(e, deadline)
            }
        })?;
    }
    receipt.result.ok_or_else(|| {
        Asked::Failed(RpcError::internal(format!(
            "{host} answered the read with no result; is it on a build that reads?"
        )))
    })
}

fn unanswered(host: &str) -> RpcError {
    RpcError::new(-32000, format!("{host} did not answer the read through the mesh hub"))
        .with_data(json!({"reason": "mesh.read_unanswered", "retryable": true}))
}

/// The hub's refusal as this daemon's: a session it does not know is `no session`, as a send's.
/// Any other failure (after `mesh_retry` tried again what passes) names the route it took, the
/// only one this daemon has to HOST (`forward` comes here only when no ssh peer or tailnet has
/// the session), and the route that does not need the hub.
fn hub_error(host: &str, key: &str, e: HubError) -> RpcError {
    match e.code.as_deref() {
        Some("mesh.unknown_recipient") => {
            RpcError::not_found(format!("no session matches \"{host}/{key}\""))
        }
        code => RpcError::new(-32000, through_hub_only(host, &e.message)).with_data(json!({
            "reason": code.unwrap_or("mesh.unavailable"),
            "candidates": e.candidates,
            "retryable": !e.refused,
            "route": "hub",
        })),
    }
}

/// A failed read's words: what the hub said, that the hub is the only route here, and the other.
fn through_hub_only(host: &str, why: &str) -> String {
    format!(
        "{why} (this machine reaches {host} only through the mesh hub; a direct link does not \
         need it: `acpmux machine add {host}`)"
    )
}

#[cfg(test)]
#[path = "mesh_read_tests.rs"]
mod tests;
