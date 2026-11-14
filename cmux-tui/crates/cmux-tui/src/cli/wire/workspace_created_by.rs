//! `workspace create` from a cmux terminal against a daemon without
//! `workspace-created-by-v1`: an older daemon refuses an unknown field, so
//! the CLI drops `created_by` and the workspace goes where it did before.
//! `wire::run_once` and the agents/MCP transport (`mcp/transport.rs`) both
//! send through here.

use std::io::BufReader;
use std::path::Path;

use serde_json::Value;

use cmux_tui_core::platform::transport;
use cmux_tui_core::server::WORKSPACE_CREATED_BY_CAPABILITY;

/// Removes `created_by` from a `workspace.create` request the daemon cannot
/// take; true when the request changed.
pub(in crate::cli) fn drop_unsupported(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    socket: &Path,
    request: &mut Value,
) -> bool {
    if request["operation"] != "workspace.create"
        || request["params"].get("created_by").is_none()
        || super::super::launch_credential::advertises(
            reader,
            socket,
            WORKSPACE_CREATED_BY_CAPABILITY,
        )
    {
        return false;
    }
    request
        .get_mut("params")
        .and_then(Value::as_object_mut)
        .is_some_and(|params| params.remove("created_by").is_some())
}
