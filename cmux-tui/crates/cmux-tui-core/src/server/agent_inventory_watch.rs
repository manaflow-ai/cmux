//! An explicit cache subscription on one trusted native owner connection.
//! Only bounded invalidation receipts cross this carrier, never cache rows.
//! No acpmux starter, legacy health, reconnect or fallback path is used.

#[path = "agent_inventory_watch/state.rs"]
mod state;
pub(in crate::server) use state::Watches;

use crate::mux::Mux;
use crate::resource::MachinePublicId;
use crate::server::MessageWriter;
use crate::server::agent_inventory::{self, CALL_TIMEOUT, Failure};
use crate::server::agent_session_attach::agent_session_link::{AcpmuxLink, Inbound, LinkError};
use serde_json::{Value, json};
use std::sync::Arc;

pub(in crate::server) const CAPABILITY: &str = "agent-inventory-watch-v1";
pub(in crate::server) const FENCED_CAPABILITY: &str = "agent-inventory-watch-fence-v1";
pub(in crate::server) const ADMISSION_CAPABILITY: &str = "agent-inventory-watch-admission-v1";
const FEATURE: &str = "harnessInventoryWatch";
const WATCH: &str = "_acpmux/harness/inventory/watch";

enum Dispatch {
    Deferred,
    Value(Value),
    Sent(bool),
}

pub(in crate::server) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("agent-inventory-watch") {
        return None;
    }
    let Ok(Value::Object(mut fields)) = serde_json::from_str::<Value>(message) else { return None };
    if fields.remove("cmd").as_ref().and_then(Value::as_str) != Some("agent-inventory-watch") {
        return None;
    }
    let id = fields.remove("id");
    let mut admission_receipt = false;
    let result = (|| {
        if !mux.agent_carrier_allowed(client) {
            return Err(Failure::NotTrusted);
        }
        let expected = fields
            .remove("expected_machine_id")
            .and_then(|v| v.as_str().map(str::to_owned))
            .ok_or(Failure::BadRequest)?;
        let expected = MachinePublicId::parse(expected).map_err(|_| Failure::BadRequest)?;
        if expected != mux.machine_public_id {
            return Err(Failure::OwnerMismatch);
        }
        let enabled =
            fields.remove("enabled").and_then(|v| v.as_bool()).ok_or(Failure::BadRequest)?;
        let expected_watch = match fields.remove("expected_watch_id") {
            None => None,
            Some(Value::String(value)) if !enabled && valid_watch_id(&value) => Some(value),
            _ => return Err(Failure::BadRequest),
        };
        let receipt = match fields.remove("admission_receipt") {
            None => false,
            Some(Value::Bool(value)) if enabled => value,
            _ => return Err(Failure::BadRequest),
        };
        if !fields.is_empty() || message.len() > 4096 {
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
        let spawned = std::thread::Builder::new()
            .name("mux-inventory-watch".into())
            .stack_size(256 * 1024)
            .spawn(move || {
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
