//! An explicit cache subscription on one trusted native owner connection.
//! Only bounded invalidation receipts cross this carrier, never cache rows.
//! No acpmux starter, legacy health, reconnect or fallback path is used.
//!
//! Wire: the `agent-inventory-watch` command and the `agent-inventory-changed`
//! (background priority) and `agent-inventory-watch-ended` events in
//! spec/sdk-schema.json. This module's route ([`ROUTES`], server/routes.rs) decodes
//! the command as [`Command`], so check-sdk-schema.py reads its request fields from it
//! (scripts/handler_commands.py).

#[path = "agent_inventory_watch/state.rs"]
mod state;
pub(in crate::server) use state::Watches;

use crate::mux::Mux;
use crate::resource::MachinePublicId;
use crate::server::agent_inventory::{self, CALL_TIMEOUT, Failure};
use crate::server::agent_session_attach::agent_session_link::{AcpmuxLink, Inbound, LinkError};
use crate::server::command_args::present_non_null;
use crate::server::routes::{Route, RouteLine, RouteName};
use crate::server::{FrameStage, MessageWriter};
use crate::supervised::{self, Fatal, ShutdownBehavior};
use crate::thread_qos::ThreadType;
use serde::Deserialize;
use serde_json::{Map, Value, json};
use std::sync::Arc;

pub(in crate::server) const CAPABILITY: &str = "agent-inventory-watch-v1";
pub(in crate::server) const FENCED_CAPABILITY: &str = "agent-inventory-watch-fence-v1";
pub(in crate::server) const ADMISSION_CAPABILITY: &str = "agent-inventory-watch-admission-v1";
const FEATURE: &str = "harnessInventoryWatch";
const WATCH: &str = "_acpmux/harness/inventory/watch";
const COMMAND: &str = "agent-inventory-watch";

/// The request [`handle`] serves; spec/sdk-schema.json types it.
#[derive(Deserialize)]
#[serde(tag = "cmd")]
enum Command {
    #[serde(rename = "agent-inventory-watch")]
    Watch(Params),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Params {
    expected_machine_id: String,
    enabled: bool,
    #[serde(default, deserialize_with = "present_non_null")]
    expected_watch_id: Option<String>,
    #[serde(default, deserialize_with = "present_non_null")]
    admission_receipt: Option<bool>,
}

enum Dispatch {
    Deferred,
    Value(Value),
    Sent(bool),
}

/// The `cmd` names this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[Route] = &[Route {
    names: &[RouteName::Exact(COMMAND)],
    stage: FrameStage::AgentInventoryWatch,
    entry: handle,
}];

/// The route's typed handler: the line's `cmd` named [`Command`], so it decodes the line
/// once and answers it. A line whose full decode fails is left to the `Command` parse
/// (`None`).
fn handle(line: &RouteLine<'_>) -> Option<bool> {
    let RouteLine { mux, client, message, writer, .. } = *line;
    let mut fields = crate::line_parses::parse::<Map<String, Value>>(message).ok()?;
    let id = fields.remove("id");
    let mut admission_receipt = false;
    let result = (|| {
        if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
            return Err(Failure::NotTrusted);
        }
        let Command::Watch(params) =
            serde_json::from_value(Value::Object(fields)).map_err(|_| Failure::BadRequest)?;
        let expected =
            MachinePublicId::parse(params.expected_machine_id).map_err(|_| Failure::BadRequest)?;
        if expected != mux.machine_public_id {
            return Err(Failure::OwnerMismatch);
        }
        let enabled = params.enabled;
        let expected_watch = match params.expected_watch_id {
            None => None,
            Some(value) if !enabled && valid_watch_id(&value) => Some(value),
            Some(_) => return Err(Failure::BadRequest),
        };
        let receipt = match params.admission_receipt {
            None => false,
            Some(value) if enabled => value,
            Some(_) => return Err(Failure::BadRequest),
        };
        if message.len() > 4096 {
            return Err(Failure::BadRequest);
        }
        admission_receipt = receipt;
        let watches = &mux.control_clients.agent_sessions.inventory_watches;
        if !enabled {
            watches.disconnect_matching(client, expected_watch.as_deref());
            return Ok(Dispatch::Value(json!({})));
        }
        if let Some(existing) = watches.get(client) {
            return existing.respond(id.clone()).map(Dispatch::Sent);
        }
        let (socket, generation) =
            mux.control_clients.agent_sessions.inventory_socket().ok_or(Failure::Unavailable)?;
        let slot = agent_inventory::reserve(mux)?;
        let watch = state::Watch::new(mux, client, socket, generation, writer.clone())?;
        watches.insert(watch.clone())?;
        let failure_watch = watch.clone();
        let worker_id = id.clone();
        let mux_for_refusal = Arc::downgrade(mux);
        let spawned = spawn_thread(move || {
            let result = start(&watch, worker_id.clone());
            drop(slot);
            match result {
                Ok(true) => {}
                Ok(false) => watch.stop(Failure::Unavailable, false),
                Err(error) => {
                    watch.stop(error, false);
                    refuse(
                        mux_for_refusal.upgrade().as_deref(),
                        client,
                        &watch.writer,
                        worker_id,
                        error,
                        receipt,
                    );
                }
            }
        });
        if spawned.is_err() {
            failure_watch.stop(Failure::Busy, false);
            return Err(Failure::Busy);
        }
        Ok(Dispatch::Deferred)
    })();
    Some(match result {
        Ok(Dispatch::Deferred) => true,
        Ok(Dispatch::Sent(keep_open)) => keep_open,
        Ok(Dispatch::Value(value)) => agent_inventory::reply(writer, id, Ok(value)),
        Err(error) => refuse(Some(mux), client, writer, id, error, admission_receipt),
    })
}

/// A capability-negotiated refusal proves absence only while holding the lease registry lock.
fn refuse(
    mux: Option<&Mux>,
    client: u64,
    writer: &MessageWriter,
    id: Option<Value>,
    error: Failure,
    opted_in: bool,
) -> bool {
    if opted_in
        && matches!(error, Failure::Unavailable | Failure::Unsupported | Failure::Busy)
        && let Some(mux) = mux
    {
        return mux.control_clients.agent_sessions.inventory_watches.refuse(
            client,
            &mux.machine_public_id,
            writer,
            id,
            error,
        );
    }
    agent_inventory::reply(writer, id, Err(error))
}

fn start(watch: &Arc<state::Watch>, id: Option<Value>) -> Result<bool, Failure> {
    if !watch.current_socket() {
        return Err(Failure::Unavailable);
    }
    let weak = Arc::downgrade(watch);
    let link = AcpmuxLink::connect(&watch.socket, move |inbound| {
        if let Some(watch) = weak.upgrade() {
            watch.inbound(inbound);
        }
    })
    .map_err(|_| Failure::Unavailable)?;
    watch.set_link(link.clone())?;
    let initialized = link.call("initialize", json!({"protocolVersion":1,
        "clientInfo":{"name":"cmux-machine-inventory-watch","version":"1"},"clientCapabilities":{}}),
        CALL_TIMEOUT).map_err(|_| Failure::Unavailable)?;
    if !agent_inventory::supports(&initialized, FEATURE) {
        return Err(Failure::Unsupported);
    }
    watch.negotiated()?;
    let initial =
        link.call(WATCH, json!({"enabled":true}), CALL_TIMEOUT).map_err(|error| match error {
            LinkError::MethodNotFound(_) => Failure::Unsupported,
            _ => Failure::Unavailable,
        })?;
    watch.activate(id, &initial)
}

/// Starts `body` on a `mux-inventory-watch` thread: a watcher, utility as
/// Chromium's kUtility, started through `spawn_raisable`
/// so a ranked lock can raise it.
fn spawn_thread(
    body: impl FnOnce() + Send + 'static,
) -> std::io::Result<supervised::SupervisedThread<()>> {
    supervised::spawn_raisable(
        "mux-inventory-watch",
        ThreadType::Utility.qos(),
        Fatal,
        ShutdownBehavior::Continue,
        body,
    )
}

fn revision(value: &Value) -> Result<u64, Failure> {
    if !agent_inventory::valid_snapshot(value) {
        return Err(Failure::InvalidResponse);
    }
    value.get("revision").and_then(Value::as_u64).ok_or(Failure::InvalidResponse)
}

fn valid_watch_id(value: &str) -> bool {
    value.strip_prefix("inventory_watch_").is_some_and(|suffix| {
        suffix.len() == 32
            && suffix.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    })
}

#[cfg(test)]
#[test]
fn watch_ids_are_the_schema_bound() {
    use crate::server::agent_inventory::schema;
    let id = format!("inventory_watch_{}", "0123456789abcdef".repeat(2));
    assert!(valid_watch_id(&id));
    assert!(!valid_watch_id(&format!("{id}0")));
    let bound = Some(id.len() as u64);
    assert_eq!(schema::max_bytes("AgentInventoryWatchActive", "watch_id"), bound);
    assert_eq!(schema::request_max_bytes("agent-inventory-watch", "expected_watch_id"), bound);
}

/// The watch thread is declared at the raisable class of Utility:
/// Utility where a lock can raise it.
#[cfg(test)]
#[test]
fn the_watch_thread_is_a_utility_thread() {
    let (release, released) = std::sync::mpsc::channel::<()>();
    let thread = spawn_thread(move || {
        let _ = released.recv();
    })
    .expect("the watch thread starts");
    crate::thread_qos::tests::assert_declared(
        "mux-inventory-watch",
        cmux_tui_platform::qos::raisable_class(ThreadType::Utility.qos()),
    );
    drop(release);
    thread.join().expect("the watch thread ends");
}
