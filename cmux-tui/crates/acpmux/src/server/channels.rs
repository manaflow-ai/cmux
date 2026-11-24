//! Agent byte channels (ultra-connectivity design A1, RFD 0164 B9): an agent opens, listens on
//! and closes a named channel to another agent, on this machine or on a peer daemon it is not
//! resident on, and the two talk in bytes over whatever path carries the peer link.
//!
//! Wire (`agent-channels-v1`; a client checks the capability, a daemon checks its peer's):
//!
//! - Client to its own daemon, requests: `_acpmux/channel/listen {service}`,
//!   `_acpmux/channel/unlisten {service}`, `_acpmux/channel/open {service, peer?, text?|data?}`
//!   answering `{channelId, service}`.
//! - Client to its own daemon, notifications (one ordered worker per connection, so bytes stay in
//!   order): `_acpmux/channel/send {channelId, text|data}`, `_acpmux/channel/close {channelId,
//!   reason?}`.
//! - Daemon to client, notifications: `_acpmux/channel/opened {channelId, service, from, text?|
//!   data?}` to the listener, `_acpmux/channel/data {channelId, text|data}`,
//!   `_acpmux/channel/closed {channelId, reason}`.
//! - Peer leg: the opening daemon is a client of the listening one. It sends
//!   `_acpmux/channel/connect {channelId, service, from, text?|data?}`, then `send` and `close`;
//!   the listening daemon answers with `data` and `closed` on the same link.
//!
//! No round trip before the first byte: `open` may carry the first bytes, the peer leg's
//! `connect` is a notification that goes out with them, and the opener is answered as soon as it
//! is queued on the link. A refusal comes back as `closed` (`no_listener`), one round trip later.
//! `text` is UTF-8 and `data` base64; both pass through unchanged, bounded by the frame limit.
//!
//! A channel ends when either side closes it, when either connection ends, or when the peer
//! link it rode drops or moves to a new link (`link_lost`): the opener opens a new one. Only
//! this machine's own clients listen and open, and only the owner's own daemons (peer token or
//! the Cloud carrier's owner) connect from far away; a connect never hops on to a third machine.

use std::collections::HashMap;
use std::sync::{Arc, Mutex as StdMutex, Weak};

use serde_json::{Map, Value, json};

use super::{Conn, Origin};
use crate::hub::Hub;
use crate::no_panic::LockExt;
use crate::rpc::{Message, RpcError, method};

/// The capability id (`capabilities.rs`): the daemon serves this file's wire.
pub(crate) const CAPABILITY: &str = "agent-channels-v1";

/// Open channels one connection may hold: a client that opens and never closes runs out, not the
/// daemon.
const PER_CONN: usize = 256;
/// Open channels on this daemon.
const TOTAL: usize = 4096;
/// The longest service name.
const SERVICE_MAX: usize = 128;

/// This daemon's listeners and open channels (one per `Hub`).
#[derive(Default)]
pub(crate) struct Channels(StdMutex<Table>);

#[derive(Default)]
struct Table {
    listeners: HashMap<String, Listener>,
    open: HashMap<String, Channel>,
}

struct Listener {
    conn_id: String,
    conn: Weak<Conn>,
}

/// One side of a channel.
#[derive(Clone)]
enum End {
    /// A connection to this daemon: a local client, or the link of the peer daemon that opened it.
    Conn { id: String, conn: Weak<Conn> },
    /// This daemon's own link to peer `name` (its `generation`), on link `epoch`.
    Peer { name: String, generation: u64, epoch: u64 },
}

impl End {
    fn of(conn: &Arc<Conn>) -> Self {
        End::Conn { id: conn.id.clone(), conn: Arc::downgrade(conn) }
    }

    fn is_conn(&self, id: &str) -> bool {
        matches!(self, End::Conn { id: own, .. } if own == id)
    }

    fn is_peer(&self, peer: &str, generation: u64) -> bool {
        matches!(self, End::Peer { name, generation: g, .. } if name == peer && *g == generation)
    }
}

struct Channel {
    opener: End,
    listener: End,
}

impl Channel {
    /// The other side of the one `from` matches.
    fn other(&self, from: impl Fn(&End) -> bool) -> Option<&End> {
        if from(&self.opener) {
            Some(&self.listener)
        } else if from(&self.listener) {
            Some(&self.opener)
        } else {
            None
        }
    }
}

fn refused(reason: &str, text: impl Into<String>) -> RpcError {
    RpcError::invalid_params(text.into()).with_data(json!({"reason": format!("channel.{reason}")}))
}

/// Who may listen and open: this machine's own clients, not a trigger or a read-only machine.
fn local_client(conn: &Conn) -> bool {
    conn.origin == Origin::Local
        && !conn.is_trigger()
        && conn.auth != super::ConnAuth::ReadOnlyDevice
}

/// Who may connect from far away: the owner's own daemon on another machine.
fn peer_daemon(conn: &Conn) -> bool {
    conn.origin == Origin::Peer && conn.auth.peer_daemon()
}

fn service_of(params: &Value) -> Result<String, RpcError> {
    let service = params.get("service").and_then(Value::as_str).unwrap_or_default();
    let ok = !service.is_empty()
        && service.len() <= SERVICE_MAX
        && service.bytes().all(|b| b.is_ascii_alphanumeric() || b"._:/-".contains(&b));
    if !ok {
        return Err(refused(
            "bad_params",
            "service: 1-128 characters of letters, digits and . _ : / -",
        ));
    }
    Ok(service.to_owned())
}

/// The bytes a frame carries: `text` or `data`, at most one, each a string. `need`: one is
/// required (`send`), else both may be absent (`open`, `connect`).
fn payload(params: &Value, need: bool) -> Result<Option<(&'static str, Value)>, RpcError> {
    let text = params.get("text");
    let data = params.get("data");
    match (text, data) {
        (Some(_), Some(_)) => Err(refused("bad_params", "send text or data, not both")),
        (Some(t @ Value::String(_)), None) => Ok(Some(("text", t.clone()))),
        (None, Some(d @ Value::String(_))) => Ok(Some(("data", d.clone()))),
        (None, None) if !need => Ok(None),
        (None, None) => Err(refused("bad_params", "send needs text or data")),
        _ => Err(refused("bad_params", "text and data are strings (data in base64)")),
    }
}

fn channel_id_of(params: &Value) -> Option<String> {
    params.get("channelId").and_then(Value::as_str).filter(|id| id.len() <= 64).map(str::to_owned)
}

fn frame(channel: &str, bytes: Option<(&'static str, Value)>, extra: Value) -> Value {
    let mut map = Map::new();
    map.insert("channelId".into(), Value::from(channel));
    if let Some((key, value)) = bytes {
        map.insert(key.into(), value);
    }
    if let Value::Object(extra) = extra {
        map.extend(extra);
    }
    Value::Object(map)
}

fn this_host() -> String {
    crate::sent_by::this_host().unwrap_or_else(|| "local".into())
}

/// Tells end `to` about its channel. A connection hears `data` and `closed`; a peer link is told
/// `send` and `close`, which its daemon hands on as `data` and `closed`. False: that end is gone.
async fn deliver(hub: &Hub, to: &End, closing: bool, params: Value) -> bool {
    match to {
        End::Conn { conn, .. } => {
            let Some(conn) = conn.upgrade() else { return false };
            let m = if closing { method::MUX_CHANNEL_CLOSED } else { method::MUX_CHANNEL_DATA };
            conn.send(&Message::notification(m, params));
            true
        }
        End::Peer { name, generation, epoch } => {
            let Some(peer) = hub.peer_by_name(name).filter(|p| p.generation == *generation) else {
                return false;
            };
            if peer.link_epoch() != *epoch {
                return false;
            }
            let m = if closing { method::MUX_CHANNEL_CLOSE } else { method::MUX_CHANNEL_SEND };
            peer.notify(m, params).await.is_ok()
        }
    }
}

/// The requests: `listen`, `unlisten` and `open`. None: not a channel method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(
        m,
        method::MUX_CHANNEL_LISTEN | method::MUX_CHANNEL_UNLISTEN | method::MUX_CHANNEL_OPEN
    ) {
        return None;
    }
    if !local_client(conn) {
        return Some(Err(refused("refused", "only this machine's own clients open or listen")));
    }
    Some(match m {
        method::MUX_CHANNEL_LISTEN => listen(hub, conn, params),
        method::MUX_CHANNEL_UNLISTEN => unlisten(hub, conn, params),
        _ => open(hub, conn, params).await,
    })
}

fn listen(hub: &Hub, conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    let service = service_of(params)?;
    let mut table = hub.channels.0.lock_or_recover();
    if let Some(held) = table.listeners.get(&service)
        && held.conn_id != conn.id
        && held.conn.upgrade().is_some_and(|c| c.is_open())
    {
        return Err(refused("service_taken", format!("another client listens on {service}")));
    }
    table
        .listeners
        .insert(service.clone(), Listener { conn_id: conn.id.clone(), conn: Arc::downgrade(conn) });
    Ok(json!({"service": service, "host": this_host()}))
}

fn unlisten(hub: &Hub, conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    let service = service_of(params)?;
    let mut table = hub.channels.0.lock_or_recover();
    let mine = table.listeners.get(&service).is_some_and(|l| l.conn_id == conn.id);
    if mine {
        table.listeners.remove(&service);
    }
    Ok(json!({"service": service, "removed": mine}))
}

/// The live listener of `service`, if any.
fn listener_of(table: &Table, service: &str) -> Option<Arc<Conn>> {
    table.listeners.get(service).and_then(|l| l.conn.upgrade()).filter(|c| c.is_open())
}

fn room(table: &Table, conn_id: &str) -> Result<(), RpcError> {
    if table.open.len() >= TOTAL {
        return Err(refused("too_many", "this daemon holds as many channels as it may"));
    }
    let mine = table
        .open
        .values()
        .filter(|c| c.opener.is_conn(conn_id) || c.listener.is_conn(conn_id))
        .count();
    if mine >= PER_CONN {
        return Err(refused(
            "too_many",
            format!("one connection holds at most {PER_CONN} channels"),
        ));
    }
    Ok(())
}

async fn open(hub: &Arc<Hub>, conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    let service = service_of(params)?;
    let bytes = payload(params, false)?;
    let id = format!("ch-{}", uuid::Uuid::now_v7().simple());
    let peer = params.get("peer").and_then(Value::as_str).filter(|p| !p.is_empty());
    let from = json!({"host": this_host()});
    let Some(name) = peer.filter(|p| *p != this_host()) else {
        // On this machine: straight to the listener's connection.
        let listener = {
            let mut table = hub.channels.0.lock_or_recover();
            room(&table, &conn.id)?;
            let Some(listener) = listener_of(&table, &service) else {
                return Err(refused("no_listener", format!("nothing listens on {service} here")));
            };
            table.open.insert(
                id.clone(),
                Channel { opener: End::of(conn), listener: End::of(&listener) },
            );
            listener
        };
        let opened = frame(&id, bytes, json!({"service": service, "from": from}));
        listener.send(&Message::notification(method::MUX_CHANNEL_OPENED, opened));
        return Ok(json!({"channelId": id, "service": service}));
    };
    let Some(link) = hub.peer_by_name(name) else {
        return Err(refused("peer_unknown", format!("no peer named {name}")));
    };
    if !link.connected.load(std::sync::atomic::Ordering::SeqCst) {
        return Err(refused("peer_unreachable", format!("{name} is not connected")));
    }
    if !link.agent_channels() {
        return Err(refused("peer_unsupported", format!("{name} runs an acpmux without channels")));
    }
    let end =
        End::Peer { name: name.to_owned(), generation: link.generation, epoch: link.link_epoch() };
    {
        let mut table = hub.channels.0.lock_or_recover();
        room(&table, &conn.id)?;
        table.open.insert(id.clone(), Channel { opener: End::of(conn), listener: end });
    }
    let connect = frame(&id, bytes, json!({"service": service, "from": from}));
    if let Err(e) = link.notify(method::MUX_CHANNEL_CONNECT, connect).await {
        hub.channels.0.lock_or_recover().open.remove(&id);
        return Err(refused("peer_unreachable", e.message));
    }
    Ok(json!({"channelId": id, "service": service, "peer": name}))
}

/// How many frames a connection may have waiting before its reader waits for room.
const QUEUE: usize = 256;

/// The connection's channel worker: `send`, `close` and `connect`, handled one at a time in the
/// order they came. It ends when the sender is dropped, after the frames already queued.
pub(super) fn spawn_worker(
    hub: Arc<Hub>,
    conn: Arc<Conn>,
) -> (tokio::sync::mpsc::Sender<(String, Value)>, tokio::task::JoinHandle<()>) {
    let (tx, mut rx) = tokio::sync::mpsc::channel::<(String, Value)>(QUEUE);
    let owner = conn.clone();
    let worker = owner.scope.spawn_named("channel frames", async move {
        while let Some((m, params)) = rx.recv().await {
            notification(&hub, &conn, &m, &params).await;
        }
    });
    (tx, worker)
}

/// True for the notifications this file takes from a client or a peer daemon.
pub(super) fn takes(m: &str) -> bool {
    matches!(m, method::MUX_CHANNEL_SEND | method::MUX_CHANNEL_CLOSE | method::MUX_CHANNEL_CONNECT)
}

/// `send`, `close` and (from a peer daemon) `connect`, in the order the connection sent them.
pub(super) async fn notification(hub: &Arc<Hub>, conn: &Arc<Conn>, m: &str, params: &Value) {
    if m == method::MUX_CHANNEL_CONNECT {
        return connect(hub, conn, params);
    }
    if !local_client(conn) && !peer_daemon(conn) {
        return;
    }
    let Some(id) = channel_id_of(params) else { return };
    let closing = m == method::MUX_CHANNEL_CLOSE;
    let other = {
        let mut table = hub.channels.0.lock_or_recover();
        let other = table.open.get(&id).and_then(|c| c.other(|e| e.is_conn(&conn.id)).cloned());
        if closing && other.is_some() {
            table.open.remove(&id);
        }
        other
    };
    let Some(other) = other else {
        // Not this connection's channel (closed already, or never its): it learns so.
        let closed = frame(&id, None, json!({"reason": "unknown_channel"}));
        conn.send(&Message::notification(method::MUX_CHANNEL_CLOSED, closed));
        return;
    };
    let bytes = if closing {
        None
    } else {
        match payload(params, true) {
            Ok(bytes) => bytes,
            // A frame it cannot read ends the channel on both sides: bytes were lost.
            Err(_) => return close_one(hub, &id, None, json!({"reason": "bad_params"})).await,
        }
    };
    if closing {
        let reason = params.get("reason").and_then(Value::as_str).unwrap_or("closed");
        deliver(hub, &other, true, frame(&id, None, json!({"reason": reason}))).await;
        return;
    }
    if !deliver(hub, &other, false, frame(&id, bytes, json!({}))).await {
        let gone = if matches!(other, End::Peer { .. }) { "link_lost" } else { "peer_gone" };
        close_one(hub, &id, None, json!({"reason": gone})).await;
    }
}

/// A peer daemon's `connect`: to this machine's listener, never on to a third machine.
fn connect(hub: &Arc<Hub>, conn: &Arc<Conn>, params: &Value) {
    let Some(id) = channel_id_of(params) else { return };
    let closed = |reason: &str| {
        let closed = frame(&id, None, json!({"reason": reason}));
        conn.send(&Message::notification(method::MUX_CHANNEL_CLOSED, closed));
    };
    if !peer_daemon(conn) {
        return closed("refused");
    }
    let (Ok(service), Ok(bytes)) = (service_of(params), payload(params, false)) else {
        return closed("bad_params");
    };
    let listener = {
        let mut table = hub.channels.0.lock_or_recover();
        if table.open.contains_key(&id) {
            drop(table);
            return closed("duplicate_channel");
        }
        if room(&table, &conn.id).is_err() {
            drop(table);
            return closed("too_many");
        }
        let Some(listener) = listener_of(&table, &service) else {
            drop(table);
            return closed("no_listener");
        };
        table
            .open
            .insert(id.clone(), Channel { opener: End::of(conn), listener: End::of(&listener) });
        listener
    };
    let from = params.get("from").cloned().filter(Value::is_object).unwrap_or_else(|| json!({}));
    let opened = frame(&id, bytes, json!({"service": service, "from": from}));
    listener.send(&Message::notification(method::MUX_CHANNEL_OPENED, opened));
}

/// Removes channel `id` and tells its other side (every side but the connection `but`).
async fn close_one(hub: &Hub, id: &str, but: Option<&str>, why: Value) {
    let Some(channel) = hub.channels.0.lock_or_recover().open.remove(id) else { return };
    for end in [channel.opener, channel.listener] {
        if but.is_some_and(|b| end.is_conn(b)) {
            continue;
        }
        deliver(hub, &end, true, frame(id, None, why.clone())).await;
    }
}

/// A connection ended: its listeners go, and each of its channels closes on the other side.
pub(super) async fn conn_ended(hub: &Hub, conn: &Conn) {
    let ends: Vec<(String, End)> = {
        let mut table = hub.channels.0.lock_or_recover();
        table.listeners.retain(|_, l| l.conn_id != conn.id);
        let ids: Vec<String> = table
            .open
            .iter()
            .filter(|(_, c)| c.opener.is_conn(&conn.id) || c.listener.is_conn(&conn.id))
            .map(|(id, _)| id.clone())
            .collect();
        ids.into_iter()
            .filter_map(|id| {
                let c = table.open.remove(&id)?;
                let other = c.other(|e| e.is_conn(&conn.id))?.clone();
                Some((id, other))
            })
            .collect()
    };
    for (id, other) in ends {
        deliver(hub, &other, true, frame(&id, None, json!({"reason": "peer_gone"}))).await;
    }
}

/// True for what a peer daemon sends back on a channel this daemon opened (`hub/peers.rs`).
pub(crate) fn from_peer_method(m: &str) -> bool {
    matches!(m, method::MUX_CHANNEL_DATA | method::MUX_CHANNEL_CLOSED)
}

/// `data` or `closed` from peer `peer` (its `generation`): handed to the local opener as is.
pub(crate) fn from_peer(hub: &Hub, peer: &str, generation: u64, m: &str, params: &Value) {
    let Some(id) = channel_id_of(params) else { return };
    let closing = m == method::MUX_CHANNEL_CLOSED;
    let opener = {
        let mut table = hub.channels.0.lock_or_recover();
        let Some(channel) = table.open.get(&id) else { return };
        if !channel.listener.is_peer(peer, generation) {
            return;
        }
        let opener = channel.opener.clone();
        if closing {
            table.open.remove(&id);
        }
        opener
    };
    let End::Conn { conn, .. } = opener else { return };
    let Some(conn) = conn.upgrade() else {
        if !closing {
            hub.channels.0.lock_or_recover().open.remove(&id);
        }
        return;
    };
    let mut params = params.clone();
    if let Some(map) = params.as_object_mut() {
        map.retain(|k, _| matches!(k.as_str(), "channelId" | "text" | "data" | "reason"));
    }
    conn.send(&Message::notification(m, params));
}

/// The link to `peer` dropped: every channel that rode it closes for its local side.
pub(crate) fn link_lost(hub: &Hub, peer: &str, generation: u64) {
    let lost: Vec<(String, End)> = {
        let mut table = hub.channels.0.lock_or_recover();
        let ids: Vec<String> = table
            .open
            .iter()
            .filter(|(_, c)| c.listener.is_peer(peer, generation))
            .map(|(id, _)| id.clone())
            .collect();
        ids.into_iter().filter_map(|id| table.open.remove(&id).map(|c| (id, c.opener))).collect()
    };
    for (id, opener) in lost {
        if let End::Conn { conn, .. } = opener
            && let Some(conn) = conn.upgrade()
        {
            let closed = frame(&id, None, json!({"reason": "link_lost"}));
            conn.send(&Message::notification(method::MUX_CHANNEL_CLOSED, closed));
        }
    }
}

/// Open channels and listeners, for `_acpmux/status` and tests.
pub(crate) fn counts(hub: &Hub) -> (usize, usize) {
    let table = hub.channels.0.lock_or_recover();
    (table.open.len(), table.listeners.len())
}

#[cfg(test)]
#[path = "channels_tests.rs"]
mod tests;
