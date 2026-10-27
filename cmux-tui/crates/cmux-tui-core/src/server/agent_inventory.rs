//! Cached inventory and explicit registry refresh of THIS machine, over the trusted native
//! daemon carrier (local, SSH or Cloud). The conversations-only relay never
//! admits this verb. No client-selected socket, machine or control params.
//!
//! Wire: `agent-inventory` and `agent-inventory-refresh` in spec/sdk-schema.json (agents
//! family; the refresh is `background` priority because it waits on registries for
//! seconds). This module's route ([`ROUTES`], server/routes.rs) decodes them as
//! [`Command`] before the server's `Command` enum, so check-sdk-schema.py reads their
//! request fields from it (scripts/handler_commands.py).

#[path = "agent_inventory_watch.rs"]
pub(super) mod watch;

use crate::panic_free::JsonFields;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::agent_session_attach::agent_session_link::{AcpmuxLink, LinkError};
use super::command_args::present_non_null;
use super::responses::send_response;
use super::routes::{Route, RouteLine, RouteName};
use super::{FrameStage, MessageWriter, Response};
use crate::mux::Mux;

pub(super) const CAPABILITY: &str = "agent-inventory-v1";
pub(super) const OWNER_CAPABILITY: &str = "agent-inventory-owner-v1";
pub(super) const REFRESH_CAPABILITY: &str = "agent-inventory-refresh-v1";
const READ_COMMAND: &str = "agent-inventory";
const REFRESH_COMMAND: &str = "agent-inventory-refresh";
const MAX_READS: usize = 8;
const MAX_HARNESSES: usize = 256;
/// Spec `AgentInventoryChannel`.
const CHANNELS: [&str; 8] =
    ["npm", "bun", "brew", "brewCask", "native", "launcher", "standalone", "missing"];
/// Spec `AgentInventoryAuth`.
const AUTH: [&str; 3] = ["signedIn", "signedOut", "unknown"];
/// Spec `AgentInventoryFamily`: the CLI families forwarded as `family`; any other is null.
const FAMILIES: [&str; 9] =
    ["claude", "codex", "opencode", "pi", "chief", "gemini", "amp", "copilot", "cursor"];
pub(super) const CALL_TIMEOUT: Duration = Duration::from_secs(2);

/// The two requests [`handle`] serves; spec/sdk-schema.json types them.
#[derive(Deserialize)]
#[serde(tag = "cmd")]
enum Command {
    #[serde(rename = "agent-inventory")]
    Read(ReadParams),
    #[serde(rename = "agent-inventory-refresh")]
    Refresh(RefreshParams),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReadParams {
    #[serde(default, deserialize_with = "present_non_null")]
    expected_machine_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RefreshParams {
    expected_machine_id: String,
}

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

/// The `cmd` names this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[Route] = &[Route {
    names: &[RouteName::Exact(READ_COMMAND), RouteName::Exact(REFRESH_COMMAND)],
    stage: FrameStage::AgentInventory,
    entry: handle,
}];

/// The route's typed handler: the line's `cmd` named one of [`Command`], so it decodes
/// the line once and answers it. A line whose full decode fails is left to the `Command`
/// parse (`None`).
///
/// The owner fence (required for refresh) only verifies this daemon; it never selects or
/// connects to another machine. Trust precedes params and no client fields
/// reach the owner's acpmux.
fn handle(line: &RouteLine<'_>) -> Option<bool> {
    let RouteLine { mux, client, message, writer, .. } = *line;
    let mut fields = crate::line_parses::parse::<Map<String, Value>>(message).ok()?;
    let id = fields.remove("id");
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Some(reply(writer, id, Err(Failure::NotTrusted)));
    }
    let (mode, expected_machine) = match serde_json::from_value::<Command>(Value::Object(fields)) {
        Ok(Command::Read(params)) => (ReadMode::Cached, params.expected_machine_id),
        Ok(Command::Refresh(params)) => (ReadMode::Refresh, Some(params.expected_machine_id)),
        Err(_) => return Some(reply(writer, id, Err(Failure::BadRequest))),
    };
    if let Some(expected) = expected_machine {
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
            || row.family.as_deref().is_some_and(|family| !FAMILIES.contains(&family))
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
                    && CHANNELS.contains(&row.channel.as_str())
                    && AUTH.contains(&row.auth.as_str())
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

/// The reply DTOs are the schema's result types (spec/sdk-schema.json).
#[cfg(test)]
pub(super) mod schema {
    use std::collections::BTreeSet;

    use serde_json::Value;

    use super::{AUTH, CHANNELS, FAMILIES, Harness, Inventory, View};

    fn sdk_schema() -> Value {
        serde_json::from_str(include_str!("../../../../spec/sdk-schema.json"))
            .expect("spec/sdk-schema.json parses")
    }

    /// Member names of the schema's object type `name`.
    pub(in crate::server) fn type_fields(name: &str) -> BTreeSet<String> {
        let schema = sdk_schema();
        let fields = schema["types"][name]["fields"].as_object();
        fields.unwrap_or_else(|| panic!("spec type {name} is an object")).keys().cloned().collect()
    }

    fn enum_values(name: &str) -> Vec<String> {
        let schema = sdk_schema();
        let values = schema["types"][name]["values"].as_array();
        let values = values.unwrap_or_else(|| panic!("spec type {name} is an enum"));
        values.iter().filter_map(Value::as_str).map(str::to_owned).collect()
    }

    /// Member names of the schema event `name`'s payload.
    pub(in crate::server) fn event_fields(name: &str) -> BTreeSet<String> {
        let schema = sdk_schema();
        let fields = schema["events"][name]["payload"]["fields"].as_object();
        fields
            .unwrap_or_else(|| panic!("spec event {name} has an object payload"))
            .keys()
            .cloned()
            .collect()
    }

    /// `max_bytes` of member `field` of the schema object type `name`.
    pub(in crate::server) fn max_bytes(name: &str, field: &str) -> Option<u64> {
        sdk_schema()["types"][name]["fields"][field]["max_bytes"].as_u64()
    }

    /// `max_bytes` of request field `field` of the schema command `name`.
    pub(in crate::server) fn request_max_bytes(name: &str, field: &str) -> Option<u64> {
        sdk_schema()["commands"][name]["request"]["fields"][field]["max_bytes"].as_u64()
    }

    pub(in crate::server) fn keys(value: &Value) -> BTreeSet<String> {
        value.as_object().expect("an object").keys().cloned().collect()
    }

    #[test]
    fn reply_members_are_the_schema_result_fields() {
        let inventory = Inventory {
            view: View::Inventory,
            cached: true,
            harnesses: vec![Harness {
                id: "claude".into(),
                family: Some("claude".into()),
                channel: "npm".into(),
                version: Some("1.2.3".into()),
                latest: None,
                latest_checked_at: None,
                outdated: false,
                auth: "unknown".into(),
                checked_at: 1,
            }],
        };
        assert!(inventory.valid());
        let value = serde_json::to_value(&inventory).expect("serializes");
        assert_eq!(keys(&value), type_fields("AgentInventoryResult"));
        assert_eq!(keys(&value["harnesses"][0]), type_fields("AgentInventoryHarness"));
        // The refresh reply is the same object plus the owner echo `machine`.
        let mut refresh = type_fields("AgentInventoryResult");
        refresh.insert("machine".into());
        assert_eq!(refresh, type_fields("AgentInventoryRefreshResult"));
    }

    #[test]
    fn accepted_channels_and_auth_are_the_schema_enums() {
        assert_eq!(enum_values("AgentInventoryChannel"), CHANNELS);
        assert_eq!(enum_values("AgentInventoryAuth"), AUTH);
    }

    #[test]
    fn forwarded_families_are_the_schema_enum() {
        assert_eq!(enum_values("AgentInventoryFamily"), FAMILIES);
        let schema = sdk_schema();
        let family = &schema["types"]["AgentInventoryHarness"]["fields"]["family"];
        assert_eq!(family["type"]["name"], "AgentInventoryFamily");
        assert_eq!(family["nullable"], true);
    }
}
