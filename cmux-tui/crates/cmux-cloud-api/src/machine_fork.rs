//! `machine.fork`: cmux-platform's `POST /v1/machines/{id}/fork` (`machines.fork`), a running
//! copy of a Cloud machine, memory and disk, made by the carrier's snapshot then restore. The
//! copy starts from the parent's files, processes and warm caches at that instant, so a new
//! session or sub-agent placed on it needs no clone, install or warm build (RFD 0168, "Forking
//! is the primitive"). Only the machine's creator may fork it; the copy is billed to the caller
//! from its first running second, like any machine they made.
//!
//! Args: `machine` (the parent), `clientKey` (1 to 128 characters; a retry with the same key
//! answers the same copy), optional `visibility` (`private` or `team`; the platform keeps a
//! private parent's copy private). Answers the platform's `TeamMachine` for the copy.

use serde_json::{Map, Value, json};

use super::chat::is_path_id;
use super::previews::{answered, client};
use super::{Failure, Request, optional_text, text};

/// A fork is a snapshot plus a restore on the carrier: about 6.4 s on staging (cmux-platform
/// `docs/agent-vm-lifecycle.md`), with a long tail on a large memory image.
const FORK_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(180);

/// The sizes a fork can start at, smallest first: the platform's chat ladder (cmux-platform
/// `Admission.ts` `CHAT_SIZE_NAMES`).
pub const FORK_SIZES: &[&str] = &["sm", "md", "lg", "xl", "2xl"];

/// The longest `clientKey` the platform takes.
const MAX_CLIENT_KEY: usize = 128;

pub async fn fork_machine(request: &Request, args: &Map<String, Value>) -> Result<Value, Failure> {
    let machine = text(args, "machine")?;
    if !is_path_id(machine) {
        return Err(Failure::Transport("not a machine id".into()));
    }
    let key = text(args, "clientKey")?;
    if key.is_empty() || key.chars().count() > MAX_CLIENT_KEY {
        return Err(Failure::Transport("clientKey must be 1 to 128 characters".into()));
    }
    let visibility = match optional_text(args, "visibility") {
        None => None,
        Some(v @ ("private" | "team")) => Some(v),
        Some(other) => {
            return Err(Failure::Transport(format!(
                "visibility must be private or team, not {other:?}"
            )));
        }
    };
    // A ladder size the copy starts at, never smaller than the machine (RFD 0144 piece 8).
    let size = match optional_text(args, "size") {
        None => None,
        Some(s) if FORK_SIZES.contains(&s) => Some(s),
        Some(other) => {
            return Err(Failure::Transport(format!(
                "size must be one of {}, not {other:?}",
                FORK_SIZES.join(", ")
            )));
        }
    };
    let mut body = json!({ "clientKey": key });
    if let Some(o) = body.as_object_mut() {
        if let Some(v) = visibility {
            o.insert("visibility".into(), json!(v));
        }
        if let Some(s) = size {
            o.insert("size".into(), json!(s));
        }
    }
    let body: cmux_cloud_client::types::MachinesForkBody = serde_json::from_value(body)
        .map_err(|e| Failure::Transport(format!("machine.fork body: {e}")))?;
    let client = client(request)?;
    let on =
        machine.parse().map_err(|_| Failure::Transport(format!("not a path id: {machine}")))?;
    let sent = async { client.machines_fork(&on, &body).await.map(|r| json!(r.into_inner())) };
    answered(request, FORK_TIMEOUT, format!("/v1/machines/{machine}/fork"), sent).await
}
