//! `_acpmux/trace`: the cmux daemon's `trace-start`,
//! `trace-stop` and `trace-status` reach acpmux here. Params `{op: "start" |
//! "stop" | "status", categories?: u64}`; no path: acpmux records into
//! `$ACPMUX_HOME/trace`. The local unix socket
//! only: every WebSocket origin (Web, LocalApp, Peer) gets "Method not found".
//!
//! The answer is `{pid, state: "recording" | "idle", recording_path,
//! recording_bytes, records_dropped}` or `{pid, state: "error", error:
//! "not_initialized" | "already_recording" | "not_recording"}`
//! (cmux-tui-core `process_trace.rs` reads it).

use serde_json::{Value, json};

use crate::rpc::{RpcError, method};
use crate::server::Origin;
use cmux_trace::{ControlOp, Role, TraceError};

/// The call `params` names.
fn op_of(params: &Value) -> Result<ControlOp, RpcError> {
    match params.get("op").and_then(Value::as_str) {
        Some("start") => {
            let categories = params.get("categories").and_then(Value::as_u64).ok_or_else(|| {
                RpcError::invalid_params("start needs categories (a category bitset)")
            })?;
            Ok(ControlOp::Start { categories })
        }
        Some("stop") => Ok(ControlOp::Stop),
        Some("status") => Ok(ControlOp::Status),
        _ => Err(RpcError::invalid_params("op must be start, stop or status")),
    }
}

pub(crate) async fn handle(origin: Origin, params: &Value) -> Result<Value, RpcError> {
    if origin != Origin::Local {
        return Err(RpcError::method_not_found(method::MUX_TRACE));
    }
    let op = op_of(params)?;
    let dir = crate::config::home().join("trace");
    // The first start maps the recording file: off the runtime.
    let outcome =
        crate::daemon::spawn_blocking(move || cmux_trace::apply_control(op, &dir, Role::Acpmux))
            .await
            .map_err(|error| RpcError::internal(error.to_string()))?;
    Ok(answer(std::process::id(), outcome))
}

fn answer(pid: u32, outcome: Result<cmux_trace::Status, TraceError>) -> Value {
    match outcome {
        Ok(status) => json!({
            "pid": pid,
            "state": if status.recording { "recording" } else { "idle" },
            "recording_path": status.recording_path,
            "recording_bytes": status.recording_bytes,
            "records_dropped": status.records_dropped,
        }),
        Err(error) => json!({
            "pid": pid,
            "state": "error",
            "error": match error {
                TraceError::NotInitialized => "not_initialized",
                TraceError::AlreadyRecording => "already_recording",
                TraceError::NotRecording => "not_recording",
            },
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trace_ops_parse_and_carry_no_path() {
        assert_eq!(
            op_of(&json!({"op": "start", "categories": 64, "path": "/etc"})).ok(),
            Some(ControlOp::Start { categories: 64 })
        );
        assert_eq!(op_of(&json!({"op": "stop"})).ok(), Some(ControlOp::Stop));
        assert_eq!(op_of(&json!({"op": "status"})).ok(), Some(ControlOp::Status));
        assert!(op_of(&json!({"op": "start"})).is_err());
        assert!(op_of(&json!({"op": "record"})).is_err());
    }

    #[tokio::test]
    async fn trace_is_refused_off_the_local_socket() {
        for origin in [Origin::Web, Origin::LocalApp] {
            let error = handle(origin, &json!({"op": "status"})).await.unwrap_err();
            assert_eq!(error.code, RpcError::method_not_found(method::MUX_TRACE).code);
        }
        // Refused before this process's tracer was asked anything.
        assert!(cmux_trace::status().is_none());
    }

    #[test]
    fn trace_answers_name_the_ring_or_the_error() {
        let refused = answer(7, Err(TraceError::NotInitialized));
        assert_eq!(refused, json!({"pid": 7, "state": "error", "error": "not_initialized"}));
    }
}
