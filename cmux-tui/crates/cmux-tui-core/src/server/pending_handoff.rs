//! Refusal of messages that arrive while a daemon handoff is reserved but
//! not yet acknowledged (moved out of server.rs, behavior unchanged). A
//! framed request gets the same refusal as its ERROR frame.

use serde::Deserialize;
use serde_json::{Value, json};

use super::frame_dispatch::FrameCall;
use super::responses::{send_bad_request, send_response};
use super::{
    DAEMON_SHUTDOWN_PENDING_CODE, MessageWriter, Request, ResourceError, Response,
    ResponseErrorDelivery, send_resource_response,
};

const PENDING_HANDOFF_ERROR: &str = "daemon shutdown is in progress; request was not executed";

/// The `cmd` of `Command::ClearHistory` (server/command_names.rs).
const CLEAR_HISTORY_CMD: &str = "clear-history";

/// The one member of a framed body the refusal echoes.
#[derive(Deserialize)]
struct BodyId {
    #[serde(default)]
    id: Option<Value>,
}

/// Refuses one message received while a daemon handoff is reserved but not
/// yet acknowledged. Nothing is parsed into a command or dispatched.
pub(super) fn reject_message_during_pending_handoff(message: &str, writer: &MessageWriter) -> bool {
    if let Some(call) = writer.frame_call() {
        return reject_frame_during_pending_handoff(call, message, writer);
    }
    if let Some(envelope) = crate::resource_router::parse_resource_line(message) {
        return match envelope.and_then(|envelope| {
            // Refused below, never dispatched: the actor is not recorded.
            crate::resource_router::validate_resource_envelope(envelope, crate::Actor::local_user())
        }) {
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
    match crate::line_parses::parse::<Request>(message) {
        Ok(request) => {
            send_pending_handoff_refusal(writer, request.id, request.cmd.is_clear_history())
        }
        Err(error) => send_bad_request(writer, message, &error),
    }
}

/// A framed request's refusal: the header already named a `Command` method
/// and its body names the same one (frame_dispatch.rs), so the body is not
/// parsed into a command; only its `id` is read, for a body equal to the line
/// refusal's.
fn reject_frame_during_pending_handoff(
    call: &FrameCall,
    body: &str,
    writer: &MessageWriter,
) -> bool {
    let id = crate::line_parses::parse::<BodyId>(body).ok().and_then(|body| body.id);
    send_pending_handoff_refusal(writer, id, call.method_name() == CLEAR_HISTORY_CMD)
}

/// The stable code lets a client wait for the shutdown notice that follows
/// instead of treating the refusal as a failure.
fn send_pending_handoff_refusal(
    writer: &MessageWriter,
    id: Option<Value>,
    is_clear_history: bool,
) -> bool {
    send_response(
        writer,
        Response {
            id,
            ok: false,
            data: None,
            error: Some(PENDING_HANDOFF_ERROR.to_string()),
            error_code: Some(DAEMON_SHUTDOWN_PENDING_CODE.to_string()),
            error_delivery: is_clear_history.then_some(ResponseErrorDelivery::KnownNotDelivered),
        },
    )
}

#[cfg(test)]
mod tests {
    use super::super::Command;
    use super::CLEAR_HISTORY_CMD;

    #[test]
    fn pending_handoff_clear_history_cmd_names_the_command() {
        let line = serde_json::json!({"cmd": CLEAR_HISTORY_CMD, "surface": 1});
        let command: Command = serde_json::from_value(line).unwrap();
        assert!(command.is_clear_history());
        assert_eq!(command.wire_name(), CLEAR_HISTORY_CMD);
    }
}
