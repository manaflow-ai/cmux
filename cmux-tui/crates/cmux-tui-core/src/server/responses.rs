//! Error replies to raw protocol requests (moved out of server.rs, behavior
//! unchanged).

use serde_json::Value;

use super::{MessageWriter, Response, ResponseErrorDelivery};

/// Answers a request line that did not decode into a command. The reply
/// echoes the line's `id` whenever the line is a JSON object that carries
/// one: replies can arrive out of order, so a client matches each reply to
/// its request by id, and an id-less error would reach the wrong request.
pub(super) fn send_bad_request(
    writer: &MessageWriter,
    message: &str,
    error: &serde_json::Error,
) -> bool {
    send_request_error(writer, undecodable_request_id(message), &format!("bad request: {error}"))
}

/// The `id` member of a request line that failed to decode, if the line is a
/// JSON object.
fn undecodable_request_id(message: &str) -> Option<Value> {
    match serde_json::from_str::<Value>(message) {
        Ok(Value::Object(mut object)) => object.remove("id"),
        _ => None,
    }
}

pub(super) fn send_request_error(writer: &MessageWriter, id: Option<Value>, error: &str) -> bool {
    send_request_error_with_delivery(writer, id, error, None)
}

pub(super) fn send_request_error_with_delivery(
    writer: &MessageWriter,
    id: Option<Value>,
    error: &str,
    error_delivery: Option<ResponseErrorDelivery>,
) -> bool {
    send_response(
        writer,
        Response {
            id,
            ok: false,
            data: None,
            error: Some(error.to_string()),
            error_code: None,
            error_delivery,
        },
    )
}

pub(super) fn send_response(writer: &MessageWriter, response: Response) -> bool {
    serde_json::to_value(response).is_ok_and(|value| writer.send_control(&value).is_ok())
}

/// Sends `response` with the stable `reason` of a conversation reject next to
/// its `error_code` (home.md section 2), when there is one.
pub(super) fn send_response_with_reason(
    writer: &MessageWriter,
    response: Response,
    reason: Option<String>,
) -> bool {
    let Ok(mut value) = serde_json::to_value(response) else { return false };
    if let Some(reason) = reason {
        value["reason"] = Value::String(reason);
    }
    writer.send_control(&value).is_ok()
}
