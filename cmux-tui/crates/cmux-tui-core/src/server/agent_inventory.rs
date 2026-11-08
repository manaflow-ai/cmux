//! Cached inventory and explicit registry refresh of THIS machine, over the trusted native
//! daemon carrier (local, SSH or Cloud). The conversations-only relay never
//! admits this verb. No client-selected socket, machine or control params.

#[path = "agent_inventory_watch.rs"]
pub(super) mod watch;

use crate::panic_free::JsonFields;
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
pub(super) const OWNER_CAPABILITY: &str = "agent-inventory-owner-v1";
pub(super) const REFRESH_CAPABILITY: &str = "agent-inventory-refresh-v1";
const MAX_READS: usize = 8;
const MAX_HARNESSES: usize = 256;
pub(super) const CALL_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Clone, Copy)]
enum ReadMode {
    Cached,
    Refresh,
}

impl ReadMode {
    fn feature(self) -> &'static str {
        match self {
            Self::Cached => "harnessInventory",
            Self::Refresh => "harnessInventoryRefresh",
        }
    }

    fn request(self) -> (&'static str, Value, Duration) {
        match self {
            Self::Cached => ("_acpmux/harness/health", json!({"view":"inventory"}), CALL_TIMEOUT),
            // The raw owner bounds a refresh at twenty seconds. No caller
            // chooses this timeout, method, params or a registry address.
            Self::Refresh => {
                ("_acpmux/harness/inventory/refresh", json!({}), Duration::from_secs(25))
            }
        }
    }

    fn failure(self, error: LinkError) -> Failure {
        match error {
            LinkError::MethodNotFound(_) => Failure::Unsupported,
            LinkError::Rpc(_, data) if matches!(self, Self::Refresh) => {
                match data.get("reason").and_then(Value::as_str) {
                    Some("harness_inventory.busy") => Failure::Busy,
                    Some("harness_inventory.unsupported") => Failure::Unsupported,
                    _ => Failure::Unavailable,
                }
            }
            LinkError::Busy if matches!(self, Self::Refresh) => Failure::Busy,
            _ => Failure::Unavailable,
        }
    }
}

/// Holds one bounded worker until completion, failed spawn or unwinding.
pub(super) struct ReadSlot(Arc<Mux>);

impl Drop for ReadSlot {
    fn drop(&mut self) {
        self.0.control_clients.agent_sessions.inventory_reads.fetch_sub(1, Ordering::AcqRel);
    }
}

#[derive(Debug, Clone, Copy)]
pub(super) enum Failure {
    NotTrusted,
    BadRequest,
    OwnerMismatch,
    Unavailable,
    Unsupported,
    Busy,
    InvalidResponse,
}

impl Failure {
    pub(super) fn code(&self) -> &'static str {
        match self {
            Self::NotTrusted => "agent_inventory.not_trusted",
            Self::BadRequest => "agent_inventory.bad_request",
            Self::OwnerMismatch => "agent_inventory.owner_mismatch",
            Self::Unavailable => "agent_inventory.unavailable",
            Self::Unsupported => "agent_inventory.unsupported",
            Self::Busy => "agent_inventory.busy",
            Self::InvalidResponse => "agent_inventory.invalid_response",
        }
    }
}

/// The owner fence (required for refresh) only verifies this daemon; it never selects or
/// connects to another machine. Trust precedes params and no client fields
/// reach the owner's acpmux.
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
    let mode = match fields.remove("cmd").as_ref().and_then(Value::as_str) {
        Some("agent-inventory") => ReadMode::Cached,
        Some("agent-inventory-refresh") => ReadMode::Refresh,
        _ => return None,
    };
    let id = fields.remove("id");
    if !mux.agent_carrier_allowed(client) {
        return Some(reply(writer, id, Err(Failure::NotTrusted)));
    }
    let expected_machine = fields.remove("expected_machine_id");
    if !fields.is_empty() || (matches!(mode, ReadMode::Refresh) && expected_machine.is_none()) {
        return Some(reply(writer, id, Err(Failure::BadRequest)));
    }
    if let Some(expected) = expected_machine {
        let Value::String(expected) = expected else {
            return Some(reply(writer, id, Err(Failure::BadRequest)));
        };
        let Ok(expected) = crate::resource::MachinePublicId::parse(expected) else {
            return Some(reply(writer, id, Err(Failure::BadRequest)));
        };
        if expected != mux.machine_public_id {
            return Some(reply(writer, id, Err(Failure::OwnerMismatch)));
        }
    }
    let Some(socket) = mux.control_clients.agent_sessions.socket() else {
        return Some(reply(writer, id, Err(Failure::Unavailable)));
    };
    let slot = match reserve(mux) {
        Ok(slot) => slot,
        Err(error) => return Some(reply(writer, id, Err(error))),
    };
    let worker_writer = writer.clone();
    let worker_id = id.clone();
    let owner_echo = matches!(mode, ReadMode::Refresh).then(|| mux.machine_public_id.clone());
    let spawned = std::thread::Builder::new()
        .name("mux-agent-inventory".into())
        .stack_size(256 * 1024)
        .spawn(move || {
            let result = read(&socket, mode).map(|mut value| {
                if let Some(machine) = owner_echo {
                    value.insert("machine", json!(machine));
                }
                value
            });
            drop(slot);
            reply(&worker_writer, worker_id, result);
        });
    if spawned.is_err() {
        return Some(reply(writer, id, Err(Failure::Busy)));
    }
    Some(true)
}

/// Reads, registry refresh and watch handshakes share one bounded worker budget, including
/// a cancelled connection whose Unix connect has not finished yet.
pub(super) fn reserve(mux: &Arc<Mux>) -> Result<ReadSlot, Failure> {
    if mux
        .control_clients
        .agent_sessions
        .inventory_reads
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| (n < MAX_READS).then_some(n + 1))
        .is_err()
    {
        return Err(Failure::Busy);
    }
    Ok(ReadSlot(mux.clone()))
}

pub(super) fn supports(initialized: &Value, capability: &str) -> bool {
    initialized.pointer("/_meta/acpmux/features").and_then(Value::as_array).is_some_and(
        |features| {
            features.iter().all(Value::is_string)
                && features.iter().any(|value| value.as_str() == Some(capability))
        },
    )
}

pub(super) fn valid_snapshot(value: &Value) -> bool {
    serde_json::from_value::<Inventory>(value.clone()).is_ok_and(|inventory| inventory.valid())
}

fn read(socket: &Path, mode: ReadMode) -> Result<Value, Failure> {
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
    if !supports(&initialized, mode.feature()) {
        return Err(Failure::Unsupported);
    }
    // Old builds can interpret health params as a probe/auto-update request.
    // Negotiate on this captured link and never fall back between modes.
    let (method, params, timeout) = mode.request();
    let result = link.call(method, params, timeout).map_err(|error| mode.failure(error))?;
    let mut inventory: Inventory =
        serde_json::from_value(result).map_err(|_| Failure::InvalidResponse)?;
    if !inventory.valid() {
        return Err(Failure::InvalidResponse);
    }
    // Unknown future families remain unknown. Never forward an arbitrary
    // new metadata string or infer a family from the profile id here.
    for row in &mut inventory.harnesses {
        if matches!(row.channel.as_str(), "launcher" | "missing")
            || row.family.as_deref().is_some_and(|family| {
                ![
                    "claude", "codex", "opencode", "pi", "chief", "gemini", "amp", "copilot",
                    "cursor",
                ]
                .contains(&family)
            })
        {
            row.family = None;
        }
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
    family: Option<String>,
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
    #[allow(clippy::expect_used, reason = "a constant regular expression that compiles")]
    static VERSION: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
        regex::Regex::new(r"^v?[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$")
            .expect("inventory version pattern") // crash-allow: constant pattern
    });
    version.len() <= 64 && VERSION.is_match(version)
}

pub(super) fn reply(
    writer: &MessageWriter,
    id: Option<Value>,
    result: Result<Value, Failure>,
) -> bool {
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
