//! `_acpmux/mail/*` durable inter-session mailbox RPCs.
//!
//! Mailbox state is local to one daemon. Remote Web/Peer callers are refused
//! until a federated route can preserve sender identity and delivery scope.

use super::*;
use crate::mailbox::{MailboxError, SendInput};
use serde_json::Value;
use std::collections::BTreeMap;

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    require_local_origin(conn.origin)?;
    match method {
        crate::rpc::method::MUX_MAIL_SEND => {
            let id = required_string(params, "id")?;
            let sender = required_string(params, "sender")?;
            require_attached(is_attached(conn, &sender), "send", &sender)?;
            let recipient = required_string(params, "recipient")?;
            let body = params
                .get("body")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::invalid_params("body is required"))?;
            let metadata = parse_metadata(params)?;
            let result = hub
                .mailbox()
                .send(SendInput { id, sender, recipient, body: body.to_owned(), metadata })
                .map_err(map_error)?;
            Ok(
                json!({"message": result.message, "delivery": result.receipt, "created": matches!(result.outcome, crate::mailbox::SendOutcome::Created), "duplicate": matches!(result.outcome, crate::mailbox::SendOutcome::Duplicate)}),
            )
        }
        crate::rpc::method::MUX_MAIL_READ | crate::rpc::method::MUX_MAIL_WAIT => {
            let recipient = required_string(params, "recipient")?;
            let operation =
                if method == crate::rpc::method::MUX_MAIL_WAIT { "wait" } else { "read" };
            require_attached(is_attached(conn, &recipient), operation, &recipient)?;
            let after = params.get("after").and_then(Value::as_u64).unwrap_or(0);
            let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(50) as usize;
            let page = if method == crate::rpc::method::MUX_MAIL_WAIT {
                let timeout_ms = params.get("timeoutMs").and_then(Value::as_u64).unwrap_or(10_000);
                hub.mailbox().wait(&recipient, after, limit, timeout_ms).await.map_err(map_error)?
            } else {
                hub.mailbox().page(&recipient, after, limit).map_err(map_error)?
            };
            Ok(
                json!({"cursor": page.cursor, "messages": page.rows.into_iter().map(|row| json!({"message": row.message, "delivery": row.delivery})).collect::<Vec<_>>(), "nextCursor": page.next_cursor}),
            )
        }
        crate::rpc::method::MUX_MAIL_ACK => {
            let recipient = required_string(params, "recipient")?;
            require_attached(is_attached(conn, &recipient), "ack", &recipient)?;
            let message_id = required_string(params, "messageId")?;
            let delivery = hub.mailbox().acknowledge(&recipient, &message_id).map_err(map_error)?;
            Ok(json!({"delivery": delivery}))
        }
        _ => Err(RpcError::method_not_found(method)),
    }
}

fn require_local_origin(origin: Origin) -> Result<(), RpcError> {
    if origin.web_class() {
        return Err(RpcError::invalid_params(
            "mailbox RPCs are available only on the local daemon",
        )
        .with_data(json!({"reason": "mailbox_remote_refused"})));
    }
    Ok(())
}

fn require_attached(attached: bool, operation: &str, session_id: &str) -> Result<(), RpcError> {
    if attached {
        return Ok(());
    }
    Err(RpcError::new(-32002, format!("mailbox {operation} requires an attached session"))
        .with_data(json!({"reason": "session_not_attached", "sessionId": session_id})))
}

fn is_attached(conn: &Conn, session_id: &str) -> bool {
    conn.subs.lock().unwrap().contains_key(session_id)
}

fn required_string(params: &Value, name: &str) -> Result<String, RpcError> {
    params
        .get(name)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| RpcError::invalid_params(format!("{name} is required")))
}

fn parse_metadata(params: &Value) -> Result<BTreeMap<String, Value>, RpcError> {
    match params.get("metadata") {
        None | Some(Value::Null) => Ok(BTreeMap::new()),
        Some(metadata) => serde_json::from_value(metadata.clone()).map_err(|e| {
            RpcError::invalid_params(format!("metadata must be an object: {e}"))
        }),
    }
}

fn map_error(error: MailboxError) -> RpcError {
    match error {
        MailboxError::Storage(error) => RpcError::internal(error.to_string()),
        MailboxError::NotFound(id) => {
            RpcError::not_found(format!("mailbox message {id} was not found"))
        }
        MailboxError::NotRecipient(id) => RpcError::invalid_params(format!(
            "the recipient cannot acknowledge mailbox message {id}"
        )),
        other => RpcError::invalid_params(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::{parse_metadata, require_attached, require_local_origin};
    use crate::server::Origin;
    use serde_json::json;

    #[test]
    fn remote_mailbox_rpc_is_rejected() {
        let error = require_local_origin(Origin::Web).expect_err("remote mailbox must fail closed");
        assert_eq!(error.code, -32602);
        assert_eq!(
            error.data.as_ref().map(|data| &data["reason"]),
            Some(&serde_json::json!("mailbox_remote_refused"))
        );
        assert!(require_local_origin(Origin::Peer).is_err());
    }

    #[test]
    fn local_mailbox_origins_are_allowed() {
        assert!(require_local_origin(Origin::Local).is_ok());
        assert!(require_local_origin(Origin::LocalApp).is_ok());
    }

    #[test]
    fn unbound_mailbox_rpc_is_rejected() {
        let error = require_attached(false, "ack", "session-b").expect_err("unbound ack must fail");
        assert_eq!(error.code, -32002);
        assert_eq!(
            error.data.as_ref().map(|data| &data["reason"]),
            Some(&serde_json::json!("session_not_attached"))
        );
    }
    #[test]
    fn attached_mailbox_rpc_is_allowed() {
        assert!(require_attached(true, "read", "session-b").is_ok());
    }

    #[test]
    fn detached_wait_reports_wait_operation() {
        let error =
            require_attached(false, "wait", "session-b").expect_err("detached wait must fail");
        assert!(error.message.contains("mailbox wait"));
    }

    #[test]
    fn null_metadata_is_normalized_to_empty_object() {
        let metadata = parse_metadata(&json!({"metadata": null})).expect("null is valid");
        assert!(metadata.is_empty());
    }

    #[test]
    fn non_object_metadata_is_rejected() {
        let error = parse_metadata(&json!({"metadata": "invalid"}))
            .expect_err("metadata must be an object");
        assert!(error.message.contains("metadata must be an object"));
    }
}
