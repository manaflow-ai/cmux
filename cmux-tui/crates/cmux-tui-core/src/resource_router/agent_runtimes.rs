//! `agent.runtime.list`: the coding-agent processes of this user (RFC
//! #20149 phase 1), read from the operating system when the request
//! arrives. The daemon keeps no scanner, cache, or timer for it; a viewer
//! that wants fresh figures asks again.

use std::sync::Arc;

use serde_json::{Value, json};

use super::ParsedResourceRequest;
use super::auxiliary::resolve_session;
use crate::process_inventory::{MAX_INVENTORY_PROCESSES, scan};
use crate::resource::{ResourceError, WireDecimal};
use crate::runtime_inventory::{CmuxTerminal, Runtime, classify};
use crate::{Mux, SurfaceKind};

pub(super) fn list_runtimes(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let session_id = resolve_session(mux, &request.selectors)?;
    // Read the live terminals under the lock, then the OS outside it.
    let terminals = mux.with_state(|state| {
        state
            .surfaces
            .values()
            .filter(|surface| surface.kind() == SurfaceKind::Pty && !surface.is_dead())
            .filter_map(|surface| {
                Some(CmuxTerminal {
                    terminal_id: surface.terminal_public_id()?.as_str().to_string(),
                    pid: surface.process_id()?,
                })
            })
            .collect::<Vec<_>>()
    });
    let home = std::env::var("HOME").ok();
    let inventory = classify(&scan(MAX_INVENTORY_PROCESSES), &terminals, home.as_deref());
    Ok(json!({
        "session_id": session_id.as_str(),
        "complete": inventory.complete,
        "scanned_processes": inventory.scanned_processes,
        "runtimes": inventory.runtimes.into_iter().map(runtime_json).collect::<Vec<_>>(),
    }))
}

fn runtime_json(runtime: Runtime) -> Value {
    json!({
        "id": runtime.runtime_id,
        "vendor": runtime.vendor,
        "role": runtime.role,
        "pid": runtime.pid,
        "ppid": runtime.ppid,
        "started_at_ms": WireDecimal::new(runtime.started_ms),
        "executable_path": runtime.executable_path,
        "executable_version": runtime.executable_version,
        "args": runtime.args,
        "cpu_ns": runtime.cpu_ns.map(WireDecimal::new),
        "memory_bytes": runtime.memory_bytes.map(WireDecimal::new),
        "attribution": {
            "status": runtime.attribution.status,
            "source": runtime.attribution.source,
            "terminal_id": runtime.attribution.terminal_id,
        },
        "known_cmux_terminal_ids": runtime.known_cmux_clients,
        "total_clients": runtime.total_clients,
        "can_stop_safely": runtime.can_stop_safely,
    })
}
