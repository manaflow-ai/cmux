//! Cache-only agent inventory of THIS machine, over the trusted native
//! daemon carrier (local, SSH or Cloud). The conversations-only relay never
//! admits this verb. No client-selected socket, machine or control params.

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::agent_session_attach::agent_session_link::{AcpmuxLink, LinkError};
use super::responses::send_response;
use super::{MessageWriter, Response};
use crate::mux::Mux;

pub(super) const CAPABILITY: &str = "agent-inventory-v1";
const MAX_READS: usize = 8;
const MAX_HARNESSES: usize = 256;
const CALL_TIMEOUT: Duration = Duration::from_secs(2);

/// Holds one bounded worker until completion, failed spawn or unwinding.
struct ReadSlot(Arc<Mux>);

impl Drop for ReadSlot {
    fn drop(&mut self) {
        self.0.control_clients.agent_sessions.inventory_reads.fetch_sub(1, Ordering::AcqRel);
    }
}

#[derive(Debug)]
enum Failure {
    NotTrusted,
    BadRequest,
    Unavailable,
    Unsupported,
    Busy,
    InvalidResponse,
}

impl Failure {
    fn code(&self) -> &'static str {
        match self {
            Self::NotTrusted => "agent_inventory.not_trusted",
            Self::BadRequest => "agent_inventory.bad_request",
            Self::Unavailable => "agent_inventory.unavailable",
            Self::Unsupported => "agent_inventory.unsupported",
            Self::Busy => "agent_inventory.busy",
            Self::InvalidResponse => "agent_inventory.invalid_response",
        }
    }
}

/// Only `cmd` and the response correlation id are admitted. Trust is checked
/// before params, and unknown fields never reach the owner's acpmux.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("agent-inventory") {
        return None;
    }
    let Ok(Value::Object(mut fields)) = serde_json::from_str::<Value>(message) else {
        return None;
    };
    if fields.remove("cmd").as_ref().and_then(Value::as_str) != Some("agent-inventory") {
        return None;
    }
    let id = fields.remove("id");
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Some(reply(writer, id, Err(Failure::NotTrusted)));
    }
    if !fields.is_empty() {
        return Some(reply(writer, id, Err(Failure::BadRequest)));
    }
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return Some(reply(writer, id, Err(Failure::Unavailable)));
    };
    if mux
        .control_clients
        .agent_sessions
        .inventory_reads
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| (n < MAX_READS).then_some(n + 1))
        .is_err()
    {
        return Some(reply(writer, id, Err(Failure::Busy)));
    }
    let slot = ReadSlot(mux.clone());
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let spawned = std::thread::Builder::new()
        .name("mux-agent-inventory".into())
        .stack_size(256 * 1024)
        .spawn(move || {
            let result = read(&socket);
            drop(slot);
            reply(&worker_writer, worker_id, result);
        });
    if spawned.is_err() {
        return Some(reply(writer, id, Err(Failure::Busy)));
    }
    Some(true)
}

fn read(socket: &Path) -> Result<Value, Failure> {
    // Never use agent_session_start::connect: a read must not start or
    // hand off acpmux. Nothing listening is unavailable, not an empty inventory.
    let link = AcpmuxLink::connect(socket, |_| {}).map_err(|_| Failure::Unavailable)?;
    let initialized = link
        .call(
            "initialize",
            json!({"protocolVersion":1,
        "clientInfo":{"name":"cmux-machine-inventory","version":"1"},
        "clientCapabilities":{}}),
            CALL_TIMEOUT,
        )
        .map_err(|_| Failure::Unavailable)?;
    let supported = initialized
        .pointer("/_meta/acpmux/features")
        .and_then(Value::as_array)
        .is_some_and(|features| {
            features.iter().all(Value::is_string)
                && features.iter().any(|value| value.as_str() == Some("harnessInventory"))
        });
    if !supported {
        return Err(Failure::Unsupported);
    }
    // Old acpmux builds ignore view and can check or update on this method.
    // Negotiate first, on this same link, and never fall back to legacy health.
    let result = link
        .call("_acpmux/harness/health", json!({"view":"inventory"}), CALL_TIMEOUT)
        .map_err(|error| match error {
            LinkError::MethodNotFound(_) => Failure::Unsupported,
            _ => Failure::Unavailable,
        })?;
    let inventory: Inventory =
        serde_json::from_value(result).map_err(|_| Failure::InvalidResponse)?;
    if !inventory.valid() {
        return Err(Failure::InvalidResponse);
    }
    // Reserialize the allowlisted DTO: future diagnostics and command fields
    // remain private even if the owner accidentally includes them.
    serde_json::to_value(inventory).map_err(|_| Failure::InvalidResponse)
}

#[derive(Deserialize, Serialize)]
struct Inventory {
    view: View,
    cached: bool,
    harnesses: Vec<Harness>,
}

#[derive(Deserialize, Serialize)]
enum View {
    #[serde(rename = "inventory")]
    Inventory,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Harness {
    id: String,
    channel: String,
    version: Option<String>,
    latest: Option<String>,
    latest_checked_at: Option<u64>,
    outdated: bool,
    auth: String,
    checked_at: u64,
}

impl Inventory {
    fn valid(&self) -> bool {
        self.cached
            && self.harnesses.len() <= MAX_HARNESSES
            && self.harnesses.iter().all(|row| {
                !row.id.is_empty()
                    && row.id.len() <= 128
                    && row
                        .id
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
                    && [
                        "npm",
                        "bun",
                        "brew",
                        "brewCask",
                        "native",
                        "launcher",
                        "standalone",
                        "missing",
                    ]
                    .contains(&row.channel.as_str())
                    && ["signedIn", "signedOut", "unknown"].contains(&row.auth.as_str())
                    && [&row.version, &row.latest]
                        .iter()
                        .all(|value| value.as_ref().is_none_or(|v| safe_version(v)))
                    && (!row.outdated || (row.version.is_some() && row.latest.is_some()))
            })
    }
}

fn safe_version(version: &str) -> bool {
    static VERSION: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r"^v?[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$")
            .expect("inventory version pattern") // crash-allow: constant pattern
    });
    version.len() <= 64 && VERSION.is_match(version)
}

fn reply(writer: &MessageWriter, id: Option<Value>, result: Result<Value, Failure>) -> bool {
    let (data, error_code) = match result {
        Ok(data) => (Some(data), None),
        Err(error) => (None, Some(error.code().to_string())),
    };
    send_response(
        writer,
        Response {
            id,
            ok: error_code.is_none(),
            data,
            error: error_code.clone(),
            error_code,
            error_delivery: None,
        },
    )
}
