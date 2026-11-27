//! `_acpmux/machine_ports_call`: the TCP ports listening on another of the person's machines
//! (a dev server just started there), asked from this machine's own socket (`cmux machine NAME
//! ports`) and answered by that machine's machine-call service over the hub carrier
//! (`machine_call_service.rs` [`PORTS_LIST`](crate::machine_call_service::PORTS_LIST)), behind
//! the same signed-in-machines grant as its file and Computer Use calls.
//!
//! Default deny, as `machine_files_relay.rs`: only the local unix socket may send one; a peer, a
//! paired device, the web or the app's own connection is refused. The answer is port numbers
//! only: `{"ports":[{"port":N}]}`.

use std::sync::Arc;

use serde_json::{Value, json};

use super::Conn;
use super::computer_use_relay::{Admission, admit};
use crate::hub::Hub;
use crate::rpc::RpcError;

/// How long a listing may take: one table read on the far machine, and the way there.
#[cfg(feature = "hub-carrier")]
const CALL_WAIT: std::time::Duration = std::time::Duration::from_secs(15);

fn refused(code: &str, message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"code": code}))
}

/// The machine a listing names.
pub(super) fn parse(params: &Value) -> Result<String, RpcError> {
    let machine = params.get("machine").and_then(Value::as_str).unwrap_or_default().trim();
    if machine.is_empty() || machine.len() > 256 || machine.chars().any(char::is_control) {
        return Err(refused("invalid_arguments", "name a machine"));
    }
    Ok(machine.to_owned())
}

/// Only an agent or the CLI on this machine's own socket may ask another machine.
pub(super) fn admitted(conn: &Conn) -> Result<(), RpcError> {
    if matches!(admit(conn.origin, conn.auth, None), Admission::Forward) {
        return Ok(());
    }
    Err(refused("machine_call_denied", "only this machine's own socket may ask another machine"))
}

pub(super) async fn call(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    admitted(conn)?;
    let machine = parse(params)?;
    #[cfg(feature = "hub-carrier")]
    if let Some(key) = crate::machine_call_service::machine_key(&hub.mesh_book_machines(), &machine)
    {
        return crate::machine_call_service::request(
            hub,
            &key,
            crate::machine_call_service::PORTS_LIST,
            json!({}),
            CALL_WAIT,
        )
        .await;
    }
    let _ = hub;
    Err(refused(
        "unknown_machine",
        format!("no signed-in machine named {machine:?}; `cmux machines` lists them"),
    ))
}

#[cfg(test)]
#[path = "machine_ports_relay_tests.rs"]
mod tests;
