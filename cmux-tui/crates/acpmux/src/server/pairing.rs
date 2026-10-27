//! The listener's side of pairing (`crate::pairing`): who a WebSocket
//! upgrade is (the dashboard token, a ticket being redeemed, or a paired
//! device), the redeem exchange itself, and the minter's local methods.
//!
//! - `_acpmux/pair_ticket_new {role, ttlSeconds?, url?, label?}` mints a ticket.
//! - `_acpmux/pair_list` lists tickets and paired machines.
//! - `_acpmux/pair_revoke {id}` revokes a ticket or a machine (by id or
//!   name); a machine's open connections close at once.
//! - `_acpmux/pair_issue {name, role}` issues a credential with no ticket
//!   (the joining side of the daemon role). Role `phone` is the person's
//!   only, for a phone the Mac app's mobile host serves; a live phone of
//!   that name is replaced (`Pairing::issue_phone`).
//! - `_acpmux/pair_set {id, fullAccess}` turns a `client` machine's or a phone's
//!   Full-access setting on (the person only, `hub/person.rs`) or off
//!   (`crate::pairing` module docs). Off, like a machine's revoke, puts
//!   every chat out of its policy's mode back at once.
//!
//! All five are the unix socket's only. `_acpmux/pair_redeem` is served only
//! on a connection that presented an open ticket, and nothing else is.

use crate::no_panic::JsonExt;
use std::net::SocketAddr;
use std::sync::Arc;

use cmux_local_auth::Refusal;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio_tungstenite::tungstenite::Message as Frame;

use super::{Conn, ConnAuth, Origin};
use crate::hub::Hub;
use crate::pairing::{DeviceAuth, Role};
use crate::rpc::{Message, RpcError, method};

/// What a WebSocket upgrade proved.
#[derive(Debug, Clone, Default)]
pub(super) enum Admitted {
    /// The dashboard token (every connection before pairing).
    #[default]
    Dashboard,
    /// An open ticket, to redeem on this connection and nothing else.
    Ticket(String),
    /// A paired machine's credential.
    Device(DeviceAuth),
}

/// Decide an upgrade: a ticket header, else the dashboard token, else a
/// paired device's credential in its place. A ticket or a device credential
/// counts only from a loopback address (`pairing::source_ok`).
pub(super) fn admit(
    hub: &Hub,
    from: SocketAddr,
    presented: Option<&str>,
    tickets: &[&str],
    expected: &str,
) -> Result<Admitted, Refusal> {
    if !tickets.is_empty() {
        let [secret] = tickets else { return Err(Refusal::WrongToken) };
        if !crate::pairing::source_ok(from) {
            tracing::warn!("refused a pairing ticket from {from}: plain ws:// from another host");
            return Err(Refusal::WrongToken);
        }
        if !hub.pairing.ticket_open(secret) {
            return Err(Refusal::WrongToken);
        }
        return Ok(Admitted::Ticket((*secret).to_owned()));
    }
    let dashboard = cmux_local_auth::check_token(presented, expected);
    if dashboard.is_ok() {
        return Ok(Admitted::Dashboard);
    }
    match presented.and_then(|t| hub.pairing.device_for(t)) {
        // A daemon-role record proves nothing here: this side dials it.
        Some(device) if device.role != Role::Daemon => {
            if crate::pairing::source_ok(from) {
                return Ok(Admitted::Device(device));
            }
            tracing::warn!("refused a paired machine's credential from {from}: plain ws://");
            Err(Refusal::WrongToken)
        }
        _ => dashboard.map(|()| Admitted::Dashboard),
    }
}

/// The origin and proof a paired machine's connection is served with:
/// `client` as a peer daemon, `read-only` as Web with the read-only gate,
/// `phone` as Web with its own id (what its Full-access setting reads).
pub(super) fn origin_of(device: &DeviceAuth) -> (Origin, ConnAuth) {
    match device.role {
        Role::ReadOnly => (Origin::Web, ConnAuth::ReadOnlyDevice),
        Role::Phone => (Origin::Web, ConnAuth::Device),
        _ => (Origin::Peer, ConnAuth::Device),
    }
}

/// The read-only gate, before any dispatcher: a refusal, or the params the
/// request runs with.
pub(super) fn gate(conn: &Conn, m: &str, params: Value) -> Result<Value, RpcError> {
    if conn.auth != ConnAuth::ReadOnlyDevice {
        return Ok(params);
    }
    if !crate::pairing::read_only_allows(m) {
        return Err(RpcError::new(
            -32003,
            format!("{m}: this machine is paired read-only here; it can list and watch sessions, not change them"),
        )
        .with_data(json!({"reason": "read_only"})));
    }
    Ok(crate::pairing::read_only_scrub(m, params))
}

/// How long a redeeming connection may take to send its one request.
const REDEEM_WAIT: std::time::Duration = std::time::Duration::from_secs(10);

/// Serve one `_acpmux/pair_redeem` on a connection that presented `secret`,
/// answer it, and close.
pub(super) async fn serve_redeem<S>(
    hub: Arc<Hub>,
    ws: tokio_tungstenite::WebSocketStream<S>,
    secret: String,
) where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let (mut sink, mut source) = ws.split();
    let first = tokio::time::timeout(REDEEM_WAIT, async {
        while let Some(Ok(frame)) = source.next().await {
            if let Frame::Text(t) = frame {
                return Some(t.to_string());
            }
        }
        None
    })
    .await
    .ok()
    .flatten();
    let Some(Ok(Message::Request { id, method: m, params })) = first.map(|f| Message::parse(&f))
    else {
        let _ = sink.close().await;
        return;
    };
    let reply = if m == method::MUX_PAIR_REDEEM {
        redeem(&hub, &secret, params.unwrap_or(Value::Null)).await
    } else {
        Err(RpcError::method_not_found(&format!("{m} (a ticket connection only redeems)")))
    };
    let line = match reply {
        Ok(v) => Message::ok(id, v),
        Err(e) => Message::err(id, e),
    };
    let _ = sink.send(Frame::Text(line.to_value().to_string().into())).await;
    let _ = sink.close().await;
}

async fn redeem(hub: &Arc<Hub>, secret: &str, params: Value) -> Result<Value, RpcError> {
    let text = |k: &str| params.get(k).and_then(Value::as_str).map(str::to_owned);
    let name = text("name").ok_or_else(|| RpcError::invalid_params("name is required"))?;
    let advertise = (text("advertiseUrl"), text("advertiseToken"));
    let taken = hub.config.read().await.peers.contains_key(&name)
        || hub.peers().iter().any(|p| p.get("name").and_then(Value::as_str) == Some(name.as_str()));
    let redeemed = hub.pairing.redeem(secret, &name, |role| {
        if role != Role::Daemon {
            return Ok(());
        }
        let (Some(url), Some(token)) = &advertise else {
            return Err(daemon_needs("--advertise URL (wss://, or ws:// to a loopback host)"));
        };
        if !crate::pairing::transport_ok(url) {
            return Err(daemon_needs(
                "an --advertise URL that is wss://, or ws:// to a loopback host",
            ));
        }
        if crate::peer::peer_token_text(token.as_bytes()).is_none() {
            return Err(daemon_needs("a credential this machine issued"));
        }
        if taken {
            return Err(RpcError::invalid_params(format!(
                "this machine already has a peer named {name:?}; pass another --name"
            ))
            .with_data(json!({"reason": "name_taken"})));
        }
        Ok(())
    })?;
    let role = redeemed.device.role;
    tracing::info!(device = %redeemed.device.id, name = %name, role = role.as_str(), "a machine paired");
    let mut reply = json!({
        "role": role.as_str(),
        "deviceId": redeemed.device.id,
        "name": name,
        "minter": crate::pairing::machine_name(),
    });
    match (role, advertise) {
        // Checked before the redeem: a daemon-role ticket came with both.
        (Role::Daemon, (Some(url), Some(token))) => {
            hub.add_peer(&name, &url, Some(token), None, false).await?;
            reply.set("peer", json!({"name": name, "url": url}));
        }
        _ => {
            reply.set("token", json!(redeemed.token));
        }
    }
    Ok(reply)
}

fn daemon_needs(what: &str) -> RpcError {
    RpcError::invalid_params(format!("a daemon-role ticket needs {what}"))
        .with_data(json!({"reason": "advertise_required"}))
}

/// The minter's methods: `None` for every other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Conn,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(
        m,
        method::MUX_PAIR_TICKET_NEW
            | method::MUX_PAIR_LIST
            | method::MUX_PAIR_REVOKE
            | method::MUX_PAIR_ISSUE
            | method::MUX_PAIR_SET
            | method::MUX_PAIR_REDEEM
    ) {
        return None;
    }
    if conn.origin != Origin::Local || m == method::MUX_PAIR_REDEEM {
        return Some(Err(RpcError::method_not_found(&format!("{m} (local socket only)"))));
    }
    Some(match m {
        method::MUX_PAIR_TICKET_NEW => mint(hub, params).await,
        method::MUX_PAIR_LIST => Ok(hub.pairing.list()),
        method::MUX_PAIR_REVOKE => revoke(hub, params).await,
        method::MUX_PAIR_SET => set(hub, conn, params).await,
        _ => issue(hub, conn, params),
    })
}

/// `_acpmux/pair_set {id, fullAccess}`: on only from the person, since it
/// widens what runs without asking; off from any unix socket client.
async fn set(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let key = params
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("id is required"))?;
    let on = params
        .get("fullAccess")
        .and_then(Value::as_bool)
        .ok_or_else(|| RpcError::invalid_params("fullAccess (true or false) is required"))?;
    if on && !conn.is_person() {
        return Err(crate::hub::person::person_required(
            "letting a machine run chats in Full access",
        ));
    }
    let device = hub.pairing.set_full_access(key, on)?;
    let held_again = if on { 0 } else { hub.hold_policies_again().await };
    tracing::info!(device = %device.id, name = %device.name, on, "a machine's Full-access setting changed");
    Ok(json!({
        "device": device.to_value(),
        "allows": on.then(|| crate::pairing::full_access_allows(&device.name)),
        "held_again": held_again,
    }))
}

fn role_param(params: &Value) -> Result<Role, RpcError> {
    let name = params.get("role").and_then(Value::as_str).unwrap_or_default();
    Role::parse(name).ok_or_else(|| {
        RpcError::invalid_params(format!(
            "role must be daemon, client, read-only or phone, not {name:?}"
        ))
    })
}

async fn mint(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let role = role_param(params)?;
    if role == Role::Phone {
        return Err(RpcError::invalid_params(
            "a phone pairs with the Mac app, never with a ticket: mint a client or read-only ticket",
        ));
    }
    let ttl = params
        .get("ttlSeconds")
        .and_then(Value::as_u64)
        .unwrap_or(crate::pairing::DEFAULT_TTL_SECS);
    let label = params.get("label").and_then(Value::as_str).map(str::to_owned);
    let url = match params.get("url").and_then(Value::as_str) {
        Some(url) => url.to_owned(),
        None => default_url(hub).await?,
    };
    if !crate::pairing::transport_ok(&url) {
        return Err(RpcError::invalid_params(format!(
            "a ticket is redeemed only over wss://, or ws:// to a loopback host; {url:?} is neither"
        )));
    }
    let (ticket, record) =
        hub.pairing.mint(role, ttl, label, url.clone(), crate::pairing::machine_name())?;
    Ok(json!({
        "ticket": ticket.encode(),
        "id": record.id,
        "role": role.as_str(),
        "label": record.label,
        "url": url,
        "minter": ticket.minter,
        "expires_at": super::iso(record.expires_ms),
        "expires_at_unix": record.expires_ms / 1000,
    }))
}

/// The listener's own URL, when it listens on loopback (reached through an
/// ssh tunnel or a TLS terminator on this machine); otherwise the caller
/// must name the `wss://` URL the other machine dials.
async fn default_url(hub: &Hub) -> Result<String, RpcError> {
    let cfg = hub.config.read().await;
    let Some(listen) = cfg.web_listener().map(|w| w.listen.clone()) else {
        return Err(RpcError::invalid_params(
            "this daemon has no WebSocket listener to redeem a ticket on; start it with one (acpmux daemon start --listen 127.0.0.1:47811)",
        ));
    };
    let url = format!("ws://{listen}");
    if crate::pairing::transport_ok(&url) {
        Ok(url)
    } else {
        Err(RpcError::invalid_params(format!(
            "the listener is {listen}, not loopback: pass --url with the wss:// address the other machine dials"
        )))
    }
}

async fn revoke(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let key = params
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("id is required"))?;
    let reply = hub.pairing.revoke(key)?;
    // Its Full-access setting ends with it: no chat stays out of its policy's mode.
    if reply.pointer("/revoked/kind").and_then(Value::as_str) == Some("device") {
        hub.hold_policies_again().await;
    }
    // A machine this daemon drove (role daemon) is also no longer its peer.
    if reply.pointer("/revoked/kind").and_then(Value::as_str) == Some("device")
        && reply.pointer("/revoked/role").and_then(Value::as_str) == Some("daemon")
        && let Some(name) = reply.pointer("/revoked/name").and_then(Value::as_str)
    {
        let _ = hub.remove_peer(name).await;
    }
    Ok(reply)
}

fn issue(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let role = role_param(params)?;
    if role == Role::Daemon {
        return Err(RpcError::invalid_params("issue a client, read-only or phone credential"));
    }
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("name is required"))?;
    // A phone's credential names the device its Full-access setting covers, and a new one
    // takes over that setting: an agent on this machine must never hold one.
    if role == Role::Phone && !conn.is_person() {
        return Err(crate::hub::person::person_required("issuing a phone's credential"));
    }
    let (device, token) = match role {
        Role::Phone => hub.pairing.issue_phone(name)?,
        _ => hub.pairing.issue(name, role)?,
    };
    Ok(json!({"deviceId": device.id, "name": device.name, "role": role.as_str(), "token": token}))
}
