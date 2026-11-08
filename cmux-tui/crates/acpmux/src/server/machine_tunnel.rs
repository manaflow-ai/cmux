//! `_acpmux/machine.tunnel.attach` and `.detach` (`crate::machine_tunnel`): only from
//! the app's own connection, the unix socket with the person proof, since each carries the
//! person's cmux access token (`token`) and changes this Mac's place on the team's mesh. A
//! shell, an agent, a page or a peer is refused before the token is read.

use std::sync::Arc;

use serde_json::Value;

use super::{Conn, Origin};
use crate::hub::Hub;
use crate::machine_tunnel::{self, Machine};
use crate::rpc::{RpcError, method};

pub(super) async fn dispatch(
    _hub: &Arc<Hub>,
    conn: &Conn,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(
        m,
        method::MUX_MACHINE_TUNNEL_ATTACH | method::MUX_MACHINE_TUNNEL_DETACH
    ) {
        return None;
    }
    if conn.origin != Origin::Local || !conn.is_person() {
        return Some(Err(crate::hub::person::person_required("changing this Mac's Cloud tunnel")));
    }
    Some(run(m, params).await)
}

async fn run(m: &str, params: &Value) -> Result<Value, RpcError> {
    let token = machine_tunnel::token(params)?;
    let machine = Machine::joined()?;
    machine_tunnel::attach(&machine, params, &token, m == method::MUX_MACHINE_TUNNEL_DETACH).await
}
