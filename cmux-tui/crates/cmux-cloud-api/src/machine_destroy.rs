//! `destroy_machine`: cmux-platform's `DELETE /v1/machines/{id}` (`machines.destroy`). The
//! daemon's sub VMs (acpmux `placement/sub_fork.rs`, RFD 0144 piece 7) delete each fork they made
//! with it when the sub-agent ends. A library call, not a daemon op: nothing but the fork's own
//! owner calls it. A machine already gone (404) counts as deleted.

use serde_json::{Value, json};

use super::chat::is_path_id;
use super::previews::{answered, client};
use super::{Failure, Request};

/// A delete stops the machine and frees its disk; it answers well under this.
const DESTROY_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);

/// Delete `machine`. `Ok(true)`: deleted now; `Ok(false)`: it was already gone.
pub async fn destroy_machine(request: &Request, machine: &str) -> Result<bool, Failure> {
    if !is_path_id(machine) {
        return Err(Failure::Transport("not a machine id".into()));
    }
    let client = client(request)?;
    let on =
        machine.parse().map_err(|_| Failure::Transport(format!("not a path id: {machine}")))?;
    let sent = async { client.machines_destroy(&on).await.map(|r| json!(r.into_inner())) };
    match answered(request, DESTROY_TIMEOUT, format!("/v1/machines/{machine}"), sent).await {
        Ok(body) => Ok(body.get("deleted").and_then(Value::as_bool).unwrap_or(true)),
        Err(Failure::Http { status: 404, .. }) => Ok(false),
        Err(e) => Err(e),
    }
}
