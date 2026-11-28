//! The calls that reach another of the person's machines, split out of `requests.rs`'s
//! dispatch (a pure move): Computer Use (`computer_use_relay.rs`), a file or command action
//! (`machine_files_relay.rs`) and its listening ports (`machine_ports_relay.rs`).

use std::sync::Arc;

use serde_json::Value;

use super::Conn;
use crate::hub::Hub;
use crate::rpc::{RpcError, method};

/// Whether `m` is one of the calls [`dispatch`] answers.
pub(super) fn handles(m: &str) -> bool {
    matches!(
        m,
        method::MUX_COMPUTER_USE_CALL
            | method::MUX_COMPUTER_USE_MACHINES
            | method::MUX_COMPUTER_USE_STATE
            | method::MUX_MACHINE_FILES_CALL
            | method::MUX_MACHINE_PORTS_CALL
    )
}

/// Answers a call [`handles`] took.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Conn,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    match m {
        method::MUX_COMPUTER_USE_CALL => super::computer_use_relay::call(hub, conn, params).await,
        method::MUX_COMPUTER_USE_MACHINES => super::computer_use_relay::machines(hub, conn).await,
        method::MUX_COMPUTER_USE_STATE => super::computer_use_relay::state(hub, conn).await,
        method::MUX_MACHINE_FILES_CALL => super::machine_files_relay::call(hub, conn, params).await,
        method::MUX_MACHINE_PORTS_CALL => super::machine_ports_relay::call(hub, conn, params).await,
        _ => Err(RpcError::new(-32601, format!("not a machine relay call: {m}"))),
    }
}
