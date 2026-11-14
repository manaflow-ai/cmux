//! The pushed state of the Cloud machines the app shows (Leo, 2026-11-05: "yes" to a
//! per-machine state object so the app stops polling): one WebSocket per machine,
//! `GET /v1/cloud/machines/{id}/state` on the platform Worker (cmux-platform `MachineState`,
//! protocol `cmux.machine-state/1`). The app's `CloudMachineStatePush` holds the sockets; what a
//! frame means, which machines get a socket and how long a closed one waits are here.

use serde::Serialize;
use serde_json::Value;

use crate::changes::newer_revision;
use crate::record::{self, Machine, Status};

/// The first reconnect wait; each failure doubles it up to [`MAX_BACKOFF_MS`].
pub const FIRST_BACKOFF_MS: u64 = 500;
pub const MAX_BACKOFF_MS: u64 = 30_000;
/// An open socket sends [`PING`] this often, so no proxy closes it for being quiet; the
/// platform's runtime answers `pong` without waking the object.
pub const KEEPALIVE_MS: u64 = 30_000;
pub const PING: &str = r#"{"v":1,"t":"ping"}"#;

/// Whether `id` is a Worker machine id (`vm_` and 20 lowercase letters or digits): only those
/// have a state socket.
pub fn valid_id(id: &str) -> bool {
    id.strip_prefix("vm_").is_some_and(|rest| {
        rest.len() == 20
            && rest.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
    })
}

/// The state socket's URL for `machine` under `base` (the platform origin): `ws` for an `http`
/// base, else `wss`. None for a machine without a socket or a base without a scheme.
pub fn state_url(base: &str, machine: &str) -> Option<String> {
    if !valid_id(machine) {
        return None;
    }
    let (scheme, rest) = base.split_once("://")?;
    let scheme = if scheme == "http" { "ws" } else { "wss" };
    Some(format!("{scheme}://{}/v1/cloud/machines/{machine}/state", rest.trim_end_matches('/')))
}

/// Whether a listed `incoming` record replaces the last one known (`last`): unless the known
/// one is newer (a frame that answered first).
pub fn keeps_listed(last: Option<&Machine>, incoming: &Machine) -> bool {
    last.is_none_or(|last| {
        !newer_revision(last.server_revision.as_deref(), incoming.server_revision.as_deref())
    })
}

/// What one frame of `machine`'s socket means.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "action")]
pub enum Frame {
    /// Not this machine's, not a frame this client reads, or older than what is shown.
    Ignore,
    /// A new record: forward the frame to the Cloud app server first, then show `record`.
    State { forward: Value, record: Machine },
    /// The machine is gone for good: forward the frame, close the socket, and show `record`
    /// (the last one known, destroyed) when there was one.
    Removed { forward: Value, record: Option<Machine> },
}

/// The frame `text` from `machine`'s socket, over the last record shown (`last`).
pub fn frame(machine: &str, text: &str, last: Option<&Machine>) -> Frame {
    let Ok(value) = serde_json::from_str::<Value>(text) else { return Frame::Ignore };
    if value.get("machine").and_then(Value::as_str) != Some(machine) {
        return Frame::Ignore;
    }
    match value.get("t").and_then(Value::as_str) {
        Some("state") => {
            let Some(shown) = value
                .get("state")
                .and_then(|state| state.get("record"))
                .and_then(record::from_next)
            else {
                return Frame::Ignore;
            };
            // A record older than one already shown (a read that answered first) is not shown again.
            if last.is_some_and(|known| {
                newer_revision(known.server_revision.as_deref(), shown.server_revision.as_deref())
            }) {
                return Frame::Ignore;
            }
            Frame::State { forward: value, record: shown }
        }
        Some("removed") => {
            let record = last.cloned().map(|mut gone| {
                gone.status = Status::Destroyed;
                gone
            });
            Frame::Removed { forward: value, record }
        }
        _ => Frame::Ignore,
    }
}

/// Whether `apps-team-event` answered that a Cloud app server took the frame (`{servers: N}`,
/// N > 0). A reply with no server is not a hand-off: the machine stays on reads.
pub fn handed_off(reply: Option<&Value>) -> bool {
    reply
        .and_then(|reply| reply.get("servers"))
        .and_then(Value::as_f64)
        .is_some_and(|servers| servers > 0.0)
}

/// The wait after a socket closed: the first backoff again when it delivered frames
/// (`opened`), else `current_ms`; the next wait doubles, capped. Returns `(wait, next)`.
pub fn backoff(current_ms: u64, opened: bool) -> (u64, u64) {
    let wait = if opened { FIRST_BACKOFF_MS } else { current_ms };
    (wait, wait.saturating_mul(2).min(MAX_BACKOFF_MS))
}

#[cfg(test)]
mod tests;
