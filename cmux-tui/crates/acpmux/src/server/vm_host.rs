//! `_acpmux/vm_host {name?, on?}`: read or set whether a machine is a
//! dedicated agent VM (`hub/vm_host.rs`). Without `name` it is this machine;
//! with `name`, that connected peer, asked over its link (where it arrives as
//! the owner's peer daemon). Without `on` it only reads. Part of the request
//! handler (`requests.rs`).
//!
//! Never from a Web client, or a peer forwarding for one (`REMOTE_REFUSED`);
//! a peer's connection is never relayed on to another peer.

use super::{Conn, Origin};
use crate::hub::{Control, Hub, vm_host};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::sync::Arc;

/// The method name.
pub(super) const METHOD: &str = "_acpmux/vm_host";

pub(super) async fn handle(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    if super::remote_guard::control_of(conn.origin, conn.auth, params) == Control::Web {
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
    let Some(name) = params.get("name").and_then(Value::as_str) else {
        return match on {
            Some(on) => hub.set_vm_host(on).await,
            None => Ok(hub.vm_host_view().await),
        };
    };
    if conn.origin == Origin::Peer {
        return Err(RpcError::invalid_params("a peer's request is not relayed to another peer"));
    }
    let Some(peer) = hub.connected_peers().into_iter().find(|p| p.name == name) else {
        return Err(RpcError::invalid_params(format!(
            "no connected peer named {name:?}: `acpmux host ls` lists the peers"
        )));
    };
    let mut reply = peer.request(METHOD, json!({"on": on})).await?;
    reply["name"] = json!(name);
    Ok(reply)
}
