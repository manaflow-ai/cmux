//! Refusal of messages that arrive while a daemon handoff is reserved but
//! not yet acknowledged (moved out of server.rs, behavior unchanged).

use super::*;

const PENDING_HANDOFF_ERROR: &str = "daemon shutdown is in progress; request was not executed";

/// Refuses one message received while a daemon handoff is reserved but not
/// yet acknowledged. Nothing is parsed into a command or dispatched.
pub(super) fn reject_message_during_pending_handoff(message: &str, writer: &MessageWriter) -> bool {
    if crate::resource_router::is_resource_protocol_message(message) {
        return match crate::resource_router::parse_resource_request(message) {
            Ok(request) => {
                let operation = request.envelope.operation;
                send_resource_response(
                    writer,
                    request.envelope.id,
                    operation,
                    Err(ResourceError::new(
                        "operation.failed",
                        PENDING_HANDOFF_ERROR,
                        json!({
                            "operation": operation.wire_name(),
                            "reason": "daemon_handoff_pending",
                        }),
                        false,
                    )),
                )
            }
            Err(error) => {
                let response = crate::resource_router::malformed_resource_response(message, error);
                writer.send_control(&response).is_ok()
            }
        };
    }
    match serde_json::from_str::<Request>(message) {
        Ok(request) => {
            let is_clear_history = request.cmd.is_clear_history();
            // The stable code lets a client wait for the shutdown notice
            // that follows instead of treating the refusal as a failure.
            send_response(
                writer,
                Response {
                    id: request.id,
                    ok: false,
                    data: None,
                    error: Some(PENDING_HANDOFF_ERROR.to_string()),
                    error_code: Some(DAEMON_SHUTDOWN_PENDING_CODE.to_string()),
                    error_delivery: is_clear_history
                        .then_some(ResponseErrorDelivery::KnownNotDelivered),
                },
            )
        }
        Err(error) => send_bad_request(writer, message, &error),
    }
}
