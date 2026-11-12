//! Computer Use on the person's other machines, over the acpmux peer link
//! they already set up (`acpmux peer add`, or a pairing ticket): no new
//! listener, no new credential.
//!
//! ```text
//! agent -> acpmux computer-use-mcp (machine B)       this machine, A
//!       -> _acpmux/computer_use_call on A's unix socket
//!       -> the peer link to B (its peer token or A's device credential)
//!       -> _acpmux/computer_use_call on B, served as Origin::Peer
//!       -> B's cmux-tui daemon (computer-use-endpoint) -> B's worker
//! ```
//!
//! Policy (default deny; the "Remote CLI relay" rule in the root CLAUDE.md):
//!
//! - Two methods only: [`method::MUX_COMPUTER_USE_CALL`] and
//!   [`method::MUX_COMPUTER_USE_MACHINES`] (plus the peer-only state read,
//!   [`method::MUX_COMPUTER_USE_STATE`]). Nothing here spawns a process,
//!   reads or writes a path, or takes a command-bearing param: a call names
//!   one catalog tool (`cmux_computer_use::tools::find`) and its arguments,
//!   which B's worker validates and runs under B's own Computer Use policy.
//! - The local unix socket may send a call on to a named, configured peer;
//!   it never runs one here (the bridge reaches this machine's worker itself).
//! - A peer connection may run a call here only when it proved B's peer
//!   token or a `client` device credential the person issued on B: both mean
//!   the person let that machine drive this daemon. The Web listener, the
//!   app pane, a phone and a read-only machine are refused, whatever they send.
//! - The origin the worker sees comes from that proof, never from the
//!   request: `{"kind":"remote","machine":<the device's name, or "peer">,
//!   "same_account":true}`. Any `origin` or `machine` in the params is
//!   refused, so a call never hops on to a third machine. A remote origin
//!   never gets more than a local one (`policy::decide`: remote adds
//!   refusals only), and B's `computerUse.allowOwnMachines` can refuse it.
//! - The call runs in a session of its own on B (`remote:<machine>:<key>`),
//!   so it never shares a session grant with one of B's own agents.
//! - Listing machines is local only: a remote caller never learns B's peers.

use std::sync::Arc;

use cmux_computer_use::tools;
use serde_json::{Value, json};

use super::conn_auth::ConnAuth;
use super::{Conn, Origin};
use crate::computer_use::client::{Caller, Outcome, SocketDaemon};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};

/// How long `computer_use_machines` waits for each peer's state.
const STATE_WAIT: std::time::Duration = std::time::Duration::from_secs(3);

/// Who may run a call here, from the connection's proof.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Admission {
    /// The local unix socket: may send a call on to a peer.
    Forward,
    /// A machine the person let drive this daemon, by the name we know it by.
    Run {
        machine: String,
    },
    Refused(&'static str),
}

/// The paired device behind a connection: its name and role, unless revoked.
pub(super) struct DeviceRecord {
    pub name: String,
    pub role: String,
}

/// The admission rule, as a pure function of what the transport proved.
pub(super) fn admit(origin: Origin, auth: ConnAuth, device: Option<&DeviceRecord>) -> Admission {
    match (origin, auth) {
        (Origin::Local, ConnAuth::LocalSocket) => Admission::Forward,
        (Origin::Peer, ConnAuth::PeerToken) => Admission::Run { machine: "peer".into() },
        (Origin::Peer, ConnAuth::Device) => match device {
            Some(d) if d.role == "client" => Admission::Run { machine: machine_label(&d.name) },
            Some(_) => {
                Admission::Refused("only a machine paired as a client may use Computer Use here")
            }
            None => Admission::Refused("the paired machine is unknown or revoked"),
        },
        (Origin::Web | Origin::LocalApp, _) => {
            Admission::Refused("Computer Use is not reachable from this connection")
        }
        _ => Admission::Refused("this connection proved no machine of the person's"),
    }
}

/// A device name as the person sees it, without control characters.
fn machine_label(name: &str) -> String {
    let name: String = name.chars().filter(|c| !c.is_control()).take(64).collect();
    if name.trim().is_empty() { "peer".into() } else { name }
}

fn refused(code: &str, message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"code": code}))
}

/// The checked parts of a call: one catalog tool, object arguments, no
/// `machine` or `origin` for the runner.
pub(super) struct CallParams {
    pub machine: Option<String>,
    pub name: String,
    pub arguments: Value,
    pub session: String,
    pub label: String,
    pub call_id: String,
    /// The agent cursor's tag on the calling machine (`CallContext::tag`), empty for none.
    pub tag: String,
}

pub(super) fn parse(params: &Value) -> Result<CallParams, RpcError> {
    let text = |key: &str, max: usize| -> Result<String, RpcError> {
        let value = params[key].as_str().unwrap_or_default().trim();
        if value.len() > max || value.chars().any(char::is_control) {
            return Err(refused("invalid_arguments", format!("{key} is not valid")));
        }
        Ok(value.to_owned())
    };
    if params.get("origin").is_some() {
        return Err(refused("computer_use_remote_denied", "a call never names its own origin"));
    }
    let name = text("name", 64)?;
    let tool = tools::find(&name)
        .ok_or_else(|| refused("unknown_tool", format!("unknown Computer Use tool {name:?}")))?;
    if tool.name == "list_machines" {
        return Err(refused(
            "computer_use_remote_denied",
            "list_machines runs on the caller's machine",
        ));
    }
    let arguments = match params.get("arguments") {
        None | Some(Value::Null) => json!({}),
        Some(Value::Object(map)) => {
            if map.contains_key("machine") || map.contains_key("origin") {
                return Err(refused(
                    "computer_use_remote_denied",
                    "a call runs on one machine only",
                ));
            }
            Value::Object(map.clone())
        }
        Some(_) => return Err(refused("invalid_arguments", "arguments must be an object")),
    };
    let machine = Some(text("machine", 256)?).filter(|m| !m.is_empty());
    let session = text("session", 256)?;
    let call_id = text("call_id", 128)?;
    if session.is_empty() || call_id.is_empty() {
        return Err(refused("invalid_arguments", "session and call_id are required"));
    }
    Ok(CallParams {
        machine,
        name,
        arguments,
        session,
        label: text("label", 120)?,
        call_id,
        tag: text("tag", 240)?,
    })
}

fn device_record(hub: &Hub, id: Option<&str>) -> Option<DeviceRecord> {
    let id = id?;
    let list = hub.pairing.list();
    let device = list["devices"].as_array()?.iter().find(|d| d["id"] == id)?;
    if !device["revoked_at"].is_null() {
        return None;
    }
    Some(DeviceRecord {
        name: device["name"].as_str().unwrap_or_default().to_owned(),
        role: device["role"].as_str().unwrap_or_default().to_owned(),
    })
}

/// An RpcError from the peer link, with `code: unreachable` when the call
/// should be retried (the link is down or the answer did not come).
fn link_error(e: RpcError) -> RpcError {
    if e.data.as_ref().and_then(|d| d.get("code")).is_some_and(Value::is_string) {
        return e;
    }
    let message = e.message.clone();
    let data = json!({"code": "unreachable", "link": e.data});
    RpcError::new(e.code, message).with_data(data)
}

/// `_acpmux/computer_use_call`.
pub(super) async fn call(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let device = device_record(hub, conn.device.as_deref());
    let call = parse(params)?;
    match admit(conn.origin, conn.auth, device.as_ref()) {
        Admission::Refused(why) => Err(refused("computer_use_remote_denied", why)),
        Admission::Forward => {
            let Some(machine) = call.machine else {
                return Err(refused(
                    "invalid_arguments",
                    "name a machine; this machine's own calls go to its worker directly",
                ));
            };
            let peer = hub.peer_by_name(&machine).ok_or_else(|| {
                refused(
                    "unknown_machine",
                    format!("no machine named {machine:?}; see list_machines"),
                )
            })?;
            let onward = json!({
                "name": call.name,
                "arguments": call.arguments,
                "session": call.session,
                "label": call.label,
                "call_id": call.call_id,
                "tag": call.tag,
            });
            peer.request(method::MUX_COMPUTER_USE_CALL, onward).await.map_err(link_error)
        }
        Admission::Run { machine } => {
            if call.machine.is_some() {
                return Err(refused(
                    "computer_use_remote_denied",
                    "a call runs on one machine only",
                ));
            }
            // A machine joined to a team runs another machine's call only with
            // its person's control consent there.
            if crate::cli::cloud_join::require_joined_consent("control").is_err() {
                return Err(refused(
                    "computer_use_consent_required",
                    "this machine needs its person's control consent before another machine may use it",
                ));
            }
            let origin = json!({"kind": "remote", "machine": machine, "same_account": true});
            let session = format!("remote:{machine}:{}", call.session);
            let label = if call.label.is_empty() {
                format!("An agent on {machine}")
            } else {
                format!("{} on {machine}", call.label)
            };
            let outcome = tokio::task::spawn_blocking(move || {
                let caller =
                    Caller::new(SocketDaemon::from_env(), session, label).with_origin(origin);
                caller.set_cursor_tag(&call.tag);
                caller.call(&call.name, &call.arguments, &call.call_id)
            })
            .await
            .map_err(|e| RpcError::internal(format!("the call stopped: {e}")))?;
            Ok(match outcome {
                Outcome::Output(out) => json!({"result": out.to_json()}),
                Outcome::Off(reason) => json!({"state": "off", "reason": reason}),
                Outcome::Failed { code, message } => {
                    let retry = code == "computer_use_unavailable";
                    return Err(refused(if retry { "unreachable" } else { &code }, message));
                }
            })
        }
    }
}

/// `_acpmux/computer_use_state` (peer only): whether Computer Use is on here.
pub(super) async fn state(hub: &Arc<Hub>, conn: &Conn) -> Result<Value, RpcError> {
    let device = device_record(hub, conn.device.as_deref());
    match admit(conn.origin, conn.auth, device.as_ref()) {
        Admission::Run { .. } => {}
        Admission::Forward => {
            return Err(refused("invalid_arguments", "ask a peer, not this machine"));
        }
        Admission::Refused(why) => return Err(refused("computer_use_remote_denied", why)),
    }
    let data = tokio::task::spawn_blocking(|| {
        SocketDaemon::from_env().request(crate::computer_use::client::ENDPOINT_CMD, json!({}))
    })
    .await
    .map_err(|e| RpcError::internal(format!("the state read stopped: {e}")))?;
    Ok(match data {
        Ok(data) => json!({"state": data["state"].as_str().unwrap_or("unavailable")}),
        Err(_) => json!({"state": "unavailable"}),
    })
}

/// `_acpmux/computer_use_machines` (local only): the configured peers, with
/// whether Computer Use is on there.
pub(super) async fn machines(hub: &Arc<Hub>, conn: &Conn) -> Result<Value, RpcError> {
    if !matches!(admit(conn.origin, conn.auth, None), Admission::Forward) {
        return Err(refused("computer_use_remote_denied", "only this machine lists its machines"));
    }
    let mut rows = Vec::new();
    let mut asks = tokio::task::JoinSet::new();
    for summary in hub.peers() {
        let Some(name) = summary["name"].as_str().map(str::to_owned) else { continue };
        let connected = summary["connected"].as_bool().unwrap_or(false);
        match (connected, hub.peer_by_name(&name)) {
            (true, Some(peer)) => {
                asks.spawn(async move {
                    let state = tokio::time::timeout(
                        STATE_WAIT,
                        peer.request(method::MUX_COMPUTER_USE_STATE, json!({})),
                    )
                    .await;
                    let computer_use = match state {
                        Ok(Ok(v)) => v["state"].as_str().unwrap_or("unknown").to_owned(),
                        Ok(Err(e)) if e.message.contains("not found") => "unsupported".to_owned(),
                        Ok(Err(_)) => "refused".to_owned(),
                        Err(_) => "unknown".to_owned(),
                    };
                    json!({"name": name, "reachable": true, "computer_use": computer_use})
                });
            }
            _ => rows.push(json!({"name": name, "reachable": false, "computer_use": "unknown"})),
        }
    }
    while let Some(row) = asks.join_next().await {
        if let Ok(row) = row {
            rows.push(row);
        }
    }
    rows.sort_by_key(|r| r["name"].as_str().unwrap_or_default().to_owned());
    Ok(json!({"machines": rows}))
}

#[cfg(test)]
#[path = "computer_use_relay_tests.rs"]
mod tests;
