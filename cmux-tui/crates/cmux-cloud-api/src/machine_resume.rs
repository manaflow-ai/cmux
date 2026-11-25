//! `resume_machine`: cmux-platform's `POST /v1/machines/{id}/resume` (`machines.resume`). The
//! daemon's sub VMs (acpmux `placement/sub_fork_run.rs`, RFD 0144 piece 7) call it on each fork
//! before they reach it: a request alone does not reliably wake a paused fork (the split drill,
//! run 45390380891: 8 of 20 first requests answered HTTP 502). A library call, not a daemon op.
//! Resuming a machine that already runs answers it as it is.

use serde_json::{Value, json};

use super::chat::is_path_id;
use super::previews::{answered, client};
use super::{Failure, Request};

/// A resume asks the provider to start the machine; it answers well under this.
const RESUME_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

/// Resume `machine`; answers its row (`TeamMachine`) as the platform gives it.
pub async fn resume_machine(request: &Request, machine: &str) -> Result<Value, Failure> {
    if !is_path_id(machine) {
        return Err(Failure::Transport("not a machine id".into()));
    }
    let client = client(request)?;
    let on =
        machine.parse().map_err(|_| Failure::Transport(format!("not a path id: {machine}")))?;
    let sent = async { client.machines_resume(&on).await.map(|r| json!(r.into_inner())) };
    answered(request, RESUME_TIMEOUT, format!("/v1/machines/{machine}/resume"), sent).await
}
