//! `_acpmux/vm_host {name?, on?}`: read or set whether a machine is a
//! dedicated agent VM (`hub/vm_host.rs`). Without `name` it is this machine;
//! with `name`, that connected peer, asked over its link (where it arrives as
//! the owner's peer daemon). Without `on` it only reads. One file of the request
//! handler's methods (`methods/mod.rs`).
//!
//! Never from a Web client, or a peer forwarding for one (`REMOTE_REFUSED`),
//! and turned on only by the person's own clients (`vm_boundary::owner`): not
//! a paired machine's credential. A peer's connection is never relayed on to
//! another peer.

use crate::hub::{Control, Hub, vm_host};
use crate::rpc::RpcError;
use crate::server::{Conn, Origin};
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::sync::Arc;

/// The method name.
pub(in crate::server) const METHOD: &str = "_acpmux/vm_host";

pub(super) async fn handle(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    if crate::server::remote_guard::control_of(conn.origin, conn.auth, params) == Control::Web {
        return Err(RpcError::new(
            -32000,
            "vmHost is changed only from this machine, its cmux app, or its owner's own machine",
        )
        .with_data(json!({"reason": vm_host::REMOTE_REFUSED})));
    }
    let on = match params.get("on") {
        None | Some(Value::Null) => None,
        Some(Value::Bool(on)) => Some(*on),
        Some(_) => return Err(RpcError::invalid_params("on must be true or false")),
    };
    // Turning it back on lets the owner's boundary in again: only the person's own clients,
    // never a paired machine's credential or a peer forwarding one (`hub/vm_boundary.rs`).
    // Off only narrows.
    let control = crate::server::remote_guard::control_of(conn.origin, conn.auth, params);
    if on == Some(true) && !crate::hub::vm_boundary::owner(conn.auth, control, params) {
        return Err(RpcError::new(
            -32000,
            "vmHost is turned on only from this machine, its cmux app, or its owner's own machine",
        )
        .with_data(json!({"reason": vm_host::REMOTE_REFUSED})));
    }
    let Some(name) = params.get("name").and_then(Value::as_str) else {
        return match on {
            Some(on) => hub.set_vm_host(on).await,
            None => Ok(hub.vm_host_view().await),
        };
    };
    if conn.origin == Origin::Peer {
        return Err(RpcError::invalid_params("a peer's request is not relayed to another peer"));
    }
    let Some(peer) = hub.peer_by_name(name) else {
        return Err(RpcError::invalid_params(format!(
            "no peer named {name:?}: `acpmux machine ls` lists the peers"
        )));
    };
    let mut reply = crate::server::peer_targeted::request(&peer, METHOD, json!({"on": on})).await?;
    reply.set("name", json!(name));
    Ok(reply)
}
